import Foundation

/// Small, deterministic sRGB palette math; no images, observers or runtime service.
struct MLRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        red = Double((number >> 16) & 255) / 255
        green = Double((number >> 8) & 255) / 255
        blue = Double(number & 255) / 255
    }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    func mixed(with other: Self, amount: Double) -> Self {
        let weight = min(1, max(0, amount))
        return Self(red: red + (other.red - red) * weight,
                    green: green + (other.green - green) * weight,
                    blue: blue + (other.blue - blue) * weight)
    }
    private var luminance: Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    func contrast(with other: Self) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
    func readable(on background: Self, dark: Bool) -> Self {
        guard contrast(with: background) < 4.5 else { return self }
        let target = Self(red: dark ? 1 : 0, green: dark ? 1 : 0, blue: dark ? 1 : 0)
        var lower = 0.0, upper = 1.0
        for _ in 0..<24 {
            let middle = (lower + upper) / 2
            if mixed(with: target, amount: middle).contrast(with: background) >= 4.5 { upper = middle }
            else { lower = middle }
        }
        return mixed(with: target, amount: upper)
    }
}
