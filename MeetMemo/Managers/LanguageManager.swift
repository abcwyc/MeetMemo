import Foundation

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var language: AppLanguage {
        didSet {
            UserDefaultsManager.shared.appLanguage = language
        }
    }

    init() {
        self.language = UserDefaultsManager.shared.appLanguage
    }

    func t(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
}
