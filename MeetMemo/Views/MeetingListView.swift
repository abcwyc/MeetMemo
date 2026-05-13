import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SidebarLayout {
    static let horizontalPadding: CGFloat = 12
    static let actionCapsuleInset: CGFloat = 4
    static let actionSpacing: CGFloat = 4
    static let primaryButtonMinWidth: CGFloat = 112
    static let secondaryButtonMinWidth: CGFloat = 76
    static let secondaryButtonPreferredWidth: CGFloat = 96
    static let sidebarMinimumWidth: CGFloat = 230
    static let sidebarPreferredWidth: CGFloat = 260
    static let listTopPadding: CGFloat = 12

    static var actionRowPreferredWidth: CGFloat {
        primaryButtonMinWidth
            + secondaryButtonPreferredWidth
            + actionSpacing
            + actionCapsuleInset * 2
    }
}

struct MeetingListView: View {
    @StateObject private var viewModel = MeetingListViewModel()
    @ObservedObject var settingsViewModel: SettingsViewModel
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @EnvironmentObject var langMgr: LanguageManager
    @State private var selectedMeeting: MeetingSummary?
    @State private var navigationPath = NavigationPath()
    @State private var renamingMeeting: MeetingSummary?
    @State private var deletingMeeting: MeetingSummary?
    @State private var renameText = ""
    @State private var isImportingAudioFile = false

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .overlay {
            if viewModel.isLoading {
                ProgressView(langMgr.t("加载会议中...", "Loading meetings..."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.clear)
            } else if viewModel.isImportingAudio {
                VStack(spacing: 12) {
                    ProgressView(
                        value: viewModel.audioImportProgress,
                        total: 1
                    ) {
                        Text(langMgr.t("正在导入并转录音频...", "Importing and transcribing audio..."))
                    }
                    .frame(width: 260)

                    Button(role: .cancel) {
                        viewModel.cancelAudioImport()
                    } label: {
                        Label(langMgr.t("取消", "Cancel"), systemImage: "xmark.circle")
                    }
                }
                .padding(18)
                .background(.regularMaterial)
                .cornerRadius(10)
            }
        }
        .fileImporter(
            isPresented: $isImportingAudioFile,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            importAudioFile(result)
        }
        .alert(langMgr.t("错误", "Error"), isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button(langMgr.t("确定", "OK")) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            sidebarActionRow
                .padding(EdgeInsets(
                    top: 8,
                    leading: SidebarLayout.horizontalPadding,
                    bottom: 8,
                    trailing: SidebarLayout.horizontalPadding
                ))

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(langMgr.t("搜索会议...", "Search meetings..."), text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(EdgeInsets(top: 2, leading: 12, bottom: 10, trailing: 12))

            Divider()

            Color.clear
                .frame(height: SidebarLayout.listTopPadding)

            List(selection: $selectedMeeting) {
                ForEach(sortedMeetings, id: \.id) { meeting in
                    meetingRow(meeting)
                }
                .onDelete(perform: deleteMeetings)
            }
            .tint(.accentColor)
            .overlay {
                if viewModel.filteredMeetings.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? langMgr.t("暂无会议", "No Meetings Yet") : langMgr.t("无结果", "No Results"),
                        systemImage: viewModel.searchText.isEmpty ? "mic.slash" : "magnifyingglass",
                        description: Text(viewModel.searchText.isEmpty
                            ? langMgr.t("新建会议开始转录", "Start a new meeting to begin transcribing")
                            : langMgr.t("尝试其他搜索词", "Try a different search term"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(langMgr.t("会议", "Meetings"))
        .navigationSplitViewColumnWidth(
            min: SidebarLayout.sidebarMinimumWidth,
            ideal: SidebarLayout.sidebarPreferredWidth,
            max: 360
        )
        .alert(langMgr.t("重命名会议", "Rename Meeting"), isPresented: Binding(
            get: { renamingMeeting != nil },
            set: { if !$0 { renamingMeeting = nil } }
        )) {
            TextField(langMgr.t("会议名称", "Meeting Name"), text: $renameText)
            Button(langMgr.t("确认", "Confirm")) {
                if let meeting = renamingMeeting {
                    viewModel.renameMeeting(meeting, title: renameText)
                }
                renamingMeeting = nil
            }
            Button(langMgr.t("取消", "Cancel"), role: .cancel) {
                renamingMeeting = nil
            }
        }
        .alert(langMgr.t("删除会议", "Delete Meeting"), isPresented: Binding(
            get: { deletingMeeting != nil },
            set: { if !$0 { deletingMeeting = nil } }
        )) {
            Button(langMgr.t("删除", "Delete"), role: .destructive) {
                if let meeting = deletingMeeting {
                    deleteMeeting(meeting)
                }
                deletingMeeting = nil
            }
            Button(langMgr.t("取消", "Cancel"), role: .cancel) {
                deletingMeeting = nil
            }
        } message: {
            Text(langMgr.t("确定要删除这个会议吗？此操作不可撤销。", "Are you sure you want to delete this meeting? This action cannot be undone."))
        }
    }

    private var sidebarActionRow: some View {
        HStack(spacing: 4) {
            Button {
                createAndSelectMeeting()
            } label: {
                Label(langMgr.t("创建会议", "Create Meeting"), systemImage: "plus")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SidebarPrimaryActionButtonStyle())
            .controlSize(.large)
            .frame(minWidth: SidebarLayout.primaryButtonMinWidth)
            .layoutPriority(1)
            .disabled(recordingSessionManager.isRecording || viewModel.isImportingAudio)
            .help(recordingSessionManager.isRecording
                ? langMgr.t("录制中无法创建新会议", "Cannot create new meeting while recording is active")
                : langMgr.t("新建会议", "New Meeting"))

            Button {
                isImportingAudioFile = true
            } label: {
                Label(langMgr.t("导入", "Import"), systemImage: "arrow.down.to.line")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(
                minWidth: SidebarLayout.secondaryButtonMinWidth,
                idealWidth: SidebarLayout.secondaryButtonPreferredWidth,
                maxWidth: SidebarLayout.secondaryButtonPreferredWidth
            )
            .buttonStyle(SidebarSecondaryActionButtonStyle())
            .controlSize(.large)
            .layoutPriority(0)
            .disabled(recordingSessionManager.isRecording || viewModel.isImportingAudio)
            .help(recordingSessionManager.isRecording
                ? langMgr.t("录制中无法导入音频", "Cannot import audio while recording is active")
                : langMgr.t("导入音频并转录", "Import audio and transcribe it"))
        }
        .padding(SidebarLayout.actionCapsuleInset)
        .frame(maxWidth: .infinity)
        .background {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
                }
        }
    }

    private var detailContent: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let selectedMeeting = selectedMeeting {
                    MeetingDetailContentView(
                        meeting: selectedMeeting.placeholderMeeting,
                        initialSelectedTab: selectedMeeting.hasGeneratedNotes ? .enhancedNotes : .transcript,
                        initialHasTranscript: selectedMeeting.hasTranscript,
                        initialHasGeneratedNotes: selectedMeeting.hasGeneratedNotes,
                        onOpenSettings: {
                            navigationPath.append("settings")
                        },
                        onDelete: {
                            self.selectedMeeting = nil
                        }
                    )
                } else {
                    ContentUnavailableView(
                        langMgr.t("请选择一个会议", "Select a Meeting"),
                        systemImage: "sidebar.leading",
                        description: Text(langMgr.t("从侧边栏选择会议查看详情", "Choose a meeting from the sidebar to view its details"))
                    )
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if selectedMeeting == nil {
                        Button {
                            navigationPath.append("settings")
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help(langMgr.t("设置", "Settings"))
                    }
                }
            }
            .navigationDestination(for: String.self) { path in
                if path == "settings" {
                    SettingsView(viewModel: settingsViewModel, navigationPath: $navigationPath)
                } else if path == "templates" {
                    TemplateListView()
                }
            }
        }
    }

    private var sortedMeetings: [MeetingSummary] {
        viewModel.filteredMeetings.sorted { $0.date > $1.date }
    }

    private func meetingRow(_ meeting: MeetingSummary) -> some View {
        MeetingRowView(
            meeting: meeting,
            onRename: { beginRenaming(meeting) },
            onRevealSourceFile: { revealSourceFile(for: meeting) },
            onDelete: { deletingMeeting = meeting }
        )
        .tag(meeting)
    }

    private func beginRenaming(_ meeting: MeetingSummary) {
        renameText = meeting.title
        renamingMeeting = meeting
    }

    private func deleteMeeting(_ meeting: MeetingSummary) {
        if selectedMeeting?.id == meeting.id {
            selectedMeeting = nil
        }
        viewModel.deleteMeeting(meeting)
    }

    private func deleteMeetings(at indexSet: IndexSet) {
        for index in indexSet {
            deleteMeeting(sortedMeetings[index])
        }
    }

    private func revealSourceFile(for meeting: MeetingSummary) {
        let fileURL = LocalStorageManager.shared.meetingsDirectoryURL
            .appendingPathComponent("\(meeting.id.uuidString).json")

        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(LocalStorageManager.shared.meetingsDirectoryURL)
        }
    }

    private func createAndSelectMeeting() {
        let newMeeting = viewModel.createNewMeeting()
        selectedMeeting = MeetingSummary(meeting: newMeeting)
    }

    private func importAudioFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                if let meeting = await viewModel.importAudioFile(url: url) {
                    selectedMeeting = MeetingSummary(meeting: meeting)
                }
            }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private final class MovablePanelCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct SidebarPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        SidebarPrimaryActionButtonBody(configuration: configuration, isEnabled: isEnabled)
    }
}

