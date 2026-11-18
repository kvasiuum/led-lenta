import Foundation
import AVFoundation
import UIKit

/// Светомузыка: детектор бита + Радуга / Мой цвет / Вспышки, отправка на ленту ≤ 25 раз в секунду.
/// Часы — таймер GCD каждые 10 мс: работает и в фоне, пока играет звук или слушает микрофон.
final class LightEngine: ObservableObject {
    private var s: Services { .shared }

    enum Mode: String, CaseIterable, Codable, Identifiable {
        case rainbow, mono, strobe
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rainbow: return "Радуга"
            case .mono: return "Мой цвет"
            case .strobe: return "Вспышки"
            }
        }
    }

    @Published private(set) var running = false
    @Published var mode: Mode = Prefs.get("mode", Mode.rainbow) {
        didSet { Prefs.set("mode", mode); if s.app.now == .music { s.app.setNow(.music) } }
    }
    @Published var sens: Double = Prefs.get("sens", 6.0) { didSet { Prefs.set("sens", sens) } }
    @Published var smooth: Double = Prefs.get("smooth", 6.0) { didSet { Prefs.set("smooth", smooth) } }
    @Published var keepAwake: Bool = Prefs.get("keepAwake", true) {
        didSet { Prefs.set("keepAwake", keepAwake); applyIdle() }
    }

    var sensValue: Int { clamp(Int(sens.rounded()), 1, 10) }

    // MARK: состояние цикла (всё на main)
    private enum Path { case idle, mic, file, sc }
    private var path: Path = .idle
    private var timer: DispatchSourceTimer?

    private var loudAvg = 0.0, lastBeat = -1e12, lastSend = -1e12
    private var level = 0.0, hue = 0.0, hueTarget = 0.0, beatPeak = 1.0
    private var bdPrev: [Double] = [], bdRatios: [Double] = [], bdPeak = 0.0
    private var lastTick: Double?
    private var waveIdx = -1, lastBeatNo = -1
    private var lastHop = -1
    private var lastUI = 0.0

    // микрофон
    private var micAnalyzer: StreamAnalyzer?
    private var micHop = 0

    // MARK: - Когда работать

    /// Пересчитать, нужен ли цикл и откуда брать звук
    func refresh() {
        let music = s.music
        let cur = s.player.current
        let newPath: Path
        if music.micActive { newPath = .mic }
        else if let c = cur, c.source == .file, s.files.isPlaying, s.files.trackID == c.id { newPath = .file }
        else if let c = cur, c.source != .file, s.web.playing, s.web.trackID == c.id { newPath = .sc }
        else { newPath = .idle }

        if newPath != path {
            path = newPath
            resetState()
            if newPath == .mic {
                micAnalyzer = StreamAnalyzer(sampleRate: music.mic.sampleRate)
                micHop = 0
            } else {
                micAnalyzer = nil
            }
        }
        if newPath == .idle { stop() } else { start() }
    }

    /// Новая форма волны: сетку ударов считаем заново
    func waveChanged() { lastBeatNo = -1 }

    private func resetState() {
        loudAvg = 0; level = 0; bdPrev = []; bdRatios = []; bdPeak = 0
        lastTick = nil; lastBeat = -1e12; lastSend = -1e12
        hue = s.app.hs.h; hueTarget = hue
        lastBeatNo = -1; waveIdx = -1; lastHop = -1
    }

    private func start() {
        guard !running else { return }
        s.app.stopAutoFx()
        resetState()
        running = true
        s.app.setNow(.music)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        applyIdle()
    }

    private func stop() {
        guard running else { return }
        timer?.cancel()
        timer = nil
        running = false
        s.live.level = 0
        applyIdle()
        s.app.sendColor(s.app.currentRGB)          // обратно к выбранному цвету
        s.app.setNow(.color)
    }

    /// Не гасить экран, пока работает светомузыка
    private func applyIdle() {
        UIApplication.shared.isIdleTimerDisabled = running && keepAwake
    }

    // MARK: - Один такт

    private func tick() {
        let wall = nowMs()
        switch path {
        case .mic: tickMic()
        case .file: tickFile()
        case .sc: tickSC(wall)
        case .idle: return
        }
        output(wall)
    }

    private func tickMic() {
        guard let an = micAnalyzer else { return }
        let samples = s.music.mic.drain()
        if samples.isEmpty { return }
        for f in an.feed(samples) {
            let t = Double(micHop) * Double(StreamAnalyzer.hop) / an.sampleRate * 1000
            micHop += 1
            stepFeature(f, t: t)
        }
    }

    private func tickFile() {
        let eng = s.files
        guard let player = eng.player, let an = eng.analysis else { return }
        let sr = an.sampleRate
        // что слышно сейчас: позиция минус задержка вывода, плюс запас на Bluetooth ленты
        let latency = AVAudioSession.sharedInstance().outputLatency
        let pos = player.currentTime - latency + 0.09
        let hop = Int(max(0, pos) * sr / Double(StreamAnalyzer.hop))
        if hop < lastHop || hop - lastHop > 60 {           // перемотка — начинаем заново
            resetState()
            lastHop = hop - 1
        }
        if hop >= an.features.count {
            // разбор ещё не дошёл до этого места — ровный пульс 120 BPM
            if hop != lastHop {
                lastHop = hop
                let ms = pos * 1000
                let ph = ms.truncatingRemainder(dividingBy: 500) / 500
                let beat = ph < 0.08 && ms - lastBeat > 300
                if beat { lastBeat = ms }
                beatPeak = 1
                common(t: ms, beat: beat, body: 0.4)
            }
            return
        }
        while lastHop < hop {
            lastHop += 1
            let t = Double(lastHop) * Double(StreamAnalyzer.hop) / sr * 1000
            stepFeature(an.features[lastHop], t: t)
        }
    }

    /// Детектор бочки по басовой полосе: RMS сравнивается с последними ~90 мс и ~1.5 с
    private func stepFeature(_ f: HopFeature, t: Double) {
        let loud = Double(f.loud)
        loudAvg = loudAvg > 0 ? loudAvg * 0.99 + loud * 0.01 : loud
        let body = clamp(loud / max(loudAvg * 1.6, 1), 0, 1)

        let e = Double(f.bass[sensValue - 1])
        bdPeak = max(e, bdPeak * 0.9985)
        let before = bdPrev.isEmpty ? e : bdPrev.reduce(0, +) / Double(bdPrev.count)
        bdPrev.append(e); if bdPrev.count > 8 { bdPrev.removeFirst() }
        let r = e / max(before, 1e-4)
        let m = bdRatios.isEmpty ? 1 : bdRatios.reduce(0, +) / Double(bdRatios.count)
        let sd = bdRatios.isEmpty ? 0 : sqrt(bdRatios.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(bdRatios.count))
        bdRatios.append(r); if bdRatios.count > 140 { bdRatios.removeFirst() }
        let beat = r > max(1.25, m + 1.2 * sd) && e > bdPeak * 0.3 && e > 0.004 && t - lastBeat > 250
        beatPeak = 1
        if beat {
            lastBeat = t
            beatPeak = 0.45 + 0.55 * clamp(e / max(bdPeak, 1e-4), 0, 1)
        }
        common(t: t, beat: beat, body: body)
    }

    /// Встроенные плееры без микрофона: форма волны SoundCloud + сетка темпа, иначе ровный ритм
    private func tickSC(_ t: Double) {
        let sc = s.web, wave = sc.wave
        let sensV = sensValue
        let pos = sc.nowPos() + 90                        // небольшой запас на задержку Bluetooth
        var beat = false, body = 0.0
        beatPeak = 1
        if wave.ready, let n = wave.n, let onset = wave.onset, sc.dur > 0, !n.isEmpty {
            let i = clamp(Int(pos / sc.dur * Double(n.count)), 0, n.count - 1)
            body = n[i]
            if let tempo = wave.tempo {
                // удары берутся из сетки темпа, поэтому попадают в бит, а не в каждое колебание громкости
                let no = Int(((pos - tempo.phaseMs) / tempo.periodMs).rounded(.down))
                if no != lastBeatNo {
                    let every = sensV >= 4 ? 1 : 2                  // низкая чувствительность: через удар
                    beat = lastBeatNo != -1 && no % every == 0 && body > 0.12
                    lastBeatNo = no
                    beatPeak = 0.35 + 0.65 * body                 // тихие места мигают мягко, дропы — сильно
                    if sensV <= 3 && body < 0.45 { beat = false }
                }
            } else if i != waveIdx {
                waveIdx = i
                beat = onset[i] > 0.26 - Double(sensV) * 0.019 && body > 0.25 && t - lastBeat > 250
            }
        } else {
            let ph = pos.truncatingRemainder(dividingBy: 500) / 500  // нет формы волны: ровно 120 BPM
            beat = ph < 0.08 && t - lastBeat > 300
            body = 0.4
        }
        if beat { lastBeat = t }
        common(t: t, beat: beat, body: body)
    }

    private func common(t: Double, beat: Bool, body: Double) {
        let sm = smooth                                         // 1 = резко … 10 = плавно
        let dk = clamp(lastTick.map { (t - $0) / 21.3 } ?? 1, 0.2, 4)
        lastTick = t
        if mode == .strobe {
            level = beat ? 1 : level * pow(0.72, dk)
        } else {
            level = beat ? max(level, beatPeak) : max(level * pow(0.86 + sm * 0.011, dk), 0.12 + body * 0.45)
        }
        if mode == .rainbow {
            if beat { hueTarget += 64 - sm * 4.4 }             // 1 → 60° за бит, 10 → 20°
            hueTarget += 0.12 * dk
            hue += (hueTarget - hue) * (1 - pow(1 - (0.24 - sm * 0.019), dk))
            if hue > 1e5 { hue -= 36000; hueTarget -= 36000 }
        }
    }

    private func output(_ wall: Double) {
        let base = s.app.currentRGB
        let full: RGB
        switch mode {
        case .rainbow: full = hsv2rgb(hue, 1, 1)
        case .mono: full = base
        case .strobe: full = .white
        }
        if wall - lastUI >= 33 {
            lastUI = wall
            s.live.level = level
            s.live.rgb = full
        }
        guard wall - lastSend >= 40, s.ble.isConnected else { return }   // ≈ 25 команд в секунду
        lastSend = wall
        let rgb = mode == .rainbow ? hsv2rgb(hue, 1, level) : full.scaled(level)
        s.app.sendColor(rgb)
    }
}
