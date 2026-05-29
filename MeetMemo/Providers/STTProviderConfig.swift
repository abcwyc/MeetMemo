import Foundation

struct STTProviderConfig: Hashable {
    var locale: Locale

    var isConfigured: Bool { true }

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
    }
}
