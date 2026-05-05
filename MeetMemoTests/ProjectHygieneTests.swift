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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String, from root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
