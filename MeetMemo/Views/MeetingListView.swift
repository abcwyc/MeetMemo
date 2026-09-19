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
    /// The fully loaded meeting currently presented in the detail pane.
    /// Keeping this separate from the sidebar selection lets the old detail
    /// remain visible while the newly selected JSON is decoded off-main,
    /// avoiding the placeholder -> full-content double refresh.
    @State private var presentedMeeting: Meeting?
    /// The target whose load has taken long enough to warrant visible feedback.
    /// Fast local loads never show a transient spinner.
    @State private var switchingIndicatorMeetingId: UUID?
    @State private var navigationPath = NavigationPath()
    @State private var renamingMeeting: MeetingSummary?
    @State private var deletingMeeting: MeetingSummary?
    @State private var renameText = ""
    @State private var isImportingAudioFile = false
    @Environment(\.colorScheme) private var colorScheme

    /// Lightens the sidebar material instead of replacing it, so the subtle tint stays.
    private var sidebarBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.55)
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .task(id: selectedMeeting?.id) {
            await presentSelectedMeeting()
        }
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
        .alert(langMgr.t("转录已停止", "Transcription Stopped"), isPresented: Binding(
            get: { recordingSessionManager.recordingTerminationNotice != nil },
            set: { if !$0 { recordingSessionManager.recordingTerminationNotice = nil } }
        )) {
            Button(langMgr.t("确定", "OK")) {
                recordingSessionManager.recordingTerminationNotice = nil
            }
        } message: {
            Text(recordingSessionManager.recordingTerminationNotice ?? "")
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
                TextField(langMgr.t("搜索会议或 #标签", "Search meetings or #tag"), text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(langMgr.t("清除搜索", "Clear search"))
                }
            }
            .padding(EdgeInsets(top: 2, leading: 12, bottom: 10, trailing: 12))

            if !viewModel.allTags.isEmpty {
                sidebarTagFilterRow
                    .padding(.bottom, 8)
            }

            Divider()

            Color.clear
                .frame(height: SidebarLayout.listTopPadding)

            List(selection: $selectedMeeting) {
                ForEach(viewModel.meetingsGroupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.meetings, id: \.id) { meeting in
                            meetingRow(meeting)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                deleteMeeting(group.meetings[index])
                            }
                        }
                    } header: {
                        Text(daySectionTitle(for: group.day))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
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
        .background(sidebarBackgroundColor)
        .overlay(alignment: .trailing) {
            // Hairline separator between the sidebar and the detail pane.
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(width: 0.5)
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
            .disabled(recordingSessionManager.isSessionBusy || viewModel.isImportingAudio)
            .help(recordingSessionManager.isSessionBusy
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
            .disabled(recordingSessionManager.isSessionBusy || viewModel.isImportingAudio)
            .help(recordingSessionManager.isSessionBusy
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
                if let meeting = presentedMeeting {
                    MeetingDetailContentView(
                        meeting: meeting,
                        initialSelectedTab: meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? .transcript
                            : .enhancedNotes,
                        initialHasTranscript: meeting.hasFinalTranscript,
                        initialHasGeneratedNotes: !meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        onOpenSettings: {
                            navigationPath.append("settings")
                        },
                        onDelete: {
                            self.selectedMeeting = nil
                            self.presentedMeeting = nil
                        }
                    )
                    .overlay(alignment: .top) {
                        if switchingIndicatorMeetingId == selectedMeeting?.id {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(langMgr.t("正在切换会议…", "Switching meeting…"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeOut(duration: 0.16), value: switchingIndicatorMeetingId)
                } else if selectedMeeting != nil {
                    ProgressView(langMgr.t("加载会议内容中…", "Loading meeting…"))
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var sidebarTagFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.allTags, id: \.self) { tag in
                    let isActive = isActiveTagFilter(tag)
                    Button {
                        viewModel.searchText = isActive ? "" : "#\(tag)"
                    } label: {
                        MeetingTagChip(tag: tag, isHighlighted: isActive)
                    }
                    .buttonStyle(.plain)
                    .help(langMgr.t("按标签筛选", "Filter by tag"))
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func isActiveTagFilter(_ tag: String) -> Bool {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = query.first, first == "#" || first == "＃" else { return false }
        return query.dropFirst().trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(tag) == .orderedSame
    }

    private func daySectionTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            return langMgr.t("今天", "Today")
        }
        if calendar.isDateInYesterday(day) {
            return langMgr.t("昨天", "Yesterday")
        }

        let locale = langMgr.language == .chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        var style = Date.FormatStyle.dateTime.locale(locale).month(.abbreviated).day().weekday(.abbreviated)
        if !calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            style = style.year()
        }
        return day.formatted(style)
    }

    private func meetingRow(_ meeting: MeetingSummary) -> some View {
        MeetingRowView(
            meeting: meeting,
            onSelectTag: { tag in viewModel.searchText = "#\(tag)" },
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
        if presentedMeeting?.id == meeting.id {
            presentedMeeting = nil
        }
        viewModel.deleteMeeting(meeting)
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
        presentedMeeting = newMeeting
        selectedMeeting = MeetingSummary(meeting: newMeeting)
    }

    private func importAudioFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                if let meeting = await viewModel.importAudioFile(url: url) {
                    presentedMeeting = meeting
                    selectedMeeting = MeetingSummary(meeting: meeting)
                }
            }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }

    /// Decodes the target before replacing the detail pane. Sidebar
    /// selection still responds immediately, while the currently visible
    /// meeting remains stable until the replacement is ready. `.task(id:)`
    /// cancels stale selections when the user clicks through the list fast.
    @MainActor
    private func presentSelectedMeeting() async {
        guard let selectedMeeting else {
            withAnimation(.easeOut(duration: 0.12)) {
                presentedMeeting = nil
                switchingIndicatorMeetingId = nil
            }
            return
        }

        guard presentedMeeting?.id != selectedMeeting.id else {
            switchingIndicatorMeetingId = nil
            return
        }

        let meetingId = selectedMeeting.id
        let shouldShowSwitchingIndicator = presentedMeeting != nil
        let indicatorTask = Task { @MainActor in
            guard shouldShowSwitchingIndicator else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled,
                  self.selectedMeeting?.id == meetingId,
                  self.presentedMeeting?.id != meetingId else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                switchingIndicatorMeetingId = meetingId
            }
        }
        defer { indicatorTask.cancel() }

        let loadedMeeting = await Task.detached(priority: .userInitiated) {
            LocalStorageManager.shared.loadMeeting(id: meetingId)
        }.value

        guard !Task.isCancelled, self.selectedMeeting?.id == meetingId else { return }

        // Swap the already-decoded model without an implicit animation. The
        // child view and web editor update in one transaction, which avoids
        // animating intermediate layout from one meeting into the next.
        presentedMeeting = loadedMeeting ?? selectedMeeting.placeholderMeeting
        withAnimation(.easeOut(duration: 0.16)) {
            switchingIndicatorMeetingId = nil
        }
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

struct MeetingRowView: View {
    let meeting: MeetingSummary
    var onSelectTag: (String) -> Void = { _ in }
    var onRename: () -> Void = {}
    var onRevealSourceFile: () -> Void = {}
    var onDelete: () -> Void = {}
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @EnvironmentObject var langMgr: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                if recordingSessionManager.isRecordingMeeting(meeting.id) {
                    Image(systemName: "record.circle")
                        .foregroundColor(.red)
                        .font(.body)
                }
                Text(meeting.title.isEmpty ? langMgr.t("未命名会议", "Untitled meeting") : meeting.title)
                    .font(.body)
                    .fontWeight(.regular)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(timestampText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()
                if !meeting.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(meeting.tags, id: \.self) { tag in
                            MeetingTagChip(tag: tag, isCompact: true)
                                .onTapGesture { onSelectTag(tag) }
                        }
                    }
                    .lineLimit(1)
                    .clipped()
                }
                Spacer(minLength: 0)
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
        // The day is already shown by the section header.
        let locale = langMgr.language == .chinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US")
        return meeting.date.formatted(.dateTime.locale(locale).hour().minute())
    }
}

// MARK: - Tags

struct MeetingTagChip: View {
    let tag: String
    var isCompact = false
    var isHighlighted = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text("#\(tag)")
                .font(.system(size: isCompact ? 10 : 11, weight: .regular))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .regular))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundColor(isHighlighted ? .white : .accentColor)
        .padding(.horizontal, isCompact ? 5 : 7)
        .padding(.vertical, isCompact ? 1 : 3)
        .background {
            Capsule(style: .continuous)
                .fill(isHighlighted ? Color.accentColor : Color.accentColor.opacity(0.12))
        }
        .fixedSize()
    }
}

#Preview {
    MeetingListView(settingsViewModel: SettingsViewModel())
        .environmentObject(LanguageManager.shared)
}
