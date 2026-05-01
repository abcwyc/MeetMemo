import Foundation
import SwiftUI

@MainActor
class TemplatesViewModel: ObservableObject {
    @Published var templates: [NoteTemplate] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    init() {
        loadTemplates()
    }
    
    func loadTemplates() {
        isLoading = true
        templates = LocalStorageManager.shared.loadTemplates()
        isLoading = false
    }
    
    func saveTemplate(_ template: NoteTemplate) {
        if LocalStorageManager.shared.saveTemplate(template) {
            loadTemplates()
        } else {
            errorMessage = "Failed to save template"
        }
    }
    
    func deleteTemplate(_ template: NoteTemplate) {
        if LocalStorageManager.shared.deleteTemplate(template) {
            loadTemplates()
        } else {
            errorMessage = "Cannot delete default templates"
        }
    }
    
    func createNewTemplate() -> NoteTemplate {
        return NoteTemplate(
            title: "新模板",
            context: "请描述这个会议类型的背景、需要关注的信息，以及希望生成的纪要结构。"
        )
    }
} 
