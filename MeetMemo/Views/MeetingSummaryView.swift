import SwiftUI

struct MeetingSummaryView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @EnvironmentObject var langMgr: LanguageManager

    private var meeting: Meeting { viewModel.meeting }
    private var isExtracting: Bool { viewModel.isExtractingStructuredSummary }

    private var hasAnyContent: Bool {
        !meeting.oneLiner.isEmpty ||
        !meeting.discussions.isEmpty ||
        !meeting.decisions.isEmpty ||
        !meeting.followUpTasks.isEmpty ||
        !meeting.risks.isEmpty ||
        !meeting.openQuestions.isEmpty ||
        !meeting.milestones.isEmpty ||
        !meeting.diagrams.isEmpty
    }

    var body: some View {
        ScrollView {
            if !hasAnyContent && !isExtracting {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    emptyState
                }
                .padding()
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    statusSection
                    headerSection

                    if isExtracting && !hasAnyContent {
                        extractingIndicator
                    }

                    if !meeting.discussions.isEmpty {
                        discussionsSection
                    }

                    if !meeting.decisions.isEmpty {
                        decisionsSection
                    }

                    if !meeting.followUpTasks.isEmpty {
                        actionItemsSection
                    }

                    if !meeting.risks.isEmpty {
                        risksSection
                    }

                    if !meeting.openQuestions.isEmpty {
                        openQuestionsSection
                    }

                    if !meeting.milestones.isEmpty {
                        milestonesSection
                    }

                    if !meeting.diagrams.isEmpty {
                        diagramsSection
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
        .onAppear {
            viewModel.extractStructuredSummaryIfNeeded()
        }
    }

    // MARK: - Header Section (Meeting Metadata)

    @ViewBuilder
    private var statusSection: some View {
        if isExtracting {
            SummaryExtractingBanner(
                title: langMgr.t("正在提取结构化内容", "Extracting structured content"),
                message: langMgr.t(
                    "正在分析转录原文，完成后会更新议题、决策、风险、待确认问题和待办。",
                    "Analyzing the transcript. Topics, decisions, risks, questions, and tasks will update when complete."
                )
            )
        } else if let message = viewModel.structuredSummaryErrorMessage {
            SummaryStatusBanner(
                icon: "exclamationmark.triangle",
                message: message,
                tint: .red,
                actionTitle: langMgr.t("重试", "Retry"),
                action: { viewModel.refreshStructuredSummary() }
            )
        } else if viewModel.isStructuredSummaryStale {
            SummaryStatusBanner(
                icon: "arrow.triangle.2.circlepath",
                message: langMgr.t("转录原文已变化，行动摘要可能不是最新。", "Transcript changed. This digest may be out of date."),
                tint: .orange,
                actionTitle: langMgr.t("刷新", "Refresh"),
                action: { viewModel.refreshStructuredSummary() }
            )
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                metaRow(
                    icon: "calendar",
                    text: meeting.date.formatted(date: .long, time: .shortened)
                )

                if !meeting.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metaRow(icon: "mappin", text: meeting.location)
                }

                if !meeting.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metaRow(
                        icon: "person.circle",
                        text: langMgr.t("主持：\(meeting.host)", "Host: \(meeting.host)")
                    )
                }
            }

            if !meeting.speakerParticipantNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    Text(langMgr.t("参会人", "Attendees"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                    AttendeesFlow(names: meeting.speakerParticipantNames)
                }
            }

            if !meeting.oneLiner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Text(meeting.oneLiner)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metaRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Extracting Indicator

    private var extractingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text(langMgr.t("正在分析转录原文...", "Analyzing transcript..."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Discussions Section

    private var discussionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SummarySectionHeader(
                icon: "text.bubble",
                title: langMgr.t("议题讨论", "Discussion Topics"),
                count: meeting.discussions.count
            )
            ForEach(Array(meeting.discussions.enumerated()), id: \.element.id) { index, discussion in
                DiscussionCard(index: index + 1, discussion: discussion, langMgr: langMgr)
            }
        }
    }

    // MARK: - Decisions Section

    private var decisionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummarySectionHeader(
                icon: "checkmark.seal",
                title: langMgr.t("关键决策", "Key Decisions"),
                count: meeting.decisions.count
            )
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(meeting.decisions) { decision in
                    DecisionGridCard(decision: decision, langMgr: langMgr)
                }
            }
        }
    }

    // MARK: - Action Items Section

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummarySectionHeader(
                icon: "checklist",
                title: langMgr.t("待办事项", "Action Items"),
                count: meeting.followUpTasks.count
            )
            let grouped = Dictionary(grouping: meeting.followUpTasks, by: \.kind)
            let kindOrder: [FollowUpTaskKind] = [.actionItem, .confirmation, .followUp, .manual]
            VStack(alignment: .leading, spacing: 14) {
                ForEach(kindOrder, id: \.self) { kind in
                    if let tasks = grouped[kind], !tasks.isEmpty {
                        TaskTableSection(kind: kind, tasks: tasks, langMgr: langMgr)
                    }
                }
            }
        }
    }

    // MARK: - Risks Section

    private var risksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummarySectionHeader(
                icon: "exclamationmark.triangle",
                title: langMgr.t("风险事项", "Risks"),
                count: meeting.risks.count
            )
            ForEach(meeting.risks) { risk in
                RiskCard(risk: risk, langMgr: langMgr)
            }
        }
    }

    // MARK: - Open Questions Section

    private var openQuestionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummarySectionHeader(
                icon: "questionmark.circle",
                title: langMgr.t("待确认问题", "Open Questions"),
                count: meeting.openQuestions.count
            )
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(meeting.openQuestions.enumerated()), id: \.element.id) { index, question in
                    OpenQuestionRow(
                        question: question,
                        langMgr: langMgr
                    )
                    if index < meeting.openQuestions.count - 1 {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.gray.opacity(0.10), lineWidth: 1)
            )
        }
    }

    // MARK: - Milestones Section

    private var milestonesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummarySectionHeader(
                icon: "flag.checkered",
                title: langMgr.t("里程碑", "Milestones"),
                count: meeting.milestones.count
            )
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(meeting.milestones.enumerated()), id: \.element.id) { index, milestone in
                    MilestoneRow(milestone: milestone)
                    if index < meeting.milestones.count - 1 {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.gray.opacity(0.10), lineWidth: 1)
            )
        }
    }

    // MARK: - Diagrams Section

    private var diagramsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SummarySectionHeader(
                icon: "chart.xyaxis.line",
                title: langMgr.t("图示", "Diagrams"),
                count: meeting.diagrams.count
            )
            ForEach(meeting.diagrams) { diagram in
                DiagramCard(diagram: diagram)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            langMgr.t("暂无结构化纪要", "No Structured Notes Yet"),
            systemImage: "sparkles",
            description: Text(
                meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? langMgr.t("生成 AI 纪要后自动提取结构化内容", "Generate meeting notes to extract structured content")
                : langMgr.t("点击「重新提取」生成结构化纪要", "Tap Re-extract to generate structured notes")
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SummaryStatusBanner: View {
    let icon: String
    let message: String
    let tint: Color
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(actionTitle, action: action)
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct SummaryExtractingBanner: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }
}

// MARK: - Attendees Flow Layout

private struct AttendeesFlow: View {
    let names: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                let color = ownerColor(for: name)
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.10), in: Capsule())
            }
        }
    }

    private func ownerColor(for name: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .teal, .indigo, .pink]
        let idx = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return palette[idx]
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Section Header

