import Foundation

class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    @Published var appearance: AppAppearance {
        didSet {
            UserDefaultsManager.shared.appAppearance = appearance
        }
    }

    init() {
        self.appearance = UserDefaultsManager.shared.appAppearance
    }
}
