import Foundation

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    private var localeChangeObserver: NSObjectProtocol?

    @Published var language: AppLanguage {
        didSet {
            UserDefaultsManager.shared.appLanguage = language
        }
    }

    init() {
        self.language = UserDefaultsManager.shared.appLanguage
        localeChangeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func t(_ chinese: String, _ english: String) -> String {
        resolvedLanguage == .chinese ? chinese : english
    }

    private var resolvedLanguage: AppLanguage {
        switch language {
        case .system:
            return Self.systemLanguage
        case .chinese, .english:
            return language
        }
    }

    private static var systemLanguage: AppLanguage {
        let preferredLanguage = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferredLanguage.hasPrefix("zh") ? .chinese : .english
    }
}
