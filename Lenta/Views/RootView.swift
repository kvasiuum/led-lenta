import SwiftUI

struct RootView: View {
    @EnvironmentObject var player: PlayerController
    @State private var tab = 0

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                ColorTab()
                    .tabItem { Label("Цвет", systemImage: "circle.circle") }
                    .tag(0)
                MusicTab()
                    .tabItem { Label("Музыка", systemImage: "music.note") }
                    .tag(1)
                ModesTab()
                    .tabItem { Label("Режимы", systemImage: "sparkles") }
                    .tag(2)
                TimerTab()
                    .tabItem { Label("Таймер", systemImage: "timer") }
                    .tag(3)
            }
            .tint(.white)
            SCWebHost()
            ToastView()
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $player.showFull) { FullPlayer() }
        .sensoryFeedback(.selection, trigger: tab)
    }
}

/// Страница вкладки: шапка с лентой сверху, фон из цвета ленты, место под мини-плеер снизу
struct Page<Content: View>: View {
    @EnvironmentObject var player: PlayerController
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DeviceCard()
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background { AmbientBackground() }
        .safeAreaInset(edge: .bottom) {
            MiniPlayer().animation(.spring(response: 0.45, dampingFraction: 0.85), value: player.has)
        }
    }
}
