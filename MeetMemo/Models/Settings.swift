import Foundation

struct Settings: Codable {
    var llmApiKey: String = ""
    var llmBaseURL: String = ""
    var llmModel: String = ""
    /// 选中的 LLM 预设：供应商 id、`LLMPresetProviders.customPresetID` 或空（尚未选择）。
    var llmPresetID: String = ""

    // Computed properties that access UserDefaults
    var userBlurb: String {
        get { UserDefaultsManager.shared.userBlurb }
        set { UserDefaultsManager.shared.userBlurb = newValue }
    }

    var systemPrompt: String {
        get { UserDefaultsManager.shared.systemPrompt }
        set { UserDefaultsManager.shared.systemPrompt = newValue }
    }

    var selectedTemplateId: UUID? {
        get { UserDefaultsManager.shared.selectedTemplateId }
        set { UserDefaultsManager.shared.selectedTemplateId = newValue }
    }

    var hasCompletedOnboarding: Bool {
        get { UserDefaultsManager.shared.hasCompletedOnboarding }
        set { UserDefaultsManager.shared.hasCompletedOnboarding = newValue }
    }

    var hasAcceptedTerms: Bool {
        get { UserDefaultsManager.shared.hasAcceptedTerms }
        set { UserDefaultsManager.shared.hasAcceptedTerms = newValue }
    }

    var appLanguage: AppLanguage {
        get { UserDefaultsManager.shared.appLanguage }
        set { UserDefaultsManager.shared.appLanguage = newValue }
    }

    var appAppearance: AppAppearance {
        get { UserDefaultsManager.shared.appAppearance }
        set { UserDefaultsManager.shared.appAppearance = newValue }
    }

    var notesOutputFormat: NotesOutputFormat {
        get { UserDefaultsManager.shared.notesOutputFormat }
        set { UserDefaultsManager.shared.notesOutputFormat = newValue }
    }

    var sttLocaleIdentifier: String {
        get { UserDefaultsManager.shared.sttLocaleIdentifier }
        set { UserDefaultsManager.shared.sttLocaleIdentifier = newValue }
    }

    var enableSystemAudioSTT: Bool {
        get { UserDefaultsManager.shared.enableSystemAudioSTT }
        set { UserDefaultsManager.shared.enableSystemAudioSTT = newValue }
    }

    // System prompt default loading
    static func defaultSystemPrompt() -> String {
        guard let path = Bundle.main.path(forResource: "DefaultSystemPrompt", ofType: "txt"),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "你是一个会议纪要助手，请根据会议转写、用户笔记和模板提示词生成清晰、可执行的中文会议纪要。"
        }
        return content
    }

    var fullSystemPrompt: String {
        // Dynamic profile data belongs in the lower-authority user message.
        // Keep this compatibility accessor instruction-only as well.
        Settings.defaultSystemPrompt()
    }

    static func processTemplate(_ template: String, with variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }

    init(
        llmApiKey: String = "",
        llmBaseURL: String = "",
        llmModel: String = "",
        llmPresetID: String = ""
    ) {
        self.llmApiKey = llmApiKey
        self.llmBaseURL = llmBaseURL
        self.llmModel = llmModel
        self.llmPresetID = llmPresetID
    }

    // Keychain 里的旧 JSON 可能缺少较新的字段（如 llmPresetID），逐字段兜底解码。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        llmApiKey = try container.decodeIfPresent(String.self, forKey: .llmApiKey) ?? ""
        llmBaseURL = try container.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? ""
        llmPresetID = try container.decodeIfPresent(String.self, forKey: .llmPresetID) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case llmApiKey
        case llmBaseURL
        case llmModel
        case llmPresetID
    }
}
