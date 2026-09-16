import SwiftUI

/// The real, interactive table view `MarkdownLiveEditorView` floats over a
/// table block's hidden source text — this is what "editing inside the
/// rendered view" means for tables, in place of raw pipe-table syntax.
/// Double-click a cell to edit it; committing (Return, or clicking away)
/// calls `onCommit` with the full edited grid so the caller can
/// re-serialize it back into the markdown source via
/// `MarkdownTableSerializer`.
struct MarkdownLiveTableOverlayView: View {
    let table: MarkdownDocumentModel.Table
    let onCommit: (_ headers: [String], _ rows: [[String]]) -> Void

    @State private var headers: [String]
    @State private var rows: [[String]]
    @State private var editingCell: CellLocation?
    @FocusState private var focusedCell: CellLocation?

    private struct CellLocation: Hashable {
        /// -1 for the header row, otherwise an index into `rows`.
        let row: Int
        let column: Int
    }

    init(table: MarkdownDocumentModel.Table, onCommit: @escaping (_ headers: [String], _ rows: [[String]]) -> Void) {
        self.table = table
        self.onCommit = onCommit
        _headers = State(initialValue: table.headers)
        _rows = State(initialValue: table.rows)
    }

    private var columnWidth: CGFloat {
        switch table.columnCount {
        case 0...3: return 220
        case 4: return 180
        default: return 150
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                rowView(cells: headers, rowIndex: -1, isHeader: true)
                ForEach(rows.indices, id: \.self) { index in
                    rowView(cells: rows[index], rowIndex: index, isHeader: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.035))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: focusedCell) { oldValue, newValue in
            // Commit on focus loss (clicking elsewhere), not just on Return.
            if let oldValue, oldValue != newValue, editingCell == oldValue {
                commitEditing()
            }
        }
        .onChange(of: table) { _, newTable in
            // The overlay is only recreated when table *content* changes
            // (see MarkdownLiveEditorView's diffing); a pure reposition
            // reuses this instance, so keep local state in sync defensively.
            headers = newTable.headers
            rows = newTable.rows
        }
    }

    @ViewBuilder
    private func rowView(cells: [String], rowIndex: Int, isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { column in
                let location = CellLocation(row: rowIndex, column: column)
                cellView(text: cellText(cells, column), location: location, isHeader: isHeader)
                    .frame(width: columnWidth, alignment: .topLeading)
                    .background(isHeader ? Color.secondary.opacity(0.08) : Color.clear)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: column == table.columnCount - 1 ? 0 : 1)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(isHeader ? 0.24 : 0.14))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func cellView(text: String, location: CellLocation, isHeader: Bool) -> some View {
        Group {
            if editingCell == location {
                TextField("", text: bindingForCell(location))
                    .textFieldStyle(.plain)
                    .font(isHeader ? .system(.body, weight: .semibold) : .body)
                    .focused($focusedCell, equals: location)
                    .onSubmit { commitEditing() }
            } else {
                Text(text)
                    .font(isHeader ? .system(.body, weight: .semibold) : .body)
                    .foregroundColor(isHeader ? .primary : .secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        editingCell = location
                        focusedCell = location
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func cellText(_ cells: [String], _ column: Int) -> String {
        cells.indices.contains(column) ? cells[column] : ""
    }

    private func bindingForCell(_ location: CellLocation) -> Binding<String> {
        Binding(
            get: {
                if location.row == -1 {
                    return headers.indices.contains(location.column) ? headers[location.column] : ""
                }
                guard rows.indices.contains(location.row) else { return "" }
                return rows[location.row].indices.contains(location.column) ? rows[location.row][location.column] : ""
            },
            set: { newValue in
                if location.row == -1 {
                    while headers.count <= location.column { headers.append("") }
                    headers[location.column] = newValue
                } else if rows.indices.contains(location.row) {
                    while rows[location.row].count <= location.column { rows[location.row].append("") }
                    rows[location.row][location.column] = newValue
                }
            }
        )
    }

    private func commitEditing() {
        editingCell = nil
        onCommit(headers, rows)
    }
}
