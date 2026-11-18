import Foundation

/// Публичная форма волны трека SoundCloud (картинка громкости, которую показывает сам SoundCloud).
/// Зная позицию воспроизведения, по ней можно светить без микрофона.
final class WaveState {
    var key: String?
    var n: [Double]?
    var onset: [Double]?
    var tempo: Tempo?
    var ready = false
    var failed = false

    struct Tempo {
        let bpm: Double
        let periodMs: Double
        let phaseMs: Double
    }

    func reset(failed: Bool = false) {
        key = nil; n = nil; onset = nil; tempo = nil; ready = false; self.failed = failed
    }
}

enum WaveformLoader {
    struct Result {
        let n: [Double]
        let onset: [Double]
        let tempo: WaveState.Tempo?
    }

    /// waveform_url …png → …json, нормировка, всплески громкости и сетка темпа
    static func load(waveURL: String, durationMs: Double) async -> Result? {
        var u = waveURL
        if let r = u.range(of: #"\.png(\?.*)?$"#, options: .regularExpression) { u.replaceSubrange(r, with: ".json") }
        guard let url = URL(string: u),
              let res = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any],
              let rawAny = obj["samples"] as? [Any], !rawAny.isEmpty else { return nil }
        let raw = rawAny.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard !raw.isEmpty else { return nil }
        let sorted = raw.sorted()
        let lo = sorted[Int(Double(sorted.count) * 0.1)]
        var hi = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.97))]
        if hi == 0 { hi = 1 }
        let n = raw.map { clamp(($0 - lo) / max(hi - lo, 1), 0, 1) }
        let onset: [Double] = n.indices.map { i in
            var m = 0.0, c = 0.0
            var k = max(0, i - 4)
            while k < i { m += n[k]; c += 1; k += 1 }
            return c > 0 ? n[i] - m / c : 0
        }
        let tempo = durationMs > 0 ? analyseTempo(n, msPer: durationMs / Double(n.count)) : nil
        return Result(n: n, onset: onset, tempo: tempo)
    }

    /// Темп и фаза: перебираем сетку ударов (BPM, сдвиг) и смотрим, насколько она попадает в нарастания громкости
    static func analyseTempo(_ n: [Double], msPer: Double) -> WaveState.Tempo? {
        let L = n.count
        let o: [Double] = n.indices.map { $0 > 0 ? max(0, n[$0] - n[$0 - 1]) : 0 }
        func val(_ x: Double) -> Double {
            let i = Int(x), f = x - Double(i)
            return i + 1 < L ? o[i] * (1 - f) + o[i + 1] * f : 0
        }
        func prior(_ bpm: Double) -> Double { exp(-pow(log2(bpm / 120), 2) / 0.5) }    // предпочитаем 85–170 BPM
        func score(_ per: Double, _ ph: Double) -> Double {
            var s = 0.0, c = 0.0, x = ph
            while x < Double(L) { s += val(x); c += 1; x += per }
            return c > 0 ? s / c : 0
        }
        struct Best { var sc = -1.0, bpm = 0.0, per = 0.0, ph = 0.0 }
        func search(_ lo: Double, _ hi: Double, _ step: Double, _ phases: Int) -> Best {
            var best = Best()
            var bpm = lo
            while bpm <= hi + 1e-9 {
                let per = 60000 / bpm / msPer
                if per >= 1.5 {
                    for k in 0..<phases {
                        let ph = per * Double(k) / Double(phases)
                        let sc = score(per, ph) * prior(bpm)
                        if sc > best.sc { best = Best(sc: sc, bpm: bpm, per: per, ph: ph) }
                    }
                }
                bpm += step
            }
            return best
        }
        let coarse = search(70, 180, 0.5, 16)
        guard coarse.sc > 0 else { return nil }
        let fine = search(max(60, coarse.bpm - 1), coarse.bpm + 1, 0.02, 48)
        // сэмпл формы волны покрывает целое окно; удар в среднем в его середине
        return WaveState.Tempo(bpm: fine.bpm, periodMs: fine.per * msPer, phaseMs: (fine.ph + 0.5) * msPer)
    }
}
