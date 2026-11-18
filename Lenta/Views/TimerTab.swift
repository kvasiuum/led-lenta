import SwiftUI

struct TimerTab: View {
    @EnvironmentObject var timers: TimerModel

    @State private var time: Date = {
        Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date()) ?? Date()
    }()
    @State private var act = "on"
    @State private var days: Set<Int> = [0, 1, 2, 3, 4, 5, 6]

    var body: some View {
        VStack(spacing: 14) {
            // ---- таймер сна
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle("Выключить через")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach([15, 30, 60, 120], id: \.self) { m in
                        Button(m < 60 ? "\(m) мин" : (m == 60 ? "1 час" : "\(m / 60) часа")) { timers.setSleep(minutes: m) }
                            .buttonStyle(GlassButtonStyle(height: 44))
                            .font(.subheadline)
                    }
                }
                if let at = timers.sleepAt {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            (Text("Выключится в ") + Text(at, format: .dateTime.hour().minute()).bold())
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(left(at)).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Button("Отменить") { timers.cancelSleep() }
                            .buttonStyle(GlassButtonStyle(height: 40))
                            .fixedSize()
                    }
                    .padding(14)
                    .background(Web.fill, in: RoundedRectangle(cornerRadius: Web.rMd, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .card()
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: timers.sleepAt)

            // ---- расписание
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle("Расписание")
                if timers.sched.isEmpty {
                    Hint("Пока пусто. Например: включать в 7:30 по будням, выключать в 0:30 каждый день.")
                }
                ForEach(timers.sorted) { item in
                    HStack(spacing: 14) {
                        Text(item.time).font(.system(size: 26, weight: .semibold)).tracking(-0.5).monospacedDigit().fixedSize()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.act == "on" ? "Включить" : "Выключить").font(.subheadline.weight(.semibold))
                            Text(daysText(item.days)).font(.subheadline).foregroundStyle(Web.muted).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(get: { item.on }, set: { _ in timers.toggle(item.id) }))
                            .labelsHidden()
                            .tint(.green)
                            .accessibilityLabel("\(item.act == "on" ? "Включить" : "Выключить") в \(item.time)")
                        Button { timers.remove(item.id) } label: {
                            Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(Web.muted)
                                .frame(width: 36, height: 36).contentShape(Circle())
                        }
                        .buttonStyle(PressScale())
                        .accessibilityLabel("Удалить")
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(Web.fill, in: RoundedRectangle(cornerRadius: Web.rMd, style: .continuous))
                    .opacity(item.on ? 1 : 0.55)
                }

                // форма — пунктирная рамка, как на сайте
                VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    DatePicker("Время", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    SegPicker(selection: $act, items: [("on", "Включить"), ("off", "Выключить")], label: "Действие")
                }

                HStack(spacing: 6) {
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                        let on = days.contains(d)
                        Button(dayShort[d]) {
                            if on { days.remove(d) } else { days.insert(d) }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(on ? Color.white : Web.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(on ? Web.fillOn : Color.clear, in: RoundedRectangle(cornerRadius: Web.rSm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Web.rSm, style: .continuous).strokeBorder(on ? Color.clear : Web.line, lineWidth: 1))
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }

                HStack(spacing: 10) { presets }

                Button("Добавить в расписание") {
                    guard !days.isEmpty else { Services.shared.app.showToast("Выбери хотя бы один день"); return }
                    timers.add(time: time, days: Array(days), act: act)
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                }
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: Web.rMd, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            .card()
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: timers.sched)

            // ---- фон
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Работать в фоне", isOn: $timers.keepAlive).tint(.green).font(.subheadline.weight(.medium))
                Hint("iOS усыпляет свёрнутые приложения. С этим переключателем «Лента» не засыпает, пока стоит таймер или расписание, и срабатывает вовремя. Расходует немного больше батареи. Лента должна быть в зоне Bluetooth.")
            }
            .card(padding: 18)
        }
    }

    @ViewBuilder
    private var presets: some View {
        preset("Каждый день", [0, 1, 2, 3, 4, 5, 6])
        preset("Будни", [1, 2, 3, 4, 5])
        preset("Выходные", [0, 6])
    }

    private func preset(_ title: String, _ set: [Int]) -> some View {
        // как на сайте: подчёркнутые серые ссылки
        Button { days = Set(set) } label: {
            Text(title).underline().font(.footnote).foregroundStyle(Web.muted)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
    }

    private func left(_ at: Date) -> String {
        let m = Int(ceil(max(0, at.timeIntervalSinceNow) / 60))
        return m >= 60 ? "через \(m / 60) ч \(m % 60) мин" : "через \(m) мин"
    }
}
