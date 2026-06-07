import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum VoiceInputInsertResult {
    /// 已确认插入：应用内焦点框写入，或辅助功能 API 写入成功。
    case inserted
    /// 已通过剪贴板发送 ⌘V，但无法确认是否真的落入可编辑区（尽力而为）。
    case pastedBestEffort
    /// 插入失败。
    case failed
}

@MainActor
final class VoiceInputTextInserter {
    static let shared = VoiceInputTextInserter()

    private init() {}

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var accessibilityTrustDiagnostic: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundlePath
        return "Bundle ID: \(bundleIdentifier)\nPath: \(bundlePath)"
    }

    func requestAccessibilityTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func insert(_ text: String) async -> VoiceInputInsertResult {
        guard !text.isEmpty else { return .failed }

        if insertIntoMeetMemoFocusedText(text) {
            return .inserted
        }

        if isAccessibilityTrusted, insertWithAccessibility(text) {
            return .inserted
        }

        // 剪贴板路径无法确认是否成功粘贴，只能作为「尽力而为」返回，避免误报成功。
        return await pasteWithClipboardFallback(text) ? .pastedBestEffort : .failed
    }

    private func insertIntoMeetMemoFocusedText(_ text: String) -> Bool {
        guard NSApp.isActive,
              let responder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        if let textView = responder as? NSTextView {
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        }

        if let textField = responder as? NSTextField,
           let editor = textField.currentEditor() {
            editor.replaceCharacters(in: editor.selectedRange, with: text)
            return true
        }

        return false
    }

    private func insertWithAccessibility(_ text: String) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedElement = focusedValue else {
            return false
        }

        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return false
        }
        // AXUIElement is a CoreFoundation type; the type ID check keeps this bridge bounded.
        let element = unsafeBitCast(focusedElement, to: AXUIElement.self)
        if insertViaSelectedText(text, into: element) {
            return true
        }
        return false
    }

    private func insertViaSelectedText(_ text: String, into element: AXUIElement) -> Bool {
        let selectedTextResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return selectedTextResult == .success
    }

    private func pasteWithClipboardFallback(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []

        pasteboard.clearContents()
        let didSetString = pasteboard.setString(text, forType: .string)
        guard didSetString else {
            if !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            }
            return false
        }
        let ownChangeCount = pasteboard.changeCount
        sendPasteCommand()

        try? await Task.sleep(for: .milliseconds(350))
        // 仅当这段时间内没有其他来源写入剪贴板时才恢复原内容，
        // 否则会覆盖用户期间新复制的内容。
        guard pasteboard.changeCount == ownChangeCount else {
            return true
        }
        pasteboard.clearContents()
        if !previousItems.isEmpty {
            pasteboard.writeObjects(previousItems)
        }
        return true
    }

    private func sendPasteCommand() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
