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
    @State private var lastOffset: CGFloat = 0

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
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { player.collapseFromPage() })
                .background {
                    GeometryReader { g in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: g.frame(in: .named("page")).minY)
                    }
                }
            }
            .coordinateSpace(name: "page")
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(ScrollOffsetKey.self) { y in
                // прокрутили страницу — плеер сворачивается в полоску
                if abs(y - lastOffset) > 14 { player.collapseFromPage() }
                lastOffset = y
            }
            // место под свёрнутый плеер; сама карточка лежит поверх и не сдвигает страницу —
            // иначе ползунок под пальцем «уезжал» и переставал работать
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: player.has ? 72 : 0)
            }

            VStack {
                Spacer()
                PlayerDock().animation(.spring(response: 0.45, dampingFraction: 0.85), value: player.has)
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
                    // иконка над подписью — на узком экране подписи не наезжают друг на друга
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 17, weight: .semibold))
                        Text(t.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(on ? Color.white : Web.muted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(Web.fillOn)
                                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(5)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .sensoryFeedback(.selection, trigger: tab)
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
