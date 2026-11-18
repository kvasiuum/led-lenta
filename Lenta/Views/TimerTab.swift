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
                HStack(spacing: 8) {
                    ForEach([15, 30, 60, 120], id: \.self) { m in
                        Button(m < 60 ? "\(m) мин" : (m == 60 ? "1 час" : "\(m / 60) часа")) { timers.setSleep(minutes: m) }
                            .buttonStyle(GlassButtonStyle(height: 44))
                            .font(.subheadline)
                    }
                }
                if let at = timers.sleepAt {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Лента выключится в ") + Text(at, format: .dateTime.hour().minute()).bold()
                            Text(left(at)).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Button("Отменить") { timers.cancelSleep() }
                            .buttonStyle(GlassButtonStyle(height: 40))
                            .fixedSize()
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    HStack(spacing: 12) {
                        Text(item.time).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.act == "on" ? "Включить" : "Выключить").font(.subheadline.weight(.semibold))
                            Text(daysText(item.days)).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { item.on }, set: { _ in timers.toggle(item.id) }))
                            .labelsHidden()
                            .tint(.green)
                            .accessibilityLabel("\(item.act == "on" ? "Включить" : "Выключить") в \(item.time)")
                        Button { timers.remove(item.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(RoundIconButtonStyle(size: 36))
                            .accessibilityLabel("Удалить")
                    }
                    .opacity(item.on ? 1 : 0.5)
                    .padding(.vertical, 4)
                }

                Divider().overlay(Color.white.opacity(0.08))

                HStack(spacing: 12) {
                    DatePicker("Время", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Picker("Действие", selection: $act) {
                        Text("Включить").tag("on")
                        Text("Выключить").tag("off")
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 6) {
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                        let on = days.contains(d)
                        Button(dayShort[d]) {
                            if on { days.remove(d) } else { days.insert(d) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Color.black : Color.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(on ? Color.white : Color.white.opacity(0.08), in: Circle())
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }

                HStack(spacing: 8) {
                    preset("Каждый день", [0, 1, 2, 3, 4, 5, 6])
                    preset("Будни", [1, 2, 3, 4, 5])
                    preset("Выходные", [0, 6])
                }

                Button("Добавить в расписание") {
                    guard !days.isEmpty else { Services.shared.app.showToast("Выбери хотя бы один день"); return }
                    timers.add(time: time, days: Array(days), act: act)
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
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

    private func preset(_ title: String, _ set: [Int]) -> some View {
        Button(title) { days = Set(set) }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Color.white.opacity(0.08), in: Capsule())
            .buttonStyle(.plain)
    }

    private func left(_ at: Date) -> String {
        let m = Int(ceil(max(0, at.timeIntervalSinceNow) / 60))
        return m >= 60 ? "через \(m / 60) ч \(m % 60) мин" : "через \(m) мин"
    }
}
