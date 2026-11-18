import SwiftUI

// Стиль сайта (слой Liquid Glass из index.html): стекло = размытие + градиент белого 11%→4%,
// граница 10% и «блик» по краю, ярче сверху-слева и снизу-справа. Радиусы: панели 26, кнопки 14,
// мелкие элементы 11. Основная кнопка — белая с чёрным текстом.

enum Web {
    static let muted = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.62)
    static let faint = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.38)
    static let fill = Color.white.opacity(0.08)       // --surface-2
    static let fillOn = Color.white.opacity(0.16)     // --surface-3, выбранная плашка
    static let line = Color.white.opacity(0.10)
    static let well = Color.black.opacity(0.28)       // «лунка» под переключателями и полями
    static let accent = Color(red: 0x5b / 255, green: 0x93 / 255, blue: 1)
    static let ok = Color(red: 0x3f / 255, green: 0xb9 / 255, blue: 0x50 / 255)
    static let bad = Color(red: 0xef / 255, green: 0x6b / 255, blue: 0x63 / 255)
    static let rLg: CGFloat = 26, rMd: CGFloat = 16, rSm: CGFloat = 11, rBtn: CGFloat = 14
}

/// Блик по краю стекла
private let rim = LinearGradient(
    gradient: Gradient(stops: [
        .init(color: .white.opacity(0.5), location: 0),
        .init(color: .white.opacity(0.08), location: 0.3),
        .init(color: .white.opacity(0), location: 0.5),
        .init(color: .white.opacity(0.08), location: 0.7),
        .init(color: .white.opacity(0.32), location: 1)
    ]),
    startPoint: .topLeading, endPoint: .bottomTrailing)

extension View {
    /// Стеклянная поверхность как на сайте
    func glass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false, shadow: Bool = true) -> some View {
        self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                    if let tint { shape.fill(tint) }
                }
                .shadow(color: .black.opacity(shadow ? 0.28 : 0), radius: 16, y: 12)
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    .overlay(shape.strokeBorder(rim, lineWidth: 1))
                    .allowsHitTesting(false)
            }
    }

    /// Панель
    func card(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: RoundedRectangle(cornerRadius: Web.rLg, style: .continuous))
    }

    /// Простая заливка как у .btn / .chips / строк расписания
    func webFill(_ radius: CGFloat = Web.rBtn, on: Bool = false, border: Color = Web.line) -> some View {
        self
            .background(on ? Web.fillOn : Web.fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

/// .btn.primary — белая, текст чёрный
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(Color.white.opacity(configuration.isPressed ? 0.86 : 1),
                        in: RoundedRectangle(cornerRadius: Web.rBtn, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// .btn — полупрозрачная; on — цвет акцента и рамка (как «В избранном» / «Автосмена»)
struct GlassButtonStyle: ButtonStyle {
    var on = false
    var accent: Color = .white
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(on ? accent : Color.white)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .frame(maxWidth: .infinity)
            .background((on ? accent.opacity(0.08) : (configuration.isPressed ? Color.white.opacity(0.14) : Web.fill)),
                        in: RoundedRectangle(cornerRadius: Web.rBtn, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Web.rBtn, style: .continuous)
                .strokeBorder(on ? accent.opacity(0.4) : Web.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// .power / .icon-round — круг; filled — белый (включено)
struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(filled ? Color.black : Web.muted)
            .frame(width: size, height: size)
            .background(filled ? Color.white : Web.fill, in: Circle())
            .overlay(Circle().strokeBorder(filled ? Color.white : Web.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// .seg — тёмная лунка, выбранный вариант подсвечен скользящей плашкой
struct SegPicker<T: Hashable>: View {
    @Binding var selection: T
    let items: [(T, String)]
    var label: String = ""
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { i in
                let (value, title) = items[i]
                let on = value == selection
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(on ? Color.white : Web.muted)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Web.fillOn)
                                    .overlay(alignment: .top) {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                                    }
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(4)
        .background(Web.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
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
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
    }
}

/// Серая подсказка
struct Hint: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Web.muted).fixedSize(horizontal: false, vertical: true)
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).foregroundStyle(Web.muted).lineLimit(2)
                Spacer(minLength: 8)
                Text(value).monospacedDigit().fontWeight(.medium).fixedSize()
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
                Capsule().fill(Web.fillOn)
                Capsule()
                    .fill(Color.white)
                    .frame(width: geo.size.width * CGFloat(clamp(live.level, 0, 1)))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.05), value: live.level)
    }
}

/// Подсказка как на сайте: белая плашка снизу, над плеером
struct ToastView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerController

    var body: some View {
        VStack {
            Spacer()
            if let t = app.toast {
                Text(t)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.93, green: 0.93, blue: 0.94), in: RoundedRectangle(cornerRadius: Web.rMd, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .padding(.horizontal, 16)
                    .padding(.bottom, player.has ? (player.expanded ? 220 : 80) : 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }
}
