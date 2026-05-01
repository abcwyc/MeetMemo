import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingListView: View {
    @StateObject private var viewModel = MeetingListViewModel()
    @ObservedObject var settingsViewModel: SettingsViewModel
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @EnvironmentObject var langMgr: LanguageManager
    @State private var selectedMeeting: MeetingSummary?
    @State private var navigationPath = NavigationPath()
    @State private var renamingMeeting: MeetingSummary?
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
                ProgressView(langMgr.t("正在导入并转录音频...", "Importing and transcribing audio..."))
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(langMgr.t("搜索会议...", "Search meetings..."), text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            Divider()

            Spacer().frame(height: 12)

            List(selection: $selectedMeeting) {
                ForEach(groupedMeetings, id: \.day) { dayGroup in
                    Section {
                        ForEach(dayGroup.meetings, id: \.id) { meeting in
                            meetingRow(meeting)
                        }
                        .onDelete { indexSet in
                            deleteMeetings(at: indexSet, in: dayGroup)
                        }
                    } header: {
                        Text(dayGroup.day)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                }
            }
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
    }

    private var detailContent: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let selectedMeeting = selectedMeeting {
                    MeetingDetailContentView(
                        meeting: selectedMeeting.placeholderMeeting,
                        initialSelectedTab: selectedMeeting.hasGeneratedNotes ? .enhancedNotes : .transcript,
                        onDelete: {
                            self.selectedMeeting = nil
                        }
                    )
                    .id(selectedMeeting.id)
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
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        createAndSelectMeeting()
                    } label: {
                        Label(langMgr.t("创建", "Create"), systemImage: "plus")
                    }
                    .disabled(recordingSessionManager.isRecording || viewModel.isImportingAudio)
                    .help(recordingSessionManager.isRecording
                        ? langMgr.t("录制中无法创建新会议", "Cannot create new meeting while recording is active")
                        : langMgr.t("新建会议", "New Meeting"))

                    Button {
                        isImportingAudioFile = true
                    } label: {
                        Label(langMgr.t("导入", "Import"), systemImage: "arrow.down.to.line")
                    }
                    .disabled(recordingSessionManager.isRecording || viewModel.isImportingAudio)
                    .help(recordingSessionManager.isRecording
                        ? langMgr.t("录制中无法导入音频", "Cannot import audio while recording is active")
                        : langMgr.t("导入音频并转录", "Import audio and transcribe it"))
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        navigationPath.append("settings")
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help(langMgr.t("设置", "Settings"))
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

    private var groupedMeetings: [DayGroup] {
        let calendar = Calendar.current
        let now = Date()

        let grouped = Dictionary(grouping: viewModel.filteredMeetings) { meeting in
            calendar.startOfDay(for: meeting.date)
        }

        return grouped.map { (date, meetings) in
            let dayString: String

            if calendar.isDateInToday(date) {
                dayString = langMgr.t("今天", "Today")
            } else if calendar.isDateInYesterday(date) {
                dayString = langMgr.t("昨天", "Yesterday")
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                dayString = date.formatted(.dateTime.weekday(.wide))
            } else {
                dayString = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }

            return DayGroup(day: dayString, date: date, meetings: meetings.sorted { $0.date > $1.date })
        }.sorted { $0.date > $1.date }
    }

    private func meetingRow(_ meeting: MeetingSummary) -> some View {
        MeetingRowView(
            meeting: meeting,
            onRename: { beginRenaming(meeting) },
            onDelete: { deleteMeeting(meeting) }
        )
        .tag(meeting)
    }

    private func beginRenaming(_ meeting: MeetingSummary) {
        renameText = meeting.title
        renamingMeeting = meeting
    }

    private func deleteMeeting(_ meeting: MeetingSummary) {
        viewModel.deleteMeeting(meeting)
        if selectedMeeting?.id == meeting.id {
            selectedMeeting = nil
        }
    }

    private func deleteMeetings(at indexSet: IndexSet, in dayGroup: DayGroup) {
        for index in indexSet {
            deleteMeeting(dayGroup.meetings[index])
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

struct DayGroup {
    let day: String
    let date: Date
    let meetings: [MeetingSummary]
}

struct MeetingRowView: View {
    let meeting: MeetingSummary
    var onRename: () -> Void = {}
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
                Text(meeting.date, style: .time)
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
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(langMgr.t("删除", "Delete"), systemImage: "trash")
            }
        }
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
    @StateObject private var viewModel: MeetingViewModel
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @EnvironmentObject var langMgr: LanguageManager
    @State private var showDeleteAlert = false
    @State private var isEditing = false
    @State private var showCopyConfirmation = false
    @State private var showAddLinkSheet = false
    @State private var linkURLText = ""
    @State private var linkContextText = ""
    @State private var isImportingContextFile = false
    let onDelete: () -> Void

    init(meeting: Meeting, initialSelectedTab: MeetingViewTab? = nil, onDelete: @escaping () -> Void) {
        self._viewModel = StateObject(wrappedValue: MeetingViewModel(meeting: meeting, initialSelectedTab: initialSelectedTab))
        self.onDelete = onDelete
    }

    private var cannotStartRecording: Bool {
        recordingSessionManager.isRecording && !recordingSessionManager.isRecordingMeeting(viewModel.meeting.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            detailHeader

            VStack(alignment: .leading, spacing: 8) {
                contentToolbar

                switch viewModel.selectedTab {
                case .context:
                    contextView
                case .transcript:
                    transcriptView
                case .enhancedNotes:
                    enhancedNotesView
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
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
            viewModel.deleteIfEmpty()
        }
        .fileImporter(
            isPresented: $isImportingContextFile,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            importContextFile(result)
        }
        .sheet(isPresented: $showAddLinkSheet) {
            addLinkSheet
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(langMgr.t("会议标题", "Meeting Title"), text: $viewModel.meeting.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textFieldStyle(.plain)

                Spacer()

                moreMenu
            }
            .padding(.bottom, 10)

            HStack {
                Picker("", selection: $viewModel.selectedTab) {
                    ForEach(MeetingViewTab.allCases, id: \.self) { tab in
                        Text(langMgr.t(tab.chineseLabel, tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Spacer()

                HStack(spacing: 8) {
                    generateNotesButton
                    recordingButton
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
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

    private var generateNotesButton: some View {
        Menu {
            ForEach(viewModel.templates) { template in
                Button(template.title) {
                    viewModel.selectedTemplateId = template.id
                    viewModel.selectedTab = .enhancedNotes
                    isEditing = false
                }
            }
        } label: {
            HStack(spacing: 4) {
                if viewModel.isGeneratingNotes {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "sparkles")
                        .font(.caption)
                }
                Text(langMgr.t("生成", "Generate"))
            }
            .frame(minWidth: 110, minHeight: 36)
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                Group {
                    if viewModel.shouldAnimateGenerateButton {
                        ShimmerOverlay(color: .green)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.meeting.hasFinalTranscript || viewModel.isGeneratingNotes || viewModel.isRecording || viewModel.isStartingRecording)
        .help(langMgr.t("使用模板生成增强笔记", "Generate enhanced notes using a template"))
    }

    private var recordingButton: some View {
        Button {
            viewModel.toggleRecording()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundColor(viewModel.isRecording ? .red : .accentColor)
                Text(viewModel.recordingButtonText)
            }
            .frame(minWidth: 110, minHeight: 36)
            .background(viewModel.isRecording ? Color.red.opacity(0.1) : Color.accentColor.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                Group {
                    if viewModel.shouldAnimateTranscribeButton {
                        ShimmerOverlay(color: .accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(cannotStartRecording || viewModel.isValidatingKey || viewModel.isStartingRecording)
        .help(cannotStartRecording
            ? langMgr.t("另一个会议正在录制中", "Another meeting is currently being recorded")
            : langMgr.t("开始或停止本次会议的录制", "Start or stop recording for this meeting"))
    }

    private var contentToolbar: some View {
        HStack(spacing: 8) {
            Text(langMgr.t(viewModel.selectedTab.chineseLabel, viewModel.selectedTab.rawValue))
                .font(.headline)
                .foregroundColor(.secondary)

            Spacer()

            if viewModel.selectedTab == .context || viewModel.selectedTab == .enhancedNotes {
                Button {
                    isEditing.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isEditing ? "eye" : "pencil")
                        Text(isEditing ? langMgr.t("预览", "Preview") : langMgr.t("编辑", "Edit"))
                    }
                    .frame(minWidth: 75, minHeight: 24)
                    .font(.caption)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Button {
                viewModel.copyCurrentTabContent()
                showCopyConfirmation = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    showCopyConfirmation = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCopyConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundColor(showCopyConfirmation ? .green : .primary)
                    Text(showCopyConfirmation ? langMgr.t("已复制！", "Copied!") : langMgr.t("复制", "Copy"))
                        .foregroundColor(showCopyConfirmation ? .green : .primary)
                }
                .frame(minWidth: 70, minHeight: 24)
                .font(.caption)
                .background(showCopyConfirmation ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content Views

    private var contextView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEditing {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button {
                            viewModel.addTextContextItem()
                        } label: {
                            Label(langMgr.t("添加文本", "Add Text"), systemImage: "text.alignleft")
                        }

                        Button {
                            linkURLText = ""
                            linkContextText = ""
                            showAddLinkSheet = true
                        } label: {
                            Label(langMgr.t("添加链接", "Add Link"), systemImage: "link")
                        }

                        Button {
                            isImportingContextFile = true
                        } label: {
                            Label(langMgr.t("导入文件", "Import File"), systemImage: "doc.badge.plus")
                        }

                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

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
                                        onDelete: { viewModel.deleteContextItem(item) },
                                        onRefresh: {
                                            if let currentItem = viewModel.meeting.contextItems.first(where: { $0.id == item.id }) {
                                                viewModel.refreshLinkContextItem(currentItem)
                                            }
                                        }
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
                        items: viewModel.meeting.contextItems,
                        onRefresh: { viewModel.refreshLinkContextItem($0) }
                    )
                        .font(.body)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var addLinkSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(langMgr.t("添加链接上下文", "Add Link Context"))
                .font(.headline)

            TextField("https://example.com", text: $linkURLText)
                .textFieldStyle(.roundedBorder)

            IMESafeTextEditor(text: $linkContextText, minHeight: 120)
                .frame(minHeight: 120)
                .background(Color.gray.opacity(0.06))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button(langMgr.t("取消", "Cancel")) {
                    showAddLinkSheet = false
                }
                Button(langMgr.t("添加", "Add")) {
                    viewModel.addLinkContextItem(urlString: linkURLText, notes: linkContextText)
                    showAddLinkSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
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
            if isEditing {
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
}

private struct ContextEditorCard: View {
    @EnvironmentObject var langMgr: LanguageManager
    @Binding var item: MeetingContextItem
    let onDelete: () -> Void
    let onRefresh: () -> Void

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

                if item.kind == .link {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(item.extractionStatus == .extracting)
                    .help(langMgr.t("重新读取链接", "Read link again"))
                }

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
    let onRefresh: (MeetingContextItem) -> Void

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

                            if item.kind == .link {
                                Button {
                                    onRefresh(item)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.plain)
                                .disabled(item.extractionStatus == .extracting)
                                .help(langMgr.t("重新读取链接", "Read link again"))
                            }
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

#Preview {
    MeetingListView(settingsViewModel: SettingsViewModel())
        .environmentObject(LanguageManager.shared)
}
