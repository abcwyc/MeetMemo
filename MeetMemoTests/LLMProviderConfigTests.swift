import XCTest
@testable import MeetMemo

final class LLMProviderConfigTests: XCTestCase {
    func testGoPresetResolvesSavedAndLegacyConfigurations() {
        var settings = Settings()
        settings.llmPresetID = "opencode-go"
        settings.llmBaseURL = "https://opencode.ai/zen/go/v1"
        XCTAssertEqual(LLMPresetProviders.resolve(for: settings)?.id, "opencode-go")
        settings.llmPresetID = ""
        settings.llmBaseURL += "/"
        XCTAssertEqual(LLMPresetProviders.resolve(for: settings)?.id, "opencode-go")
        XCTAssertNil(LLMPresetProviders.provider(matchingBaseURL: "https://opencode.ai/zen/v1"))
    }

    func testGoPresetPreservesExplicitCustomSelection() {
        var settings = Settings()
        settings.llmPresetID = LLMPresetProviders.customPresetID
        settings.llmBaseURL = "https://opencode.ai/zen/go/v1"
        XCTAssertNil(LLMPresetProviders.resolve(for: settings))
    }

    func testDifferentMeetingsUseDifferentGoSessions() throws {
        for session in ["meeting-one", "meeting-two"] {
            let config = LLMProviderConfig(apiKey: "test", baseURL: "https://opencode.ai/zen/go/v1", model: "kimi-k3", sessionID: session)
            var request = URLRequest(url: try config.requestURL(endpoint: "/chat/completions"))
            config.applyGoRoutingHeaders(to: &request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), session)
        }
    }

    func testGoHeadersUseMeetingSessionAndAppIdentity() throws {
        let config = LLMProviderConfig(apiKey: "test", baseURL: "https://opencode.ai/zen/go/v1", model: "kimi-k3", sessionID: "meeting-one")
        var request = URLRequest(url: try config.requestURL(endpoint: "/chat/completions"))
        config.applyGoRoutingHeaders(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), "meeting-one")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("MeetMemo/") == true)
    }

    func testGoUtilitySessionIsStableAcrossConfigs() throws {
        let first = LLMProviderConfig(apiKey: "test", baseURL: "https://opencode.ai/zen/go/v1", model: "kimi-k3")
        let second = LLMProviderConfig(apiKey: "test", baseURL: first.baseURL, model: "glm-5.2")
        var firstRequest = URLRequest(url: try first.requestURL(endpoint: "/chat/completions"))
        var secondRequest = URLRequest(url: try second.requestURL(endpoint: "/chat/completions"))
        first.applyGoRoutingHeaders(to: &firstRequest)
        second.applyGoRoutingHeaders(to: &secondRequest)
        let session = firstRequest.value(forHTTPHeaderField: "x-opencode-session")
        XCTAssertNotNil(session)
        XCTAssertEqual(session, secondRequest.value(forHTTPHeaderField: "x-opencode-session"))
    }

    func testGoHeadersAreNotSentToOtherProvidersOrLookalikeHosts() throws {
        for address in ["https://api.openai.com/v1", "https://opencode.ai/zen/v1", "https://opencode.ai.example.com/zen/go/v1"] {
            let config = LLMProviderConfig(apiKey: "test", baseURL: address, model: "test", sessionID: "meeting-one")
            var request = URLRequest(url: try config.requestURL(endpoint: "/chat/completions"))
            config.applyGoRoutingHeaders(to: &request)
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-session"))
            XCTAssertNil(request.value(forHTTPHeaderField: "User-Agent"))
        }
    }

    func testAnthropicBaseURLUsesMessagesAPI() throws {
        let config = LLMProviderConfig(
            apiKey: "test-key",
            baseURL: "https://api.anthropic.com",
            model: "claude-test"
        )

        XCTAssertEqual(config.apiStyle, .anthropicMessages)
        XCTAssertEqual(try config.requestURL(endpoint: "/v1/messages").absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testAnthropicV1BaseURLDoesNotDuplicateVersionSegment() throws {
        let config = LLMProviderConfig(
            apiKey: "test-key",
            baseURL: "https://api.anthropic.com/v1",
            model: "claude-test"
        )

        XCTAssertEqual(config.apiStyle, .anthropicMessages)
        XCTAssertEqual(try config.requestURL(endpoint: "/v1/messages").absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testOpenAICompatibleBaseURLUsesChatCompletions() throws {
        let config = LLMProviderConfig(
            apiKey: "test-key",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            model: "ep-test"
        )

        XCTAssertEqual(config.apiStyle, .openAICompatibleChatCompletions)
        XCTAssertEqual(
            try config.requestURL(endpoint: "/chat/completions").absoluteString,
            "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        )
    }

    func testOpenAICompatibleV1BaseURLKeepsVersionSegment() throws {
        let config = LLMProviderConfig(
            apiKey: "test-key",
            baseURL: "https://api.openai.com/v1",
            model: "gpt-test"
        )

        XCTAssertEqual(config.apiStyle, .openAICompatibleChatCompletions)
        XCTAssertEqual(
            try config.requestURL(endpoint: "/chat/completions").absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }

    func testFullEndpointBaseURLIsNotAppendedTwice() throws {
        let config = LLMProviderConfig(
            apiKey: "test-key",
            baseURL: "https://api.openai.com/v1/chat/completions",
            model: "gpt-test"
        )

        XCTAssertEqual(
            try config.requestURL(endpoint: "/chat/completions").absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }
}
