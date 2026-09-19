import Foundation
import os

/// Centralized OSLog categories.
///
/// Replaces direct `print` calls: `print` synchronously writes to stdout on
/// whatever thread it is called from (including the audio hot path), while
/// OSLog is buffered by the system and viewable in Xcode's console and
/// Console.app with proper subsystem/category filtering.
///
/// Messages are logged at `.debug` level, matching the previous print-only
/// diagnostics: visible while developing, not persisted in release builds.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "MeetMemo"

    /// Audio capture, STT feeding, process tap.
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// JSON persistence under the Documents directory.
    static let storage = Logger(subsystem: subsystem, category: "storage")
    /// Recording session lifecycle and availability.
    static let session = Logger(subsystem: subsystem, category: "session")
    /// STT engines (SpeechAnalyzer, sherpa-onnx) and model readiness.
    static let stt = Logger(subsystem: subsystem, category: "stt")
    /// LLM request/response and prompt assembly.
    static let llm = Logger(subsystem: subsystem, category: "llm")
    /// View/UI-layer diagnostics.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
