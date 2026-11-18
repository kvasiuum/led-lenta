import SwiftUI

/// Шапка: «Лента», статус, подключение/питание, превью ленты, яркость
struct DeviceCard: View {
    @EnvironmentObject var ble: LEDController
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Лента").font(.system(size: 30, weight: .bold)).tracking(-0.5)
                    StatusLine()
                }
                Spacer()
                if ble.isConnected {
                    Button { app.togglePower() } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(RoundIconButtonStyle(size: 54, filled: app.powered))
                    .accessibilityLabel(app.powered ? "Выключить ленту" : "Включить ленту")
                    .sensoryFeedback(.impact(weight: .medium), trigger: app.powered)
                    .contextMenu {
                        Button("Сменить ленту", systemImage: "arrow.triangle.2.circlepath") { ble.connectTapped() }
                        Button("Отключиться", systemImage: "xmark.circle", role: .destructive) { ble.disconnect() }
                    }
                } else {
                    Button(connectTitle) { ble.connectTapped() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }

            StripPreview().padding(.top, 20)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(app.nowTitle).font(.subheadline.weight(.semibold))
                    Text(app.nowSubtitle).font(.subheadline).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 6)
                SliderRow(label: "Яркость", value: "\(Int(app.brightness.rounded()))%",
                          v: Binding(get: { app.brightness }, set: { app.setBrightness($0) }),
                          range: 1...100, tint: app.currentRGB.color)
            }
            .padding(.top, 12)
        }
        .card()
        .sheet(isPresented: $ble.showPicker) { DevicePicker() }
    }

    private var connectTitle: String {
        if case .lost = ble.status { return "Переподключить" }
        return "Подключить"
    }
}

struct StatusLine: View {
    @EnvironmentObject var ble: LEDController

    var body: some View {
        let (text, color) = info
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.footnote).foregroundStyle(color == .red ? Color.red : Color.white.opacity(color == .green ? 1 : 0.6))
        }
        .animation(.easeOut(duration: 0.2), value: text)
    }

    private var info: (String, Color) {
        switch ble.status {
        case .idle: return ("Не подключено", .gray)
        case .bluetoothOff: return ("Bluetooth выключен", .red)
        case .unauthorized: return ("Нет доступа к Bluetooth", .red)
        case .unsupported: return ("Bluetooth недоступен", .red)
        case .searching: return ("Ищу ленту…", .gray)
        case .connecting: return ("Подключаюсь…", .gray)
        case .connected(let name): return (name, .green)
        case .reconnecting(let n): return ("Переподключаюсь… (\(n))", .gray)
        case .lost: return ("Соединение потеряно", .red)
        case .failed(let m): return (m, .red)
        }
    }
}

/// 24 светодиода: что лента показывает сейчас
struct StripPreview: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var live: LiveLight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { i in
                let (c, l) = dot(i)
                Circle()
                    .fill(c)
                    .frame(width: 8, height: 8)
                    .opacity(app.now == .off ? 1 : 0.25 + l * 0.75)
                    .shadow(color: app.now == .off ? .clear : c.opacity(0.9), radius: 3 + l * 6)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func dot(_ i: Int) -> (Color, Double) {
        switch app.now {
        case .off: return (Color(red: 0.15, green: 0.16, blue: 0.18), 0)
        case .fx: return (Color(hue: Double(i) / 24, saturation: 0.85, brightness: 1), 1)
        case .music: return (live.rgb.color, live.level)
        case .color: return (app.currentRGB.color, 1)
        }
    }
}

/// Поиск ленты: список найденных устройств и подсказки
struct DevicePicker: View {
    @EnvironmentObject var ble: LEDController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if ble.found.isEmpty {
                        HStack(spacing: 12) {
                            if ble.scanning { ProgressView() }
                            Text(ble.scanning ? "Ищу ленты рядом…" : "Ничего не нашлось")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(ble.found) { d in
                        Button { ble.choose(d.id) } label: {
                            HStack {
                                Image(systemName: d.matches ? "lightbulb.led.fill" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(d.matches ? Color.yellow : Color.secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading) {
                                    Text(d.name.isEmpty ? "Без имени" : d.name).foregroundStyle(.primary)
                                    Text(signal(d.rssi)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Найденные")
                } footer: {
                    Toggle("Показать все устройства", isOn: $ble.showAll).padding(.top, 8)
                }

                Section("Лента не нашлась? Проверь") {
                    Label("Родное приложение ленты и nRF Connect полностью закрыты (смахни вверх): лента держит одно подключение.", systemImage: "1.circle")
                    Label("Ноутбук отключён от ленты или его Bluetooth выключен.", systemImage: "2.circle")
                    Label("Настройки → Лента → Bluetooth включён.", systemImage: "3.circle")
                    Label("Вынь контроллер из розетки на 5 секунд и вставь обратно.", systemImage: "4.circle")
                }
                .font(.subheadline)
            }
            .navigationTitle("Подключить ленту")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { ble.stopScan(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if ble.scanning { ProgressView() }
                    else { Button("Искать") { ble.connectTapped() } }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func signal(_ rssi: Int) -> String {
        let q = rssi > -60 ? "отличный" : rssi > -75 ? "хороший" : rssi > -88 ? "слабый" : "очень слабый"
        return "Сигнал \(q) · \(rssi) дБм"
    }
}
