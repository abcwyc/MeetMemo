import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var langMgr: LanguageManager
    @ObservedObject private var sherpaModel = SherpaModelManager.shared
    @State private var llmApiKey = ""
    @State private var llmBaseURL = ""
    @State private var llmModel = ""
    @State private var micPermissionGranted = false
    @State private var systemAudioPermissionGranted = false
    @State private var audioRecordingPermission = AudioRecordingPermission()
    @State private var senseVoiceModelVariant: SenseVoiceModelVariant = UserDefaultsManager.shared.senseVoiceModelVariant
    private let llmSetupGuideURL = URL(string: "https://file.348580.xyz/2026/05/8fdfba8153b5029297b42f4ac6c4d00d.html")!

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 32) {
                        // Permissions Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text(langMgr.t("所需权限", "Required Permissions"))
                                .font(.title2)
                                .fontWeight(.semibold)

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

                        VStack(alignment: .leading, spacing: 12) {
                            Text(langMgr.t("本地语音识别模型", "Local Speech Recognition Model"))
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(langMgr.t(
                                "推荐使用 SenseVoice：兼容更多 macOS 版本，下载完成后可离线转录并支持发言人区分。",
                                "SenseVoice is recommended: it works across more macOS versions, runs offline after download, and supports speaker separation."
                            ))
                            .font(.body)
                            .foregroundColor(.secondary)

                            Picker("", selection: $senseVoiceModelVariant) {
                                ForEach(SenseVoiceModelVariant.allCases, id: \.self) { variant in
                                    Text(senseVoiceVariantPickerLabel(variant)).tag(variant)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 360, alignment: .leading)
                            .disabled(sherpaModel.isDownloading)
                            .onChange(of: senseVoiceModelVariant) { _, newValue in
                                UserDefaultsManager.shared.senseVoiceModelVariant = newValue
                                Task { await sherpaModel.refreshReadiness() }
                            }

                            Text(senseVoiceVariantDescription(senseVoiceModelVariant))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

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
                                            // installError is published by SherpaModelManager.
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
                            .padding()
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Provider Configuration Section
                        VStack(alignment: .leading, spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(langMgr.t("服务配置", "Service Configuration"))
                                    .font(.title2)
                                    .fontWeight(.semibold)

                                Text(langMgr.t("请填写 LLM 配置以启用笔记生成功能。", "Please fill in the LLM configuration to enable notes generation."))
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(langMgr.t("LLM 配置", "LLM Configuration"))
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    Button {
                                        syncProviderFieldsToSettings()
                                        settingsViewModel.testLLMConnection()
                                    } label: {
                                        if settingsViewModel.isTestingLLM {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text(langMgr.t("测试连接", "Test Connection"))
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(settingsViewModel.isTestingLLM)
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

                                SecureField("API Key", text: $llmApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)

                                TextField("Base URL", text: $llmBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)

                                TextField("Model Name", text: $llmModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack {
                            Spacer()

                            Button(langMgr.t("跳过配置", "Skip Setup")) {
                                settingsViewModel.skipOnboarding()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button(langMgr.t("开始使用", "Get Started")) {
                                syncProviderFieldsToSettings()
                                settingsViewModel.completeOnboarding()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!canProceed)
                        }
                    }
                    .padding(.vertical, 30)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            UserDefaultsManager.shared.sttEngine = .sherpaSenseVoice
            senseVoiceModelVariant = UserDefaultsManager.shared.senseVoiceModelVariant
            checkPermissions()
            settingsViewModel.loadProviderConfig()
            llmApiKey = settingsViewModel.settings.llmApiKey
            llmBaseURL = settingsViewModel.settings.llmBaseURL
            llmModel = settingsViewModel.settings.llmModel
            Task { await sherpaModel.refreshReadiness() }
        }
        .onChange(of: audioRecordingPermission.status) { oldValue, newValue in
            systemAudioPermissionGranted = (newValue == .authorized)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
            Task { await sherpaModel.refreshReadiness() }
        }
        .alert(item: $settingsViewModel.activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(langMgr.t("确定", "OK")))
            )
        }
    }

    private var canProceed: Bool {
        micPermissionGranted &&
        sherpaModel.isReady &&
        systemAudioPermissionGranted &&
        !llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func syncProviderFieldsToSettings() {
        settingsViewModel.settings.llmApiKey = llmApiKey
        settingsViewModel.settings.llmBaseURL = llmBaseURL
        settingsViewModel.settings.llmModel = llmModel
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
                    settingsViewModel.activeAlert = AlertMessage(
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
                settingsViewModel.activeAlert = AlertMessage(
                    title: langMgr.t("需要权限", "Permission Required"),
                    message: langMgr.t(
                        "需要系统录音权限才能捕获他人的声音，请在「系统设置 > 隐私与安全性 > 麦克风」中为本应用开启。",
                        "System audio recording access is required to capture what others say in meetings. Please enable this app in System Preferences > Security & Privacy > Privacy > Microphone."
                    )
                )
            }
        }
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

        return sherpaModel.installError ?? langMgr.t(
            "首次使用前需要下载 SenseVoice 本地模型（约 \(senseVoiceInstallSizeText)）。",
            "Download the local SenseVoice models before first use (~\(senseVoiceInstallSizeText))."
        )
    }

    private var senseVoiceInstallSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sherpaModel.activeApproximateBytes)
    }

    private func senseVoiceVariantPickerLabel(_ variant: SenseVoiceModelVariant) -> String {
        switch variant {
        case .quantized:
            return langMgr.t("轻量版", "Lite")
        case .fullPrecision:
            return langMgr.t("高准确率", "High Accuracy")
        }
    }

    private func senseVoiceVariantDescription(_ variant: SenseVoiceModelVariant) -> String {
        switch variant {
        case .quantized:
            return langMgr.t(
                "量化版，下载更小、运行更轻，适合多数设备。",
                "Quantized model. Smaller download and lighter runtime, suitable for most devices."
            )
        case .fullPrecision:
            return langMgr.t(
                "非量化版，体积和内存占用更高，适合优先追求识别准确率。",
                "Full-precision model. Larger download and memory use, best when recognition accuracy matters most."
            )
        }
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let grantedLabel: String
    let enableLabel: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(grantedLabel)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } else {
                Button(enableLabel) {
                    action()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }
}

#Preview {
    OnboardingView(settingsViewModel: SettingsViewModel())
        .environmentObject(LanguageManager.shared)
        .frame(width: 600, height: 700)
}
