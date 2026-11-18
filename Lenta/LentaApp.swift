import SwiftUI

@main
struct LentaApp: App {
    private let s = Services.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(s.ble)
                .environmentObject(s.app)
                .environmentObject(s.live)
                .environmentObject(s.light)
                .environmentObject(s.music)
                .environmentObject(s.library)
                .environmentObject(s.sc)
                .environmentObject(s.player)
                .environmentObject(s.timers)
                .onAppear { s.start() }
        }
    }
}
