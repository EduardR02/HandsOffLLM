//
//  HandsOffLLMTests.swift
//  HandsOffLLMTests
//
//  Created by Eduard Rantsevich on 08.04.25.
//

import Testing
@testable import HandsOffLLM
import Foundation

struct HandsOffLLMTests {

    @Test func openAIClientUsesResponsesEndpointAndCurrentModelFlags() throws {
        let context = makeContext(
            modelId: "gpt-5.2",
            openAIKey: "openai-key",
            webSearchEnabled: true,
            openAIReasoningEffort: .high
        )

        let request = try OpenAIClient().makeRequest(with: context)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")

        let body = try requestBody(from: request)
        #expect(body["model"] as? String == "gpt-5.2")
        #expect((body["reasoning"] as? [String: String])?["effort"] == "high")
        #expect(body["tools"] as? [[String: String]] == [["type": "web_search_preview"]])
    }

    @Test func openAICompatibleClientsShareDecodingAndUseProviderEndpoints() throws {
        let context = makeContext(
            modelId: "grok-4-fast",
            xaiKey: "xai-key",
            moonshotKey: "moonshot-key",
            webSearchEnabled: true,
            reasoningEnabled: true
        )

        let xai = XAIClient()
        let moonshot = MoonshotClient()

        let xaiRequest = try xai.makeRequest(with: context)
        let moonshotRequest = try moonshot.makeRequest(with: context)

        #expect(xaiRequest.url?.absoluteString == "https://api.x.ai/v1/chat/completions")
        #expect(moonshotRequest.url?.absoluteString == "https://api.moonshot.ai/v1/chat/completions")

        let xaiBody = try requestBody(from: xaiRequest)
        let moonshotBody = try requestBody(from: moonshotRequest)

        #expect(xaiBody["max_completion_tokens"] as? Int == 4096)
        #expect(moonshotBody["max_tokens"] as? Int == 4096)
        #expect((xaiBody["search_parameters"] as? [String: String])?["mode"] == "auto")
        #expect(xaiBody["reasoning_effort"] as? String == "high")

        let chunk = "{\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
        #expect(xai.decodeChunk(chunk) == "Hello")
        #expect(moonshot.decodeChunk(chunk) == "Hello")
    }

    @Test func xaiNonReasoningModelsDoNotSetReasoningEffort() throws {
        let context = makeContext(
            modelId: "grok-4-fast-non-reasoning",
            xaiKey: "xai-key",
            webSearchEnabled: true,
            reasoningEnabled: true
        )

        let request = try XAIClient().makeRequest(with: context)
        let body = try requestBody(from: request)

        #expect((body["search_parameters"] as? [String: String])?["mode"] == "auto")
        #expect(body["reasoning_effort"] as? String == nil)
    }

    @Test func geminiThinkingToggleAppliesToFlashModelsOnly() throws {
        let flashThinkingEnabled = makeContext(
            modelId: "gemini-3-flash",
            geminiKey: "gemini-key",
            reasoningEnabled: true
        )
        let flashThinkingDisabled = makeContext(
            modelId: "gemini-3-flash-preview",
            geminiKey: "gemini-key",
            reasoningEnabled: false
        )
        let proContext = makeContext(
            modelId: "gemini-3-pro",
            geminiKey: "gemini-key",
            reasoningEnabled: true
        )

        let flashEnabledBody = try requestBody(from: try GeminiClient().makeRequest(with: flashThinkingEnabled))
        let flashDisabledBody = try requestBody(from: try GeminiClient().makeRequest(with: flashThinkingDisabled))
        let proBody = try requestBody(from: try GeminiClient().makeRequest(with: proContext))

        let flashEnabledConfig = flashEnabledBody["generationConfig"] as? [String: Any]
        let flashDisabledConfig = flashDisabledBody["generationConfig"] as? [String: Any]
        let proConfig = proBody["generationConfig"] as? [String: Any]

        #expect((flashEnabledConfig?["thinking_config"] as? [String: Any])?["thinkingBudget"] as? Int == 8192)
        #expect((flashDisabledConfig?["thinking_config"] as? [String: Any])?["thinkingBudget"] as? Int == 0)
        #expect(proConfig?["thinking_config"] as? [String: Any] == nil)
    }

    @Test func providerDetectionCoversUpdatedModelFamilies() {
        #expect(LLMProvider.provider(forModelId: "gpt-5.2") == .openai)
        #expect(LLMProvider.provider(forModelId: "gpt-5.2-mini") == .openai)
        #expect(LLMProvider.provider(forModelId: "codex-mini-5.3") == .openai)
        #expect(LLMProvider.provider(forModelId: "claude-sonnet-4.6") == .claude)
        #expect(LLMProvider.provider(forModelId: "gemini-3-pro") == .gemini)
        #expect(LLMProvider.provider(forModelId: "grok-4-fast") == .xai)
        #expect(LLMProvider.provider(forModelId: "kimi-k2.5") == .moonshot)
        #expect(LLMProvider.provider(forModelId: "unknown-model") == nil)
    }

