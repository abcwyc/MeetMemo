import Foundation

struct MeetingHTMLExporter {

    static func generateHTML(for meeting: Meeting) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let meetingDate = dateFormatter.string(from: meeting.date)

        let exportFormatter = DateFormatter()
        exportFormatter.dateStyle = .short
        exportFormatter.timeStyle = .short
        let exportDate = exportFormatter.string(from: Date())

        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? "会议纪要" : title

        var bodySections = headerSection(
            title: displayTitle,
            meetingDate: meetingDate,
            exportDate: exportDate,
            meeting: meeting
        )

        if !meeting.discussions.isEmpty {
            bodySections += discussionsSection(meeting.discussions)
        }
        if !meeting.decisions.isEmpty {
            bodySections += decisionsSection(meeting.decisions)
        }
        if !meeting.followUpTasks.isEmpty {
            bodySections += tasksSection(meeting.followUpTasks)
        }
        if !meeting.risks.isEmpty {
            bodySections += risksSection(meeting.risks)
        }
        if !meeting.openQuestions.isEmpty {
            bodySections += questionsSection(meeting.openQuestions)
        }
        if !meeting.milestones.isEmpty {
            bodySections += milestonesSection(meeting.milestones)
        }
        let notes = meeting.generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            bodySections += notesSection(notes)
        }

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>\(displayTitle.esc)</title>
          <style>\(embeddedCSS)</style>
        </head>
        <body>
          <div class="container">
        \(bodySections)
          </div>
        </body>
        </html>
        """
    }

    // MARK: - Sections

    private static func headerSection(
        title: String,
        meetingDate: String,
        exportDate: String,
        meeting: Meeting
    ) -> String {
        var html = "<header>\n"
        html += "  <h1>\(title.esc)</h1>\n"
        html += "  <p class=\"meta\">\(meetingDate.esc) &nbsp;·&nbsp; 导出于 \(exportDate.esc)</p>\n"

        if !meeting.oneLiner.isEmpty {
            html += "  <p class=\"one-liner\">\(meeting.oneLiner.esc)</p>\n"
        }

        let dc = meeting.decisions.count
        let tc = meeting.followUpTasks.count
        let rc = meeting.risks.count
        let qc = meeting.openQuestions.count
        if dc + tc + rc + qc > 0 {
            html += "  <div class=\"metrics\">\n"
            if dc > 0 { html += "    <span class=\"chip\">\(dc) 项决策</span>\n" }
            if tc > 0 { html += "    <span class=\"chip\">\(tc) 项待办</span>\n" }
            if rc > 0 { html += "    <span class=\"chip\">\(rc) 项风险</span>\n" }
            if qc > 0 { html += "    <span class=\"chip\">\(qc) 个问题</span>\n" }
            html += "  </div>\n"
        }
        html += "</header>\n\n"
        return html
    }

    private static func discussionsSection(_ discussions: [MeetingDiscussion]) -> String {
        var html = "<section>\n"
        html += "  <h2>议题讨论</h2>\n"
        for (i, d) in discussions.enumerated() {
            html += "  <div class=\"discussion-card\">\n"
            html += "    <div class=\"discussion-index\">\(i + 1)</div>\n"
            html += "    <div class=\"discussion-body\">\n"
            html += "      <p class=\"discussion-title\">\(d.title.esc)</p>\n"
            if !d.summary.isEmpty {
                html += "      <p class=\"discussion-summary\">\(d.summary.esc)</p>\n"
            }
            if d.hasConsensus && !d.consensus.isEmpty {
                html += "      <div class=\"consensus-block\">\n"
                html += "        <span class=\"consensus-label\">达成共识：</span>\(d.consensus.esc)\n"
                html += "      </div>\n"
            }
            html += "    </div>\n"
            html += "  </div>\n"
        }
        html += "</section>\n\n"
        return html
    }

    private static func decisionsSection(_ decisions: [MeetingDecision]) -> String {
        var html = "<section>\n"
        html += "  <h2>关键决策</h2>\n"
        html += "  <div class=\"decisions-grid\">\n"
        for d in decisions {
            let (_, badgeText) = confidenceStyle(d.confidence)
            let isApproved = d.confidence == "high" || d.confidence == "medium"
            let badgeColor = d.confidence == "low" ? "#d97706" : (d.confidence == "high" ? "#16a34a" : "#2563eb")
            html += "    <div class=\"decision-grid-card\">\n"
            if !d.owner.isEmpty {
                html += "      <p class=\"dg-category\">\(d.owner.esc)</p>\n"
            }
            html += "      <p class=\"dg-title\">\(d.title.esc)</p>\n"
            html += "      <p class=\"dg-badge\" style=\"color:\(badgeColor)\">\(isApproved ? "✓ " : "")\(badgeText)</p>\n"
            html += "    </div>\n"
        }
        html += "  </div>\n"
        html += "</section>\n\n"
        return html
    }

    private static func tasksSection(_ tasks: [MeetingFollowUpTask]) -> String {
        let kindOrder: [FollowUpTaskKind] = [.actionItem, .confirmation, .followUp, .manual]
        let grouped = Dictionary(grouping: tasks, by: \.kind)
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none

        var html = "<section>\n"
        html += "  <h2>待办事项</h2>\n"
        for kind in kindOrder {
            guard let items = grouped[kind], !items.isEmpty else { continue }
            html += "  <h3>\(kind.displayName.esc)</h3>\n"
            html += "  <table class=\"task-table\">\n"
            html += "    <thead><tr><th>任务</th><th>负责人</th><th>截止时间</th></tr></thead>\n"
            html += "    <tbody>\n"
            for task in items {
                let ownerText = task.owner.isEmpty ? "—" : task.owner.esc
                let dueText = task.dueDate.map { df.string(from: $0).esc } ?? "—"
                html += "      <tr>\n"
                html += "        <td>\(task.title.esc)"
                if !task.detail.isEmpty {
                    html += "<br><span class=\"task-detail\">\(task.detail.esc)</span>"
                }
                html += "</td>\n"
                if task.owner.isEmpty {
                    html += "        <td class=\"task-owner-empty\">—</td>\n"
                } else {
                    html += "        <td><span class=\"task-owner\">\(ownerText)</span></td>\n"
                }
                html += "        <td class=\"task-due\">\(dueText)</td>\n"
                html += "      </tr>\n"
            }
            html += "    </tbody>\n"
            html += "  </table>\n"
        }
        html += "</section>\n\n"
        return html
    }

    private static func risksSection(_ risks: [MeetingRisk]) -> String {
        var html = "<section>\n"
        html += "  <h2>风险事项</h2>\n"
        for r in risks {
            let (severityClass, severityText) = severityStyle(r.severity)
            html += "  <div class=\"card risk-card\">\n"
            html += "    <div class=\"risk-bar \(severityClass)\"></div>\n"
            html += "    <div class=\"risk-body\">\n"
            html += "      <p class=\"card-title\">\(r.title.esc) <span class=\"badge \(severityClass)\">\(severityText)</span></p>\n"
            if !r.mitigation.isEmpty {
                html += "      <p class=\"card-meta\">应对：\(r.mitigation.esc)</p>\n"
            }
            if !r.owner.isEmpty {
                html += "      <p class=\"card-meta\">负责：\(r.owner.esc)</p>\n"
            }
            html += "    </div>\n"
            html += "  </div>\n"
        }
        html += "</section>\n\n"
        return html
    }

    private static func questionsSection(_ questions: [MeetingOpenQuestion]) -> String {
        var html = "<section>\n"
        html += "  <h2>待确认问题</h2>\n"
        html += "  <div class=\"question-list\">\n"
        for q in questions {
            html += "    <div class=\"question-row\">\n"
            html += "      <span class=\"question-icon\">○</span>\n"
            html += "      <div class=\"question-body\">\n"
            html += "        <p class=\"question-text\">\(q.question.esc)</p>\n"
            if !q.owner.isEmpty || !q.nextStep.isEmpty {
                html += "        <p class=\"question-meta\">"
                if !q.owner.isEmpty { html += "负责：\(q.owner.esc)" }
                if !q.owner.isEmpty && !q.nextStep.isEmpty { html += " &nbsp;·&nbsp; " }
                if !q.nextStep.isEmpty { html += "→ \(q.nextStep.esc)" }
                html += "</p>\n"
            }
            html += "      </div>\n"
            html += "    </div>\n"
        }
        html += "  </div>\n"
        html += "</section>\n\n"
        return html
    }

    private static func milestonesSection(_ milestones: [MeetingMilestone]) -> String {
        var html = "<section>\n"
        html += "  <h2>里程碑</h2>\n"
        html += "  <div class=\"milestone-list\">\n"
        for m in milestones {
            html += "    <div class=\"milestone-row\">\n"
            html += "      <span class=\"milestone-dot\"></span>\n"
            html += "      <div class=\"milestone-body\">\n"
            html += "        <div class=\"milestone-header\">\n"
            html += "          <span class=\"milestone-title\">\(m.title.esc)</span>\n"
            if !m.targetDate.isEmpty {
                html += "          <span class=\"milestone-date\">\(m.targetDate.esc)</span>\n"
            }
            html += "        </div>\n"
            if !m.milestoneDescription.isEmpty {
                html += "        <p class=\"milestone-desc\">\(m.milestoneDescription.esc)</p>\n"
            }
            html += "      </div>\n"
            html += "    </div>\n"
        }
        html += "  </div>\n"
        html += "</section>\n\n"
        return html
    }

    private static func notesSection(_ markdown: String) -> String {
        var html = "<section>\n"
        html += "  <h2>完整纪要</h2>\n"
        html += "  <div class=\"notes-body\">\n"
        html += markdownToHTML(markdown)
        html += "  </div>\n"
        html += "</section>\n"
        return html
    }

    // MARK: - Markdown → HTML

    private static func markdownToHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out = ""
        var i = 0
        var inUL = false
        var inOL = false

        func closeList() {
            if inUL { out += "</ul>\n"; inUL = false }
            if inOL { out += "</ol>\n"; inOL = false }
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Headings
            if trimmed.hasPrefix("#### ") {
                closeList()
                out += "<h4>\(inline(String(trimmed.dropFirst(5))))</h4>\n"
            } else if trimmed.hasPrefix("### ") {
                closeList()
                out += "<h3>\(inline(String(trimmed.dropFirst(4))))</h3>\n"
            } else if trimmed.hasPrefix("## ") {
                closeList()
                out += "<h2>\(inline(String(trimmed.dropFirst(3))))</h2>\n"
            } else if trimmed.hasPrefix("# ") {
                closeList()
                out += "<h1>\(inline(String(trimmed.dropFirst(2))))</h1>\n"
            }
            // Table
            else if trimmed.hasPrefix("|") {
                closeList()
                var rows: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[i])
                    i += 1
                }
                out += tableToHTML(rows)
                continue
            }
            // Unordered list
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if inOL { out += "</ol>\n"; inOL = false }
                if !inUL { out += "<ul>\n"; inUL = true }
                let content = String(trimmed.dropFirst(2))
                out += "<li>\(inline(content))</li>\n"
            }
            // Ordered list
            else if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil,
                    let spaceRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                if inUL { out += "</ul>\n"; inUL = false }
                if !inOL { out += "<ol>\n"; inOL = true }
                let content = String(trimmed[spaceRange.upperBound...])
                out += "<li>\(inline(content))</li>\n"
            }
            // Empty line
            else if trimmed.isEmpty {
                closeList()
            }
            // Paragraph
            else {
                closeList()
                out += "<p>\(inline(trimmed))</p>\n"
            }

            i += 1
        }
        if inUL { out += "</ul>\n" }
        if inOL { out += "</ol>\n" }
        return out
    }

    private static func tableToHTML(_ rows: [String]) -> String {
        guard !rows.isEmpty else { return "" }
        var html = "<table>\n"
        let cells = parseCells(rows[0])
        html += "<thead><tr>" + cells.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>\n"
        html += "<tbody>\n"
        for row in rows.dropFirst() {
            let t = row.trimmingCharacters(in: .whitespaces)
            // Skip separator rows like |---|---|
            if t.replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: " ", with: "").isEmpty {
                continue
            }
            let c = parseCells(row)
            html += "<tr>" + c.map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
        }
        html += "</tbody></table>\n"
        return html
    }

    private static func parseCells(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Apply inline Markdown (bold, italic) to HTML-escaped text.
    private static func inline(_ text: String) -> String {
        var s = text.esc
        // **bold**
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        // *italic* (not preceded/followed by another *)
        s = s.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, with: "<em>$1</em>", options: .regularExpression)
        // ~~strikethrough~~
        s = s.replacingOccurrences(of: #"~~(.+?)~~"#, with: "<del>$1</del>", options: .regularExpression)
        return s
    }

    // MARK: - Style helpers

    private static func confidenceStyle(_ confidence: String) -> (cssClass: String, label: String) {
        switch confidence {
        case "high":   return ("badge-green", "✓ 已确认")
        case "low":    return ("badge-orange", "待确认")
        default:       return ("badge-blue", "已确认")
        }
    }

    private static func severityStyle(_ severity: String) -> (cssClass: String, label: String) {
        switch severity {
        case "high":   return ("sev-high", "高")
        case "low":    return ("sev-low", "低")
        default:       return ("sev-medium", "中")
        }
    }

    // MARK: - CSS

    private static let embeddedCSS = """

      *, *::before, *::after { box-sizing: border-box; }
      body {
        font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        font-size: 16px;
        line-height: 1.65;
        color: #1a1a1a;
        background: #ffffff;
        margin: 0;
        padding: 24px 16px;
      }
      .container { max-width: 860px; margin: 0 auto; }

      /* Header */
      header { margin-bottom: 32px; padding-bottom: 20px; border-bottom: 1px solid #e5e5e5; }
      h1 { font-size: 1.75rem; font-weight: 700; margin: 0 0 6px; color: #111; }
      .meta { font-size: 0.85rem; color: #888; margin: 0 0 12px; }
      .one-liner { font-size: 1.05rem; font-style: italic; color: #444; margin: 12px 0; }
      .metrics { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
      .chip {
        font-size: 0.78rem; font-weight: 500; color: #555;
        background: #f0f0f0; border-radius: 100px;
        padding: 3px 10px;
      }

      /* Sections */
      section { margin-bottom: 32px; }
      h2 { font-size: 1.1rem; font-weight: 600; color: #111; margin: 0 0 12px; border-bottom: 1px solid #ebebeb; padding-bottom: 6px; }
      h3 { font-size: 0.9rem; font-weight: 600; color: #666; text-transform: uppercase; letter-spacing: .04em; margin: 14px 0 6px; }
      h4 { font-size: 0.95rem; font-weight: 600; margin: 10px 0 4px; }

      /* Discussions */
      .discussion-card {
        display: flex; gap: 12px; align-items: flex-start;
        background: #fafafa; border: 1px solid #e8e8e8;
        border-radius: 8px; padding: 12px 14px; margin-bottom: 10px;
      }
      .discussion-index {
        flex-shrink: 0; width: 24px; height: 24px;
        background: rgba(59,130,246,0.12); border-radius: 50%;
        display: flex; align-items: center; justify-content: center;
        font-size: 0.75rem; font-weight: 600; color: #2563eb;
      }
      .discussion-body { flex: 1; }
      .discussion-title { font-size: 0.95rem; font-weight: 600; color: #1a1a1a; margin: 0 0 4px; }
      .discussion-summary { font-size: 0.85rem; color: #666; margin: 0 0 8px; }
      .consensus-block {
        font-size: 0.85rem; color: #1a1a1a;
        background: rgba(34,197,94,0.07);
        border-left: 3px solid rgba(34,197,94,0.5);
        border-radius: 0 6px 6px 0;
        padding: 7px 10px; margin-top: 6px;
      }
      .consensus-label { font-weight: 600; color: #166534; }

      /* Decisions Grid */
      .decisions-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
      .decision-grid-card {
        background: #f8f8f8; border: 1px solid #e5e5e5; border-radius: 8px;
        padding: 12px; display: flex; flex-direction: column; gap: 6px; min-height: 80px;
      }
      .dg-category { font-size: 0.72rem; color: #aaa; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .dg-title { font-size: 0.92rem; font-weight: 600; color: #1a1a1a; margin: 0; flex: 1; }
      .dg-badge { font-size: 0.72rem; font-weight: 600; margin: 0; }
      @media (max-width: 600px) { .decisions-grid { grid-template-columns: repeat(2, 1fr); } }

      /* Task Table */
      .task-table { width: 100%; border-collapse: collapse; font-size: 0.88rem; margin-bottom: 4px; }
      .task-table th { text-align: left; font-size: 0.75rem; color: #888; font-weight: 600; padding: 6px 10px; background: #f4f4f4; }
      .task-table td { padding: 8px 10px; border-top: 1px solid #ebebeb; vertical-align: top; color: #1a1a1a; }
      .task-detail { font-size: 0.78rem; color: #aaa; }
      .task-owner { font-size: 0.78rem; font-weight: 500; color: #2563eb; background: rgba(37,99,235,0.1); border-radius: 100px; padding: 2px 7px; }
      .task-owner-empty { color: #ccc; }
      .task-due { font-size: 0.82rem; color: #666; white-space: nowrap; }

      /* Questions */
      .question-list { background: #fafafa; border: 1px solid #e8e8e8; border-radius: 8px; overflow: hidden; }
      .question-row { display: flex; gap: 10px; padding: 10px 14px; border-bottom: 1px solid #ebebeb; }
      .question-row:last-child { border-bottom: none; }
      .question-icon { color: #d97706; font-size: 1rem; line-height: 1.6; flex-shrink: 0; }
      .question-body { flex: 1; }
      .question-text { font-size: 0.92rem; color: #1a1a1a; margin: 0 0 3px; }
      .question-meta { font-size: 0.8rem; color: #888; margin: 0; }

      /* Milestones */
      .milestone-list { border-left: 2px solid #e5e5e5; margin-left: 8px; padding-left: 16px; }
      .milestone-row { display: flex; gap: 0; align-items: flex-start; position: relative; margin-bottom: 14px; }
      .milestone-dot {
        position: absolute; left: -22px; top: 4px;
        width: 10px; height: 10px; border-radius: 50%;
        background: #007aff; border: 2px solid #fff; box-shadow: 0 0 0 1px #e5e5e5;
      }
      .milestone-body { flex: 1; }
      .milestone-header { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
      .milestone-title { font-size: 0.95rem; font-weight: 600; color: #1a1a1a; }
      .milestone-date { font-size: 0.82rem; font-weight: 500; color: #888; white-space: nowrap; }
      .milestone-desc { font-size: 0.85rem; color: #666; margin: 3px 0 0; }

      /* Cards */
      .card {
        background: #f8f8f8;
        border: 1px solid #e5e5e5;
        border-radius: 8px;
        padding: 12px 14px;
        margin-bottom: 8px;
      }
      .card-title { font-size: 0.95rem; font-weight: 500; margin: 6px 0 4px; color: #1a1a1a; }
      .card-meta { font-size: 0.82rem; color: #888; margin: 2px 0; }
      .card-detail { font-size: 0.85rem; color: #555; margin: 4px 0; }
      .synced { color: #3a9a5c; }

      /* Badges */
      .badge {
        display: inline-block; font-size: 0.72rem; font-weight: 600;
        border-radius: 4px; padding: 2px 7px; margin-bottom: 4px;
      }
      .badge-green  { background: rgba(40,167,69,.12); color: #1e7e34; }
      .badge-blue   { background: rgba(13,110,253,.1);  color: #0a5299; }
      .badge-orange { background: rgba(253,126,20,.12); color: #b85c00; }
      .sev-high   { background: rgba(220,53,69,.1);  color: #b02a37; }
      .sev-medium { background: rgba(253,126,20,.1); color: #b85c00; }
      .sev-low    { background: rgba(40,167,69,.1);  color: #1e7e34; }

      /* Risk card */
      .risk-card { display: flex; gap: 10px; align-items: stretch; }
      .risk-bar { width: 4px; border-radius: 2px; flex-shrink: 0; min-height: 40px; }
      .risk-bar.sev-high   { background: #dc3545; }
      .risk-bar.sev-medium { background: #fd7e14; }
      .risk-bar.sev-low    { background: #28a745; }
      .risk-body { flex: 1; }

      /* Details/summary */
      details { margin-top: 6px; }
      summary { font-size: 0.82rem; color: #888; cursor: pointer; }
      blockquote {
        font-size: 0.85rem; font-style: italic; color: #666;
        border-left: 3px solid #ddd; margin: 6px 0 0 0; padding: 4px 10px;
      }

      /* Notes */
      .notes-body p  { margin: 0 0 10px; }
      .notes-body h1 { font-size: 1.3rem; margin: 20px 0 8px; }
      .notes-body h2 { font-size: 1.1rem; margin: 16px 0 6px; border: none; }
      .notes-body h3 { font-size: 0.95rem; margin: 12px 0 4px; text-transform: none; letter-spacing: 0; }
      .notes-body h4 { font-size: 0.9rem; }
      .notes-body ul, .notes-body ol { padding-left: 1.4em; margin: 0 0 10px; }
      .notes-body li { margin-bottom: 3px; }
      .notes-body table { border-collapse: collapse; width: 100%; margin-bottom: 14px; font-size: 0.88rem; }
      .notes-body th, .notes-body td { border: 1px solid #ddd; padding: 6px 10px; text-align: left; }
      .notes-body th { background: #f0f0f0; font-weight: 600; }
      .notes-body tr:nth-child(even) td { background: #fafafa; }

      /* Dark mode */
      @media (prefers-color-scheme: dark) {
        body { background: #1c1c1e; color: #e5e5e7; }
        h1 { color: #f5f5f7; }
        .meta, summary, .card-meta { color: #8e8e93; }
        .one-liner { color: #adadb8; }
        .chip { background: #2c2c2e; color: #adadb8; }
        header { border-bottom-color: #3a3a3c; }
        h2 { color: #f5f5f7; border-bottom-color: #3a3a3c; }
        .card { background: #2c2c2e; border-color: #3a3a3c; }
        .card-title { color: #e5e5e7; }
        .card-detail { color: #adadb8; }
        blockquote { border-left-color: #48484a; color: #8e8e93; }
        details summary { color: #8e8e93; }
        .notes-body th { background: #2c2c2e; }
        .notes-body th, .notes-body td { border-color: #3a3a3c; }
        .notes-body tr:nth-child(even) td { background: #232325; }
        .decision-grid-card { background: #2c2c2e; border-color: #3a3a3c; }
        .dg-title { color: #e5e5e7; }
        .dg-category { color: #636366; }
        .task-table th { background: #2c2c2e; color: #636366; }
        .task-table td { color: #e5e5e7; border-top-color: #3a3a3c; }
        .task-detail { color: #636366; }
        .task-due { color: #8e8e93; }
        .question-list { background: #242426; border-color: #3a3a3c; }
        .question-row { border-bottom-color: #3a3a3c; }
        .question-text { color: #e5e5e7; }
        .question-meta { color: #8e8e93; }
        .milestone-list { border-left-color: #3a3a3c; }
        .milestone-dot { background: #0a84ff; border-color: #1c1c1e; box-shadow: 0 0 0 1px #3a3a3c; }
        .milestone-title { color: #e5e5e7; }
        .milestone-date { color: #8e8e93; }
        .milestone-desc { color: #8e8e93; }
        .discussion-card { background: #242426; border-color: #3a3a3c; }
        .discussion-title { color: #e5e5e7; }
        .discussion-summary { color: #8e8e93; }
        .consensus-block { background: rgba(34,197,94,0.09); border-left-color: rgba(34,197,94,0.4); color: #e5e5e7; }
        .consensus-label { color: #4ade80; }
      }

    """
}

// MARK: - String HTML escape helper

private extension String {
    var esc: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
