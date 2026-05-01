import XCTest
@testable import MeetMemo

final class LLMProviderConfigTests: XCTestCase {
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
