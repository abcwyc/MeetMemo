import SwiftUI

/// 供应商预设选择 + 凭证填写，供设置页与引导页共用。
/// 选中预设后只暴露 API Key 与模型下拉；选择「自定义」时展示全部三个手动字段。
struct LLMProviderConfigSection: View {
    @Binding var settings: Settings
    @EnvironmentObject private var langMgr: LanguageManager
    /// 用户显式选择“手动输入…”。仅存在派生值会让 Picker 选完 .manual 后立即弹回原模型。
    @State private var isManualModelEntry = false
    /// 会话内按供应商记忆 API Key：切换时清空输入框避免残留别家的 key 造成已输入的错觉，
    /// 切回时自动恢复。跨启动仍只持久化当前激活供应商的 key。
    @State private var apiKeysByPreset: [String: String] = [:]

    private enum ModelOption: Hashable {
        case preset(String)
        case manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerGrid

            if let preset = activePreset {
                presetFields(for: preset)
            } else {
                customFields
            }
        }
    }

    // MARK: - Provider grid

    private var providerGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
            ForEach(LLMPresetProviders.all) { preset in
                LLMProviderCard(
                    title: preset.name(langMgr),
                    badgeText: preset.badgeText,
                    badgeColor: preset.badgeColor,
                    isSelected: activePreset?.id == preset.id
                ) {
                    select(preset)
                }
            }

            LLMProviderCard(
                title: langMgr.t("自定义", "Custom"),
                badgeText: "⚙",
                badgeColor: Color(nsColor: .systemGray),
                isSelected: activePreset == nil
            ) {
                // 自定义通常沿用同一把 key 换地址（如代理），字段保持现状，只记住原供应商的 key。
                if let current = activePreset {
                    rememberAPIKey(for: current)
                }
                settings.llmPresetID = LLMPresetProviders.customPresetID
            }
        }
    }

    // MARK: - Preset fields

    @ViewBuilder
    private func presetFields(for preset: LLMPresetProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField("API Key", text: $settings.llmApiKey)
                    .textFieldStyle(.roundedBorder)

                if let keyURL = URL(string: preset.apiKeyURL) {
                    Link(langMgr.t("获取 Key ↗", "Get Key ↗"), destination: keyURL)
                        .buttonStyle(.link)
                }
            }

            Picker(langMgr.t("模型", "Model"), selection: modelSelection(for: preset)) {
                ForEach(preset.recommendedModels, id: \.self) { model in
                    Text(model).tag(ModelOption.preset(model))
                }
                Text(langMgr.t("手动输入…", "Manual Input…")).tag(ModelOption.manual)
            }
            .pickerStyle(.menu)

            if case .manual = currentModelOption(for: preset) {
                TextField("Model Name", text: $settings.llmModel)
                    .textFieldStyle(.roundedBorder)
            }

            Text(preset.baseURL)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var customFields: some View {
        VStack(spacing: 8) {
            SecureField("API Key", text: $settings.llmApiKey)
                .textFieldStyle(.roundedBorder)

            TextField("Base URL", text: $settings.llmBaseURL)
                .textFieldStyle(.roundedBorder)

            TextField("Model Name", text: $settings.llmModel)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - State helpers

    private var activePreset: LLMPresetProvider? {
        LLMPresetProviders.resolve(for: settings)
    }

    /// 切换预设：自动填充 Base URL 与默认模型，API Key 换成该供应商自己记忆的那把（没有则留空）。
    private func select(_ preset: LLMPresetProvider) {
        guard activePreset?.id != preset.id else { return }
        if let current = activePreset {
            rememberAPIKey(for: current)
        }
        settings.llmPresetID = preset.id
        settings.llmBaseURL = preset.baseURL
        settings.llmModel = preset.defaultModel
        settings.llmApiKey = apiKeysByPreset[preset.id] ?? ""
        isManualModelEntry = false
    }

    private func rememberAPIKey(for preset: LLMPresetProvider) {
        let key = settings.llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            apiKeysByPreset.removeValue(forKey: preset.id)
        } else {
            apiKeysByPreset[preset.id] = settings.llmApiKey
        }
    }

    private func currentModelOption(for preset: LLMPresetProvider) -> ModelOption {
        if isManualModelEntry {
            return .manual
        }
        if preset.recommendedModels.contains(settings.llmModel) {
            return .preset(settings.llmModel)
        }
        if settings.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .preset(preset.defaultModel)
        }
        return .manual
    }

    private func modelSelection(for preset: LLMPresetProvider) -> Binding<ModelOption> {
        Binding<ModelOption>(
            get: { currentModelOption(for: preset) },
            set: { option in
                switch option {
                case .preset(let model):
                    settings.llmModel = model
                    isManualModelEntry = false
                case .manual:
                    // 保留当前模型名作为可编辑的起始值。
                    isManualModelEntry = true
                }
            }
        )
    }
}

private struct LLMProviderCard: View {
    let title: String
    let badgeText: String
    let badgeColor: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Text(badgeText)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    )

                Text(title)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : Color(NSColor.separatorColor),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