private struct SidebarPrimaryActionButtonBody: View {
    let configuration: SidebarPrimaryActionButtonStyle.Configuration
    let isEnabled: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(isEnabled ? .white : .secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background {
                Capsule(style: .continuous)
                    .fill(backgroundColor)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    }
            }
            .contentShape(Capsule(style: .continuous))
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color.secondary.opacity(0.14)
        }

        if configuration.isPressed {
            return Color.accentColor.opacity(0.78)
        }

        return Color.accentColor.opacity(isHovering ? 0.88 : 1)
    }

    private var borderColor: Color {
        isHovering && isEnabled ? Color.white.opacity(0.26) : Color.clear
    }
}

private struct SidebarSecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        SidebarSecondaryActionButtonBody(configuration: configuration, isEnabled: isEnabled)
    }
}

private struct SidebarSecondaryActionButtonBody: View {
    let configuration: SidebarSecondaryActionButtonStyle.Configuration
    let isEnabled: Bool
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(isEnabled ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            }
            .contentShape(Capsule(style: .continuous))
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color.secondary.opacity(0.08)
        }

        if configuration.isPressed {
            return Color.secondary.opacity(0.18)
        }

        return Color.secondary.opacity(isHovering ? 0.12 : 0)
    }
}

private struct DetailHeaderActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isConfirmed = false
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundColor(foregroundColor)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var foregroundColor: Color {
        if !isEnabled { return .secondary }
        if isConfirmed { return .green }
        return .primary
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled { return Color.secondary.opacity(0.06) }
        if isConfirmed { return Color.green.opacity(isPressed ? 0.16 : 0.1) }
        if isSelected { return Color.secondary.opacity(isPressed ? 0.22 : 0.16) }
        return Color.secondary.opacity(isPressed ? 0.14 : 0.08)
    }
}

struct MeetingRowView: View {
    let meeting: MeetingSummary
    var onRename: () -> Void = {}
    var onRevealSourceFile: () -> Void = {}
    var onDelete: () -> Void = {}
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @EnvironmentObject var langMgr: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if recordingSessionManager.isRecordingMeeting(meeting.id) {
                    Image(systemName: "record.circle")
                        .foregroundColor(.red)
                        .font(.headline)
                }
                Text(meeting.title.isEmpty ? langMgr.t("未命名会议", "Untitled meeting") : meeting.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            HStack {
                Text(timestampText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                onRename()
            } label: {
                Label(langMgr.t("重命名", "Rename"), systemImage: "pencil")
            }

            Button {
                onRevealSourceFile()
            } label: {
                Label(langMgr.t("查看源文件", "Show Source File"), systemImage: "doc.text")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(langMgr.t("删除会议", "Delete Meeting"), systemImage: "trash")
            }
        }
    }

    private var timestampText: String {
        let locale = langMgr.language == .chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        let datePart = meeting.date.formatted(.dateTime.locale(locale).month(.abbreviated).day())
        let timePart = meeting.date.formatted(.dateTime.locale(locale).hour().minute())
        return "\(datePart) · \(timePart)"
    }
}

// MARK: - Transcript Chunk Row

struct TranscriptChunkRowView: View {
    let chunk: TranscriptDisplayChunk

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Image(systemName: chunk.source.icon)
                    .font(.caption2)
                    .foregroundColor(chunk.source == .mic ? .blue : .orange)
            }
            .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chunk.sourceLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(chunk.source == .mic ? .blue : .orange)

                    if let speakerLabel = chunk.speakerLabel {
                        Text(speakerLabel)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }

                    Spacer(minLength: 8)

                    Text(chunk.timeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                Text(chunk.text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(chunk.isFinal ? 1.0 : 0.72)
            }
        }
        .padding(.vertical, 4)
        .opacity(chunk.isFinal ? 1.0 : 0.9)
    }
}

// MARK: - Meeting Detail Content View

struct MeetingDetailContentView: View {
    let meeting: Meeting
    let initialSelectedTab: MeetingViewTab?
    let initialHasTranscript: Bool
    let initialHasGeneratedNotes: Bool
    @StateObject private var viewModel: MeetingViewModel
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @EnvironmentObject var langMgr: LanguageManager
    @State private var showDeleteAlert = false
    @State private var isContextEditing = false
    @State private var isEnhancedNotesEditing = false
    @State private var showCopyConfirmation = false
    @State private var isImportingContextFile = false
    @State private var speakerNamingWindow: NSWindow?
    @State private var followUpTasksWindow: NSWindow?
    @State private var speakerNamingWindowDelegate: MovablePanelCloseDelegate?
    @State private var followUpTasksWindowDelegate: MovablePanelCloseDelegate?
    @State private var hoveredTab: MeetingViewTab?
    @State private var isGenerateButtonHovered = false
    @State private var isRecordingButtonHovered = false
    @State private var windowWidth: CGFloat = 1000
    let onOpenSettings: () -> Void
    let onDelete: () -> Void

