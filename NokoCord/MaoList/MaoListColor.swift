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
        let own = luminance, background = other.luminance
        return (max(own, background) + 0.05) / (min(own, background) + 0.05)
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


/// Stable identifiers are persisted independently of the custom accent.
enum MLThemePreset: String, CaseIterable, Identifiable {
    case aurora, sunset, nebula, ocean, sakura, ember, meadow, twilight
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var hexColors: [String] {
        switch self {
        case .aurora: ["60E3B5", "65B8F5", "B697FF"]
        case .sunset: ["FFB36B", "F77DA7", "B58AFF"]
        case .nebula: ["B99AFF", "EF83D5", "789FFF"]
        case .ocean: ["5DDCD5", "68B9FF", "77E0B5"]
        case .sakura: ["FF9FCB", "F7BCD9", "CAA2F5"]
        case .ember: ["FF826C", "FFB354", "F4D878"]
        case .meadow: ["94DB78", "55CDA8", "C8E58A"]
        case .twilight: ["8294EF", "B680DA", "F29AB7"]
        }
    }
}
