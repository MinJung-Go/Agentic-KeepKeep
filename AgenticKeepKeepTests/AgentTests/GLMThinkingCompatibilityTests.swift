import XCTest
@testable import AgenticKeepKeep

final class GLMThinkingCompatibilityTests: XCTestCase {
    private func capture(model: String, thinking: Bool?, streaming: Bool = false, override: String? = nil) async throws -> [String: Any] {
        defer { MockURLProtocol.reset() }
        MockURLProtocol.responder = { _ in
            let body = streaming
                ? "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
                : #"{"choices":[{"message":{"content":"ok"}}]}"#
            return (200, Data(body.utf8))
        }
        let client = OpenAICompatibleClient(config: LLMClientConfig(baseURL: "https://fixture.invalid", apiKey: "fixture", model: model), session: MockURLProtocol.makeSession())
        var request = LLMRequest(messages: [.user("hi")], thinkingEnabled: thinking)
        request.model = override
        if streaming { _ = try await LLMStreamCollector.collect(client.stream(request)) }
        else { _ = try await client.complete(request) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(MockURLProtocol.lastRequestBody)) as? [String: Any])
    }

    func testGLM53AlwaysUsesSupportedThinkingParameters() async throws {
        for model in ["glm-5.3", "glm-5.3-flash", "GLM-5.3", "zai-org/GLM-5.3"] {
            for enabled: Bool? in [false, true, nil] {
                let body = try await capture(model: model, thinking: enabled)
                XCTAssertEqual(body["reasoning_effort"] as? String, enabled == false ? "low" : "high")
                XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "enabled")
            }
        }
    }

    func testStreamingDisabledBecomesLow() async throws {
        let body = try await capture(model: "glm-5.3-flash", thinking: false, streaming: true)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "enabled")
    }

    func testRequestModelOverrideDeterminesCompatibility() async throws {
        let body = try await capture(model: "gpt-4o", thinking: false, override: "glm-5.3")
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
    }

    func testOlderGLMCanStillDisableThinking() async throws {
        let body = try await capture(model: "glm-5.2", thinking: false)
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
    }

    func testOtherModelsDoNotAcquireRequiredThinking() async throws {
        for model in ["gpt-4o", "glm-4.7", "glm-5", "glm-5.30", "custom-model"] {
            XCTAssertFalse(OpenAICompatibleClient.requiresThinking(model: model))
        }
        let body = try await capture(model: "gpt-4o", thinking: false)
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["thinking"])
    }
}
