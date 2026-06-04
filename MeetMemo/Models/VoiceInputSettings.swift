import Carbon.HIToolbox
import Foundation

enum VoiceInputTriggerMode: String, CaseIterable, Codable, Identifiable {
    case singlePress
    case doublePress
    case pressAndHold
    case keyCombination

    var id: Self { self }
}

enum VoiceInputTriggerKey: String, CaseIterable, Identifiable {
    case rightCommand
    case leftCommand
    case function
    case rightOption
    case leftOption

    var id: Self { self }

    var shortcut: VoiceInputShortcut {
        switch self {
        case .rightCommand:
            return VoiceInputShortcut(
                keyCode: UInt16(kVK_RightCommand),
                modifierMask: UInt64(CGEventFlags.maskCommand.rawValue),
                usesFunctionKey: false
            )
        case .leftCommand:
            return VoiceInputShortcut(
                keyCode: UInt16(kVK_Command),
                modifierMask: UInt64(CGEventFlags.maskCommand.rawValue),
                usesFunctionKey: false
            )
        case .function:
            return VoiceInputShortcut(
                keyCode: nil,
                modifierMask: UInt64(CGEventFlags.maskSecondaryFn.rawValue),
                usesFunctionKey: true
            )
        case .rightOption:
            return VoiceInputShortcut(
                keyCode: UInt16(kVK_RightOption),
                modifierMask: UInt64(CGEventFlags.maskAlternate.rawValue),
                usesFunctionKey: false
            )
        case .leftOption:
            return VoiceInputShortcut(
                keyCode: UInt16(kVK_Option),
                modifierMask: UInt64(CGEventFlags.maskAlternate.rawValue),
                usesFunctionKey: false
            )
        }
    }

    var displayName: String {
        switch self {
        case .rightCommand:
            return "右 Command"
        case .leftCommand:
            return "左 Command"
        case .function:
            return "fn"
        case .rightOption:
            return "右 Option"
        case .leftOption:
            return "左 Option"
        }
    }

    static func resolve(from shortcut: VoiceInputShortcut) -> VoiceInputTriggerKey {
        VoiceInputTriggerKey.allCases.first { $0.shortcut == shortcut } ?? .rightCommand
    }
}

struct VoiceInputShortcut: Codable, Hashable {
    var keyCode: UInt16?
    var modifierMask: UInt64
    var usesFunctionKey: Bool

    static let defaultShortcut = VoiceInputShortcut(
        keyCode: UInt16(kVK_RightCommand),
        modifierMask: UInt64(CGEventFlags.maskCommand.rawValue),
        usesFunctionKey: false
    )

    var isEmpty: Bool {
        keyCode == nil && modifierMask == 0 && !usesFunctionKey
    }

    var displayName: String {
        if let keyCode, Self.isModifierKey(keyCode) {
            return Self.keyName(for: keyCode)
        }

        var parts: [String] = []
        let flags = CGEventFlags(rawValue: modifierMask)
        if flags.contains(.maskCommand) { parts.append("⌘") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if usesFunctionKey { parts.append("fn") }
        if let keyCode {
            parts.append(Self.keyName(for: keyCode))
        }
        return parts.isEmpty ? "未设置" : parts.joined(separator: parts.count > 1 ? " " : "")
    }

    func matches(keyCode eventKeyCode: UInt16?, flags eventFlags: CGEventFlags) -> Bool {
        let normalizedFlags = Self.normalizedFlags(eventFlags)
        if usesFunctionKey && !normalizedFlags.contains(.maskSecondaryFn) {
            return false
        }
        if !usesFunctionKey && normalizedFlags.contains(.maskSecondaryFn) && keyCode == nil {
            return false
        }

        let expectedFlags = CGEventFlags(rawValue: modifierMask)
        let expectedNormalized = Self.normalizedFlags(expectedFlags)
        guard normalizedFlags.intersection(Self.relevantModifierFlags) == expectedNormalized.intersection(Self.relevantModifierFlags) else {
            return false
        }

        if let keyCode {
            return eventKeyCode == keyCode
        }
        return eventKeyCode == nil
    }

    func validationMessage(mode: VoiceInputTriggerMode, using langMgr: LanguageManager) -> String? {
        if isEmpty {
            return langMgr.t("请选择一个快捷键。", "Choose a shortcut.")
        }

        if mode == .singlePress, let keyCode, modifierMask == 0, !usesFunctionKey, Self.isPrintableKey(keyCode) {
            return langMgr.t(
                "单个普通字符会影响日常输入，请改用 fn、双击或组合键。",
                "A single printable key would interfere with typing. Use fn, double press, or a key combination."
            )
        }

        if mode == .keyCombination && !hasNonFunctionModifier {
            return langMgr.t(
                "组合键至少需要包含 Command、Option、Control 或 Shift。",
                "A key combination must include Command, Option, Control, or Shift."
            )
        }

        if Self.reservedShortcuts.contains(self) {
            return langMgr.t("该快捷键与常见系统或应用快捷键冲突。", "This shortcut conflicts with a common system or app shortcut.")
        }

        return nil
    }

    private var hasNonFunctionModifier: Bool {
        let flags = CGEventFlags(rawValue: modifierMask)
        return flags.contains(.maskCommand)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskControl)
            || flags.contains(.maskShift)
    }

