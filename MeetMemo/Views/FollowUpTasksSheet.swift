import SwiftUI

struct FollowUpTasksSheet: View {
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
            viewModel.populateFollowUpTasksFromStructuredSummaryIfNeeded()
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
        !viewModel.meeting.openQuestions.isEmpty ||
        !viewModel.meeting.milestones.isEmpty
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

            let sourceExcerpt = nonDuplicateFollowUpTaskExcerpt(
                task.sourceExcerpt,
                comparedTo: [task.title, task.detail]
            )
            if !sourceExcerpt.isEmpty {
                Text(sourceExcerpt)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Toggle(langMgr.t("截止日期", "Due Date"), isOn: hasDueDate)
                    .toggleStyle(.checkbox)

                if task.dueDate == nil,
                   !task.dueDateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(langMgr.t(
                        "原文：\(task.dueDateText)",
                        "Transcript: \(task.dueDateText)"
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

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

private func nonDuplicateFollowUpTaskExcerpt(_ text: String, comparedTo visibleTexts: [String]) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let normalizedText = normalizedFollowUpTaskText(trimmed)
    let normalizedVisibleTexts = visibleTexts
        .map { normalizedFollowUpTaskText($0) }
        .filter { !$0.isEmpty && $0.count >= 8 }

    let duplicatesVisibleText = normalizedVisibleTexts.contains { visibleText in
        normalizedText == visibleText ||
        normalizedText.contains(visibleText) ||
        visibleText.contains(normalizedText)
    }

    return duplicatesVisibleText ? "" : trimmed
}

private func normalizedFollowUpTaskText(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"'‘’。.!！?？"))
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
            if !risk.sourceExcerpt.isEmpty {
                Text("\u{201C}\(risk.sourceExcerpt)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
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
            if !question.sourceExcerpt.isEmpty {
                Text("\u{201C}\(question.sourceExcerpt)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}
