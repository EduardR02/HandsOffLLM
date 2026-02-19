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
            reasoningEnabled: true,
            reasoningEffort: .high
        )

        let request = try OpenAIClient().makeRequest(with: context)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")

        let body = try requestBody(from: request)
        #expect(body["model"] as? String == "gpt-5.2")
        #expect((body["reasoning"] as? [String: String])?["effort"] == "high")
        #expect(body["tools"] as? [[String: String]] == [["type": "web_search_preview"]])
    }

    @Test func openAIReasoningEffortLevelsMapDirectlyForGPT5() throws {
        let client = OpenAIClient()
        let expectedEfforts: [ReasoningEffort: String] = [
            .minimal: "minimal",
            .low: "low",
            .medium: "medium",
            .high: "high",
            .xhigh: "xhigh"
        ]

        for (effort, expected) in expectedEfforts {
            let context = makeContext(
                modelId: "gpt-5.2",
                openAIKey: "openai-key",
                reasoningEnabled: true,
                reasoningEffort: effort
            )

            let body = try requestBody(from: try client.makeRequest(with: context))
            let mappedEffort = (body["reasoning"] as? [String: String])?["effort"]
            #expect(mappedEffort == expected)
        }
    }

    @Test func openAICompatibleClientsShareDecodingAndUseProviderEndpoints() throws {
        let context = makeContext(
            modelId: "grok-4-fast",
            xaiKey: "xai-key",
            moonshotKey: "moonshot-key",
            webSearchEnabled: true,
            reasoningEnabled: true,
            reasoningEffort: .medium
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

    @Test func xaiReasoningEffortIsAlwaysHardcodedHighWhenEnabled() throws {
        let minimalContext = makeContext(
            modelId: "grok-4-fast",
            xaiKey: "xai-key",
            reasoningEnabled: true,
            reasoningEffort: .minimal
        )
        let xhighContext = makeContext(
            modelId: "grok-4-fast",
            xaiKey: "xai-key",
            reasoningEnabled: true,
            reasoningEffort: .xhigh
        )

        let minimalBody = try requestBody(from: try XAIClient().makeRequest(with: minimalContext))
        let xhighBody = try requestBody(from: try XAIClient().makeRequest(with: xhighContext))

        #expect(minimalBody["reasoning_effort"] as? String == "high")
        #expect(xhighBody["reasoning_effort"] as? String == "high")
    }

    @Test func claudeRequestBuildsThinkingPayloadAndMarksLastMessageEphemeral() throws {
        let messages = [
            ChatMessage(id: UUID(), role: "user", content: "hello"),
            ChatMessage(id: UUID(), role: "assistant", content: "hi"),
            ChatMessage(id: UUID(), role: "user", content: "please help")
        ]
        let context = makeContext(
            modelId: "claude-sonnet-4.6",
            anthropicKey: "anthropic-key",
            messages: messages,
            systemPrompt: "You are concise",
            maxTokens: 7000,
            webSearchEnabled: true,
            reasoningEnabled: true,
            reasoningEffort: .low
        )

        let request = try ClaudeClient().makeRequest(with: context)
        let body = try requestBody(from: request)

        #expect(body["system"] as? String == "You are concise")
        #expect(body["temperature"] == nil)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((body["output_config"] as? [String: String])?["effort"] == "high")
        #expect((body["tools"] as? [[String: Any]])?.first?["type"] as? String == "web_search_20250305")

        guard let payloadMessages = body["messages"] as? [[String: Any]] else {
            Issue.record("Claude payload did not contain messages")
            return
        }

        let firstContent = (payloadMessages.first?["content"] as? [[String: Any]])?.first
        let lastContent = (payloadMessages.last?["content"] as? [[String: Any]])?.first
        let firstCacheControl = firstContent?["cache_control"] as? [String: String]
        let lastCacheControl = lastContent?["cache_control"] as? [String: String]

        #expect(firstCacheControl == nil)
        #expect(lastCacheControl?["type"] == "ephemeral")
    }

    @Test func claudeNonThinkingRequestUsesTemperatureAndNoThinkingBlock() throws {
        let context = makeContext(
            modelId: "claude-sonnet-4.6",
            anthropicKey: "anthropic-key",
            systemPrompt: nil,
            reasoningEnabled: false
        )

        let body = try requestBody(from: try ClaudeClient().makeRequest(with: context))
        #expect(body["system"] == nil)
        #expect(body["thinking"] == nil)
        let temperature = (body["temperature"] as? NSNumber)?.floatValue
        #expect(temperature != nil)
        #expect(abs((temperature ?? 0) - 0.8) < 0.0001)
    }

    @Test func claudeOpusReasoningEffortClampsToSupportedAdaptiveLevels() throws {
        let minimalContext = makeContext(
            modelId: "claude-opus-4.6",
            anthropicKey: "anthropic-key",
            reasoningEnabled: true,
            reasoningEffort: .minimal
        )
        let xhighContext = makeContext(
            modelId: "claude-opus-4.6",
            anthropicKey: "anthropic-key",
            reasoningEnabled: true,
            reasoningEffort: .xhigh
        )

        let minimalBody = try requestBody(from: try ClaudeClient().makeRequest(with: minimalContext))
        let xhighBody = try requestBody(from: try ClaudeClient().makeRequest(with: xhighContext))

        #expect((minimalBody["thinking"] as? [String: String])?["type"] == "adaptive")
        #expect((xhighBody["thinking"] as? [String: String])?["type"] == "adaptive")
        #expect((minimalBody["output_config"] as? [String: String])?["effort"] == "low")
        #expect((xhighBody["output_config"] as? [String: String])?["effort"] == "max")
    }

    @Test func geminiRequestBuildsSSEURLAndPayloadShape() throws {
        let context = makeContext(
            modelId: "gemini-3-flash-preview",
            geminiKey: "  gemini-key  ",
            messages: [
                ChatMessage(id: UUID(), role: "user", content: "Question"),
                ChatMessage(id: UUID(), role: "assistant", content: "Answer")
            ],
            systemPrompt: "Stay short",
            webSearchEnabled: true,
            reasoningEnabled: true,
            reasoningEffort: .medium
        )

        let request = try GeminiClient().makeRequest(with: context)
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Issue.record("Gemini request URL should be valid")
            return
        }

        #expect(url.path == "/v1beta/models/gemini-3-flash-preview:streamGenerateContent")
        #expect(components.queryItems?.contains(URLQueryItem(name: "alt", value: "sse")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "key", value: "gemini-key")) == true)

        let body = try requestBody(from: request)
        let contents = body["contents"] as? [[String: Any]]
        let generationConfig = body["generationConfig"] as? [String: Any]
        let safety = (body["safetySettings"] as? [[String: String]]) ?? []
        let systemInstruction = body["systemInstruction"] as? [String: Any]
        let tools = body["tools"] as? [[String: Any]]
        let firstRole = contents?.first?["role"] as? String
        let lastRole = contents?.last?["role"] as? String

        #expect(contents?.count == 2)
        #expect(firstRole == "user")
        #expect(lastRole == "model")
        let thinkingConfig = generationConfig?["thinking_config"] as? [String: Any]
        let thinkingLevel = thinkingConfig?["thinkingLevel"] as? String
        let includeThoughts = thinkingConfig?["include_thoughts"] as? Bool
        let googleSearchConfig = tools?.first?["google_search"] as? [String: Any]
        #expect(thinkingLevel == "medium")
        #expect(includeThoughts == true)
        #expect(googleSearchConfig?.isEmpty == true)
        #expect((systemInstruction?["parts"] as? [[String: String]])?.first?["text"] == "Stay short")

        let expectedSafety = Set([
            "HARM_CATEGORY_HARASSMENT",
            "HARM_CATEGORY_HATE_SPEECH",
            "HARM_CATEGORY_SEXUALLY_EXPLICIT",
            "HARM_CATEGORY_DANGEROUS_CONTENT"
        ])
        let categories = Set(safety.compactMap { $0["category"] })
        let allThresholdsNone = safety.allSatisfy { $0["threshold"] == "BLOCK_NONE" }
        #expect(categories == expectedSafety)
        #expect(allThresholdsNone)
    }

    @Test func geminiProxyRequestOmitsKeyFromQueryString() throws {
        let context = makeContext(
            modelId: "gemini-3-pro",
            geminiKey: nil,
            useProxy: true
        )

        let request = try GeminiClient().makeRequest(with: context)
        guard let components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            Issue.record("Gemini request URL should be valid")
            return
        }

        #expect(components.queryItems?.contains(URLQueryItem(name: "alt", value: "sse")) == true)
        #expect(components.queryItems?.contains(where: { $0.name == "key" }) == false)
    }

    @Test func geminiFlashReasoningEffortClampsXhighToHigh() throws {
        let flashXhigh = makeContext(
            modelId: "gemini-3-flash-preview",
            geminiKey: "gemini-key",
            reasoningEnabled: true,
            reasoningEffort: .xhigh
        )

        let flashXhighBody = try requestBody(from: try GeminiClient().makeRequest(with: flashXhigh))
        let flashConfig = flashXhighBody["generationConfig"] as? [String: Any]
        let flashThinking = flashConfig?["thinking_config"] as? [String: Any]

        #expect(flashThinking?["thinkingLevel"] as? String == "high")
        #expect(flashThinking?["include_thoughts"] as? Bool == true)
    }

    @Test func geminiProReasoningEffortClampsMinimalAndMediumToTwoLevels() throws {
        let proMinimal = makeContext(
            modelId: "gemini-3-pro",
            geminiKey: "gemini-key",
            reasoningEnabled: true,
            reasoningEffort: .minimal
        )
        let proMedium = makeContext(
            modelId: "gemini-3-pro",
            geminiKey: "gemini-key",
            reasoningEnabled: true,
            reasoningEffort: .medium
        )
        let disabledContext = makeContext(
            modelId: "gemini-3-pro",
            geminiKey: "gemini-key",
            reasoningEnabled: false,
            reasoningEffort: .high
        )

        let proMinimalBody = try requestBody(from: try GeminiClient().makeRequest(with: proMinimal))
        let proMediumBody = try requestBody(from: try GeminiClient().makeRequest(with: proMedium))
        let disabledBody = try requestBody(from: try GeminiClient().makeRequest(with: disabledContext))

        let proMinimalConfig = proMinimalBody["generationConfig"] as? [String: Any]
        let proMediumConfig = proMediumBody["generationConfig"] as? [String: Any]
        let disabledConfig = disabledBody["generationConfig"] as? [String: Any]

        let proMinimalThinking = proMinimalConfig?["thinking_config"] as? [String: Any]
        let proMediumThinking = proMediumConfig?["thinking_config"] as? [String: Any]
        let disabledThinking = disabledConfig?["thinking_config"] as? [String: Any]

        let proMinimalLevel = proMinimalThinking?["thinkingLevel"] as? String
        let proMediumLevel = proMediumThinking?["thinkingLevel"] as? String
        let disabledLevel = disabledThinking?["thinkingLevel"] as? String
        let proMinimalIncludesThoughts = proMinimalThinking?["include_thoughts"] as? Bool
        let proMediumIncludesThoughts = proMediumThinking?["include_thoughts"] as? Bool

        #expect(proMinimalLevel == "low")
        #expect(proMediumLevel == "high")
        #expect(disabledLevel == "low")
        #expect(proMinimalIncludesThoughts == true)
        #expect(proMediumIncludesThoughts == true)
    }

    @Test func providerDetectionCoversUpdatedModelFamilies() {
        #expect(LLMProvider.provider(forModelId: "gpt-5.2") == .openai)
        #expect(LLMProvider.provider(forModelId: "gpt-5.2-mini") == .openai)
        #expect(LLMProvider.provider(forModelId: "gpt-5.3-codex") == .openai)
        #expect(LLMProvider.provider(forModelId: "codex-mini-latest") == .openai)
        #expect(LLMProvider.provider(forModelId: "claude-sonnet-4.6") == .claude)
        #expect(LLMProvider.provider(forModelId: "gemini-3-pro") == .gemini)
        #expect(LLMProvider.provider(forModelId: "grok-4.1") == .xai)
        #expect(LLMProvider.provider(forModelId: "grok-4-fast") == .xai)
        #expect(LLMProvider.provider(forModelId: "kimi-k2.5") == .moonshot)
        #expect(LLMProvider.provider(forModelId: "unknown-model") == nil)
        #expect(LLMProvider.provider(forModelId: "") == nil)
        #expect(LLMProvider.provider(forModelId: "   ") == nil)
    }

    @MainActor @Test func providerTokenCapsMatchUpdatedLimits() {
        #expect(SettingsService.maxTokensOpenAI == 100000)
        #expect(SettingsService.maxTokensAnthropic == 64000)
        #expect(SettingsService.maxTokensGemini == 65536)
        #expect(SettingsService.maxTokensXAI == 131072)
        #expect(SettingsService.maxTokensMoonshot == 262144)
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
        let mixedDictionary = """
        {"id":"pred_4","status":"succeeded","output":{"audio":"https://example.com/4.wav","duration":1.75}}
        """.data(using: .utf8)!
        let nestedArrayObject = """
        {"id":"pred_5","status":"succeeded","output":[{"metadata":"ignored","url":"https://example.com/5.wav"}]}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        #expect(try decoder.decode(ReplicateTTSResponse.self, from: single).outputURL == "https://example.com/1.wav")
        #expect(try decoder.decode(ReplicateTTSResponse.self, from: array).outputURL == "https://example.com/2.wav")
        #expect(try decoder.decode(ReplicateTTSResponse.self, from: dictionary).outputURL == "https://example.com/3.wav")
        #expect(try decoder.decode(ReplicateTTSResponse.self, from: mixedDictionary).outputURL == "https://example.com/4.wav")
        #expect(try decoder.decode(ReplicateTTSResponse.self, from: nestedArrayObject).outputURL == "https://example.com/5.wav")
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
        let bodyData = Data("{\"model\":\"gpt-5.2\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"say \\\"hi\\\"\"}],\"metadata\":{\"attempt\":2,\"flags\":[true,false,null]}}".utf8)
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
        #expect(((payload["bodyData"] as? [String: Any])?["messages"] as? [[String: String]])?.first?["content"] == "say \"hi\"")
        #expect(((payload["bodyData"] as? [String: Any])?["metadata"] as? [String: Any])?["attempt"] as? Int == 2)

        #expect((try? JSONSerialization.jsonObject(with: payloadData)) != nil)
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
        anthropicKey: String? = nil,
        geminiKey: String? = nil,
        messages: [ChatMessage] = [ChatMessage(id: UUID(), role: "user", content: "hello")],
        systemPrompt: String? = "You are helpful",
        temperature: Float = 0.8,
        maxTokens: Int = 4096,
        webSearchEnabled: Bool = false,
        reasoningEnabled: Bool = false,
        reasoningEffort: ReasoningEffort = .high,
        useProxy: Bool = false
    ) -> LLMClientContext {
        LLMClientContext(
            messages: messages,
            systemPrompt: systemPrompt,
            temperature: temperature,
            maxTokens: maxTokens,
            modelId: modelId,
            temperatureCap: 2.0,
            tokenCap: 8192,
            openAIKey: openAIKey,
            xaiKey: xaiKey,
            moonshotKey: moonshotKey,
            anthropicKey: anthropicKey,
            geminiKey: geminiKey,
            webSearchEnabled: webSearchEnabled,
            reasoningEffort: reasoningEffort,
            reasoningEnabled: reasoningEnabled,
            useProxy: useProxy
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
