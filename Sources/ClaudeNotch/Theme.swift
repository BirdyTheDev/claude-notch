import SwiftUI

enum Theme {
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let claudeDeep = Color(red: 0.706, green: 0.322, blue: 0.212)
    static let green = Color(red: 0.42, green: 0.80, blue: 0.51)
    static let blue = Color(red: 0.42, green: 0.64, blue: 0.95)
    static let amber = Color(red: 0.98, green: 0.76, blue: 0.35)
    static let dim = Color(white: 0.55)

    static let panel = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let stroke = Color.white.opacity(0.08)
    static let chip = Color.white.opacity(0.06)
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
