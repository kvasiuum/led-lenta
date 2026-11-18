import Foundation
import Combine

/// Все модели приложения в одном месте. Модели обращаются друг к другу через `Services.shared`.
final class Services {
    static let shared = Services()

    let ble = LEDController()
    let app = AppModel()
    let live = LiveLight()
    let light = LightEngine()
    let music = MusicModel()
    let library = LibraryStore()
    let files = FileEngine()
    let web = WebPlayer()
    let player = PlayerController()
    let timers = TimerModel()

    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        player.wire()
        timers.start()
        app.applyColor(send: false)
        ble.autoConnect()
    }
}
