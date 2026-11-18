import Foundation
import AVFoundation

/// Источник звука для светомузыки: свои треки, SoundCloud или микрофон
final class MusicModel: ObservableObject {
    private var s: Services { .shared }

    enum Source: String, CaseIterable, Identifiable {
        case file, sc, mic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .file: return "Свои треки"
            case .sc: return "SoundCloud"
            case .mic: return "Микрофон"
            }
        }
    }

    @Published var source: Source = .file {
        didSet {
            guard source != oldValue else { return }
            if source != .mic { stopMic() }
            if source == .mic { s.player.pauseActive() }
        }
    }
    @Published private(set) var micActive = false
    let mic = MicListener()

    func toggleMic() { micActive ? stopMic() : startMic() }

    func startMic() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { self.s.app.showToast("Нет доступа к микрофону. Разреши в Настройках"); return }
                AudioSessionManager.activate(mic: true)
                do {
                    try self.mic.start()
                    self.micActive = true
                } catch {
                    self.s.app.showToast("Не удалось включить микрофон")
                }
                self.s.light.refresh()
                self.s.timers.updateKeepAlive()
            }
        }
    }

    func stopMic() {
        guard micActive else { return }
        mic.stop()
        micActive = false
        s.light.refresh()
        s.timers.updateKeepAlive()
    }
}