    init(
        meeting: Meeting,
        initialSelectedTab: MeetingViewTab? = nil,
        initialHasTranscript: Bool = false,
        initialHasGeneratedNotes: Bool = false,
        onOpenSettings: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.initialSelectedTab = initialSelectedTab
        self.initialHasTranscript = initialHasTranscript
        self.initialHasGeneratedNotes = initialHasGeneratedNotes
        self._viewModel = StateObject(wrappedValue: MeetingViewModel(
            meeting: meeting,
            initialSelectedTab: initialSelectedTab,
            initialHasTranscript: initialHasTranscript,
            initialHasGeneratedNotes: initialHasGeneratedNotes
        ))
        self.onOpenSettings = onOpenSettings
        self.onDelete = onDelete
    }

    private var cannotStartRecording: Bool {
        recordingSessionManager.isRecording && !recordingSessionManager.isRecordingMeeting(viewModel.meeting.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 25) {
                detailHeader

                VStack(alignment: .leading, spacing: 0) {
                    switch viewModel.selectedTab {
                    case .context:
                        contextView
                    case .transcript:
                        transcriptView
                    case .enhancedNotes:
                        switch viewModel.aiNotesSubTab {
                        case .notes:
                            enhancedNotesView
                        case .digest:
                            MeetingSummaryView(viewModel: viewModel)
                                .environmentObject(langMgr)
                        }
                    case .summary:
                        MeetingSummaryView(viewModel: viewModel)
                            .environmentObject(langMgr)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16))
            .frame(maxHeight: .infinity)
        }
        .overlay {
            if viewModel.isLoadingMeeting {
                ProgressView(langMgr.t("加载会议内容中...", "Loading meeting..."))
                    .padding(18)
                    .background(.regularMaterial)
                    .cornerRadius(10)
            }
        }
        .alert(langMgr.t("错误", "Error"), isPresented: .constant(viewModel.errorMessage != nil)) {
            Button(langMgr.t("确定", "OK")) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(langMgr.t("删除会议", "Delete Meeting"), isPresented: $showDeleteAlert) {
            Button(langMgr.t("删除", "Delete"), role: .destructive) {
                viewModel.deleteMeeting()
                onDelete()
            }
            Button(langMgr.t("取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(langMgr.t("确定要删除这个会议吗？此操作不可撤销。", "Are you sure you want to delete this meeting? This action cannot be undone."))
        }
        .onDisappear {
            viewModel.cancelGeneratingNotes()
            viewModel.deleteIfEmpty()
            speakerNamingWindow?.close()
            followUpTasksWindow?.close()
        }
        .fileImporter(
            isPresented: $isImportingContextFile,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            importContextFile(result)
        }
        .onChange(of: meeting.id) { _, _ in
            viewModel.switchToMeeting(
                meeting,
                initialSelectedTab: initialSelectedTab,
                initialHasTranscript: initialHasTranscript,
                initialHasGeneratedNotes: initialHasGeneratedNotes
            )
            hoveredTab = nil
            isContextEditing = false
            isEnhancedNotesEditing = false
            showCopyConfirmation = false
        }
        .background(WindowWidthReader(width: $windowWidth))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                detailActionButtons
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if shouldShowToolbarTabs {
                    detailTabBar
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(langMgr.t("设置", "Settings"))
            }
        }
    }

    private var shouldShowToolbarTabs: Bool {
        windowWidth >= 500
    }

    private var usesCompactToolbarActions: Bool {
        windowWidth < 700
    }

    private var detailActionButtons: some View {
        HStack(spacing: 4) {
            recordingButton
            generateNotesButton
        }
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(.separator.opacity(0.32), lineWidth: 1)
                }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var detailTabBar: some View {
        HStack(spacing: 3) {
            ForEach(MeetingViewTab.displayOrder, id: \.self) { tab in
                Button {
                    viewModel.selectedTab = tab
                } label: {
                    Text(tab.label(using: langMgr))
                        .font(.system(size: 13, weight: viewModel.selectedTab == tab ? .semibold : .medium))
                        .foregroundColor(viewModel.selectedTab == tab ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(width: 76, height: 30)
                        .background {
                            if viewModel.selectedTab == tab || hoveredTab == tab {
                                Capsule(style: .continuous)
                                    .fill(tabButtonBackgroundColor(for: tab))
                            }
                        }
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredTab = isHovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
                }
            }
        }
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(.separator.opacity(0.32), lineWidth: 1)
                }
        }
        .fixedSize()
    }

    private func tabButtonBackgroundColor(for tab: MeetingViewTab) -> Color {
        if viewModel.selectedTab == tab {
            return Color.secondary.opacity(0.18)
        }

        return Color.secondary.opacity(0.10)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                TextField(langMgr.t("会议标题", "Meeting Title"), text: $viewModel.meeting.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 180)

                Spacer()

                titleActionButtons
                moreMenu
            }

            if viewModel.hasGeneratedNotes,
               let templateId = viewModel.selectedTemplateId,
               let template = viewModel.templates.first(where: { $0.id == templateId }) {
                Text(langMgr.t("使用「\(template.title)」模板生成", "Generated with '\(template.title)'"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var meetingStatusLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 6) {
                Circle()
                    .fill(statusIndicatorColor)
                    .frame(width: 7, height: 7)

                Text(statusText(now: timeline.date))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(statusTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusIndicatorColor: Color {
        if viewModel.isRecording || viewModel.isStartingRecording {
            return .red
        }

        if viewModel.isGeneratingNotes {
            return .accentColor
        }

        if viewModel.hasGeneratedNotes {
            return .green
        }

        return .secondary.opacity(0.55)
    }

    private var statusTextColor: Color {
        viewModel.errorMessage == nil ? .secondary : .red
    }

    private func statusText(now: Date) -> String {
        if let error = viewModel.errorMessage {
            return langMgr.t("出现错误：", "Error: ") + error
        }

        if viewModel.isStartingRecording || viewModel.isValidatingKey {
            return langMgr.t("正在检查转录配置...", "Checking transcription settings...")
        }

        if viewModel.isRecording {
            let elapsed = formattedElapsedTime(since: viewModel.recordingStartedAt, now: now)
            return langMgr.t(
                "正在录制 \(elapsed) · 已转写 \(viewModel.transcriptCharacterCount) 字",
                "Recording \(elapsed) · \(viewModel.transcriptCharacterCount) characters transcribed"
            )
        }

        if viewModel.isGeneratingNotes {
            return langMgr.t("正在生成会议纪要...", "Generating meeting notes...")
        }

        if viewModel.hasGeneratedNotes {
            return langMgr.t("会议纪要已生成，可编辑或重新生成", "Meeting notes generated. You can edit or regenerate them.")
        }

        if viewModel.meeting.hasFinalTranscript {
            return langMgr.t("转录已就绪，可以生成会议纪要", "Transcript is ready. You can generate meeting notes.")
        }

        if viewModel.meeting.transcriptChunks.isEmpty {
            return langMgr.t("尚未开始录制", "Recording has not started yet.")
        }

        return langMgr.t("暂无完整转录，继续录制后再生成纪要", "No final transcript yet. Resume recording before generating notes.")
    }

    private func formattedElapsedTime(since startDate: Date?, now: Date) -> String {
        guard let startDate else { return "00:00" }

        let elapsedSeconds = max(0, Int(now.timeIntervalSince(startDate)))
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var moreMenu: some View {
        Menu {
            if viewModel.selectedTab == .context || viewModel.selectedTab == .enhancedNotes {
                Button {
                    toggleCurrentEditingMode()
                } label: {
                    Label(
                        isCurrentTabEditing ? langMgr.t("预览", "Preview") : langMgr.t("编辑", "Edit"),
                        systemImage: isCurrentTabEditing ? "eye" : "pencil"
                    )
                }
            }

            Button {
                copyCurrentTabContent()
            } label: {
                Label(
                    showCopyConfirmation ? langMgr.t("已复制", "Copied") : langMgr.t("复制", "Copy"),
                    systemImage: showCopyConfirmation ? "checkmark.circle.fill" : "doc.on.doc"
                )
            }

            Divider()

            Button {
                viewModel.exportHTML()
            } label: {
                Label(langMgr.t("导出 HTML", "Export as HTML"), systemImage: "square.and.arrow.up")
            }
            .disabled(!viewModel.canExportCurrentTabHTML)

            Divider()

            Button(langMgr.t("删除会议", "Delete Meeting"), role: .destructive) {
                showDeleteAlert = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundColor(.secondary)
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .menuStyle(BorderlessButtonMenuStyle())
        .frame(width: 20, height: 20)
    }

    private var titleActionButtons: some View {
        HStack(spacing: 8) {
            if viewModel.selectedTab == .enhancedNotes && viewModel.toolbarHasGeneratedNotes {
                Button {
                    viewModel.aiNotesSubTab = .notes
                } label: {
                    Label(langMgr.t("会议纪要", "Meeting Notes"), systemImage: "doc.text")
                }
                .buttonStyle(DetailHeaderActionButtonStyle(isSelected: viewModel.aiNotesSubTab == .notes))

                Button {
                    viewModel.showActionDigest()
                } label: {
                    Label(langMgr.t("行动摘要", "Action Digest"), systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(DetailHeaderActionButtonStyle(isSelected: viewModel.aiNotesSubTab == .digest))
            }

            if viewModel.selectedTab == .enhancedNotes {
                Button {
                    openFollowUpTasksWindow()
                } label: {
                    Label(langMgr.t("管理待办", "Tasks"), systemImage: "checklist")
                }
                .buttonStyle(DetailHeaderActionButtonStyle())
            }

            if viewModel.selectedTab == .context {
                Button {
                    isContextEditing = true
                    viewModel.addTextContextItem()
                } label: {
                    Label(langMgr.t("添加文本", "Add Text"), systemImage: "text.alignleft")
                }
                .buttonStyle(DetailHeaderActionButtonStyle())

                Button {
                    isImportingContextFile = true
                } label: {
                    Label(langMgr.t("导入文件", "Import File"), systemImage: "doc.badge.plus")
                }
                .buttonStyle(DetailHeaderActionButtonStyle())
            }

            if viewModel.selectedTab == .transcript {
                Button {
                    openSpeakerNamingWindow()
                } label: {
                    Label(langMgr.t("标记发言人", "Label Speakers"), systemImage: "person.2")
                }
                .buttonStyle(DetailHeaderActionButtonStyle())
                .disabled(viewModel.speakerNamingOptions.isEmpty)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var generateNotesButton: some View {
        Menu {
            Button {
                Task {
                    await generateNotesWithTemplate(viewModel.selectedTemplateId)
                }
            } label: {
                Label(
                    viewModel.hasGeneratedNotes ? langMgr.t("重新生成纪要", "Regenerate Notes") : langMgr.t("按当前模板生成", "Generate with Current Template"),
                    systemImage: "sparkles"
                )
            }

            if viewModel.hasGeneratedNotes {
                Button {
                    Task { await viewModel.extractStructuredSummary() }
                } label: {
                    Label(
                        viewModel.isExtractingStructuredSummary
                            ? langMgr.t("提取中...", "Extracting...")
                            : langMgr.t("仅重新提取结构", "Re-extract Structure Only"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(viewModel.isExtractingStructuredSummary)
            }

            Divider()

            ForEach(viewModel.templates) { template in
                Button(template.title) {
                    Task {
                        await generateNotesWithTemplate(template.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isGeneratingNotes {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 12, height: 12)
                } else if usesCompactToolbarActions {
                    Image(systemName: "sparkles")
                }

                if !usesCompactToolbarActions {
                    Text(generateButtonTitle)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(generateButtonForegroundColor)
            .frame(minWidth: usesCompactToolbarActions ? 30 : 106, minHeight: 30)
            .padding(.horizontal, usesCompactToolbarActions ? 0 : 12)
            .background {
                Capsule(style: .continuous)
                    .fill(generateButtonBackgroundColor)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(generateButtonBorderColor, lineWidth: 1)
            }
            .overlay(
                Group {
                    if viewModel.shouldAnimateGenerateButton {
                        ShimmerOverlay(color: .green)
                            .clipShape(Capsule(style: .continuous))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { isGenerateButtonHovered = $0 }
        .disabled(!viewModel.toolbarHasFinalTranscript || viewModel.isGeneratingNotes || viewModel.isRecording || viewModel.isStartingRecording)
        .help(generateButtonHelp)
    }

    private var recordingButton: some View {
        Button {
            print("🎙️ Recording toolbar button tapped for meeting: \(viewModel.meeting.id)")
            viewModel.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: viewModel.recordingButtonIconName)
                    .foregroundColor(viewModel.isRecording ? .red : .accentColor)

                if !usesCompactToolbarActions {
                    Text(viewModel.recordingButtonText)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(recordingButtonForegroundColor)
            .frame(minWidth: usesCompactToolbarActions ? 30 : 104, minHeight: 30)
            .padding(.horizontal, usesCompactToolbarActions ? 0 : 12)
            .background {
                Capsule(style: .continuous)
                    .fill(recordingButtonBackgroundColor)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(recordingButtonBorderColor, lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
            .overlay(
                Group {
                    if viewModel.shouldAnimateTranscribeButton {
                        ShimmerOverlay(color: .accentColor)
                            .clipShape(Capsule(style: .continuous))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { isRecordingButtonHovered = $0 }
        .disabled(cannotStartRecording || viewModel.isValidatingKey || viewModel.isStartingRecording)
        .help(cannotStartRecording
            ? langMgr.t("另一个会议正在录制中", "Another meeting is currently being recorded")
            : langMgr.t("开始、继续或结束本次会议的录制", "Start, resume, or end recording for this meeting"))
    }

    private var generateButtonTitle: String {
        if viewModel.isGeneratingNotes {
            return langMgr.t("生成中", "Generating")
        }

        return viewModel.toolbarHasGeneratedNotes ? langMgr.t("重新生成纪要", "Regenerate Notes") : langMgr.t("生成纪要", "Generate Notes")
    }

    private var generateButtonHelp: String {
        if viewModel.isRecording || viewModel.isStartingRecording {
            return langMgr.t("录制结束后可以生成会议纪要", "End recording before generating notes")
        }

        if !viewModel.toolbarHasFinalTranscript {
            return langMgr.t("需要完整转录后才能生成会议纪要", "A final transcript is required before generating notes")
        }

        return langMgr.t("使用模板生成或重新生成会议纪要", "Generate or regenerate meeting notes using a template")
    }

    private var generateButtonForegroundColor: Color {
        viewModel.toolbarHasFinalTranscript && !viewModel.isRecording && !viewModel.isStartingRecording ? .green : .secondary
    }

    private var generateButtonBackgroundColor: Color {
        if viewModel.toolbarHasFinalTranscript && !viewModel.isRecording && !viewModel.isStartingRecording {
            return Color.green.opacity(isGenerateButtonHovered ? 0.24 : 0.18)
        }

        return Color.secondary.opacity(isGenerateButtonHovered ? 0.14 : 0.08)
    }

    private var generateButtonBorderColor: Color {
        if viewModel.toolbarHasFinalTranscript && !viewModel.isRecording && !viewModel.isStartingRecording {
            return Color.green.opacity(isGenerateButtonHovered ? 0.42 : 0.3)
        }

        return isGenerateButtonHovered ? Color.secondary.opacity(0.18) : Color.clear
    }

    private var recordingButtonForegroundColor: Color {
        viewModel.isRecording ? .red : .accentColor
    }

    private var recordingButtonBackgroundColor: Color {
        if viewModel.isRecording {
            return Color.red.opacity(isRecordingButtonHovered ? 0.22 : 0.16)
        }

        return Color.accentColor.opacity(isRecordingButtonHovered ? 0.22 : 0.16)
    }

    private var recordingButtonBorderColor: Color {
        if viewModel.isRecording {
            return Color.red.opacity(isRecordingButtonHovered ? 0.42 : 0.3)
        }

        return Color.accentColor.opacity(isRecordingButtonHovered ? 0.38 : 0.26)
    }

    private var isCurrentTabEditing: Bool {
        switch viewModel.selectedTab {
        case .context:
            return isContextEditing
        case .enhancedNotes:
            return isEnhancedNotesEditing
        case .transcript, .summary:
            return false
        }
    }

    private func toggleCurrentEditingMode() {
        switch viewModel.selectedTab {
        case .context:
            isContextEditing.toggle()
        case .enhancedNotes:
            isEnhancedNotesEditing.toggle()
        case .transcript, .summary:
            break
        }
    }

    private func generateNotesWithTemplate(_ templateId: UUID?) async {
        viewModel.selectedTab = .enhancedNotes
        isEnhancedNotesEditing = false

        if viewModel.selectedTemplateId == templateId {
            await viewModel.generateNotes()
        } else {
            viewModel.selectedTemplateId = templateId
        }
    }

    private func copyCurrentTabContent() {
        viewModel.copyCurrentTabContent()
        showCopyConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showCopyConfirmation = false
        }
    }

    // MARK: - Content Views

    private var contextView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isContextEditing {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.meeting.contextItems.isEmpty {
                        Text(langMgr.t("添加会议议程、背景材料、客户信息或你的补充判断。", "Add an agenda, background material, customer details, or your own notes."))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(8)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(viewModel.meeting.contextItems) { item in
                                    ContextEditorCard(
                                        item: contextItemBinding(for: item),
                                        onDelete: { viewModel.deleteContextItem(item) }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                if viewModel.meeting.formattedMeetingContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(langMgr.t("暂无上下文...", "No context yet..."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .foregroundColor(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                } else {
                    ContextPreviewList(
                        items: viewModel.meeting.contextItems
                    )
                        .font(.body)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func importContextFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                viewModel.addFileContextItem(url: url, text: text)
            } catch {
                viewModel.errorMessage = langMgr.t(
                    "无法读取文件内容。当前支持 UTF-8 文本文件。",
                    "Could not read this file. UTF-8 text files are supported for now."
                )
            }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private var transcriptView: some View {
        TranscriptListView(displayChunks: viewModel.transcriptDisplayChunks)
    }

    private var enhancedNotesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isEnhancedNotesEditing {
                oneLinerCard
            }
            if isEnhancedNotesEditing {
                IMESafeTextEditor(text: Binding(
                    get: { viewModel.meeting.generatedNotes },
                    set: { viewModel.meeting.generatedNotes = $0 }
                ))
                .frame(minHeight: 110)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .frame(maxHeight: .infinity)
            } else {
                RenderedNotesView(text: viewModel.meeting.generatedNotes)
                    .font(.body)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(8)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var oneLinerCard: some View {
        if viewModel.isExtractingStructuredSummary && viewModel.meeting.oneLiner.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.65)
                Text(langMgr.t("正在提取摘要...", "Extracting summary..."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
        } else if !viewModel.meeting.oneLiner.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(viewModel.meeting.oneLiner)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
        }
    }

    private func contextItemBinding(for item: MeetingContextItem) -> Binding<MeetingContextItem> {
        Binding(
            get: {
                viewModel.meeting.contextItems.first(where: { $0.id == item.id }) ?? item
            },
            set: { updatedItem in
                guard let index = viewModel.meeting.contextItems.firstIndex(where: { $0.id == item.id }) else {
                    return
                }
                viewModel.meeting.contextItems[index] = updatedItem
            }
        )
    }

    private func openSpeakerNamingWindow() {
        if let window = speakerNamingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var panel: NSWindow!
        let content = SpeakerNamingSheet(
            options: viewModel.speakerNamingOptions,
            participantNames: viewModel.speakerParticipantNames,
            onCancel: {
                panel.close()
                speakerNamingWindow = nil
            },
            onSave: { participantNames, mappings in
                viewModel.applySpeakerNaming(participantNames: participantNames, mappings: mappings)
                panel.close()
                speakerNamingWindow = nil
            }
        )
        .environmentObject(langMgr)

        panel = makeMovablePanel(
            title: langMgr.t("标记发言人", "Label Speakers"),
            size: NSSize(width: 820, height: 600),
            content: content
        )
        speakerNamingWindow = panel
        let closeDelegate = MovablePanelCloseDelegate {
            speakerNamingWindow = nil
            speakerNamingWindowDelegate = nil
        }
        speakerNamingWindowDelegate = closeDelegate
        panel.delegate = closeDelegate
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openFollowUpTasksWindow() {
        if let window = followUpTasksWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var panel: NSWindow!
        let content = FollowUpTasksSheet(
            viewModel: viewModel,
            onClose: {
                panel.close()
                followUpTasksWindow = nil
            }
        )
        .environmentObject(langMgr)

        panel = makeMovablePanel(
            title: langMgr.t("管理待办", "Manage Tasks"),
            size: NSSize(width: 760, height: 640),
            content: content
        )
        followUpTasksWindow = panel
        let closeDelegate = MovablePanelCloseDelegate {
            followUpTasksWindow = nil
            followUpTasksWindowDelegate = nil
        }
        followUpTasksWindowDelegate = closeDelegate
        panel.delegate = closeDelegate
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMovablePanel<Content: View>(
        title: String,
        size: NSSize,
        content: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: AppearanceManager.shared.appearance.nsAppearanceName)
        window.center()
        window.contentViewController = NSHostingController(
            rootView: MovablePanelRoot(content: content)
        )
        return window
    }
}

private struct MovablePanelRoot<Content: View>: View {
    @ObservedObject private var appearanceMgr = AppearanceManager.shared
    let content: Content

    var body: some View {
        content
            .preferredColorScheme(appearanceMgr.appearance == .light ? .light : .dark)
            .background(WindowAppearanceSync(appearance: appearanceMgr.appearance))
    }
}

private struct WindowAppearanceSync: NSViewRepresentable {
    let appearance: AppAppearance

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.appearance = NSAppearance(named: appearance.nsAppearanceName)
        }
    }
}

private struct WindowWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(width: $width)
    }

    func makeNSView(context: Context) -> WindowWidthReportingView {
        let view = WindowWidthReportingView(frame: .zero)
        view.onWidthChange = context.coordinator.updateWidth
        return view
    }

    func updateNSView(_ nsView: WindowWidthReportingView, context: Context) {
        context.coordinator.width = $width
        nsView.onWidthChange = context.coordinator.updateWidth
        nsView.reportWidth()
    }

    final class Coordinator {
        var width: Binding<CGFloat>

        init(width: Binding<CGFloat>) {
            self.width = width
        }

        func updateWidth(_ newWidth: CGFloat) {
            width.wrappedValue = newWidth
        }
    }
}

private final class WindowWidthReportingView: NSView {
    var onWidthChange: ((CGFloat) -> Void)?
    private var resizeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeObserver.map(NotificationCenter.default.removeObserver)
        resizeObserver = nil

        guard let window else { return }
        reportWidth()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.reportWidth()
        }
    }

    deinit {
        resizeObserver.map(NotificationCenter.default.removeObserver)
    }

    func reportWidth() {
        guard let width = window?.frame.width else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onWidthChange?(width)
        }
    }
}

private struct ContextEditorCard: View {
    @EnvironmentObject var langMgr: LanguageManager
    @Binding var item: MeetingContextItem
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    langMgr.t(item.kind.displayName, item.kind.englishDisplayName),
                    systemImage: item.kind.icon
                )
                .font(.caption)
                .foregroundColor(.secondary)

                TextField(langMgr.t("标题", "Title"), text: $item.title)
                    .textFieldStyle(.plain)
                    .font(.headline)

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help(langMgr.t("删除上下文", "Delete context"))
            }

            if item.kind != .text {
                TextField(langMgr.t("来源", "Source"), text: Binding(
                    get: { item.source ?? "" },
                    set: { item.source = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            ContextExtractionStatusView(item: item)

            IMESafeTextEditor(text: $item.extractedText, minHeight: 110)
                .frame(minHeight: 110)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.22), lineWidth: 1)
                )
        }
        .padding(12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}

private struct IMESafeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var minHeight: CGFloat = 110

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.update(text: $text)
        textView.minSize = NSSize(width: 0, height: minHeight)

        // During Chinese/Japanese/Korean IME composition, NSTextView keeps the
        // in-progress pinyin/kana in marked text. Replacing the string from
        // SwiftUI at that moment clears the marked text and loses the input.
        guard !textView.hasMarkedText(), textView.string != text else { return }

        let selectedRanges = clampedSelectedRanges(textView.selectedRanges, textLength: text.utf16.count)
        textView.string = text
        textView.selectedRanges = selectedRanges
    }

    private func clampedSelectedRanges(_ ranges: [NSValue], textLength: Int) -> [NSValue] {
        ranges.map { value in
            let range = value.rangeValue
            let location = min(range.location, textLength)
            let availableLength = max(0, textLength - location)
            let length = min(range.length, availableLength)
            return NSValue(range: NSRange(location: location, length: length))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func update(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            if textView.hasMarkedText() {
                return
            }

            commit(textView.string)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            commit(textView.string)
        }

        private func commit(_ value: String) {
            guard value != text.wrappedValue else { return }
            DispatchQueue.main.async {
                self.text.wrappedValue = value
            }
        }
    }
}

private struct ContextPreviewList: View {
    @EnvironmentObject var langMgr: LanguageManager
    let items: [MeetingContextItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(items.filter { !$0.trimmedText.isEmpty || $0.extractionStatus == .extracting }) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: item.kind.icon)
                                .foregroundColor(.secondary)
                            Text(item.displayTitle)
                                .font(.headline)
                            Spacer()
                            Text(langMgr.t(item.kind.displayName, item.kind.englishDisplayName))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let source = item.source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(source)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        ContextExtractionStatusView(item: item)

                        if !item.trimmedText.isEmpty {
                            RenderedNotesView(text: item.trimmedText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)

                    if item.id != items.filter({ !$0.trimmedText.isEmpty || $0.extractionStatus == .extracting }).last?.id {
                        Divider()
                    }
                }
            }
            .padding()
        }
    }
}

private struct ContextExtractionStatusView: View {
    @EnvironmentObject var langMgr: LanguageManager
    let item: MeetingContextItem

    var body: some View {
        switch item.extractionStatus {
        case .extracting:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
                Text(langMgr.t("正在读取网页内容...", "Reading webpage content..."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .succeeded:
            if item.kind != .text {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(langMgr.t("已读取内容，可继续编辑", "Content read. You can edit it."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(item.extractionError ?? langMgr.t("读取失败，可手动粘贴内容。", "Reading failed. You can paste content manually."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .idle:
            EmptyView()
        }
    }
}

private struct TranscriptListView: View {
    @EnvironmentObject var langMgr: LanguageManager
    let displayChunks: [TranscriptDisplayChunk]
    private let bottomAnchorID = "transcript-bottom-anchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if displayChunks.isEmpty {
                    Text(langMgr.t("转录内容将在此显示...", "Transcript will appear here..."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .foregroundColor(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(displayChunks) { chunk in
                            TranscriptChunkRowView(chunk: chunk)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .padding()
                }
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: displayChunks) { _, _ in
                scrollToBottom(proxy)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !displayChunks.isEmpty else { return }

        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

private struct SpeakerParticipantDraft: Identifiable, Hashable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

private struct SpeakerNamingSheet: View {
    @EnvironmentObject var langMgr: LanguageManager
    let options: [TranscriptSpeakerNamingOption]
    let participantNames: [String]
    let onCancel: () -> Void
    let onSave: ([String], [String: String]) -> Void

    @State private var participants: [SpeakerParticipantDraft]
    @State private var assignments: [String: UUID]
    @State private var newParticipantName = ""

    init(
        options: [TranscriptSpeakerNamingOption],
        participantNames: [String],
        onCancel: @escaping () -> Void,
        onSave: @escaping ([String], [String: String]) -> Void
    ) {
        self.options = options
        self.participantNames = participantNames
        self.onCancel = onCancel
        self.onSave = onSave

        var seenNames = Set<String>()
        var drafts: [SpeakerParticipantDraft] = []
        for rawName in participantNames {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            drafts.append(SpeakerParticipantDraft(name: name))
        }

        for option in options {
            guard let name = option.currentName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            drafts.append(SpeakerParticipantDraft(name: name))
        }

        let participantIdByName = Dictionary(uniqueKeysWithValues: drafts.map { ($0.name, $0.id) })
        var initialAssignments: [String: UUID] = [:]
        for option in options {
            guard let name = option.currentName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let participantId = participantIdByName[name] else { continue }
            initialAssignments[option.id] = participantId
        }

        _participants = State(initialValue: drafts)
        _assignments = State(initialValue: initialAssignments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            HStack(alignment: .top, spacing: 18) {
                speakerAssignmentPanel
                    .frame(minWidth: 420, idealWidth: 500, maxWidth: .infinity)

                Divider()
                    .frame(height: 390)

                participantPanel
                    .frame(width: 250)
            }

            footer
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 540)
        .background(ClearInitialFocusView())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(langMgr.t("标记发言人", "Label Speakers"))
                .font(.title3)
                .fontWeight(.semibold)

            Text(langMgr.t(
                "为转录中识别出的默认发言人选择实际参会人。一个参会人可以对应多个默认发言人。",
                "Assign real participant names to detected speaker labels. One participant can map to multiple speaker labels."
            ))
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }

    private var speakerAssignmentPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(langMgr.t("默认发言人", "Detected Speakers"))
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(options) { option in
                        speakerAssignmentRow(option)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 410)
        }
    }

    private func speakerAssignmentRow(_ option: TranscriptSpeakerNamingOption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(option.defaultLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 88, alignment: .leading)

                Picker("", selection: Binding<UUID?>(
                    get: { assignments[option.id] },
                    set: { newValue in
                        assignments[option.id] = newValue
                    }
                )) {
                    Text(langMgr.t("未命名", "Unnamed")).tag(Optional<UUID>.none)
                    ForEach(validParticipants) { participant in
                        Text(participant.name.trimmingCharacters(in: .whitespacesAndNewlines))
                            .tag(Optional(participant.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                Spacer()
            }

            if !option.sampleTexts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(option.sampleTexts, id: \.self) { sample in
                        Text("\"\(sample)\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(8)
    }

    private var participantPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(langMgr.t("参会人名单", "Participants"))
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if participants.isEmpty {
                        Text(langMgr.t("先添加参会人姓名", "Add participant names first"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }

                    ForEach($participants) { $participant in
                        HStack(spacing: 6) {
                            BorderlessRoundedTextField(
                                placeholder: langMgr.t("姓名", "Name"),
                                text: $participant.name
                            )
                            .frame(height: 34)

                            Button {
                                removeParticipant(participant.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                            .help(langMgr.t("删除", "Delete"))
                        }
                    }
                }
            }
            .frame(maxHeight: 330)

            Divider()

            HStack(spacing: 8) {
                TextField(langMgr.t("添加姓名", "Add name"), text: $newParticipantName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addParticipant)

                Button {
                    addParticipant()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(langMgr.t("添加", "Add"))
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(langMgr.t("取消", "Cancel")) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button(langMgr.t("保存", "Save")) {
                onSave(savedParticipantNames, savedMappings)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var validParticipants: [SpeakerParticipantDraft] {
        participants.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var savedParticipantNames: [String] {
        var seenNames = Set<String>()
        var names: [String] = []

        for participant in validParticipants {
            let name = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            names.append(name)
        }

        return names
    }

    private var savedMappings: [String: String] {
        let participantNameById = Dictionary(
            uniqueKeysWithValues: validParticipants.map {
                ($0.id, $0.name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )

        return assignments.reduce(into: [String: String]()) { result, pair in
            guard let name = participantNameById[pair.value], !name.isEmpty else { return }
            result[pair.key] = name
        }
    }

    private func addParticipant() {
        let name = newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        participants.append(SpeakerParticipantDraft(name: name))
        newParticipantName = ""
    }

    private func removeParticipant(_ id: UUID) {
        participants.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
    }
}

private struct FollowUpTasksSheet: View {
    @ObservedObject var viewModel: MeetingViewModel
    @EnvironmentObject var langMgr: LanguageManager
    let onClose: () -> Void
    @State private var reminderLists: [ReminderListOption] = []
    @State private var selectedReminderListId = ""
    @State private var newTaskTitle = ""
    @State private var isLoadingLists = false
    @State private var localErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            listPicker
            taskList
            manualEntry
            footer
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 560)
        .task {
            await loadReminderLists()
            await viewModel.refreshReminderLinks()
            if viewModel.meeting.followUpTasks.isEmpty &&
                !viewModel.meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await viewModel.extractFollowUpTasks()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(langMgr.t("管理待办", "Manage Tasks"))
                    .font(.title2.weight(.semibold))
                Text(langMgr.t("确认后将任务添加到系统提醒事项。", "Confirm tasks before adding them to Reminders."))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                Task { await viewModel.extractFollowUpTasks() }
            } label: {
                Label(
                    viewModel.isExtractingFollowUpTasks ? langMgr.t("识别中", "Extracting") : langMgr.t("重新识别", "Extract"),
                    systemImage: "sparkles"
                )
            }
            .buttonStyle(DetailHeaderActionButtonStyle())
            .disabled(viewModel.isExtractingFollowUpTasks || viewModel.meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var listPicker: some View {
        HStack(spacing: 10) {
            Label(langMgr.t("提醒列表", "Reminder List"), systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.medium))

            Picker("", selection: $selectedReminderListId) {
                if reminderLists.isEmpty {
                    Text(langMgr.t("默认列表", "Default List")).tag("")
                }

                ForEach(reminderLists) { list in
                    Text(list.isDefault
                         ? langMgr.t("\(list.title)（默认）", "\(list.title) (Default)")
                         : list.title)
                        .tag(list.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            .disabled(isLoadingLists)

            if isLoadingLists {
                ProgressView()
                    .scaleEffect(0.55)
            }

            Spacer()
        }
    }

    private var hasStructuredContent: Bool {
        !viewModel.meeting.decisions.isEmpty ||
        !viewModel.meeting.risks.isEmpty ||
        !viewModel.meeting.openQuestions.isEmpty
    }

    private var taskList: some View {
        Group {
            if viewModel.isExtractingFollowUpTasks && viewModel.meeting.followUpTasks.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(langMgr.t("正在从会议纪要中识别待办...", "Extracting tasks from the meeting notes..."))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.meeting.followUpTasks.isEmpty && !hasStructuredContent {
                VStack(spacing: 8) {
                    Image(systemName: "checklist.unchecked")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(langMgr.t("还没有待办，可重新识别或手动补录。", "No tasks yet. Extract again or add one manually."))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        structuredSummarySections
                        if !viewModel.meeting.followUpTasks.isEmpty {
                            if hasStructuredContent {
                                Divider()
                                    .padding(.vertical, 4)
                                Text(langMgr.t("待办事项", "Action Items"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(viewModel.meeting.followUpTasks) { task in
                                FollowUpTaskRow(
                                    task: binding(for: task),
                                    selectedReminderListId: selectedReminderListId,
                                    isSyncing: viewModel.syncingFollowUpTaskIds.contains(task.id),
                                    onAdd: { currentTask in
                                        Task { await viewModel.createReminder(for: currentTask, listIdentifier: selectedReminderListId.isEmpty ? nil : selectedReminderListId) }
                                    },
                                    onRemove: { currentTask in
                                        Task { await viewModel.removeReminder(for: currentTask) }
                                    },
                                    onDeleteLocal: { currentTask in
                                        viewModel.deleteFollowUpTask(currentTask)
                                    }
                                )
                                .environmentObject(langMgr)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var structuredSummarySections: some View {
        if !viewModel.meeting.decisions.isEmpty {
            DisclosureGroup(
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.meeting.decisions) { decision in
                            DecisionRow(decision: decision, langMgr: langMgr)
                        }
                    }
                    .padding(.top, 4)
                },
                label: {
                    Label(langMgr.t("关键决策", "Key Decisions"), systemImage: "checkmark.seal")
                        .font(.subheadline.weight(.semibold))
                }
            )
        }

        if !viewModel.meeting.risks.isEmpty {
            DisclosureGroup(
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.meeting.risks) { risk in
                            RiskRow(risk: risk, langMgr: langMgr)
                        }
                    }
                    .padding(.top, 4)
                },
                label: {
                    Label(langMgr.t("风险事项", "Risks"), systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                }
            )
        }

        if !viewModel.meeting.openQuestions.isEmpty {
            DisclosureGroup(
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.meeting.openQuestions) { question in
                            OpenQuestionRow(question: question, langMgr: langMgr)
                        }
                    }
                    .padding(.top, 4)
                },
                label: {
                    Label(langMgr.t("待确认问题", "Open Questions"), systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                }
            )
        }
    }

    private var manualEntry: some View {
        HStack(spacing: 8) {
            TextField(langMgr.t("手动补录待办", "Add a task manually"), text: $newTaskTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addManualTask)

            Button {
                addManualTask()
            } label: {
                Label(langMgr.t("添加", "Add"), systemImage: "plus")
            }
            .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = viewModel.errorMessage ?? localErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(langMgr.t("完成", "Done")) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func binding(for task: MeetingFollowUpTask) -> Binding<MeetingFollowUpTask> {
        Binding(
            get: {
                viewModel.meeting.followUpTasks.first(where: { $0.id == task.id }) ?? task
            },
            set: { updatedTask in
                guard let index = viewModel.meeting.followUpTasks.firstIndex(where: { $0.id == task.id }) else { return }
                var taskToSave = updatedTask
                taskToSave.updatedAt = Date()
                viewModel.meeting.followUpTasks[index] = taskToSave
            }
        )
    }

    private func addManualTask() {
        viewModel.addManualFollowUpTask(title: newTaskTitle)
        newTaskTitle = ""
    }

    private func loadReminderLists() async {
        isLoadingLists = true
        defer { isLoadingLists = false }

        do {
            let lists = try await ReminderManager.shared.reminderLists()
            reminderLists = lists
            selectedReminderListId = lists.first(where: \.isDefault)?.id ?? lists.first?.id ?? ""
            localErrorMessage = nil
        } catch {
            localErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct FollowUpTaskRow: View {
    @Binding var task: MeetingFollowUpTask
    @EnvironmentObject var langMgr: LanguageManager
    let selectedReminderListId: String
    let isSyncing: Bool
    let onAdd: (MeetingFollowUpTask) -> Void
    let onRemove: (MeetingFollowUpTask) -> Void
    let onDeleteLocal: (MeetingFollowUpTask) -> Void

    private var hasDueDate: Binding<Bool> {
        Binding(
            get: { task.dueDate != nil },
            set: { enabled in
                task.dueDate = enabled ? (task.dueDate ?? Date()) : nil
            }
        )
    }

    private var dueDate: Binding<Date> {
        Binding(
            get: { task.dueDate ?? Date() },
            set: { task.dueDate = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Label(
                    langMgr.t(task.kind.displayName, task.kind.englishDisplayName),
                    systemImage: task.kind.icon
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()

                TextField(langMgr.t("任务标题", "Task title"), text: $task.title)
                    .textFieldStyle(.plain)
                    .font(.headline)

                Spacer()

                Button {
                    task.isSyncedToReminders ? onRemove(task) : onAdd(task)
                } label: {
                    if isSyncing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 18, height: 18)
                    } else {
                        Label(
                            task.isSyncedToReminders ? langMgr.t("移除", "Remove") : langMgr.t("添加", "Add"),
                            systemImage: task.isSyncedToReminders ? "minus.circle" : "plus.circle"
                        )
                    }
                }
                .buttonStyle(DetailHeaderActionButtonStyle(isConfirmed: task.isSyncedToReminders))
                .disabled(isSyncing || task.trimmedTitle.isEmpty)

                Button {
                    onDeleteLocal(task)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .disabled(task.isSyncedToReminders)
                .help(task.isSyncedToReminders
                      ? langMgr.t("请先从提醒事项中移除", "Remove it from Reminders first")
                      : langMgr.t("删除待办", "Delete task"))
            }

            TextField(langMgr.t("补充说明", "Details"), text: $task.detail)
                .textFieldStyle(.roundedBorder)

            if !task.sourceExcerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(task.sourceExcerpt)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Toggle(langMgr.t("截止日期", "Due Date"), isOn: hasDueDate)
                    .toggleStyle(.checkbox)

                if task.dueDate != nil {
                    DatePicker("", selection: dueDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .frame(maxWidth: 220)
                }

                Spacer()

                if let listTitle = task.reminderCalendarTitle, task.isSyncedToReminders {
                    Text(langMgr.t("已添加至 \(listTitle)", "Added to \(listTitle)"))
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(8)
    }
}

private struct BorderlessRoundedTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.drawsBackground = true
        textField.backgroundColor = .controlBackgroundColor
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true

        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }
    }
}

private struct ClearInitialFocusView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

// MARK: - Shimmer Overlay
struct ShimmerOverlay: View {
    @State private var animate: Bool = false
    let color: Color

    init(color: Color = .green) {
        self.color = color
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.clear, color.opacity(0.1), Color.clear]),
                        startPoint: UnitPoint(x: animate ? 2.5 : -1, y: 0.5),
                        endPoint: UnitPoint(x: animate ? 3.5 : 0, y: 0.5)
                    )
                )
                .frame(width: width, height: height)
                .onAppear {
                    animate = true
                }
                .animation(
                    Animation.linear(duration: 1.5).repeatForever(autoreverses: false),
                    value: animate
                )
        }
        .allowsHitTesting(false)
    }
}

private struct DecisionRow: View {
    let decision: MeetingDecision
    let langMgr: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                confidenceBadge
                Text(decision.title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !decision.owner.isEmpty {
                Text(langMgr.t("负责人：\(decision.owner)", "Owner: \(decision.owner)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !decision.sourceExcerpt.isEmpty {
                Text("\u{201C}\(decision.sourceExcerpt)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var confidenceBadge: some View {
        let isLow = decision.confidence == "low"
        return Text(isLow ? langMgr.t("待确认", "Unconfirmed") : langMgr.t("已确认", "Confirmed"))
            .font(.caption2.weight(.medium))
            .foregroundStyle(isLow ? Color.orange : Color.green)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                (isLow ? Color.orange : Color.green).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }
}

private struct RiskRow: View {
    let risk: MeetingRisk
    let langMgr: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(severityColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                Text(risk.title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !risk.mitigation.isEmpty {
                Text(langMgr.t("应对：\(risk.mitigation)", "Mitigation: \(risk.mitigation)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !risk.owner.isEmpty {
                Text(langMgr.t("负责人：\(risk.owner)", "Owner: \(risk.owner)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var severityColor: Color {
        switch risk.severity {
        case "high": return .red
        case "low": return .green
        default: return .orange
        }
    }
}

private struct OpenQuestionRow: View {
    let question: MeetingOpenQuestion
    let langMgr: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(question.question)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.owner.isEmpty {
                Text(langMgr.t("负责确认：\(question.owner)", "Owner: \(question.owner)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !question.nextStep.isEmpty {
                Text(langMgr.t("下一步：\(question.nextStep)", "Next: \(question.nextStep)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    MeetingListView(settingsViewModel: SettingsViewModel())
        .environmentObject(LanguageManager.shared)
}
