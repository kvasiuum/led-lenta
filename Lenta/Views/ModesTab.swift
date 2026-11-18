import SwiftUI

struct ModesTab: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Page {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Button { app.runFx(app.fx - 1) } label: { Image(systemName: "minus") }
                        .buttonStyle(RoundIconButtonStyle(size: 58))
                        .accessibilityLabel("Предыдущий режим")
                    VStack(spacing: 2) {
                        Text("\(app.fx)")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(app.fx)))
                            .animation(.snappy, value: app.fx)
                        Text("режим из 210").font(.footnote).foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    Button { app.runFx(app.fx + 1) } label: { Image(systemName: "plus") }
                        .buttonStyle(RoundIconButtonStyle(size: 58))
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
                    .sensoryFeedback(.success, trigger: app.isFav)

                    Button { app.toggleAutoFx() } label: {
                        Label("Автосмена", systemImage: "arrow.clockwise").lineLimit(1)
                    }
                    .buttonStyle(GlassButtonStyle(on: app.autoFx, accent: Color(red: 0.45, green: 0.65, blue: 1)))
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
                                    .background(cur ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true)
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
