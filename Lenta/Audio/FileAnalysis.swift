import Foundation
import AVFoundation

/// Разбор своего трека заранее, быстрее реального времени: на каждый шаг в 512 сэмплов —
/// громкость и бас. Во время игры светомузыка берёт признаки по текущей позиции плеера,
/// поэтому свет точно попадает в звук, работает в фоне и не боится перемотки.
/// Потокобезопасно: дописывается на фоне, читается потоком света.
final class FileAnalysis {
    private let lock = NSLock()
    private var features: [HopFeature] = []
    private var sr: Double = 44100
    private var cancelled = false
    private var finished = false

    var count: Int { lock.lock(); defer { lock.unlock() }; return features.count }
    var sampleRate: Double { lock.lock(); defer { lock.unlock() }; return sr }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    /// Признаки в диапазоне (что есть)
    func slice(_ r: Range<Int>) -> [HopFeature] {
        lock.lock(); defer { lock.unlock() }
        let lo = max(0, r.lowerBound), hi = min(r.upperBound, features.count)
        return lo < hi ? Array(features[lo..<hi]) : []
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    init(url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(url)
        }
    }

    private func run(_ url: URL) {
        defer { lock.lock(); finished = true; lock.unlock() }
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        lock.lock(); sr = format.sampleRate; lock.unlock()
        let analyzer = StreamAnalyzer(sampleRate: format.sampleRate)
        let chunk = AVAudioFrameCount(StreamAnalyzer.hop * 32)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: Int(chunk))

        while !isCancelled && file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += data[c][i] }
                mono[i] = sum / Float(max(channels, 1))
            }
            let feats = analyzer.feed(Array(mono[0..<n]))
            lock.lock(); features.append(contentsOf: feats); lock.unlock()
        }
    }
}
