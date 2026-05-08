import SwiftUI

struct TemplateEditView: View {
    @State private var template: NoteTemplate
    @EnvironmentObject var langMgr: LanguageManager
    let onSave: (NoteTemplate) -> Void
    let showsCancelButton: Bool
    @Environment(\.dismiss) private var dismiss

    init(template: NoteTemplate, showsCancelButton: Bool = false, onSave: @escaping (NoteTemplate) -> Void) {
        self._template = State(initialValue: template)
        self.showsCancelButton = showsCancelButton
        self.onSave = onSave
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                // Template Name
                VStack(alignment: .leading, spacing: 8) {
                    Text(langMgr.t("模板名称", "Template Name"))
                        .font(.headline)
                        .foregroundColor(.primary)

                    TextField(langMgr.t("模板名称", "Template Name"), text: $template.title)
                        .textFieldStyle(.roundedBorder)
                }

                // Template prompt
                VStack(alignment: .leading, spacing: 8) {
                    Text(langMgr.t("模板提示词", "Template Prompt"))
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(langMgr.t("描述会议类型、输出结构和关注重点。可以直接写章节要求。", "Describe the meeting type, output structure, and focus areas. You can write section requirements directly."))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $template.context)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                        .frame(minHeight: 320)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }

                // Save button
                HStack(spacing: 20) {
                    Spacer()

                    if showsCancelButton {
                        Button {
                            dismiss()
                        } label: {
                            Text(langMgr.t("取消", "Cancel"))
                                .font(.headline)
                                .frame(width: 140)
                                .padding(.vertical, 12)
                                .background(Color.secondary.opacity(0.14))
                                .foregroundColor(.primary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onSave(template)
                        dismiss()
                    } label: {
                        Text(langMgr.t("保存模板", "Save Template"))
                            .font(.headline)
                            .frame(width: 180)
                            .padding(.vertical, 12)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        template.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                .padding(.top)
            }
            .padding(24)
        }
        .navigationTitle(langMgr.t("编辑模板", "Edit Template"))
    }
}

#Preview {
    NavigationStack {
        TemplateEditView(
            template: NoteTemplate(
                title: "示例模板",
                context: "这是一段示例提示词。请按“摘要、重点、行动项”的结构生成会议纪要。"
            )
        ) { _ in }
    }
    .environmentObject(LanguageManager.shared)
}
