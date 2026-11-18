import Foundation
import AVFoundation
import UIKit
import QuartzCore

/// Светомузыка: детектор бита + Радуга / Мой цвет / Вспышки, отправка на ленту.
///
/// Работает на своём потоке, а не в главном: анимации интерфейса больше не задерживают свет.
/// Такты идут с вертикальной синхронизацией (CADisplayLink, 60–120 Гц) — ровно в такт кадрам экрана;
/// когда приложение свёрнуто и экрана нет, их ведёт таймер каждые 8 мс.
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
        didSet { Prefs.set("mode", mode); pushConfig(); if s.app.now == .music { s.app.setNow(.music) } }
    }
    @Published var sens: Double = Prefs.get("sens", 6.0) { didSet { Prefs.set("sens", sens); pushConfig() } }
    @Published var smooth: Double = Prefs.get("smooth", 6.0) { didSet { Prefs.set("smooth", smooth); pushConfig() } }
    @Published var keepAwake: Bool = Prefs.get("keepAwake", true) {
        didSet { Prefs.set("keepAwake", keepAwake); applyIdle() }
    }
    /// Насколько раньше показывать свет (мс): компенсирует задержку Bluetooth ленты
    @Published var leadMs: Double = Prefs.get("leadMs", 160.0) { didSet { Prefs.set("leadMs", leadMs); pushConfig() } }

    var sensValue: Int { clamp(Int(sens.rounded()), 1, 10) }

    // MARK: - Снимок состояния для потока света (собирается в главном потоке 20 раз в секунду)

    enum Path { case idle, mic, file, web }

    struct WebSnap {
        var pos = 0.0, posAt = 0.0, playing = false, dur = 0.0
        var n: [Double]?, onset: [Double]?, tempo: WaveState.Tempo?, ready = false
    }

    private struct Cfg {
        var path: Path = .idle
        var mode: Mode = .rainbow
        var sens = 6
        var smooth = 6.0
        var lead = 160.0
        var base = RGB.red
        var hue0 = 0.0
        var order = "GRB"
        var gamma = true
        var connected = false
        var latency = 0.0
        var player: AVAudioPlayer?
        var analysis: FileAnalysis?
        var web = WebSnap()
        var micRate = 48000.0
    }

    private let cfgLock = NSLock()
    private var cfgShared = Cfg()
    private var path: Path = .idle                       // main
    private var cfgTimer: Timer?                         // main, 20 Гц
    private let clock = LightClock()

    // MARK: состояние цикла (только поток света)
    private var lastPath: Path = .idle
    private var loudAvg = 0.0, lastBeat = -1e12, lastSend = -1e12
    private var level = 0.0, hue = 0.0, hueTarget = 0.0, beatPeak = 1.0
    private var bdPrev: [Double] = [], bdRatios: [Double] = [], bdPeak = 0.0
    private var lastTick: Double?
    private var waveIdx = -1, lastBeatNo = -1
    private var lastHop = -1
    private var lastUI = 0.0
    private var beatPending = false
    private var micAnalyzer: StreamAnalyzer?
    private var micHop = 0
    private var resetBeatGrid = false

    init() {
        clock.onTick = { [weak self] in self?.tick() }
    }

    // MARK: - Когда работать (главный поток)

    func refresh() {
        let cur = s.player.current
        let newPath: Path
        if s.music.micActive { newPath = .mic }
        else if let c = cur, c.source == .file, s.files.isPlaying, s.files.trackID == c.id { newPath = .file }
        else if let c = cur, c.source != .file, s.web.playing, s.web.trackID == c.id { newPath = .web }
        else { newPath = .idle }
        path = newPath
        pushConfig()
        if newPath == .idle { stop() } else { start() }
    }

    /// Новая форма волны: сетку ударов считаем заново
    func waveChanged() {
        cfgLock.lock(); resetBeatGrid = true; cfgLock.unlock()
        pushConfig()
    }

    /// Собрать снимок настроек и источников для потока света
    func pushConfig() {
        var c = Cfg()
        c.path = path
        c.mode = mode
        c.sens = sensValue
        c.smooth = smooth
        c.lead = leadMs
        c.base = s.app.currentRGB
        c.hue0 = s.app.hs.h
        c.order = s.app.order
        c.gamma = s.app.gamma
        c.connected = s.ble.isConnected
        c.latency = AVAudioSession.sharedInstance().outputLatency
        c.player = s.files.player
        c.analysis = s.files.analysis
        c.web = s.web.lightSnap()
        c.micRate = s.music.mic.sampleRate
        cfgLock.lock(); cfgShared = c; cfgLock.unlock()
    }

    private func start() {
        guard !running else { return }
        s.app.stopAutoFx()
        running = true
        s.app.setNow(.music)
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pushConfig() }
        RunLoop.main.add(t, forMode: .common)
        cfgTimer = t
        clock.start()
        applyIdle()
    }

    private func stop() {
        guard running else { return }
        cfgTimer?.invalidate()
        cfgTimer = nil
        running = false
        applyIdle()
        // сначала останавливаем такты, потом возвращаем выбранный цвет — чтобы последний кадр не перебил его
        clock.stop { [weak self] in
            guard let self else { return }
            self.s.live.level = 0
            if !self.running {
                self.s.app.sendColor(self.s.app.currentRGB)
                self.s.app.setNow(.color)
            }
        }
    }

    private func applyIdle() {
        UIApplication.shared.isIdleTimerDisabled = running && keepAwake
    }

    // MARK: - Такт (поток света)

    private func tick() {
        cfgLock.lock()
        let c = cfgShared
        let regrid = resetBeatGrid
        resetBeatGrid = false
        cfgLock.unlock()
        if regrid { lastBeatNo = -1 }

        if c.path != lastPath {
            lastPath = c.path
            resetState(c)
            if c.path == .mic { micAnalyzer = StreamAnalyzer(sampleRate: c.micRate); micHop = 0 } else { micAnalyzer = nil }
        }
        let wall = nowMs()
        switch c.path {
        case .mic: tickMic(c)
        case .file: tickFile(c)
        case .web: tickWeb(c, wall)
        case .idle: return
        }
        output(c, wall)
    }

    private func resetState(_ c: Cfg) {
        loudAvg = 0; level = 0; bdPrev = []; bdRatios = []; bdPeak = 0
        lastTick = nil; lastBeat = -1e12; lastSend = -1e12
        hue = c.hue0; hueTarget = hue
        lastBeatNo = -1; waveIdx = -1; lastHop = -1
    }

    private func tickMic(_ c: Cfg) {
        guard let an = micAnalyzer else { return }
        let samples = s.music.mic.drain()
        if samples.isEmpty { return }
        for f in an.feed(samples) {
            let t = Double(micHop) * Double(StreamAnalyzer.hop) / an.sampleRate * 1000
            micHop += 1
            stepFeature(f, t: t, c)
        }
    }

    private func tickFile(_ c: Cfg) {
        guard let player = c.player, let an = c.analysis else { return }
        let sr = an.sampleRate
        // что слышно сейчас: позиция минус задержка вывода, плюс запас на Bluetooth ленты
        let pos = player.currentTime - c.latency + c.lead / 1000
        let hop = Int(max(0, pos) * sr / Double(StreamAnalyzer.hop))
        if hop < lastHop || hop - lastHop > 60 {           // перемотка — начинаем заново
            resetState(c)
            lastHop = hop - 1
        }
        let count = an.count
        if hop >= count {
            // разбор ещё не дошёл до этого места — ровный пульс 120 BPM
            if hop != lastHop {
                lastHop = hop
                let ms = pos * 1000
                let ph = ms.truncatingRemainder(dividingBy: 500) / 500
                let beat = ph < 0.08 && ms - lastBeat > 300
                if beat { lastBeat = ms }
                beatPeak = 1
                common(t: ms, beat: beat, body: 0.4, c)
            }
            return
        }
        guard hop > lastHop else { return }
        let feats = an.slice(lastHop + 1..<hop + 1)
        for f in feats {
            lastHop += 1
            let t = Double(lastHop) * Double(StreamAnalyzer.hop) / sr * 1000
            stepFeature(f, t: t, c)
        }
    }

    /// Детектор бочки по басовой полосе: RMS сравнивается с последними ~90 мс и ~1.5 с
    private func stepFeature(_ f: HopFeature, t: Double, _ c: Cfg) {
        let loud = Double(f.loud)
        loudAvg = loudAvg > 0 ? loudAvg * 0.99 + loud * 0.01 : loud
        let body = clamp(loud / max(loudAvg * 1.6, 1), 0, 1)

        let e = Double(f.bass[c.sens - 1])
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
        common(t: t, beat: beat, body: body, c)
    }

    /// Встроенные плееры: форма волны SoundCloud + сетка темпа, иначе ровный ритм
    private func tickWeb(_ c: Cfg, _ t: Double) {
        let w = c.web
        let sensV = c.sens
        let now = w.playing ? w.pos + (t - w.posAt) : w.pos
        // что слышно сейчас (минус задержка наушников) + запас на задержку ленты
        let pos = now - c.latency * 1000 + c.lead
        var beat = false, body = 0.0
        beatPeak = 1
        if w.ready, let n = w.n, let onset = w.onset, w.dur > 0, !n.isEmpty {
            let i = clamp(Int(pos / w.dur * Double(n.count)), 0, n.count - 1)
            body = n[i]
            if let tempo = w.tempo {
                // удары из сетки темпа — попадают в бит, а не в каждое колебание громкости
                let no = Int(((pos - tempo.phaseMs) / tempo.periodMs).rounded(.down))
                if no != lastBeatNo {
                    let every = sensV >= 4 ? 1 : 2
                    beat = lastBeatNo != -1 && no % every == 0 && body > 0.12
                    lastBeatNo = no
                    beatPeak = 0.35 + 0.65 * body
                    if sensV <= 3 && body < 0.45 { beat = false }
                }
            } else if i != waveIdx {
                waveIdx = i
                beat = onset[i] > 0.26 - Double(sensV) * 0.019 && body > 0.25 && t - lastBeat > 250
            }
        } else {
            let ph = pos.truncatingRemainder(dividingBy: 500) / 500   // нет формы волны: ровно 120 BPM
            beat = ph < 0.08 && t - lastBeat > 300
            body = 0.4
        }
        if beat { lastBeat = t }
        common(t: t, beat: beat, body: body, c)
    }

    private func common(t: Double, beat: Bool, body: Double, _ c: Cfg) {
        let sm = c.smooth                                        // 1 = резко … 10 = плавно
        let dk = clamp(lastTick.map { (t - $0) / 21.3 } ?? 1, 0.2, 4)
        lastTick = t
        if beat { beatPending = true }
        if c.mode == .strobe {
            level = beat ? 1 : level * pow(0.72, dk)
        } else {
            level = beat ? max(level, beatPeak) : max(level * pow(0.86 + sm * 0.011, dk), 0.12 + body * 0.45)
        }
        if c.mode == .rainbow {
            if beat { hueTarget += 64 - sm * 4.4 }              // 1 → 60° за бит, 10 → 20°
            hueTarget += 0.12 * dk
            hue += (hueTarget - hue) * (1 - pow(1 - (0.24 - sm * 0.019), dk))
            if hue > 1e5 { hue -= 36000; hueTarget -= 36000 }
        }
    }

    private func output(_ c: Cfg, _ wall: Double) {
        let full: RGB
        switch c.mode {
        case .rainbow: full = hsv2rgb(hue, 1, 1)
        case .mono: full = c.base
        case .strobe: full = .white
        }
        // превью на экране — не чаще 60 раз в секунду
        if wall - lastUI >= 16 {
            lastUI = wall
            let l = level
            DispatchQueue.main.async {
                let live = Services.shared.live
                live.level = l
                if live.rgb != full { live.rgb = full }
            }
        }
        // ≈ 25 команд в секунду, но удар уходит сразу
        let due = wall - lastSend >= 40 || (beatPending && wall - lastSend >= 12)
        guard due, c.connected else { return }
        lastSend = wall
        beatPending = false
        let rgb = c.mode == .rainbow ? hsv2rgb(hue, 1, level) : full.scaled(level)
        let v = Self.strip(rgb, order: c.order, gamma: c.gamma)
        s.ble.send("color", Cmd.color(v[0], v[1], v[2]))
    }

    static func strip(_ c: RGB, order: String, gamma: Bool) -> [UInt8] {
        var r = clamp(c.r, 0, 255), g = clamp(c.g, 0, 255), b = clamp(c.b, 0, 255)
        if gamma { r = gammaTable[r]; g = gammaTable[g]; b = gammaTable[b] }
        let map: [Character: Int] = ["R": r, "G": g, "B": b]
        return order.map { UInt8(map[$0] ?? 0) }
    }
}

