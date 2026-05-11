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
        !meeting.openQuestions.isEmpty
    }

    var body: some View {
        ScrollView {
            if !hasAnyContent && !isExtracting {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    heroSection

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
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isExtracting && meeting.oneLiner.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(langMgr.t("正在分析会议纪要...", "Analyzing meeting notes..."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if !meeting.oneLiner.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .padding(.top, 1)
                    Text(meeting.oneLiner)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.orange.opacity(0.5))
                        .frame(width: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                MetricChip(
                    icon: "checkmark.seal",
                    count: meeting.decisions.count,
                    label: langMgr.t("决策", "Decisions")
                )
                MetricChip(
                    icon: "checklist",
                    count: meeting.followUpTasks.count,
                    label: langMgr.t("待办", "Tasks")
                )
                MetricChip(
                    icon: "exclamationmark.triangle",
                    count: meeting.risks.count,
                    label: langMgr.t("风险", "Risks")
                )
                MetricChip(
                    icon: "questionmark.circle",
                    count: meeting.openQuestions.count,
                    label: langMgr.t("问题", "Questions")
                )
                Spacer()
            }
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
                    OpenQuestionRow(question: question, langMgr: langMgr)
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

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            langMgr.t("暂无摘要", "No Summary Yet"),
            systemImage: "sparkles",
            description: Text(
                meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? langMgr.t("生成 AI 纪要后自动提取结构化摘要", "Generate meeting notes to extract a structured summary")
                : langMgr.t("点击「重新提取」生成摘要", "Tap Re-extract to generate summary")
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Metric Chip

private struct MetricChip: View {
    let icon: String
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(count == 0 ? .tertiary : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.08), in: Capsule())
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
            // Kind label header
            Text(langMgr.t(kind.displayName, kind.englishDisplayName))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // Column header row
            HStack(spacing: 0) {
                Text(langMgr.t("任务", "Task"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(langMgr.t("截止时间", "Due Date"))
                    .frame(width: 110, alignment: .leading)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.06))

            Divider()

            // Task rows
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                HStack(alignment: .top, spacing: 0) {
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

                    dueDateView(task.dueDate)
                        .frame(width: 110, alignment: .leading)
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
