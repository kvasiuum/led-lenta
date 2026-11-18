import Foundation
import AVFoundation

/// Разбор своего трека заранее, быстрее реального времени: на каждый шаг в 512 сэмплов —
/// громкость и бас. Во время игры светомузыка берёт признаки по текущей позиции плеера,
/// поэтому свет точно попадает в звук, работает в фоне и не боится перемотки.
final class FileAnalysis {
    private(set) var features: [HopFeature] = []    // дополняется на main
    private(set) var sampleRate: Double = 44100
    private(set) var done = false

    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    init(url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run(url)
        }
    }

    private func run(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else {
            DispatchQueue.main.async { self.done = true }
            return
        }
        let format = file.processingFormat
        let sr = format.sampleRate
        DispatchQueue.main.async { self.sampleRate = sr }
        let analyzer = StreamAnalyzer(sampleRate: sr)
        let chunk: AVAudioFrameCount = AVAudioFrameCount(StreamAnalyzer.hop * 32)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: Int(chunk))

        while !cancelled && file.framePosition < file.length {
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
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else { return }
                self.features.append(contentsOf: feats)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.done = true }
    }
}
