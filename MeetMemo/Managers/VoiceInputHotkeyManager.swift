import AppKit
import Carbon.HIToolbox

@MainActor
final class VoiceInputHotkeyManager: ObservableObject {
    static let shared = VoiceInputHotkeyManager()

    @Published private(set) var isMonitoring = false
    @Published private(set) var lastErrorMessage: String?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var previousFlags: CGEventFlags = []
    private var lastActivationAt: Date?
    private var isHoldingShortcut = false
    private let doublePressWindow: TimeInterval = 0.45

    // 「干净轻拍」判定：修饰键释放时才触发，且按下期间没有叠加其他按键/修饰键，
    // 用时也足够短。避免把右 Command 等常用修饰键当作组合键使用时被误触发。
    private var tapCandidateActive = false
    private var tapCandidateStartedAt: Date?
    private var tapPolluted = false
    private let cleanTapMaxDuration: TimeInterval = 0.6

    private init() {}

    private struct EventSnapshot: Sendable {
        let type: CGEventType
        let keyCode: UInt16
        let flagsRawValue: UInt64

        var flags: CGEventFlags {
            CGEventFlags(rawValue: flagsRawValue)
        }
    }

    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            let snapshot = EventSnapshot(
                type: type,
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                flagsRawValue: UInt64(event.flags.rawValue)
            )
            Task { @MainActor in
                VoiceInputHotkeyManager.shared.handle(snapshot)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: nil
        ) else {
            isMonitoring = false
            lastErrorMessage = LanguageManager.shared.t(
                "无法监听全局快捷键，请在系统设置中允许 MeetMemo 使用辅助功能。",
                "Unable to monitor global shortcuts. Allow MeetMemo to use Accessibility in System Settings."
            )
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isMonitoring = true
        lastErrorMessage = nil
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        isMonitoring = false
        resetTransientState()
    }

    private func resetTransientState() {
        previousFlags = []
        lastActivationAt = nil
        isHoldingShortcut = false
        tapCandidateActive = false
        tapCandidateStartedAt = nil
        tapPolluted = false
    }

    func refresh() {
        stop()
        if UserDefaultsManager.shared.voiceInputEnabled {
            start()
        }
    }

    private func handle(_ snapshot: EventSnapshot) {
        guard UserDefaultsManager.shared.voiceInputEnabled else { return }

        if snapshot.type == .tapDisabledByTimeout || snapshot.type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let mode = UserDefaultsManager.shared.voiceInputTriggerMode
        let shortcut = UserDefaultsManager.shared.voiceInputShortcut
        let flags = VoiceInputShortcut.normalizedFlags(snapshot.flags)
        let keyCode = snapshot.keyCode

        switch snapshot.type {
        case .keyDown:
            if mode == .doublePress && VoiceInputManager.shared.state == .listening {
                VoiceInputManager.shared.stop()
                lastActivationAt = nil
                return
            }
            // 任何普通按键都会污染正在进行中的「轻拍」，使其不再被判定为一次激活。
            if tapCandidateActive {
                tapPolluted = true
            }
            if mode == .keyCombination, shortcut.matches(keyCode: keyCode, flags: flags) {
                handleActivation(mode: mode)
            }
        case .keyUp:
            if mode == .pressAndHold && isHoldingShortcut && shortcut.keyCode == keyCode {
                endHold()
            }
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: flags, shortcut: shortcut, mode: mode)
        default:
            break
        }

        previousFlags = flags
    }

    private func handleFlagsChanged(
        keyCode: UInt16,
        flags: CGEventFlags,
        shortcut: VoiceInputShortcut,
        mode: VoiceInputTriggerMode
    ) {
        let didAppear: Bool
        let didDisappear: Bool

        if shortcut.usesFunctionKey {
            didAppear = flags.contains(.maskSecondaryFn) && !previousFlags.contains(.maskSecondaryFn)
            didDisappear = !flags.contains(.maskSecondaryFn) && previousFlags.contains(.maskSecondaryFn)
        } else if let shortcutKeyCode = shortcut.keyCode {
            didAppear = shortcutKeyCode == keyCode && shortcut.matches(keyCode: keyCode, flags: flags)
            didDisappear = shortcutKeyCode == keyCode && !shortcut.matches(keyCode: keyCode, flags: flags)
        } else {
            didAppear = flags.rawValue != 0 && shortcut.matches(keyCode: nil, flags: flags)
            didDisappear = flags.rawValue == 0
        }

        // 轻拍过程中若叠加了快捷键之外的修饰键（例如右 Command 期间再按 Shift），视为污染。
        if tapCandidateActive, !didDisappear {
            let expected = VoiceInputShortcut.normalizedFlags(CGEventFlags(rawValue: shortcut.modifierMask))
            let extra = flags.intersection(VoiceInputShortcut.relevantModifierFlags).subtracting(expected)
            if !extra.isEmpty {
                tapPolluted = true
            }
        }

        switch mode {
        case .pressAndHold:
            if didAppear {
                beginHold()
            } else if didDisappear && isHoldingShortcut {
                endHold()
            }
        case .singlePress, .doublePress:
            if mode == .doublePress && VoiceInputManager.shared.state == .listening && didAppear {
                VoiceInputManager.shared.stop()
                lastActivationAt = nil
                tapCandidateActive = false
                tapCandidateStartedAt = nil
                tapPolluted = false
                return
            }
            if didAppear {
                beginTapCandidate()
            } else if didDisappear {
                resolveTapCandidate(mode: mode)
            }
        case .keyCombination:
            break
        }
    }

    private func beginTapCandidate() {
        tapCandidateActive = true
        tapPolluted = false
        tapCandidateStartedAt = Date()
    }

    private func resolveTapCandidate(mode: VoiceInputTriggerMode) {
        guard tapCandidateActive else { return }
        tapCandidateActive = false
        let polluted = tapPolluted
        tapPolluted = false
        let duration = tapCandidateStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        tapCandidateStartedAt = nil
        // 只有「干净的快速轻拍」才算一次激活：期间没有其他按键、按下时长足够短。
        guard !polluted, duration <= cleanTapMaxDuration else { return }
        handleActivation(mode: mode)
    }

    private func handleActivation(mode: VoiceInputTriggerMode) {
        switch mode {
        case .singlePress, .keyCombination:
            VoiceInputManager.shared.toggle()
        case .doublePress:
            let now = Date()
            if let lastActivationAt,
               now.timeIntervalSince(lastActivationAt) <= doublePressWindow {
                self.lastActivationAt = nil
                VoiceInputManager.shared.toggle()
            } else {
                lastActivationAt = now
            }
        case .pressAndHold:
            break
        }
    }

    private func beginHold() {
        guard !isHoldingShortcut else { return }
        isHoldingShortcut = true
        VoiceInputManager.shared.start()
    }

    private func endHold() {
        isHoldingShortcut = false
        VoiceInputManager.shared.stop()
    }
}
