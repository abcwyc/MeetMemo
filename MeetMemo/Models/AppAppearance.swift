import AppKit

enum AppAppearance: String, CaseIterable, Codable {
    case light = "light"
    case dark = "dark"

    var chineseLabel: String {
        switch self {
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }

    var englishLabel: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearanceName: NSAppearance.Name {
        switch self {
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}
