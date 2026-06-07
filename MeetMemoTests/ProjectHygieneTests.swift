import XCTest

final class ProjectHygieneTests: XCTestCase {
    func testRemovedTelemetryAndAutoUpdateDependenciesStayRemoved() throws {
        let root = repositoryRoot()
        let projectFile = try read("MeetMemo.xcodeproj/project.pbxproj", from: root)
        let readme = try read("README.md", from: root)
        let agents = try read("AGENTS.md", from: root)
        let claude = try read("CLAUDE.md", from: root)
        let releaseScript = try read("scripts/build_release.sh", from: root)

        for content in [projectFile, readme, agents, claude, releaseScript] {
            XCTAssertFalse(content.contains("PostHog"))
            XCTAssertFalse(content.contains("posthog"))
            XCTAssertFalse(content.contains("Sparkle"))
            XCTAssertFalse(content.contains("appcast"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("appcast.xml").path))

        let packageResolved = root.appendingPathComponent("MeetMemo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        if FileManager.default.fileExists(atPath: packageResolved.path) {
            let packageText = try String(contentsOf: packageResolved, encoding: .utf8)
            XCTAssertFalse(packageText.contains("PostHog"))
            XCTAssertFalse(packageText.contains("Sparkle"))
        }
    }

    func testCodeSigningVerifierDoesNotPrintNotarizationPassword() throws {
        let script = try read("scripts/verify_codesigning.sh", from: repositoryRoot())
        XCTAssertFalse(script.contains("APP_PASSWORD: $APP_PASSWORD"))
        XCTAssertTrue(script.contains("APP_PASSWORD: Set"))
    }

    func testAudioImportFlowKeepsFinalizationAndCancellationGuards() throws {
        let root = repositoryRoot()
        let transcriber = try read("MeetMemo/Services/AudioFileTranscriber.swift", from: root)
        let viewModel = try read("MeetMemo/ViewModels/MeetingListViewModel.swift", from: root)

        XCTAssertTrue(transcriber.contains("analyzer.analyzeSequence(from: file)"))
        XCTAssertTrue(transcriber.contains("analyzer.finalizeAndFinish(through: lastSample)"))
        XCTAssertTrue(viewModel.contains("try Task.checkCancellation()"))
    }

    func testMeetingResumeKeepsSystemAudioRecoveryPaths() throws {
        let audioManager = try read("MeetMemo/Managers/AudioManager.swift", from: repositoryRoot())

        XCTAssertTrue(audioManager.contains("scheduleSystemAudioTapRetry(sessionToken: activeSessionToken)"))
        XCTAssertFalse(audioManager.contains("objectID.readProcessIsRunning(),"))
        XCTAssertTrue(audioManager.contains("systemSTTConnectingSessionID = sessionToken"))
        XCTAssertTrue(audioManager.contains("connectSTTProvider(\n                    for: .system,\n                    offsetMilliseconds: offset,\n                    sessionToken: sessionToken"))
    }

    func testRecordingStopSpinnerStaysUntilProviderCleanupCompletes() throws {
        let audioManager = try read("MeetMemo/Managers/AudioManager.swift", from: repositoryRoot())

        guard let disconnectRange = audioManager.range(of: "self.disconnectSTTProviders()"),
              let stopDoneRange = audioManager.range(of: "self.isStoppingRecording = false", range: disconnectRange.upperBound..<audioManager.endIndex) else {
            XCTFail("Expected stop finalization to clear isStoppingRecording after provider cleanup")
            return
        }

        XCTAssertLessThan(disconnectRange.lowerBound, stopDoneRange.lowerBound)
    }

    func testAppSourcesAvoidCrashOnlyShortcutsOutsideGeneratedBridge() throws {
        let root = repositoryRoot()
        let appRoot = root.appendingPathComponent("MeetMemo")
        let riskyPatterns = ["as!", "try!", "fatalError("]
        var violations: [String] = []

        guard let enumerator = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("Could not enumerate app sources")
            return
        }

        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
            if relativePath.hasPrefix("MeetMemo/SherpaOnnxBridge/") {
                continue
            }

            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in riskyPatterns where source.contains(pattern) {
                violations.append("\(relativePath) contains \(pattern)")
            }
        }

        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String, from root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
