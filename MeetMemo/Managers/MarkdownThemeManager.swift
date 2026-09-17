import Foundation

final class MarkdownThemeManager: ObservableObject {
    static let shared = MarkdownThemeManager()

    @Published var theme: MarkdownTheme {
        didSet {
            UserDefaultsManager.shared.markdownTheme = theme
        }
    }

    private init() {
        theme = UserDefaultsManager.shared.markdownTheme
    }
}
