import Foundation

enum AppLanguage: String, CaseIterable, Codable {
    case system = "system"
    case chinese = "zh"
    case english = "en"

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    func displayName(using langMgr: LanguageManager) -> String {
        switch self {
        case .system:
            return langMgr.t("跟随系统", "System")
        case .chinese:
            return "中文"
        case .english:
            return "English"
        }
    }
}
