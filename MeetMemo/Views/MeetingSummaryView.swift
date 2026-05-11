import SwiftUI

struct MeetingSummaryView: View {
    @ObservedObject var viewModel: MeetingViewModel
    @EnvironmentObject var langMgr: LanguageManager

    private var meeting: Meeting { viewModel.meeting }
    private var isExtracting: Bool { viewModel.isExtractingStructuredSummary }

    private var hasAnyContent: Bool {
        !meeting.oneLiner.isEmpty ||
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
                VStack(alignment: .leading, spacing: 20) {
                    heroSection

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
                Text(meeting.oneLiner)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Decisions Section

    private var decisionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummarySectionHeader(
                icon: "checkmark.seal",
                title: langMgr.t("关键决策", "Key Decisions"),
                count: meeting.decisions.count
            )
            ForEach(meeting.decisions) { decision in
                DecisionCard(decision: decision, langMgr: langMgr)
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
            ForEach(kindOrder, id: \.self) { kind in
                if let tasks = grouped[kind], !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(langMgr.t(kind.displayName, kind.englishDisplayName))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        ForEach(tasks) { task in
                            TaskSummaryRow(task: task, langMgr: langMgr)
                        }
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
            ForEach(meeting.openQuestions) { question in
                OpenQuestionCard(question: question, langMgr: langMgr)
            }
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

// MARK: - Shared Sub-views

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

private struct DecisionCard: View {
    let decision: MeetingDecision
    let langMgr: LanguageManager
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                confidenceBadge
                if !decision.owner.isEmpty {
                    Spacer()
                    Label(decision.owner, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(decision.title)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            if !decision.reason.isEmpty {
                Text(decision.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !decision.sourceExcerpt.isEmpty {
                DisclosureGroup(
                    isExpanded: $isExpanded,
                    content: {
                        Text("\u{201C}\(decision.sourceExcerpt)\u{201D}")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .italic()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    },
                    label: {
                        Text(langMgr.t("查看原文", "View Source"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var confidenceBadge: some View {
        let (label, color): (String, Color) = {
            switch decision.confidence {
            case "high":   return (langMgr.t("✓ 已确认", "✓ Confirmed"), .green)
            case "low":    return (langMgr.t("待确认", "Unconfirmed"), .orange)
            default:       return (langMgr.t("已确认", "Confirmed"), .blue)
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

private struct TaskSummaryRow: View {
    let task: MeetingFollowUpTask
    let langMgr: LanguageManager

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: task.kind.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let due = task.dueDate {
                    Text(due, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !task.detail.isEmpty {
                    Text(task.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if task.isSyncedToReminders {
                Image(systemName: "bell.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

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

private struct OpenQuestionCard: View {
    let question: MeetingOpenQuestion
    let langMgr: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