/// Часы светомузыки на своём потоке: CADisplayLink (вертикальная синхронизация) на экране,
/// таймер 8 мс в фоне. Всё, что делает onTick, выполняется на этом потоке по очереди.
final class LightClock: NSObject {
    var onTick: (() -> Void)?

    private var thread: Thread?
    private var link: CADisplayLink?
    private var timer: Timer?
    private var active = false

    func start() {
        if thread == nil {
            let t = Thread { [weak self] in self?.runLoop() }
            t.name = "lenta.light"
            t.qualityOfService = .userInteractive
            thread = t
            t.start()
            NotificationCenter.default.addObserver(self, selector: #selector(appChanged), name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(appChanged), name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        let fg = UIApplication.shared.applicationState != .background
        perform(#selector(begin(_:)), on: thread!, with: NSNumber(value: fg), waitUntilDone: false)
    }

    /// Остановить такты; done — на главном потоке, когда последний такт уже прошёл
    func stop(_ done: @escaping () -> Void) {
        guard let t = thread else { done(); return }
        perform(#selector(end(_:)), on: t, with: DoneBox(done), waitUntilDone: false)
    }

    private func runLoop() {
        let rl = RunLoop.current
        rl.add(Port(), forMode: .default)          // держит цикл живым
        while !Thread.current.isCancelled {
            _ = autoreleasepool { rl.run(mode: .default, before: .distantFuture) }
        }
    }

    @objc private func appChanged() {
        guard active, let t = thread else { return }
        let fg = UIApplication.shared.applicationState != .background
        perform(#selector(begin(_:)), on: t, with: NSNumber(value: fg), waitUntilDone: false)
    }

    // ниже — только на потоке света

    @objc private func begin(_ fg: NSNumber) {
        active = true
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
        if fg.boolValue {
            let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .current, forMode: .default)
            link = l
        } else {
            let t = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in self?.onTick?() }
            RunLoop.current.add(t, forMode: .default)
            timer = t
        }
    }

    @objc private func end(_ box: DoneBox) {
        active = false
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
        let done = box.done
        DispatchQueue.main.async { done() }
    }

    @objc private func frame(_ l: CADisplayLink) {
        onTick?()
    }

    private final class DoneBox: NSObject {
        let done: () -> Void
        init(_ d: @escaping () -> Void) { done = d }
    }
}
