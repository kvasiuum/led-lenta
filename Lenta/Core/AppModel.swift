import SwiftUI

enum NowKind { case color, fx, music, off }

/// Цвет, яркость, питание, встроенные режимы, порядок каналов и подсказки.
final class AppModel: ObservableObject {
    private var s: Services { .shared }

    @Published var hs: HS = Prefs.get("hs", HS(h: 0, s: 1))
    @Published var brightness: Double = Prefs.get("bright", 100.0)
    @Published private(set) var powered = true
    @Published private(set) var now: NowKind = .color
    private var lastKind: NowKind = .color

    // режимы
    @Published private(set) var fx: Int = Prefs.get("fx", 1)
    @Published private(set) var favs: [Int] = Prefs.get("favs", [Int]())
    @Published private(set) var autoFx = false
    private var autoTimer: Timer?

    // если цвета не совпадают
    @Published var order: String = Prefs.get("order", "GRB") {
        didSet { Prefs.set("order", order); applyColor() }
    }
    @Published var gamma: Bool = Prefs.get("gamma", true) {
        didSet { Prefs.set("gamma", gamma); applyColor() }
    }

    // всплывающая подсказка
    @Published private(set) var toast: String?
    private var toastWork: DispatchWorkItem?

    var currentRGB: RGB { hsv2rgb(hs.h, hs.s, 1) }

    // MARK: - Отправка

    func toStrip(_ c: RGB) -> [UInt8] {
        var r = clamp(c.r, 0, 255), g = clamp(c.g, 0, 255), b = clamp(c.b, 0, 255)
        if gamma { r = gammaTable[r]; g = gammaTable[g]; b = gammaTable[b] }
        let map: [Character: Int] = ["R": r, "G": g, "B": b]
        return order.map { UInt8(map[$0] ?? 0) }
    }

    func sendColor(_ c: RGB) {
        let v = toStrip(c)
        s.ble.send("color", Cmd.color(v[0], v[1], v[2]))
    }

    /// true — ленты нет, показана подсказка
    @discardableResult
    func needConn() -> Bool {
        if !s.ble.isConnected { showToast("Сначала подключи ленту"); return true }
        return false
    }

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = text }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: w)
    }

    // MARK: - Цвет

    func pick(_ newHS: HS) {
        hs = newHS
        applyColor()
    }

    func pick(rgb: RGB) {
        hs = rgb2hs(rgb)
        applyColor()
    }

    func applyColor(send: Bool = true) {
        Prefs.set("hs", hs)
        let musicOn = s.light.running
        if !musicOn && (send || now == .color) { setNow(.color) }
        if send && !musicOn {
            stopAutoFx()
            sendColor(currentRGB)
        }
    }

    func setBrightness(_ v: Double) {
        let p = Int(v.rounded())
        guard p != Int(brightness.rounded()) else { brightness = v; return }
        brightness = v
        Prefs.set("bright", Double(p))
        s.ble.send("brightness", Cmd.brightness(p))
    }

    func testRed() {
        if needConn() { return }
        sendColor(.red)
    }

    // MARK: - Питание

    func setPower(_ on: Bool) {
        powered = on
        if !on { stopAllMusic() }
        s.ble.send("power", Cmd.power(on))
        setNow(on ? lastKind : .off)
    }

    func togglePower() {
        if needConn() { return }
        setPower(!powered)
    }

    func stopAllMusic() {
        s.player.pauseActive()
        s.music.stopMic()
    }

    func setNow(_ kind: NowKind) {
        var k = kind
        if !powered && k != .off { lastKind = k; k = .off }
        if k != .off { lastKind = k }
        now = k
    }

    var nowTitle: String {
        switch now {
        case .off: return "Выключено"
        case .fx: return "Режим \(fx)"
        case .music: return "Под музыку"
        case .color: return "Статичный цвет"
        }
    }

    var nowSubtitle: String {
        switch now {
        case .off: return "Нажми кнопку питания, чтобы включить"
        case .fx: return autoFx ? "Автосмена каждые 10 секунд" : "Встроенный эффект контроллера"
        case .music: return s.light.mode.title
        case .color: return currentRGB.text
        }
    }

    // MARK: - Режимы 1–210

    func runFx(_ n: Int) {
        fx = ((n - 1) % 210 + 210) % 210 + 1
        Prefs.set("fx", fx)
        setNow(.fx)
        if needConn() { return }
        stopAllMusic()
        s.ble.send("effect", Cmd.effect(fx))
    }

    func stopAutoFx() {
        autoTimer?.invalidate()
        autoTimer = nil
        if autoFx { autoFx = false }
    }

    func toggleAutoFx() {
        if autoFx { stopAutoFx(); return }
        runFx(fx)
        autoFx = true
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.runFx(self.fx + 1)
        }
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
        setNow(.fx)
    }

    var isFav: Bool { favs.contains(fx) }

    func toggleFav() {
        if favs.contains(fx) { favs.removeAll { $0 == fx } } else { favs = (favs + [fx]).sorted() }
        Prefs.set("favs", favs)
    }

    func playFav(_ n: Int) {
        stopAutoFx()
        runFx(n)
    }
}

/// То, что лента показывает прямо сейчас под музыку (обновляется ~30 раз в секунду)
final class LiveLight: ObservableObject {
    @Published var level: Double = 0
    @Published var rgb: RGB = .red
}
