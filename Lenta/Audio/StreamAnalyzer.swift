import Foundation
import Accelerate

/// «Чувствительность к биту»: 10 → слушаем бас до 80 Гц (только бочка), 1 → до 200 Гц
func sensHz(_ v: Int) -> Double { (200 - Double(clamp(v, 1, 10) - 1) * 120 / 9).rounded() }

/// Признаки одного шага в 512 сэмплов: громкость 0–8 кГц (0…255, как getByteFrequencyData)
/// и RMS басовой полосы для каждого из 10 положений чувствительности.
struct HopFeature {
    var loud: Float
    var bass: [Float]
}

/// Биквадратный фильтр по формулам Web Audio (Q для НЧ/ВЧ — в децибелах)
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func lowpass(_ f: Double, sr: Double, qdB: Double = 0.7) -> Biquad {
        var q = Biquad()
        let w0 = 2 * Double.pi * f / sr, cw = cos(w0)
        let alpha = sin(w0) / (2 * pow(10, qdB / 20))
        let a0 = 1 + alpha
        q.b0 = Float((1 - cw) / 2 / a0); q.b1 = Float((1 - cw) / a0); q.b2 = q.b0
        q.a1 = Float(-2 * cw / a0); q.a2 = Float((1 - alpha) / a0)
        return q
    }

    static func highpass(_ f: Double, sr: Double, qdB: Double = 0.7) -> Biquad {
        var q = Biquad()
        let w0 = 2 * Double.pi * f / sr, cw = cos(w0)
        let alpha = sin(w0) / (2 * pow(10, qdB / 20))
        let a0 = 1 + alpha
        q.b0 = Float((1 + cw) / 2 / a0); q.b1 = Float(-(1 + cw) / a0); q.b2 = q.b0
        q.a1 = Float(-2 * cw / a0); q.a2 = Float((1 - alpha) / a0)
        return q
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Поток моно-сэмплов → признаки каждые 512 сэмплов.
/// Повторяет то, что делал Web Audio: анализатор FFT 2048 (окно Блэкмана, сглаживание 0.4, −90…−10 дБ)
/// и цепочку ВЧ 30 Гц → 3×НЧ на частоте чувствительности → RMS последних 512 сэмплов.
final class StreamAnalyzer {
    static let hop = 512
    static let fftN = 2048
    private static let log2n = vDSP_Length(11)

    let sampleRate: Double
    private let l1: Int
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: fftN)
    private var hist = [Float](repeating: 0, count: fftN)
    private var windowed = [Float](repeating: 0, count: fftN)
    private var re = [Float](repeating: 0, count: fftN / 2)
    private var im = [Float](repeating: 0, count: fftN / 2)
    private var mags = [Float](repeating: 0, count: fftN / 2)
    private var smoothed = [Float](repeating: 0, count: fftN / 2)
    private var acc: [Float] = []
    private var hp: Biquad
    private var lp: [Biquad]          // 10 положений × 3 ступени

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        l1 = max(1, min(Self.fftN / 2 - 1, Int((8000 / (sampleRate / Double(Self.fftN))).rounded())))
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        let n = Float(Self.fftN)
        for i in 0..<Self.fftN {
            let x = Float(i) / n
            window[i] = 0.42 - 0.5 * cos(2 * .pi * x) + 0.08 * cos(4 * .pi * x)
        }
        hp = .highpass(30, sr: sampleRate)
        var filters: [Biquad] = []
        for v in 1...10 {
            let f = sensHz(v)
            for _ in 0..<3 { filters.append(.lowpass(f, sr: sampleRate)) }
        }
        lp = filters
        acc.reserveCapacity(Self.hop * 4)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func feed(_ samples: [Float]) -> [HopFeature] {
        acc.append(contentsOf: samples)
        var out: [HopFeature] = []
        while acc.count >= Self.hop {
            let chunk = Array(acc[0..<Self.hop])
            acc.removeFirst(Self.hop)
            out.append(process(chunk))
        }
        return out
    }

    private func process(_ chunk: [Float]) -> HopFeature {
        // бас: RMS отфильтрованных 512 сэмплов для каждого положения чувствительности
        var sums = [Float](repeating: 0, count: 10)
        for x in chunk {
            let h = hp.process(x)
            for k in 0..<10 {
                var v = lp[k * 3].process(h)
                v = lp[k * 3 + 1].process(v)
                v = lp[k * 3 + 2].process(v)
                sums[k] += v * v
            }
        }
        let bass = sums.map { sqrt($0 / Float(Self.hop)) }

        // громкость: последние 2048 сэмплов через FFT
        hist.removeFirst(Self.hop)
        hist.append(contentsOf: chunk)
        let n = Self.fftN
        vDSP_vmul(hist, 1, window, 1, &windowed, 1, vDSP_Length(n))
        windowed.withUnsafeBufferPointer { wp in
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { mp in
                        vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }
        let scale = 1 / Float(2 * n)          // zrip даёт 2×DFT, Web Audio делит на N
        var loud: Float = 0
        for k in 1...l1 {
            let m = mags[k] * scale
            smoothed[k] = 0.4 * smoothed[k] + 0.6 * m
            let db = smoothed[k] > 0 ? 20 * log10(smoothed[k]) : -1000
            let byte = clamp((255 / 80 * (db + 90)).rounded(.down), 0, 255)
            loud += byte
        }
        return HopFeature(loud: loud / Float(l1), bass: bass)
    }
}
