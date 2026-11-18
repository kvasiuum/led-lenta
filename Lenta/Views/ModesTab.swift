import SwiftUI

struct ModesTab: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Button { app.runFx(app.fx - 1) } label: { Image(systemName: "minus").font(.system(size: 22, weight: .regular)) }
                        .buttonStyle(GlassButtonStyle(height: 56))
                        .frame(width: 56)
                        .accessibilityLabel("Предыдущий режим")
                    VStack(spacing: 2) {
                        Text("\(app.fx)")
                            .font(.system(size: 52, weight: .semibold))
                            .tracking(-1.5)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(app.fx)))
                            .animation(.snappy, value: app.fx)
                        Text("режим из 210").font(.footnote).foregroundStyle(Web.muted)
                    }
                    .frame(maxWidth: .infinity)
                    Button { app.runFx(app.fx + 1) } label: { Image(systemName: "plus").font(.system(size: 22, weight: .regular)) }
                        .buttonStyle(GlassButtonStyle(height: 56))
                        .frame(width: 56)
                        .accessibilityLabel("Следующий режим")
                }

                Slider(value: Binding(get: { Double(app.fx) }, set: { v in
                    let n = Int(v.rounded())
                    if n != app.fx { app.runFx(n) }
                }), in: 1...210, step: 1)
                .tint(.white)
                .accessibilityLabel("Выбор режима")

                HStack(spacing: 10) {
                    Button { app.toggleFav() } label: {
                        Label(app.isFav ? "В избранном" : "В избранное", systemImage: app.isFav ? "star.fill" : "star")
                            .lineLimit(1)
                    }
                    .buttonStyle(GlassButtonStyle(on: app.isFav, accent: Color(red: 1, green: 0.8, blue: 0.3)))
                    .frame(maxWidth: .infinity)
                    .sensoryFeedback(.success, trigger: app.isFav)

                    Button { app.toggleAutoFx() } label: {
                        Label("Автосмена", systemImage: "arrow.clockwise").lineLimit(1)
                    }
                    .buttonStyle(GlassButtonStyle(on: app.autoFx, accent: Web.accent))
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Избранное")
                if app.favs.isEmpty {
                    Hint("Режимы без названий, поэтому отмечай понравившиеся звёздочкой, и они появятся здесь.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 8)], spacing: 8) {
                        ForEach(app.favs, id: \.self) { n in
                            let cur = n == app.fx
                            Button { app.playFav(n) } label: {
                                Text("\(n)")
                                    .font(.body.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(cur ? Color.black : Color.white)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(cur ? Color.white : Web.fill, in: RoundedRectangle(cornerRadius: Web.rSm, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: Web.rSm, style: .continuous).strokeBorder(cur ? Color.white : Web.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Режим \(n)")
                        }
                    }
                }
            }
            .card()
        }
    }
}
