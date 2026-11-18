import SwiftUI
import WebKit

/// Квадратная обложка: картинка заполняет квадрат и обрезается, раскладку не растягивает
struct SquareArt: View {
    let source: ArtSource
    var radius: CGFloat = 16

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { ArtImage(source: source) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Плеер внизу, как на сайте: большая карточка; при касании страницы или прокрутке
/// сжимается в полоску (назад · play · вперёд), тап по полоске — снова карточка.
struct PlayerDock: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ns

    var body: some View {
        if player.has {
            Group {
                if player.expanded { card } else { bar }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { player.dockHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in player.dockHeight = h }
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .gesture(
                DragGesture(minimumDistance: 14).onEnded { v in
                    if v.translation.height > 30 { player.setExpanded(false) }
                    else if v.translation.height < -30 { player.setExpanded(true) }
                }
            )
        }
    }

    // MARK: большая карточка

    private var card: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button { player.showFull = true } label: {
                    ArtThumb(source: player.art, size: 64, radius: 12)
                        .matchedGeometryEffect(id: "art", in: ns)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Открыть плеер на весь экран")
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.title)
                        .font(.headline)
                        .lineLimit(1)
                        .matchedGeometryEffect(id: "title", in: ns)
                    HStack(spacing: 5) {
                        if let src = player.current?.source { SourceBadge(source: src) }
                        Text(player.artist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { player.setExpanded(false) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Свернуть плеер")
            }

            ScrubBar()

            HStack(spacing: 0) {
                ToggleIcon(name: "shuffle", on: player.shuffle, label: "Случайный порядок") { player.toggleShuffle() }
                Spacer(minLength: 0)
                IconButton(name: "backward.fill", size: 24, label: "Предыдущий трек") { player.prev() }
                Spacer(minLength: 0)
                IconButton(name: player.playing ? "pause.fill" : "play.fill", size: 38,
                           label: player.playing ? "Пауза" : "Воспроизвести") { player.toggle() }
                    .matchedGeometryEffect(id: "play", in: ns)
                Spacer(minLength: 0)
                IconButton(name: "forward.fill", size: 24, label: "Следующий трек") { player.next() }
                Spacer(minLength: 0)
                ToggleIcon(name: player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off,
                           label: player.repeatMode.label) { player.cycleRepeat() }
            }
            .padding(.horizontal, 2)
        }
        .padding(16)
        .glass(in: RoundedRectangle(cornerRadius: Web.rLg, style: .continuous))
        // любое касание карточки откладывает автосворачивание
        .simultaneousGesture(TapGesture().onEnded { player.touchDock() })
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in player.touchDock() })
        .sensoryFeedback(.selection, trigger: player.playing)
    }

    // MARK: компактная полоска

    private var bar: some View {
        HStack(spacing: 4) {
            ArtThumb(source: player.art, size: 40, radius: 9)
                .matchedGeometryEffect(id: "art", in: ns)
                .padding(.trailing, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "title", in: ns)
                Text(player.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(name: "backward.fill", size: 17, label: "Предыдущий трек") { player.prev() }
            IconButton(name: player.playing ? "pause.fill" : "play.fill", size: 22,
                       label: player.playing ? "Пауза" : "Воспроизвести") { player.toggle() }
                .matchedGeometryEffect(id: "play", in: ns)
            IconButton(name: "forward.fill", size: 17, label: "Следующий трек") { player.next() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { hairline }
        .glass(in: Capsule(), interactive: true)
        .contentShape(Capsule())
        .onTapGesture { player.setExpanded(true) }
        .accessibilityAction(named: "Развернуть плеер") { player.setExpanded(true) }
    }

    private var hairline: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            GeometryReader { geo in
                let d = player.duration
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: d > 0 ? geo.size.width * CGFloat(clamp(player.position / d, 0, 1)) : 0, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 26)
        }
    }
}

/// Кнопка-иконка с большой областью нажатия (не меньше 44 pt)
struct IconButton: View {
    let name: String
    var size: CGFloat = 22
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: max(44, size + 20), height: max(44, size + 14))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// Перемешать / повтор: яркая, когда включено
struct ToggleIcon: View {
    let name: String
    let on: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(on ? Color.white : Web.faint)
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottom) {
                    Circle().fill(Color.white).frame(width: 4, height: 4).opacity(on ? 1 : 0).offset(y: -3)
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
        .accessibilityValue(on ? "включено" : "выключено")
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Полоса перемотки как на сайте: тонкая, с временем по бокам; тянется пальцем
struct ScrubBar: View {
    @EnvironmentObject var player: PlayerController
    @State private var dragging = false
    @State private var dragValue = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let d = max(player.duration, 0.1)
            let p = dragging ? dragValue : min(player.position, d)
            HStack(spacing: 10) {
                Text(fmtTime(p)).frame(minWidth: 34, alignment: .leading)
                GeometryReader { g in
                    let w = max(g.size.width, 1)
                    let h: CGFloat = dragging ? 10 : 6
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2)).frame(height: h)
                        Capsule().fill(Color.white.opacity(dragging ? 1 : 0.8))
                            .frame(width: max(h, w * CGFloat(p / d)), height: h)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                dragging = true
                                dragValue = clamp(Double(v.location.x / w), 0, 1) * d
                            }
                            .onEnded { _ in
                                player.seek(dragValue)
                                dragging = false
                            }
                    )
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
                }
                .frame(height: 28)
                Text("−" + fmtTime(max(0, d - p))).frame(minWidth: 40, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityElement()
            .accessibilityLabel("Перемотка")
            .accessibilityValue("\(fmtTime(p)) из \(fmtTime(d))")
            .accessibilityAdjustableAction { dir in
                player.seek(clamp(p + (dir == .increment ? 10 : -10), 0, d))
            }
        }
    }
}

