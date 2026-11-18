import SwiftUI

enum AppTab: Int, CaseIterable, Identifiable {
    case color, music, modes, timer
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .color: return "Цвет"
        case .music: return "Музыка"
        case .modes: return "Режимы"
        case .timer: return "Таймер"
        }
    }
    var icon: String {
        switch self {
        case .color: return "circle.circle"
        case .music: return "music.note"
        case .modes: return "sparkles"
        case .timer: return "timer"
        }
    }
}

/// Как на сайте: шапка с лентой, переключатель разделов со скользящей плашкой, раздел, плеер внизу
struct RootView: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: AppTab = .color
    @State private var dir: CGFloat = 1

    var body: some View {
        ZStack {
            AmbientBackground()

            ScrollView {
                VStack(spacing: 14) {
                    DeviceCard()
                    TabSwitcher(tab: Binding(get: { tab }, set: { select($0) }))
                    Group {
                        switch tab {
                        case .color: ColorTab()
                        case .music: MusicTab()
                        case .modes: ModesTab()
                        case .timer: TimerTab()
                        }
                    }
                    .id(tab)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.asymmetric(
                        insertion: AnyTransition.opacity.combined(with: AnyTransition.offset(x: 26 * dir)),
                        removal: AnyTransition.opacity))
                    ColorFixCard()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                MiniPlayer().animation(.spring(response: 0.45, dampingFraction: 0.85), value: player.has)
            }

            WebHost()
            ToastView()
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $player.showFull) { FullPlayer() }
    }

    private func select(_ t: AppTab) {
        guard t != tab else { return }
        dir = t.rawValue > tab.rawValue ? 1 : -1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { tab = t }
    }
}

/// Переключатель разделов: стеклянная капсула, выбранный раздел подсвечен скользящей плашкой
struct TabSwitcher: View {
    @Binding var tab: AppTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { t in
                let on = t == tab
                Button { tab = t } label: {
                    HStack(spacing: 6) {
                        Image(systemName: t.icon).font(.system(size: 15, weight: .semibold))
                        Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        if on {
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(4)
        .glass(in: Capsule())
        .sensoryFeedback(.selection, trigger: tab)
    }
}
