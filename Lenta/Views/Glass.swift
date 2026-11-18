import SwiftUI

// Liquid Glass на iOS 26 (Xcode 26), матовое стекло на iOS 17–18 и в старом Xcode.

#if compiler(>=6.2)
extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.legacyGlass(in: shape, tint: tint)
        }
    }
}
#else
extension View {
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        self.legacyGlass(in: shape, tint: tint)
    }
}
#endif

extension View {
    func legacyGlass<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background((tint ?? .clear).opacity(0.35), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    /// Карточка-панель
    func card(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Белая основная кнопка
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .frame(minHeight: 46)
            .background(Color.white, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Стеклянная кнопка; on — подсвеченное состояние
struct GlassButtonStyle: ButtonStyle {
    var on = false
    var accent: Color = .white
    var height: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(on ? accent : Color.white)
            .padding(.horizontal, 16)
            .frame(minHeight: height)
            .frame(maxWidth: .infinity)
            .glass(in: Capsule(), tint: on ? accent.opacity(0.25) : nil, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Круглая иконка-кнопка
struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(filled ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(filled ? Color.white : Color.clear, in: Circle())
            .glass(in: Circle(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Фон за стеклом: цвет ленты и, пока играет музыка, размытая обложка
struct AmbientBackground: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerController

    var body: some View {
        GeometryReader { geo in
            let m = max(geo.size.width, geo.size.height)
            ZStack {
                Color(red: 0.02, green: 0.02, blue: 0.03)
                Circle()
                    .fill(app.currentRGB.color)
                    .frame(width: m * 0.9, height: m * 0.9)
                    .blur(radius: 120)
                    .opacity(hasArt ? 0.12 : 0.38)
                    .offset(x: -m * 0.25, y: -m * 0.42)
                Circle()
                    .fill(app.currentRGB.color)
                    .frame(width: m * 0.9, height: m * 0.9)
                    .blur(radius: 140)
                    .opacity(hasArt ? 0.08 : 0.2)
                    .offset(x: m * 0.3, y: m * 0.5)
                if hasArt {
                    ArtImage(source: player.art)
                        .frame(width: geo.size.width * 1.3, height: geo.size.height * 1.3)
                        .blur(radius: 60)
                        .saturation(1.4)
                        .brightness(-0.25)
                        .opacity(0.9)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.8), value: app.currentRGB)
        .animation(.easeInOut(duration: 0.8), value: hasArt)
    }

    private var hasArt: Bool { player.playing && player.art != .empty }
}

/// Обложка из файла или из сети
struct ArtImage: View {
    let source: ArtSource

    var body: some View {
        switch source {
        case .local(let u):
            if let img = UIImage(contentsOfFile: u.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else { placeholder }
        case .remote(let u):
            AsyncImage(url: u) { phase in
                if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
            }
        case .empty:
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.08)
            Image(systemName: "music.note").font(.title2).foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Миниатюра обложки фиксированного размера
struct ArtThumb: View {
    let source: ArtSource
    var size: CGFloat = 44
    var radius: CGFloat = 8

    var body: some View {
        ArtImage(source: source)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Заголовок раздела внутри карточки
struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.headline).foregroundStyle(.white)
    }
}

/// Серая подсказка
struct Hint: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
    }
}

/// Подпись + значение над ползунком
struct SliderRow: View {
    let label: String
    let value: String
    @Binding var v: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(value).monospacedDigit().fontWeight(.medium)
            }
            .font(.subheadline)
            Slider(value: $v, in: range, step: step).tint(tint)
        }
    }
}

/// Полоска уровня светомузыки
struct LevelMeter: View {
    @EnvironmentObject var live: LiveLight
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [live.rgb.color.opacity(0.7), live.rgb.color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(clamp(live.level, 0, 1)))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.05), value: live.level)
    }
}

/// Всплывающая подсказка сверху
struct ToastView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack {
            if let t = app.toast {
                Text(t)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glass(in: Capsule())
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(t)
                    .accessibilityAddTraits(.isStaticText)
            }
            Spacer()
        }
        .padding(.top, 8)
        .allowsHitTesting(false)
    }
}
