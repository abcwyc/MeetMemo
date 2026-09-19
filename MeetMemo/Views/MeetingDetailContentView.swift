import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension ToolbarContent {
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            // Custom capsules provide their own background instead of stacking it over toolbar glass.
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var showDeleteAlert = false
    @State private var contextEditorFocusRequest = 0
    /// An NSTextField that is being edited keeps its own text and writes it
    /// back when editing ends, overwriting a title generated in the meantime.
    @FocusState private var isTitleFieldFocused: Bool
    /// Bumped on every genuine "new document" boundary for the notes web
    /// editor (meeting switch, a fresh AI generation landing) — see
    /// `MarkdownWebEditorView`'s doc comment for why this can't just be
    /// derived from the notes text itself (that would remount on every
    /// keystroke).
    @State private var notesEditorDocumentRevision = 0
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
            initialHasGeneratedNotes: initialHasGeneratedNotes,
            meetingIsFullyLoaded: true
        ))
        self.onOpenSettings = onOpenSettings
        self.onDelete = onDelete
    }

    private var cannotStartRecording: Bool {
        recordingSessionManager.isSessionBusy
            && !recordingSessionManager.isRecordingMeeting(viewModel.meeting.id)
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
            viewModel.flushPendingChanges()
            viewModel.deleteIfEmpty()
            speakerNamingWindow?.close()
            followUpTasksWindow?.close()
        }
        .fileImporter(
            isPresented: $isImportingContextFile,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: true
        ) { result in
            importContextFile(result)
        }
        .onAppear {
            if viewModel.selectedTab == .context {
                prepareContextWorkspace(requestFocus: true)
            }
        }
        .onChange(of: viewModel.selectedTab) { _, selectedTab in
            if selectedTab == .context {
                prepareContextWorkspace(requestFocus: true)
            }
        }
        .onChange(of: viewModel.isGeneratingNotes) { _, isGenerating in
            if isGenerating {
                isTitleFieldFocused = false
            }
        }
        .onChange(of: meeting.id) { _, _ in
            viewModel.switchToMeeting(
                meeting,
                initialSelectedTab: initialSelectedTab,
                initialHasTranscript: initialHasTranscript,
                initialHasGeneratedNotes: initialHasGeneratedNotes,
                meetingIsFullyLoaded: true
            )
            hoveredTab = nil
            notesEditorDocumentRevision += 1
            showCopyConfirmation = false

            if viewModel.selectedTab == .context {
                prepareContextWorkspace(requestFocus: true)
            }
        }
        .background(WindowWidthReader(width: $windowWidth))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                detailActionButtons
            }
            .withoutSharedBackground()

            if shouldShowToolbarTabs {
                ToolbarItem(placement: .primaryAction) {
                    detailTabBar
                }
                .withoutSharedBackground()
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
                    .focused($isTitleFieldFocused)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 180)

                Spacer()

                titleActionButtons
                moreMenu
            }

            MeetingTagEditor(tags: $viewModel.meeting.tags)
                .environmentObject(langMgr)

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

            Button {
                viewModel.exportMarkdown()
            } label: {
                Label(langMgr.t("导出 Markdown", "Export as Markdown"), systemImage: "doc.badge.arrow.up")
            }
            .disabled(!viewModel.canExportMeetingNotesMarkdown)

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
            if viewModel.selectedTab == .enhancedNotes && viewModel.canShowActionDigestEntry {
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

            if viewModel.selectedTab == .enhancedNotes && viewModel.canShowFollowUpTasksEntry {
                Button {
                    openFollowUpTasksWindow()
                } label: {
                    Label(langMgr.t("管理待办", "Tasks"), systemImage: "checklist")
                }
                .buttonStyle(DetailHeaderActionButtonStyle())
            }

            if viewModel.selectedTab == .context {
                Button {
                    prepareContextWorkspace(requestFocus: true)
                } label: {
                    Label(langMgr.t("添加记录", "Add Note"), systemImage: "text.alignleft")
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
                        .foregroundColor(isGenerateButtonActive ? .accentColor : .secondary)
                }

                if !usesCompactToolbarActions {
                    Text(generateButtonTitle)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.8)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(generateButtonForegroundColor)
            .frame(minHeight: 30)
            .padding(.horizontal, usesCompactToolbarActions ? 8 : 10)
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
                        ShimmerOverlay(color: .accentColor)
                            .clipShape(Capsule(style: .continuous))
                    }
                }
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isGenerateButtonHovered = $0 }
        .disabled(!viewModel.toolbarHasFinalTranscript || viewModel.isGeneratingNotes || viewModel.isRecording || viewModel.isStartingRecording)
        .help(generateButtonHelp)
    }

    private var recordingButton: some View {
        Button {
            AppLog.ui.debug("🎙️ Recording toolbar button tapped for meeting: \(viewModel.meeting.id)")
            viewModel.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                if viewModel.isStoppingRecording {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: viewModel.recordingButtonIconName)
                        .foregroundColor(viewModel.isRecording ? .red : .accentColor)
                }

                if !usesCompactToolbarActions {
                    Text(viewModel.recordingButtonText)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(recordingButtonForegroundColor)
            .frame(minHeight: 30)
            .padding(.horizontal, usesCompactToolbarActions ? 8 : 10)
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
        .disabled(cannotStartRecording || viewModel.isValidatingKey || viewModel.isStartingRecording || viewModel.isStoppingRecording)
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

    private var isGenerateButtonActive: Bool {
        viewModel.toolbarHasFinalTranscript && !viewModel.isRecording && !viewModel.isStartingRecording
    }

    /// First-time generation is the primary next step; regenerating is secondary and stays neutral.
    private var isGenerateButtonEmphasized: Bool {
        isGenerateButtonActive && !viewModel.toolbarHasGeneratedNotes
    }

    private var generateButtonForegroundColor: Color {
        if isGenerateButtonEmphasized { return .accentColor }
        return isGenerateButtonActive ? Color.primary.opacity(0.85) : .secondary
    }

    private var generateButtonBackgroundColor: Color {
        if isGenerateButtonEmphasized {
            return Color.accentColor.opacity(isGenerateButtonHovered ? 0.22 : 0.16)
        }

        if isGenerateButtonActive {
            return Color.primary.opacity(isGenerateButtonHovered ? 0.10 : 0.06)
        }

        return Color.secondary.opacity(isGenerateButtonHovered ? 0.14 : 0.08)
    }

    private var generateButtonBorderColor: Color {
        if isGenerateButtonEmphasized {
            return Color.accentColor.opacity(isGenerateButtonHovered ? 0.42 : 0.3)
        }

        if isGenerateButtonActive {
            return Color.primary.opacity(isGenerateButtonHovered ? 0.16 : 0.10)
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

    private func generateNotesWithTemplate(_ templateId: UUID?) async {
        viewModel.selectedTab = .enhancedNotes

        if viewModel.selectedTemplateId == templateId {
            await viewModel.generateNotes()
            // Fresh content landed — remount the web editor onto it rather
            // than leaving it pointed at whatever (stale, pre-generation)
            // document it last mounted.
            notesEditorDocumentRevision += 1
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

    @ViewBuilder
    private var contextView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let attachments = viewModel.meeting.contextItems.filter { $0.kind != .text }
            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(langMgr.t("附件", "Attachments"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ContextAttachmentFlowLayout(spacing: 7) {
                        ForEach(attachments) { attachment in
                            ContextAttachmentChip(
                                item: attachment,
                                onDelete: { viewModel.deleteContextItem(attachment) }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let record = viewModel.meeting.contextItems.first(where: { $0.kind == .text }) {
                ZStack(alignment: .topLeading) {
                    MarkdownWebEditorView(
                        text: contextRecordTextBinding(for: record),
                        documentId: "\(viewModel.meeting.id.uuidString)-context-\(record.id.uuidString)",
                        readOnly: false,
                        focusRequest: contextEditorFocusRequest
                    )

                    if record.extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(langMgr.t("在此输入会议背景、讨论议题或准备资料...", "Enter meeting background, agenda, or prep notes here..."))
                            .font(.system(size: MeetingNotesTypography.bodyFontSize))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, MeetingNotesTypography.contentInset)
                            .padding(.top, MeetingNotesTypography.contentInset)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 200)
                .background(
                    colorScheme == .dark
                        ? Color(nsColor: .controlBackgroundColor).opacity(0.5)
                        : Color.gray.opacity(0.05)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color(nsColor: .separatorColor)
                                : Color.gray.opacity(0.18),
                            lineWidth: 1
                        )
                }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func importContextFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var failedFileNames: [String] = []

            for url in urls {
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
                    failedFileNames.append(url.lastPathComponent)
                }
            }

            if !failedFileNames.isEmpty {
                let names = failedFileNames.joined(separator: "、")
                viewModel.errorMessage = langMgr.t(
                    "无法读取以下文件：\(names)。当前支持 UTF-8 文本文件。",
                    "Could not read: \(names). UTF-8 text files are supported for now."
                )
            }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private var transcriptView: some View {
        TranscriptListView(displayChunks: viewModel.transcriptDisplayChunks)
    }

    /// Captures the meeting identity represented by this editor update.
    /// A WKWebView callback can already be queued when the sidebar switches
    /// meetings; in that case its old binding must not write into the newly
    /// selected meeting before SwiftUI finishes updating the coordinator.
    private var generatedNotesBinding: Binding<String> {
        let boundMeetingId = viewModel.meeting.id
        return Binding(
            get: { viewModel.meeting.generatedNotes },
            set: { notes in
                guard viewModel.meeting.id == boundMeetingId else { return }
                viewModel.updateGeneratedNotes(notes)
            }
        )
    }

    private var enhancedNotesView: some View {
        // No separate edit/preview mode: the notes editor is directly
        // editable in place at all times (Atomic Editor's own design
        // principle — "the document you read is the document you edit").
        // The one exception is while AI generation is actively streaming
        // in, where editing the doc out from under the stream would be
        // incoherent — see the isGeneratingNotes branch below.
        VStack(alignment: .leading, spacing: 0) {
            notesStatusCard
            if let notice = viewModel.transcriptCompressionNotice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 8)
            }
            MarkdownWebEditorView(
                text: generatedNotesBinding,
                documentId: "\(viewModel.meeting.id.uuidString)-\(notesEditorDocumentRevision)",
                readOnly: viewModel.isGeneratingNotes,
                streamsExternalTextUpdates: viewModel.isGeneratingNotes
            )
            .frame(minHeight: 110)
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var notesStatusCard: some View {
        if viewModel.isGeneratingNotes {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.65)
                Text(langMgr.t("正在生成会议纪要...", "Generating meeting notes..."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
        } else if viewModel.isExtractingStructuredSummary {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(langMgr.t(
                    "会议纪要已生成，正在后台提取行动摘要。",
                    "Meeting notes are ready. Action digest is being extracted in the background."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
        } else {
            meetingSummaryCard
        }
    }

    @ViewBuilder
    private var meetingSummaryCard: some View {
        if !viewModel.meeting.oneLiner.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(viewModel.meeting.oneLiner)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
        }
    }

    private func prepareContextWorkspace(requestFocus: Bool) {
        viewModel.prepareContextRecord()
        guard requestFocus else { return }
        contextEditorFocusRequest += 1
    }

    private func contextRecordTextBinding(for item: MeetingContextItem) -> Binding<String> {
        let boundMeetingId = viewModel.meeting.id
        let boundItemId = item.id
        return Binding(
            get: {
                guard viewModel.meeting.id == boundMeetingId else { return "" }
                return viewModel.meeting.contextItems
                    .first(where: { $0.id == boundItemId })?
                    .extractedText ?? ""
            },
            set: { updatedText in
                guard viewModel.meeting.id == boundMeetingId,
                      let index = viewModel.meeting.contextItems.firstIndex(where: { $0.id == boundItemId }) else {
                    return
                }
                viewModel.meeting.contextItems[index].extractedText = updatedText
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

private final class MovablePanelCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
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

private struct MeetingTagEditor: View {
    @Binding var tags: [String]
    @EnvironmentObject var langMgr: LanguageManager
    @State private var draft = ""
    @State private var isAdding = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ForEach(tags, id: \.self) { tag in
                MeetingTagChip(tag: tag) {
                    tags.removeAll { $0 == tag }
                }
            }

            if isAdding {
                TextField(langMgr.t("输入标签后回车", "Type a tag, press Return"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 140)
                    .focused($isFieldFocused)
                    .onSubmit(commitDraft)
                    .onExitCommand {
                        draft = ""
                        isAdding = false
                    }
                    .onChange(of: isFieldFocused) { _, focused in
                        if !focused { commitDraft(keepEditing: false) }
                    }
            } else {
                Button {
                    isAdding = true
                    DispatchQueue.main.async { isFieldFocused = true }
                } label: {
                    Label(
                        tags.isEmpty ? langMgr.t("添加标签", "Add Tag") : langMgr.t("添加", "Add"),
                        systemImage: "plus"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commitDraft() {
        commitDraft(keepEditing: true)
    }

    private func commitDraft(keepEditing: Bool) {
        // Allow entering several tags at once, separated by commas.
        let newTags = draft.components(separatedBy: CharacterSet(charactersIn: ",，"))
        draft = ""
        let merged = Meeting.normalizedTags(tags + newTags)
        if merged != tags {
            tags = merged
        }
        if !keepEditing {
            isAdding = false
        }
    }
}

private struct TranscriptListView: View {
    @EnvironmentObject var langMgr: LanguageManager
    let displayChunks: [TranscriptDisplayChunk]
    private let bottomAnchorID = "transcript-bottom-anchor"
    @State private var isAtBottom = true

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
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding()
                }
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: displayChunks) { _, _ in
                if isAtBottom {
                    scrollToBottom(proxy)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .cornerRadius(8)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !displayChunks.isEmpty else { return }

        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}
