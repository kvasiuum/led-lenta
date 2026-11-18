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

/// Мини-полоска внизу, как на сайте; тап — полный плеер
struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerController

    var body: some View {
        if player.has {
            HStack(spacing: 12) {
                ArtThumb(source: player.art, size: 42, radius: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        if let src = player.current?.source { SourceBadge(source: src) }
                        Text(player.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.playing ? "Пауза" : "Воспроизвести")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Следующий трек")
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { progress }
            .glass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
            .onTapGesture { player.showFull = true }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAction(named: "Открыть плеер") { player.showFull = true }
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            GeometryReader { geo in
                let d = player.duration
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: d > 0 ? geo.size.width * CGFloat(clamp(player.position / d, 0, 1)) : 0, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 24)
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
            .padding(.bottom, web.showWidget ? 84 : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: web.showWidget)
    }
}

struct WebViewBox: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
