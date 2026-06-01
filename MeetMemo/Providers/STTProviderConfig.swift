import Foundation

struct STTProviderConfig: Hashable {
    var locale: Locale
    var engine: STTEngine

    var isConfigured: Bool { true }

    init(
        locale: Locale = Locale(identifier: "zh-CN"),
        engine: STTEngine = .sherpaSenseVoice
    ) {
        self.locale = locale
        self.engine = engine
    }
}