/// Полный плеер в стиле экрана блокировки iPhone
struct FullPlayer: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var web: WebPlayer
    @State private var seeking = false
    @State private var seekValue = 0.0

    var body: some View {
        GeometryReader { geo in
            let side = max(0, min(geo.size.width - 56, geo.size.height * 0.45))
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.35)).frame(width: 40, height: 5).padding(.top, 10)

                Text(player.context.isEmpty ? " " : "Играет из «\(player.context)»")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.top, 12)

                Spacer(minLength: 16)

                SquareArt(source: player.art, radius: 22)
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    .scaleEffect(player.playing ? 1 : 0.88)
                    .animation(.spring(response: 0.5, dampingFraction: 0.78), value: player.playing)

                Spacer(minLength: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(player.title).font(.title3.weight(.bold)).lineLimit(1)
                    HStack(spacing: 6) {
                        if let src = player.current?.source { SourceBadge(source: src) }
                        Text(player.artist).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                scrubber.padding(.top, 18)

                controls.padding(.top, 18)

                HStack(spacing: 10) {
                    Image(systemName: "lightbulb.led.fill").foregroundStyle(.white.opacity(0.6))
                    LevelMeter(height: 4)
                }
                .padding(.top, 22)

                if let src = player.current?.source, src != .file {
                    Button {
                        web.userShown = true
                        web.showWidget = true
                        player.showFull = false
                    } label: {
                        Label("Встроенный плеер \(src.title)", systemImage: "rectangle.on.rectangle")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 28)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background { background }
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        ZStack {
            Color.black
            if player.art != .empty {
                ArtImage(source: player.art)
                    .scaleEffect(1.5)
                    .blur(radius: 70)
                    .saturation(1.5)
                    .brightness(-0.32)
            } else {
                app.currentRGB.color.opacity(0.35).blur(radius: 120)
            }
        }
        .clipped()
        .ignoresSafeArea()
    }

    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let d = max(player.duration, 0.1)
            let p = seeking ? seekValue : min(player.position, d)
            VStack(spacing: 4) {
                Slider(value: Binding(get: { p }, set: { seekValue = $0 }), in: 0...d, onEditingChanged: { editing in
                    if editing { seekValue = p; seeking = true }
                    else { player.seek(seekValue); seeking = false }
                })
                .tint(.white)
                HStack {
                    Text(fmtTime(p))
                    Spacer()
                    Text("−" + fmtTime(max(0, d - p)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.shuffle ? Color.white : Color.white.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .background(player.shuffle ? Color.white.opacity(0.14) : Color.clear, in: Circle())
            }
            .accessibilityLabel("Случайный порядок")
            .accessibilityValue(player.shuffle ? "включён" : "выключен")
            Spacer(minLength: 0)
            Button { player.prev() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30)).frame(width: 56, height: 56)
            }
            .accessibilityLabel("Предыдущий трек")
            Spacer(minLength: 0)
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
            }
            .accessibilityLabel(player.playing ? "Пауза" : "Воспроизвести")
            Spacer(minLength: 0)
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30)).frame(width: 56, height: 56)
            }
            .accessibilityLabel("Следующий трек")
            Spacer(minLength: 0)
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.4) : Color.white)
                    .frame(width: 44, height: 44)
                    .background(player.repeatMode == .off ? Color.clear : Color.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel(player.repeatMode.label)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .sensoryFeedback(.selection, trigger: player.playing)
    }
}

/// Встроенный плеер сервиса. Всегда в окне (иначе WebKit может притормозить звук);
/// когда нужен (нажать play, войти), выезжает над мини-плеером.
struct WebHost: View {
    @EnvironmentObject var web: WebPlayer
    @EnvironmentObject var player: PlayerController

    var body: some View {
        VStack {
            Spacer()
            ZStack(alignment: .topTrailing) {
                WebViewBox(webView: web.webView)
                    .frame(height: web.showWidget ? (web.source == .spotify ? 160 : 190) : 2)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                if web.showWidget {
                    Button {
                        web.userShown = false
                        withAnimation { web.showWidget = false }
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.7), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel("Скрыть встроенный плеер")
                }
            }
            .opacity(web.showWidget ? 1 : 0.02)
            .allowsHitTesting(web.showWidget)
            .padding(.horizontal, web.showWidget ? 14 : 0)
            .padding(.bottom, web.showWidget ? (player.expanded ? 230 : 84) : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: web.showWidget)
    }
}

struct WebViewBox: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
