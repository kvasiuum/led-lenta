import SwiftUI

@main
struct LentaApp: App {
    private let s = Services.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(s.ble)
                .environmentObject(s.app)
                .environmentObject(s.live)
                .environmentObject(s.light)
                .environmentObject(s.music)
                .environmentObject(s.library)
                .environmentObject(s.files)
                .environmentObject(s.web)
                .environmentObject(s.player)
                .environmentObject(s.timers)
                .onAppear { s.start() }
                .onChange(of: phase) { _, p in
                    // вернулись в приложение — сразу ищем знакомую ленту
                    if p == .active && !s.ble.isConnected { s.ble.autoConnect() }
                }
        }
    }
}
