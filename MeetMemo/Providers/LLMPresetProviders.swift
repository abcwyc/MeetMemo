import SwiftUI

/// 内置 LLM 供应商预设。选中后自动填充 Base URL 并提供推荐模型，
/// 用户只需填写该供应商的 API Key。
struct LLMPresetProvider: Identifiable, Hashable {
    let id: String
    let nameZh: String
    let nameEn: String
    let baseURL: String
    /// 推荐模型，首个为选中预设时的默认模型。
    let recommendedModels: [String]
    let apiKeyURL: String
    let badgeText: String
    let badgeColor: Color

    var defaultModel: String { recommendedModels[0] }

    func name(_ langMgr: LanguageManager) -> String {
        langMgr.t(nameZh, nameEn)
    }
}

/// 预设供应商清单。模型名会随厂商迭代过期，更新时只改这张表。
enum LLMPresetProviders {
    /// 用户显式选择“自定义”时写入的哨兵值；空字符串表示尚未选择（待按 Base URL 反查）。
    static let customPresetID = "custom"

    static let all: [LLMPresetProvider] = [
        LLMPresetProvider(
            id: "zhipu",
            nameZh: "智谱 GLM",
            nameEn: "Zhipu GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            recommendedModels: ["glm-5.3", "glm-5.3-flash", "glm-5.2"],
            apiKeyURL: "https://open.bigmodel.cn/usercenter/apikeys",
            badgeText: "Z",
            badgeColor: Color(red: 0.23, green: 0.36, blue: 1.00)
        ),
        LLMPresetProvider(
            id: "deepseek",
            nameZh: "DeepSeek",
            nameEn: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            recommendedModels: ["deepseek-chat", "deepseek-flash", "deepseek-reasoner"],
            apiKeyURL: "https://platform.deepseek.com/api_keys",
            badgeText: "DS",
            badgeColor: Color(red: 0.30, green: 0.42, blue: 1.00)
        ),
        LLMPresetProvider(
            id: "moonshot",
            nameZh: "Kimi",
            nameEn: "Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            recommendedModels: ["kimi-k3", "kimi-k2.6"],
            apiKeyURL: "https://platform.kimi.com",
            badgeText: "K",
            badgeColor: Color(red: 0.36, green: 0.36, blue: 0.84)
        ),
        LLMPresetProvider(
            id: "qwen",
            nameZh: "通义千问",
            nameEn: "Qwen",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            recommendedModels: ["qwen-plus", "qwen-max", "qwen-turbo"],
            apiKeyURL: "https://bailian.console.aliyun.com/?apiKey=1#/api-key",
            badgeText: "Q",
            badgeColor: Color(red: 0.38, green: 0.36, blue: 0.93)
        ),
        LLMPresetProvider(
            id: "doubao",
            nameZh: "豆包",
            nameEn: "Doubao",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            recommendedModels: [
                "doubao-seed-2-0-pro-260215",
                "doubao-seed-2-0-lite-260215",
                "doubao-seed-2-0-mini-260215"
            ],
            apiKeyURL: "https://console.volcengine.com/ark",
            badgeText: "DB",
            badgeColor: Color(red: 0.00, green: 0.62, blue: 0.62)
        ),
        LLMPresetProvider(
            id: "siliconflow",
            nameZh: "硅基流动",
            nameEn: "SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1",
            recommendedModels: ["deepseek-ai/DeepSeek-V4-Flash", "deepseek-ai/DeepSeek-V3", "Qwen/Qwen3-235B-A22B"],
            apiKeyURL: "https://cloud.siliconflow.cn/account/ak",
            badgeText: "SF",
            badgeColor: Color(red: 0.31, green: 0.49, blue: 1.00)
        ),
        LLMPresetProvider(
            id: "openai",
            nameZh: "OpenAI",
            nameEn: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            recommendedModels: ["gpt-6", "gpt-6-astra", "gpt-5.6"],
            apiKeyURL: "https://platform.openai.com/api-keys",
            badgeText: "O",
            badgeColor: Color(red: 0.06, green: 0.64, blue: 0.50)
        ),
        LLMPresetProvider(
            id: "anthropic",
            nameZh: "Claude",
            nameEn: "Claude",
            baseURL: "https://api.anthropic.com",
            recommendedModels: ["claude-sonnet-5", "claude-opus-5", "claude-fable-5"],
            apiKeyURL: "https://console.anthropic.com/settings/keys",
            badgeText: "C",
            badgeColor: Color(red: 0.85, green: 0.47, blue: 0.34)
        ),
        LLMPresetProvider(
            id: "gemini",
            nameZh: "Gemini",
            nameEn: "Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            recommendedModels: ["gemini-3-pro-preview", "gemini-3-flash-preview", "gemini-3.1-flash-lite-preview"],
            apiKeyURL: "https://aistudio.google.com/apikey",
            badgeText: "G",
            badgeColor: Color(red: 0.26, green: 0.52, blue: 0.96)
        ),
        LLMPresetProvider(
            id: "openrouter",
            nameZh: "OpenRouter",
            nameEn: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            recommendedModels: ["deepseek/deepseek-chat", "anthropic/claude-sonnet-5", "openai/gpt-6"],
            apiKeyURL: "https://openrouter.ai/settings/keys",
            badgeText: "OR",
            badgeColor: Color(red: 0.40, green: 0.41, blue: 1.00)
        )
    ]

    /// 当前配置实际命中的预设；用户显式选择“自定义”时返回 nil。
    /// 优先按已存的预设 id 解析，空 id 时按 Base URL 精确反查（兼容预设功能上线前的旧配置）。
    static func resolve(for settings: Settings) -> LLMPresetProvider? {
        guard settings.llmPresetID != customPresetID else {
            return nil
        }

        if let byID = provider(id: settings.llmPresetID) {
            return byID
        }

        return provider(matchingBaseURL: settings.llmBaseURL)
    }

    static func provider(id: String) -> LLMPresetProvider? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }
        return all.first { $0.id == trimmedID }
    }

    static func provider(matchingBaseURL baseURL: String) -> LLMPresetProvider? {
        let normalized = normalizeBaseURL(baseURL)
        guard !normalized.isEmpty else { return nil }
        return all.first { normalizeBaseURL($0.baseURL) == normalized }
    }

    /// 同一服务的地址常被等价地写成带或不带 `/v1` 后缀（如 https://api.deepseek.com），
    /// 匹配时忽略尾部斜杠与 `/v1` 差异。
    private static func normalizeBaseURL(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix("/v1") {
            value.removeLast(3)
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
