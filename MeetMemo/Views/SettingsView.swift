import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject var langMgr: LanguageManager
    @ObservedObject private var appearanceMgr = AppearanceManager.shared
    @ObservedObject private var speechInstaller = SpeechModelInstaller.shared
    @ObservedObject private var sherpaModel = SherpaModelManager.shared
    @ObservedObject private var audioManager = AudioManager.shared
    @Binding var navigationPath: NavigationPath
    @State private var selectedSection: SettingsSection = .general
    @State private var micPermissionGranted = false
    @State private var systemAudioPermissionGranted = false
    @State private var audioRecordingPermission = AudioRecordingPermission()
    @State private var sttEngine: STTEngine = UserDefaultsManager.shared.sttEngine
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
            Task { await speechInstaller.checkModelAvailability() }
        }
        .onChange(of: audioRecordingPermission.status) { _, newValue in
            systemAudioPermissionGranted = (newValue == .authorized)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
            speechInstaller.refreshSpeechAuthorizationStatus()
            Task { await speechInstaller.checkModelAvailability() }
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
                        title: langMgr.t("语音识别权限", "Speech Recognition"),
                        description: langMgr.t("允许 macOS 本地语音识别处理会议音频", "Allows macOS on-device speech recognition to process meeting audio"),
                        isGranted: speechInstaller.isSpeechAuthorized,
                        grantedLabel: speechInstaller.speechAuthorizationLabel,
                        enableLabel: langMgr.t("授权", "Enable"),
                        action: requestSpeechPermission
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

            AppInfoCard()
        }
    }

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(langMgr.t("语音识别", "Speech Recognition"))
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(langMgr.t(
                    "选择识别引擎。macOS 内置引擎适合较新版本系统；本地 SenseVoice (sherpa-onnx) 适用于更老系统并支持发言人区分，需先下载模型。",
                    "Choose a speech recognition engine. The macOS built-in engine targets newer systems; the local SenseVoice (sherpa-onnx) engine works on older macOS and supports speaker labels — model download required."
                ))
                .font(.caption)
                .foregroundColor(.secondary)

                Picker("", selection: $sttEngine) {
                    Text(langMgr.t("macOS 内置", "macOS Built-in")).tag(STTEngine.appleSpeechAnalyzer)
                    Text(langMgr.t("本地 SenseVoice", "Local SenseVoice")).tag(STTEngine.sherpaSenseVoice)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(audioManager.isRecording)
                .onChange(of: sttEngine) { _, newValue in
                    UserDefaultsManager.shared.sttEngine = newValue
                }

                if audioManager.isRecording {
                    Text(langMgr.t("录音过程中无法切换识别引擎，请先结束当前录音。",
                                   "Cannot switch the engine while recording. Stop the current session first."))
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                if sttEngine == .appleSpeechAnalyzer {
                    appleSpeechEngineCard
                } else {
                    sherpaSenseVoiceEngineCard
                }
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

    private var appleSpeechEngineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(langMgr.t("识别语言", "Recognition Language"))
                    .foregroundColor(.secondary)
                Spacer()
                Text(speechInstaller.resolvedLocaleIdentifier ?? UserDefaultsManager.shared.sttLocaleIdentifier)
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 10) {
                Image(systemName: speechInstaller.isModelReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(speechInstaller.isModelReady ? .green : .secondary)
                Text(speechModelStatusText)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await speechInstaller.installModelIfNeeded() }
                } label: {
                    if speechInstaller.isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(speechInstaller.isModelReady ? langMgr.t("重新检查", "Check Again") : langMgr.t("安装模型", "Install Model"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(speechInstaller.isInstalling)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var sherpaSenseVoiceEngineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(langMgr.t("引擎", "Engine"))
                    .foregroundColor(.secondary)
                Spacer()
                Text("sherpa-onnx · SenseVoice-Small")
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 10) {
                Image(systemName: sherpaModel.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(sherpaModel.isReady ? .green : .secondary)
                Text(sherpaModelStatusText)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task {
                        do {
                            try await sherpaModel.installModelsIfNeeded()
                            await sherpaModel.refreshReadiness()
                        } catch {
                            // installError is already set by the manager; UI shows it via status text
                        }
                    }
                } label: {
                    if sherpaModel.isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(sherpaModel.isReady ? langMgr.t("重新检查", "Check Again") : langMgr.t("下载模型", "Download Models"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sherpaModel.isDownloading)
            }

            if let error = sherpaModel.installError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var sherpaModelStatusText: String {
        if sherpaModel.isDownloading {
            if let progress = sherpaModel.downloadProgress {
                return langMgr.t(
                    "正在下载 SenseVoice 模型 \(Int(progress * 100))%",
                    "Downloading SenseVoice models \(Int(progress * 100))%"
                )
            }
            return langMgr.t("正在下载 SenseVoice 模型", "Downloading SenseVoice models")
        }
        if sherpaModel.isReady {
            return langMgr.t("SenseVoice 模型已就绪", "SenseVoice models are ready")
        }
        return langMgr.t("SenseVoice 模型尚未下载（约 240 MB）",
                         "SenseVoice models not downloaded yet (~240 MB)")
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

    private func requestSpeechPermission() {
        Task { @MainActor in
            let status = await speechInstaller.requestSpeechAuthorization()
            if status != .authorized {
                viewModel.activeAlert = AlertMessage(
                    title: langMgr.t("需要权限", "Permission Required"),
                    message: langMgr.t(
                        "转录会议需要语音识别权限，请在「系统设置 > 隐私与安全性 > 语音识别」中开启。",
                        "Speech recognition access is required for transcription. Enable it in System Settings > Privacy & Security > Speech Recognition."
                    )
                )
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

    private var speechModelStatusText: String {
        if speechInstaller.isInstalling {
            if let progress = speechInstaller.installProgress {
                return langMgr.t(
                    "正在安装语音识别模型 \(Int(progress * 100))%",
                    "Installing speech recognition model \(Int(progress * 100))%"
                )
            }
            return langMgr.t("正在安装语音识别模型", "Installing speech recognition model")
        }

        if speechInstaller.isModelReady {
            return langMgr.t("语音识别模型已就绪", "Speech recognition model is ready")
        }

        return speechInstaller.installError ?? langMgr.t(
            "语音识别模型尚未安装",
            "Speech recognition model is not installed yet"
        )
    }
}

private struct AppInfoCard: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var versionText: String {
        if appVersion.isEmpty {
            return "Version Beta · Built by youcai"
        }

        return "Version \(appVersion) Beta · Built by youcai"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("MeetMemo")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("让会议记录更聪明")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(versionText)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.82))
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
