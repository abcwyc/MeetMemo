import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var langMgr: LanguageManager
    @State private var sttAppId = ""
    @State private var sttAccessToken = ""
    @State private var llmApiKey = ""
    @State private var llmBaseURL = LLMProviderConfig.defaultBaseURL
    @State private var llmModel = ""
    @State private var micPermissionGranted = false
    @State private var systemAudioPermissionGranted = false
    @State private var audioRecordingPermission = AudioRecordingPermission()

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

                        // Provider Configuration Section
                        VStack(alignment: .leading, spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(langMgr.t("服务配置", "Service Configuration"))
                                    .font(.title2)
                                    .fontWeight(.semibold)

                                Text(langMgr.t("请填写语音识别服务与 LLM 配置。", "Please fill in the speech recognition service and LLM configuration."))
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(langMgr.t("语音识别服务", "Speech Recognition"))
                                        .font(.headline)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    Button {
                                        syncProviderFieldsToSettings()
                                        settingsViewModel.testSTTConnection()
                                    } label: {
                                        if settingsViewModel.isTestingSTT {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text(langMgr.t("测试连接", "Test Connection"))
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(settingsViewModel.isTestingSTT)
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

                                TextField("APP ID", text: $sttAppId)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)

                                SecureField("Access Token", text: $sttAccessToken)
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

                                Text(langMgr.t(
                                    "填写 Base URL、API Key 和 Model Name 即可。Anthropic 地址会使用 Messages API，其他地址会使用 OpenAI 兼容的 Chat Completions API。",
                                    "Fill in Base URL, API Key, and Model Name. Anthropic URLs use the Messages API; other URLs use the OpenAI-compatible Chat Completions API."
                                ))
                                .font(.caption)
                                .foregroundColor(.secondary)

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
            checkPermissions()
            settingsViewModel.loadProviderConfig()
            sttAppId = settingsViewModel.settings.sttAppId
            sttAccessToken = settingsViewModel.settings.sttAccessToken
            llmApiKey = settingsViewModel.settings.llmApiKey
            llmBaseURL = settingsViewModel.settings.llmBaseURL
            llmModel = settingsViewModel.settings.llmModel
        }
        .onChange(of: audioRecordingPermission.status) { oldValue, newValue in
            systemAudioPermissionGranted = (newValue == .authorized)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
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
        systemAudioPermissionGranted &&
        !sttAppId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !sttAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func syncProviderFieldsToSettings() {
        settingsViewModel.settings.sttAppId = sttAppId
        settingsViewModel.settings.sttAccessToken = sttAccessToken
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
