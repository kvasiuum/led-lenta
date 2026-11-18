import Foundation
import AVFoundation

/// Воспроизведение своих файлов. Трек разбирается заранее (FileAnalysis) — светомузыка точно в такт.
final class FileEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var s: Services { .shared }

    @Published private(set) var isPlaying = false
    private(set) var player: AVAudioPlayer?
    private(set) var analysis: FileAnalysis?
    private(set) var trackID: String?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    var position: Double { player?.currentTime ?? 0 }
    var duration: Double { player?.duration ?? 0 }

    /// Загрузить и сразу играть
    @discardableResult
    func play(_ t: LTrack, url: URL) -> Bool {
        stop()
        AudioSessionManager.activate()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            analysis = FileAnalysis(url: url)
            trackID = t.id
            p.play()
            setPlaying(true)
            return true
        } catch {
            s.app.showToast("Не получается открыть «\(t.title)»")
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        analysis?.cancel()
        analysis = nil
        trackID = nil
        if isPlaying { isPlaying = false }
    }

    func toggle() { isPlaying ? pause() : resume() }

    func pause() {
        guard let p = player, p.isPlaying else { return }
        p.pause()
        setPlaying(false)
    }

    func resume() {
        guard let p = player else { return }
        AudioSessionManager.activate()
        p.play()
        setPlaying(true)
    }

    func seek(_ t: Double) {
        guard let p = player else { return }
        p.currentTime = clamp(t, 0, p.duration)
        s.player.refreshNowPlaying()
    }

    func restart() {
        guard let p = player else { return }
        p.currentTime = 0
        p.play()
        setPlaying(true)
    }

    private func setPlaying(_ on: Bool) {
        if isPlaying != on { isPlaying = on }
        s.player.changed()
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard p === self.player else { return }
            self.isPlaying = false
            self.s.player.trackEnded()
        }
    }

    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began { self.setPlaying(false) }
        }
    }
}
