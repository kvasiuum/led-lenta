import Foundation

/// Настройки в UserDefaults с префиксом «lenta.» — как localStorage в веб-версии.
enum Prefs {
    private static let defaults = UserDefaults.standard

    static func get<T: Decodable>(_ key: String, _ fallback: T) -> T {
        guard let data = defaults.data(forKey: "lenta." + key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    static func set<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: "lenta." + key)
        }
    }
}

func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(hi, max(lo, v)) }

/// 1 трек, 2 трека, 5 треков
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20) { return few }
    return many
}

/// 3:07
func fmtTime(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "0:00" }
    let total = Int(s)
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Случайный индекс, отличный от `not`
func rnd(_ n: Int, not: Int) -> Int {
    if n < 2 { return 0 }
    var i: Int
    repeat { i = Int.random(in: 0..<n) } while i == not
    return i
}

func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
