import SwiftUI

struct TemplateListView: View {
    @StateObject private var viewModel = TemplatesViewModel()
    @EnvironmentObject var langMgr: LanguageManager
    @Environment(\.dismiss) private var dismiss
    @State private var isCreatingNew = false

    var body: some View {
        List {
            ForEach(viewModel.templates) { template in
                HStack {
                    NavigationLink(value: template) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(template.title)
                                    .font(.headline)
                                if template.isDefault {
                                    Text(langMgr.t("默认", "Default"))
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                            if !template.promptPreview.isEmpty {
                                Text(template.promptPreview)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Text(langMgr.t("提示词模板", "Prompt template"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    Spacer()

                    if !template.isDefault {
                        Button(role: .destructive) {
                            viewModel.deleteTemplate(template)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    if !template.isDefault {
                        Button(role: .destructive) {
                            viewModel.deleteTemplate(template)
                        } label: {
                            Label(langMgr.t("删除模板", "Delete Template"), systemImage: "trash")
                        }
                    } else {
                        Text(langMgr.t("默认模板不可删除", "Cannot delete default template"))
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    viewModel.deleteTemplate(viewModel.templates[index])
                }
            }
        }
        .navigationTitle(langMgr.t("笔记模板", "Note Templates"))
        .navigationDestination(for: NoteTemplate.self) { template in
            TemplateEditView(template: template) { updatedTemplate in
                viewModel.saveTemplate(updatedTemplate)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreatingNew) {
            NavigationStack {
                TemplateEditView(template: viewModel.createNewTemplate(), showsCancelButton: true) { updatedTemplate in
                    viewModel.saveTemplate(updatedTemplate)
                    isCreatingNew = false
                }
            }
            .environmentObject(langMgr)
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView(langMgr.t("加载模板中...", "Loading templates..."))
            }
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
}

#Preview {
    TemplateListView()
        .environmentObject(LanguageManager.shared)
}
