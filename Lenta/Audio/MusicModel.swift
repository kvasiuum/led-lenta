import Foundation
import AVFoundation

/// Раздел «Музыка»: вкладки и микрофон для светомузыки
final class MusicModel: ObservableObject {
    private var s: Services { .shared }

    /// Вкладки раздела «Музыка»
    enum Tab: String, CaseIterable, Identifiable {
        case tracks, playlists, mic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tracks: return "Треки"
            case .playlists: return "Плейлисты"
            case .mic: return "Микрофон"
            }
        }
    }

    @Published var tab: Tab = .tracks
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
        if s.player.playing { AudioSessionManager.activate() }   // обратно к обычному воспроизведению
        s.light.refresh()
        s.timers.updateKeepAlive()
    }
}