    @Test func replicatePredictionResponseDecodesOutputShapes() throws {
        let single = """
        {"id":"pred_1","status":"succeeded","output":"https://example.com/1.wav"}
        """.data(using: .utf8)!
        let array = """
        {"id":"pred_2","status":"succeeded","output":["https://example.com/2.wav"]}
        """.data(using: .utf8)!
        let dictionary = """
        {"id":"pred_3","status":"succeeded","output":{"audio":"https://example.com/3.wav"}}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        #expect(try decoder.decode(ReplicateTTSResponse.self, from: single).outputURL == "https://example.com/1.wav")
        #expect(try decoder.decode(ReplicateTTSResponse.self, from: array).outputURL == "https://example.com/2.wav")
        #expect(try decoder.decode(ReplicateTTSResponse.self, from: dictionary).outputURL == "https://example.com/3.wav")
    }

    @Test func llmClientFactoryRejectsReplicateProvider() {
        do {
            _ = try LLMClientFactory.client(for: .replicate)
            Issue.record("Expected Replicate to be rejected as an LLM provider")
        } catch let error as LlmError {
            guard case let .streamingError(message) = error else {
                Issue.record("Expected streamingError, got: \(error)")
                return
            }
            #expect(message == "Replicate is not an LLM provider")
        } catch {
            Issue.record("Expected LlmError, got: \(error)")
        }
    }

    @Test func proxyPayloadEmbeddingPreservesRawBodyData() throws {
        let bodyData = Data("{\"model\":\"gpt-5.2\",\"stream\":true}".utf8)
        let payloadData = try ProxyService.makeProxyPayload(
            provider: .openai,
            endpoint: "https://api.openai.com/v1/responses",
            method: "POST",
            headers: ["Content-Type": "application/json"],
            bodyData: bodyData
        )

        guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            Issue.record("Proxy payload should decode into a JSON object")
            return
        }

        #expect(payload["provider"] as? String == "openai")
        #expect(payload["endpoint"] as? String == "https://api.openai.com/v1/responses")
        #expect(payload["method"] as? String == "POST")
        #expect((payload["headers"] as? [String: String])?["Content-Type"] == "application/json")
        #expect((payload["bodyData"] as? [String: Any])?["model"] as? String == "gpt-5.2")
        #expect((payload["bodyData"] as? [String: Any])?["stream"] as? Bool == true)
    }

    @Test @MainActor func settingsServiceRemovesTemporarySystemPromptPreset() {
        let settingsService = SettingsService()
        #expect(settingsService.availableSystemPrompts.contains(where: { $0.id == "remove-later" }) == false)
    }

    @Test @MainActor func historyServiceSurfacesLoadErrorsViaPublishedLastError() async throws {
        let historyService = HistoryService()
        let conversationId = UUID()

        guard let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Issue.record("Unable to resolve documents directory")
            return
        }

        let conversationsDir = docsURL.appendingPathComponent("Conversations")
        try FileManager.default.createDirectory(at: conversationsDir, withIntermediateDirectories: true)

        let invalidConversationURL = conversationsDir.appendingPathComponent("\(conversationId.uuidString).json")
        try Data("not-valid-json".utf8).write(to: invalidConversationURL, options: .atomicWrite)
        defer { try? FileManager.default.removeItem(at: invalidConversationURL) }

        let loadedConversation = await historyService.loadConversationDetail(id: conversationId)
        #expect(loadedConversation == nil)
        #expect(historyService.lastError != nil)
    }

    private func makeContext(
        modelId: String,
        openAIKey: String? = nil,
        xaiKey: String? = nil,
        moonshotKey: String? = nil,
        geminiKey: String? = nil,
        webSearchEnabled: Bool = false,
        openAIReasoningEffort: OpenAIReasoningEffort? = nil,
        reasoningEnabled: Bool = false
    ) -> LLMClientContext {
        LLMClientContext(
            messages: [ChatMessage(id: UUID(), role: "user", content: "hello")],
            systemPrompt: "You are helpful",
            temperature: 0.8,
            maxTokens: 4096,
            modelId: modelId,
            temperatureCap: 2.0,
            tokenCap: 8192,
            openAIKey: openAIKey,
            xaiKey: xaiKey,
            moonshotKey: moonshotKey,
            anthropicKey: nil,
            geminiKey: geminiKey,
            webSearchEnabled: webSearchEnabled,
            openAIReasoningEffort: openAIReasoningEffort,
            reasoningEnabled: reasoningEnabled,
            useProxy: false
        )
    }

    private func requestBody(from request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody else {
            Issue.record("Missing HTTP body")
            return [:]
        }
        guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("HTTP body was not a JSON object")
            return [:]
        }
        return decoded
    }

}
