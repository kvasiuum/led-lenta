import Foundation
import AVFoundation

/// Микрофон: сэмплы с каждого аудиоцикла складываются в буфер, светомузыка забирает их ~100 раз в секунду.
/// Ничего не записывается.
final class MicListener {
    private var engine: AVAudioEngine?
    private var sink: AVAudioSinkNode?
    private let lock = NSLock()
    private var buffer: [Float] = []
    private(set) var sampleRate: Double = 48000

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        sampleRate = input.outputFormat(forBus: 0).sampleRate
        let sink = AVAudioSinkNode { [weak self] _, frames, list -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let first = abl.first, let raw = first.mData else { return noErr }
            let p = raw.assumingMemoryBound(to: Float.self)
            let n = Int(frames)
            self.lock.lock()
            self.buffer.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
            if self.buffer.count > 96000 { self.buffer.removeFirst(self.buffer.count - 96000) }
            self.lock.unlock()
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: nil)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.sink = sink
    }

    func stop() {
        engine?.stop()
        if let e = engine, let s = sink { e.detach(s) }
        engine = nil
        sink = nil
        lock.lock(); buffer.removeAll(); lock.unlock()
    }

    /// Забрать всё накопленное
    func drain() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let b = buffer
        buffer.removeAll(keepingCapacity: true)
        return b
    }
}

enum AudioSessionManager {
    /// mic — слушать комнату (вместе с музыкой из других приложений);
    /// mix — тихо работать в фоне ради таймеров, не мешая другим приложениям.
    static func activate(mic: Bool = false, mix: Bool = false) {
        let s = AVAudioSession.sharedInstance()
        do {
            if mic {
                try s.setCategory(.playAndRecord, mode: .measurement,
                                  options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
                try? s.setPreferredIOBufferDuration(0.005)     // микрофон отдаёт звук каждые ~5 мс, а не 23
            } else {
                try s.setCategory(.playback, mode: .default, options: mix ? [.mixWithOthers] : [])
            }
            try s.setActive(true)
        } catch {
            print("AudioSession:", error)
        }
    }
}