private struct SummarySectionHeader: View {
    let icon: String
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

// MARK: - Decision Grid Card

private struct DecisionGridCard: View {
    let decision: MeetingDecision
    let langMgr: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !decision.owner.isEmpty {
                Text(decision.owner)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(decision.title)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer(minLength: 6)

            confidenceBadge
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }

    private var confidenceBadge: some View {
        let (label, color): (String, Color) = {
            switch decision.confidence {
            case "high":   return (langMgr.t("✓ 全员通过", "✓ Approved"), .green)
            case "low":    return (langMgr.t("待确认", "Pending"), .orange)
            default:       return (langMgr.t("✓ 已确认", "✓ Confirmed"), .blue)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }
}

// MARK: - Task Table Section

private struct TaskTableSection: View {
    let kind: FollowUpTaskKind
    let tasks: [MeetingFollowUpTask]
    let langMgr: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(langMgr.t(kind.displayName, kind.englishDisplayName))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

            HStack(spacing: 0) {
                Text(langMgr.t("任务", "Task"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(langMgr.t("负责人", "Owner"))
                    .frame(width: 80, alignment: .leading)
                Text(langMgr.t("截止时间", "Due Date"))
                    .frame(width: 100, alignment: .leading)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.06))

            Divider()

            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if !task.detail.isEmpty {
                            Text(task.detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ownerChipView(task.owner)
                        .frame(width: 80, alignment: .leading)

                    dueDateView(task.dueDate)
                        .frame(width: 100, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                if index < tasks.count - 1 {
                    Divider().padding(.leading, 10)
                }
            }

            Spacer(minLength: 6)
        }
        .background(Color.gray.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func ownerChipView(_ owner: String) -> some View {
        if owner.isEmpty {
            Text("—").font(.caption2).foregroundStyle(.quaternary)
        } else {
            let color = ownerColor(for: owner)
            Text(owner)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.12), in: Capsule())
        }
    }

    private func ownerColor(for owner: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .teal, .indigo, .pink]
        let idx = abs(owner.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return palette[idx]
    }

    @ViewBuilder
    private func dueDateView(_ date: Date?) -> some View {
        if let date = date {
            let now = Date()
            let isOverdue = date < now
            let isUrgent = date < now.addingTimeInterval(2 * 24 * 3600)
            let color: Color = isOverdue ? .red : isUrgent ? .orange : .secondary
            Text(date, style: .date)
                .font(.caption)
                .foregroundStyle(color)
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Risk Card

private struct RiskCard: View {
    let risk: MeetingRisk
    let langMgr: LanguageManager

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(severityColor)
                .frame(width: 3)
                .frame(minHeight: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(risk.title)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    severityBadge
                }

                if !risk.mitigation.isEmpty {
                    Text(langMgr.t("应对：\(risk.mitigation)", "Mitigation: \(risk.mitigation)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !risk.owner.isEmpty {
                    Label(risk.owner, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var severityColor: Color {
        switch risk.severity {
        case "high": return .red
        case "low":  return .green
        default:     return .orange
        }
    }

    private var severityBadge: some View {
        let (label, color): (String, Color) = {
            switch risk.severity {
            case "high": return (langMgr.t("高", "High"), .red)
            case "low":  return (langMgr.t("低", "Low"), .green)
            default:     return (langMgr.t("中", "Medium"), .orange)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Open Question Row

private struct OpenQuestionRow: View {
    let question: MeetingOpenQuestion
    let langMgr: LanguageManager

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(question.question)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if !question.owner.isEmpty || !question.nextStep.isEmpty {
                    HStack(spacing: 8) {
                        if !question.owner.isEmpty {
                            Label(question.owner, systemImage: "person")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !question.nextStep.isEmpty {
                            Text("→ \(question.nextStep)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Discussion Card

private struct DiscussionCard: View {
    let index: Int
    let discussion: MeetingDiscussion
    let langMgr: LanguageManager

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            indexBadge

            VStack(alignment: .leading, spacing: 8) {
                Text(discussion.title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !discussion.summary.isEmpty {
                    Text(discussion.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if discussion.hasConsensus && !discussion.consensus.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.top, 1)
                        Text(langMgr.t("达成共识：", "Consensus: ") + discussion.consensus)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.07))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.green.opacity(0.4))
                            .frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.10), lineWidth: 1)
        )
    }

    private var indexBadge: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 24, height: 24)
            Text("\(index)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
        }
        .padding(.top, 1)
    }
}

// MARK: - Milestone Row

private struct MilestoneRow: View {
    let milestone: MeetingMilestone

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(milestone.title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if !milestone.targetDate.isEmpty {
                        Text(milestone.targetDate)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if !milestone.milestoneDescription.isEmpty {
                    Text(milestone.milestoneDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Diagram Card

private struct DiagramCard: View {
    let diagram: MeetingDiagram
    @State private var contentHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(diagram.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            DiagramWebView(htmlContent: diagram.htmlContent, contentHeight: $contentHeight)
                .frame(height: contentHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }
}