    static let relevantModifierFlags: CGEventFlags = [
        .maskCommand,
        .maskAlternate,
        .maskControl,
        .maskShift,
        .maskSecondaryFn
    ]

    static func normalizedFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(relevantModifierFlags)
    }

    static func fromEvent(keyCode: UInt16?, flags: CGEventFlags) -> VoiceInputShortcut {
        let normalized = normalizedFlags(flags)
        return VoiceInputShortcut(
            keyCode: keyCode,
            modifierMask: UInt64(normalized.rawValue),
            usesFunctionKey: normalized.contains(.maskSecondaryFn)
        )
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Command: return "左 Command"
        case kVK_RightCommand: return "右 Command"
        case kVK_Option: return "左 Option"
        case kVK_RightOption: return "右 Option"
        case kVK_Control: return "左 Control"
        case kVK_RightControl: return "右 Control"
        case kVK_Shift: return "左 Shift"
        case kVK_RightShift: return "右 Shift"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return "Key \(keyCode)"
        }
    }

    private static func isPrintableKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_ANSI_A...kVK_ANSI_Z,
             kVK_ANSI_0...kVK_ANSI_9,
             kVK_ANSI_Equal,
             kVK_ANSI_Minus,
             kVK_ANSI_RightBracket,
             kVK_ANSI_LeftBracket,
             kVK_ANSI_Quote,
             kVK_ANSI_Semicolon,
             kVK_ANSI_Backslash,
             kVK_ANSI_Comma,
             kVK_ANSI_Slash,
             kVK_ANSI_Period,
             kVK_ANSI_Grave,
             kVK_Space:
            return true
        default:
            return false
        }
    }

    private static func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Command,
             kVK_RightCommand,
             kVK_Option,
             kVK_RightOption,
             kVK_Control,
             kVK_RightControl,
             kVK_Shift,
             kVK_RightShift:
            return true
        default:
            return false
        }
    }

    private static var reservedShortcuts: Set<VoiceInputShortcut> {
        let command = UInt64(CGEventFlags.maskCommand.rawValue)
        let commandShift = UInt64((CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue))
        return [
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_Q), modifierMask: command, usesFunctionKey: false),
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_W), modifierMask: command, usesFunctionKey: false),
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_C), modifierMask: command, usesFunctionKey: false),
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_V), modifierMask: command, usesFunctionKey: false),
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_X), modifierMask: command, usesFunctionKey: false),
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_A), modifierMask: command, usesFunctionKey: false),
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_S), modifierMask: command, usesFunctionKey: false),
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_Z), modifierMask: command, usesFunctionKey: false),
            VoiceInputShortcut(keyCode: UInt16(kVK_ANSI_Z), modifierMask: commandShift, usesFunctionKey: false)
        ]
    }
}
