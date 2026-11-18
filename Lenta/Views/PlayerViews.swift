import SwiftUI
import WebKit

/// Мини-полоска над панелью вкладок; тап — полный плеер
struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerController

    var body: some View {
        if player.has {
            HStack(spacing: 12) {
                ArtThumb(source: player.art, size: 42, radius: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.artist).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.playing ? "Пауза" : "Воспроизвести")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 36, height: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Следующий трек")
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    GeometryReader { geo in
                        let d = player.duration
                        Capsule()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: d > 0 ? geo.size.width * CGFloat(clamp(player.position / d, 0, 1)) : 0, height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 22)
                }
            }
            .glass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
            .onTapGesture { player.showFull = true }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAction(named: "Открыть плеер") { player.showFull = true }
        }
    }
}

/// Полный плеер в стиле экрана блокировки
struct FullPlayer: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var app: AppModel
    @State private var seeking = false
    @State private var seekValue = 0.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ArtImage(source: player.art)
                .scaleEffect(1.6)
                .blur(radius: 70)
                .saturation(1.5)
                .brightness(-0.3)
                .ignoresSafeArea()
            if player.art == .empty {
                app.currentRGB.color.opacity(0.35).blur(radius: 120).ignoresSafeArea()
            }

            VStack(spacing: 22) {
                Spacer(minLength: 12)
                ArtImage(source: player.art)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    .scaleEffect(player.playing ? 1 : 0.86)
                    .animation(.spring(response: 0.5, dampingFraction: 0.75), value: player.playing)
                    .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.title).font(.title3.weight(.bold)).lineLimit(1)
                    Text(player.artist).font(.body).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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

                HStack {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle").font(.title3)
                            .foregroundStyle(player.shuffle ? Color.white : Color.white.opacity(0.45))
                    }
                    .accessibilityLabel("Случайный порядок")
                    .accessibilityValue(player.shuffle ? "включён" : "выключен")
                    Spacer()
                    Button { player.prev() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
                        .accessibilityLabel("Предыдущий трек")
                    Spacer()
                    Button { player.toggle() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 46))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 64, height: 64)
                    }
                    .accessibilityLabel(player.playing ? "Пауза" : "Воспроизвести")
                    Spacer()
                    Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                        .accessibilityLabel("Следующий трек")
                    Spacer()
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                            .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.45) : Color.white)
                    }
                    .accessibilityLabel(player.repeatMode.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .sensoryFeedback(.selection, trigger: player.playing)

                HStack(spacing: 10) {
                    Image(systemName: "lightbulb.led.fill").foregroundStyle(.white.opacity(0.6))
                    LevelMeter(height: 4)
                }
                .padding(.top, 4)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 28)
        }
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

/// Скрытый плеер SoundCloud. Всегда в окне (иначе WebKit может притормозить звук);
/// по кнопке «Показать плеер SoundCloud» выезжает над мини-плеером.
struct SCWebHost: View {
    @EnvironmentObject var sc: SoundCloudController

    var body: some View {
        VStack {
            Spacer()
            ZStack(alignment: .topTrailing) {
                WebViewBox(webView: sc.webView)
                    .frame(height: sc.showWidget ? 170 : 2)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                if sc.showWidget {
                    Button {
                        sc.userShown = false
                        withAnimation { sc.showWidget = false }
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.7), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
            .opacity(sc.showWidget ? 1 : 0.02)
            .allowsHitTesting(sc.showWidget)
            .padding(.horizontal, sc.showWidget ? 14 : 0)
            .padding(.bottom, sc.showWidget ? 140 : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sc.showWidget)
    }
}

struct WebViewBox: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
