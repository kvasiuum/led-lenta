import Foundation
import AVFoundation

struct SchedItem: Codable, Identifiable, Equatable {
    var id: String
    var time: String          // "HH:MM"
    var days: [Int]           // 0 = Вс … 6 = Сб
    var act: String           // "on" | "off"
    var on: Bool
}

let dayShort = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]

func daysText(_ days: [Int]) -> String {
    let set = Array(Set(days)).sorted()
    if set.count == 7 { return "Каждый день" }
    if set == [1, 2, 3, 4, 5] { return "По будням" }
    if set == [0, 6] { return "По выходным" }
    return [1, 2, 3, 4, 5, 6, 0].filter { set.contains($0) }.map { dayShort[$0] }.joined(separator: ", ")
}

/// Таймер сна и расписание по дням недели. Проверка раз в 10 секунд, окно в 2 минуты.
final class TimerModel: ObservableObject {
    private var s: Services { .shared }

    @Published private(set) var sleepAt: Date?
    @Published private(set) var sched: [SchedItem] = Prefs.get("sched", [SchedItem]())
    @Published var keepAlive: Bool = Prefs.get("bgTimers", false) {
        didSet { Prefs.set("bgTimers", keepAlive); updateKeepAlive() }
    }
    private var fired: [String: String] = Prefs.get("schedFired", [String: String]())
    private var timer: Timer?
    private var silent: AVAudioPlayer?

    func start() {
        let at = Prefs.get("sleepAt", 0.0)
        sleepAt = at > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: at) : nil
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
        updateKeepAlive()
    }

    // MARK: - Таймер сна

    func setSleep(minutes: Int) {
        sleepAt = Date().addingTimeInterval(Double(minutes) * 60)
        Prefs.set("sleepAt", sleepAt!.timeIntervalSince1970)
        updateKeepAlive()
    }

    func cancelSleep() {
        sleepAt = nil
        Prefs.set("sleepAt", 0.0)
        updateKeepAlive()
    }

    // MARK: - Расписание

    func add(time: Date, days: [Int], act: String) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hhmm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        sched.append(SchedItem(id: String(Int(Date().timeIntervalSince1970 * 1000), radix: 36),
                               time: hhmm, days: days, act: act, on: true))
        save()
        s.app.showToast("\(act == "on" ? "Включение" : "Выключение") в \(hhmm), \(daysText(days).lowercased())")
    }

    func toggle(_ id: String) {
        guard let i = sched.firstIndex(where: { $0.id == id }) else { return }
        sched[i].on.toggle()
        save()
    }

    func remove(_ id: String) {
        sched.removeAll { $0.id == id }
        save()
        s.app.showToast("Удалено из расписания")
    }

    var sorted: [SchedItem] { sched.sorted { $0.time < $1.time } }

    private func save() {
        Prefs.set("sched", sched)
        updateKeepAlive()
    }

    // MARK: - Проверка

    private func check() {
        let now = Date()
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let today = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let weekday = (c.weekday ?? 1) - 1          // Calendar: 1 = Вс → 0
        for item in sched where item.on && item.days.contains(weekday) && fired[item.id] != today {
            let p = item.time.split(separator: ":").compactMap { Int($0) }
            guard p.count == 2 else { continue }
            let at = p[0] * 60 + p[1]
            if mins >= at && mins < at + 2 {
                fired[item.id] = today
                Prefs.set("schedFired", fired)
                action(item.act, why: "Расписание")
            }
        }
        if let at = sleepAt, now >= at {
            sleepAt = nil
            Prefs.set("sleepAt", 0.0)
            action("off", why: "Таймер сна")
            updateKeepAlive()
        }
        objectWillChange.send()          // «через N мин»
    }

    private func action(_ act: String, why: String) {
        let ble = s.ble, app = s.app
        if !ble.isConnected { ble.autoConnect() }
        waitConnected(tries: 32) { ok in
            guard ok else { app.showToast("\(why): лента не подключена"); return }
            app.setPower(act == "on")
            if act == "on" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.sendColor(app.currentRGB) }
            }
            app.showToast("\(why): лента \(act == "on" ? "включена" : "выключена")")
        }
    }

    private func waitConnected(tries: Int, _ done: @escaping (Bool) -> Void) {
        if s.ble.isConnected { done(true); return }
        if tries <= 0 { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.waitConnected(tries: tries - 1, done) }
    }

    // MARK: - Работа в фоне

    private var armed: Bool { sleepAt != nil || sched.contains { $0.on } }

    /// iOS усыпляет свёрнутое приложение. Если включено «Работать в фоне» и есть таймер,
    /// играем тишину — тогда приложение не засыпает и таймеры срабатывают.
    func updateKeepAlive() {
        let busy = s.music.micActive || s.player.playing
        let want = keepAlive && armed && !busy
        if want && silent == nil {
            AudioSessionManager.activate(mix: true)
            if let p = try? AVAudioPlayer(data: Self.silenceWAV) {
                p.numberOfLoops = -1
                p.volume = 0
                p.play()
                silent = p
            }
        } else if !want, let p = silent {
            p.stop()
            silent = nil
        }
    }

    /// 1 секунда тишины, 8 кГц, 16 бит
    private static let silenceWAV: Data = {
        let rate: UInt32 = 8000, samples: UInt32 = 8000
        let dataSize = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }()
}
