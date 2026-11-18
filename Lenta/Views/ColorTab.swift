import SwiftUI

struct ColorTab: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Page {
            VStack(spacing: 22) {
                ColorWheel()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(presetColors.indices, id: \.self) { i in
                        let c = presetColors[i]
                        Button {
                            app.needConn()
                            app.pick(rgb: c)
                        } label: {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(c.color)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        }
                        .buttonStyle(SwatchStyle())
                        .accessibilityLabel("Цвет RGB \(c.r), \(c.g), \(c.b)")
                    }
                }
            }
            .card()

            ColorFixCard()
        }
    }
}

private struct SwatchStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Цветовой круг: угол — оттенок, расстояние от центра — насыщенность
struct ColorWheel: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var ble: LEDController
    @State private var dragging = false

    // по часовой стрелке от «трёх часов»; оттенок у нас растёт против часовой
    private let hues: [Color] = [0, 300, 240, 180, 120, 60, 0].map { hsv2rgb(Double($0), 1, 1).color }

    var body: some View {
        GeometryReader { geo in
            let size: CGFloat = min(geo.size.width, geo.size.height)
            let R: CGFloat = size / 2
            let a: Double = app.hs.h * Double.pi / 180
            let kx = CGFloat(cos(a) * app.hs.s)
            let ky = CGFloat(sin(a) * app.hs.s)
            ZStack {
                Circle().fill(AngularGradient(colors: hues, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: R))
                Circle()
                    .fill(app.currentRGB.color)
                    .frame(width: dragging ? 40 : 32, height: dragging ? 40 : 32)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                    .position(x: R + kx * R, y: R - ky * R)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            if !ble.isConnected { app.showToast("Сначала подключи ленту") }
                        }
                        let dx = Double(v.location.x - R), dy = Double(v.location.y - R)
                        var h = atan2(-dy, dx) * 180 / Double.pi
                        h = (h + 360).truncatingRemainder(dividingBy: 360)
                        let sat = clamp((dx * dx + dy * dy).squareRoot() / Double(R), 0, 1)
                        app.pick(HS(h: h, s: sat))
                    }
                    .onEnded { _ in dragging = false }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: dragging)
        .accessibilityElement()
        .accessibilityLabel("Цветовой круг")
        .accessibilityValue("R \(app.currentRGB.r), G \(app.currentRGB.g), B \(app.currentRGB.b)")
        .accessibilityAdjustableAction { dir in
            var hs = app.hs
            hs.h = (hs.h + (dir == .increment ? 5 : -5) + 360).truncatingRemainder(dividingBy: 360)
            app.pick(hs)
        }
    }
}

/// «Если цвета на ленте не совпадают»
struct ColorFixCard: View {
    @EnvironmentObject var app: AppModel
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { open.toggle() }
            } label: {
                HStack {
                    Text("Если цвета на ленте не совпадают").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                }
                .foregroundStyle(.white.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                HStack(spacing: 10) {
                    Text("Порядок цветов").foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Picker("Порядок цветов", selection: $app.order) {
                        ForEach(colorOrders, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                }
                Button("Проверка: красный") { app.testRed() }
                    .buttonStyle(GlassButtonStyle())
                Toggle("Коррекция оттенков", isOn: $app.gamma).tint(.green)
                Hint("У этой ленты порядок GRB. Если «Проверка: красный» горит не красным, меняй порядок, пока не загорится красный.")
            }
        }
        .card(padding: 18)
    }
}
