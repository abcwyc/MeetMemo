import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject var langMgr: LanguageManager
    @ObservedObject private var appearanceMgr = AppearanceManager.shared
    @Binding var navigationPath: NavigationPath
    @State private var selectedSection: SettingsSection = .general
    @State private var micPermissionGranted = false
    @State private var systemAudioPermissionGranted = false
    @State private var audioRecordingPermission = AudioRecordingPermission()
    private let llmSetupGuideURL = URL(string: "https://file.348580.xyz/2026/05/8fdfba8153b5029297b42f4ac6c4d00d.html")!

    init(viewModel: SettingsViewModel, navigationPath: Binding<NavigationPath> = .constant(NavigationPath())) {
        self.viewModel = viewModel
        self._navigationPath = navigationPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTabBar(selectedSection: $selectedSection)
                .environmentObject(langMgr)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedSection {
                    case .general:
                        generalSettings
                    case .model:
                        modelSettings
                    case .prompt:
                        promptSettings
                    }

                    saveButton
                }
                .padding(24)
            }
        }
        .navigationTitle(langMgr.t("设置", "Settings"))
        .frame(minWidth: 600, minHeight: 600)
        .onAppear {
            viewModel.loadTemplates()
            viewModel.loadProviderConfig()
            checkPermissions()
        }
        .onChange(of: audioRecordingPermission.status) { _, newValue in
            systemAudioPermissionGranted = (newValue == .authorized)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
        .onDisappear {
            DispatchQueue.main.async {
                viewModel.saveSettings(showMessage: false)
            }
        }
        .alert(item: $viewModel.activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(langMgr.t("确定", "OK")))
            )
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text(langMgr.t("所需权限", "Required Permissions"))
                    .font(.headline)
                    .foregroundColor(.primary)

                VStack(spacing: 12) {
                    PermissionRow(
                        title: langMgr.t("麦克风权限", "Microphone Access"),
                        description: langMgr.t("用于转录您在会议中说的话", "Required to transcribe what you say in meetings"),
                        isGranted: micPermissionGranted,
                        grantedLabel: langMgr.t("已授权", "Granted"),
                        enableLabel: langMgr.t("授权", "Enable"),
                        action: requestMicrophonePermission
                    )

                    PermissionRow(
                        title: langMgr.t("系统录音权限", "System Audio Recording"),
                        description: langMgr.t("用于转录会议中他人说的话", "Required to transcribe what others say in meetings"),
                        isGranted: systemAudioPermissionGranted,
                        grantedLabel: langMgr.t("已授权", "Granted"),
                        enableLabel: langMgr.t("授权", "Enable"),
                        action: requestSystemAudioPermission
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("语言", "Language"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Picker("", selection: $langMgr.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("外观", "Appearance"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Picker("", selection: $appearanceMgr.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { mode in
                        Text(langMgr.t(mode.chineseLabel, mode.englishLabel)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(langMgr.t("语音识别服务", "Speech Recognition"))
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Button {
                        viewModel.testSTTConnection()
                    } label: {
                        if viewModel.isTestingSTT {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(langMgr.t("测试连接", "Test Connection"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isTestingSTT)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(langMgr.t(
                        "豆包流式语音识别，在火山引擎控制台获取 APP ID 和 Access Token。",
                        "Doubao streaming speech recognition. Get APP ID and Access Token from the Volcano Engine console."
                    ))
                    .foregroundColor(.secondary)

                    Link(
                        langMgr.t("配置教程", "Setup Guide"),
                        destination: URL(string: "https://file.348580.xyz/2026/04/eb299b186e0b531ffebceb9141eaf2fb.html")!
                    )
                    .buttonStyle(.link)
                }
                .font(.caption)

                TextField("APP ID", text: $viewModel.settings.sttAppId)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                SecureField("Access Token", text: $viewModel.settings.sttAccessToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(langMgr.t("LLM 配置", "LLM Configuration"))
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Button {
                        viewModel.testLLMConnection()
                    } label: {
                        if viewModel.isTestingLLM {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(langMgr.t("测试连接", "Test Connection"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isTestingLLM)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(langMgr.t(
                        "填写 Base URL、API Key 和 Model Name 即可。Anthropic 地址会使用 Messages API，其他地址会使用 OpenAI 兼容的 Chat Completions API。",
                        "Fill in Base URL, API Key, and Model Name. Anthropic URLs use the Messages API; other URLs use the OpenAI-compatible Chat Completions API."
                    ))
                    .foregroundColor(.secondary)

                    Link(
                        langMgr.t("LLM配置教程", "LLM Setup Guide"),
                        destination: llmSetupGuideURL
                    )
                    .buttonStyle(.link)
                }
                .font(.caption)

                SecureField("API Key", text: $viewModel.settings.llmApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                TextField("Base URL", text: $viewModel.settings.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                TextField("Model Name", text: $viewModel.settings.llmModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var promptSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("笔记模板", "Note Templates"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(langMgr.t("创建和管理笔记模板", "Create and manage note templates"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    navigationPath.append("templates")
                } label: {
                    Text(langMgr.t("管理模板", "Manage Templates"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("用户信息", "User Information"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(langMgr.t(
                    "在了解您的一些背景信息后，生成效果更佳。请填写您的姓名、职位、公司及其他相关信息。",
                    "Generated notes work best when they include a bit of your background. You should give your name, role, company, and any other relevant information."
                ))
                .font(.caption)
                .foregroundColor(.secondary)

                TextEditor(text: $viewModel.settings.userBlurb)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(langMgr.t("系统提示词", "System Prompt"))
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Button {
                        viewModel.resetToDefaults()
                    } label: {
                        Text(langMgr.t("恢复默认", "Reset to Default"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                TextEditor(text: $viewModel.settings.systemPrompt)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }

    private var saveButton: some View {
        HStack {
            Spacer()

            Button {
                viewModel.saveSettings()
            } label: {
                Text(langMgr.t("保存设置", "Save Settings"))
                    .font(.headline)
                    .frame(width: 180)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.top)
    }

    private func checkPermissions() {
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudioPermissionGranted = (audioRecordingPermission.status == .authorized)
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micPermissionGranted = granted
                if !granted {
                    viewModel.activeAlert = AlertMessage(
                        title: langMgr.t("需要权限", "Permission Required"),
                        message: langMgr.t(
                            "录制会议需要麦克风权限，请在「系统设置 > 隐私与安全性 > 麦克风」中开启。",
                            "Microphone access is required for recording meetings. Please enable it in System Preferences > Security & Privacy > Privacy > Microphone."
                        )
                    )
                }
            }
        }
    }

    private func requestSystemAudioPermission() {
        audioRecordingPermission.request()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if audioRecordingPermission.status == .denied {
                viewModel.activeAlert = AlertMessage(
                    title: langMgr.t("需要权限", "Permission Required"),
                    message: langMgr.t(
                        "需要系统录音权限才能捕获他人的声音，请在「系统设置 > 隐私与安全性 > 麦克风」中为本应用开启。",
                        "System audio recording access is required to capture what others say in meetings. Please enable this app in System Preferences > Security & Privacy > Privacy > Microphone."
                    )
                )
            }
        }
    }
}

private struct SettingsSectionTabBar: View {
    @EnvironmentObject var langMgr: LanguageManager
    @Binding var selectedSection: SettingsSection
    @State private var hoveredSection: SettingsSection?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Text(section.title(using: langMgr))
                        .font(.system(size: 13, weight: selectedSection == section ? .semibold : .medium))
                        .foregroundColor(selectedSection == section ? .primary : .secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if selectedSection == section || hoveredSection == section {
                                Capsule(style: .continuous)
                                    .fill(tabBackgroundColor(for: section))
                            }
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Capsule(style: .continuous))
                .onHover { isHovering in
                    hoveredSection = isHovering ? section : (hoveredSection == section ? nil : hoveredSection)
                }
            }
        }
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabBackgroundColor(for section: SettingsSection) -> Color {
        if selectedSection == section {
            return Color.secondary.opacity(0.18)
        }

        return Color.secondary.opacity(0.10)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case model
    case prompt

    var id: Self { self }

    func title(using langMgr: LanguageManager) -> String {
        switch self {
        case .general:
            return langMgr.t("通用", "General")
        case .model:
            return langMgr.t("模型", "Model")
        case .prompt:
            return langMgr.t("提示词", "Prompt")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView(viewModel: SettingsViewModel())
            .environmentObject(LanguageManager.shared)
    }
}
