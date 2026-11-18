import SwiftUI

struct RGB: Codable, Equatable {
    var r: Int
    var g: Int
    var b: Int

    init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }

    static let white = RGB(255, 255, 255)
    static let red = RGB(255, 0, 0)

    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    func scaled(_ l: Double) -> RGB {
        RGB(Int((Double(r) * l).rounded()), Int((Double(g) * l).rounded()), Int((Double(b) * l).rounded()))
    }

    var text: String { "RGB \(r) · \(g) · \(b)" }
}

/// Оттенок (0–360) и насыщенность (0–1) точки на цветовом круге
struct HS: Codable, Equatable {
    var h: Double
    var s: Double
}

func hsv2rgb(_ h: Double, _ s: Double, _ v: Double) -> RGB {
    var hh = h.truncatingRemainder(dividingBy: 360)
    if hh < 0 { hh += 360 }
    func f(_ n: Double) -> Double {
        let k = (n + hh / 60).truncatingRemainder(dividingBy: 6)
        return v - v * s * max(0, min(k, 4 - k, 1))
    }
    return RGB(Int((f(5) * 255).rounded()), Int((f(3) * 255).rounded()), Int((f(1) * 255).rounded()))
}

func rgb2hs(_ c: RGB) -> HS {
    let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h = 0.0
    if d > 0 {
        if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
    }
    return HS(h: (h * 60 + 360).truncatingRemainder(dividingBy: 360), s: mx > 0 ? d / mx : 0)
}

/// Гамма 2.2: на ленте тёмные оттенки иначе выглядят слишком яркими
let gammaTable: [Int] = (0..<256).map { Int((255 * pow(Double($0) / 255, 2.2)).rounded()) }

let colorOrders = ["RGB", "RBG", "GRB", "GBR", "BRG", "BGR"]

/// 16 быстрых цветов
let presetColors: [RGB] = [
    RGB(255, 0, 0), RGB(255, 96, 0), RGB(255, 200, 0), RGB(0, 255, 0),
    RGB(0, 255, 200), RGB(0, 64, 255), RGB(150, 0, 255), RGB(255, 0, 160),
    RGB(255, 255, 255), RGB(255, 214, 170), RGB(255, 170, 80), RGB(255, 90, 90),
    RGB(90, 255, 140), RGB(90, 160, 255), RGB(230, 120, 255), RGB(120, 255, 255)
]
