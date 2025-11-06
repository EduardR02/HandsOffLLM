// ChatService.swift
import Foundation
import OSLog
import Combine

@MainActor
class ChatService: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatService")
    
    // --- Published State ---
    @Published var currentConversation: Conversation?
    @Published var isProcessingLLM: Bool = false // True while fetching/streaming LLM response
    
    // --- Combine Subjects for Communication ---
    let llmChunkSubject = PassthroughSubject<String, Never>()    // Sends LLM text chunks
    let llmErrorSubject = PassthroughSubject<Error, Never>()      // Reports LLM errors
    let llmCompleteSubject = PassthroughSubject<Void, Never>()   // Signals end of LLM stream
    
    // --- Internal State ---
    private var llmTask: Task<Void, Never>? = nil
    private var activeSession: URLSession? // Track active session for cancellation
    private var currentFullResponse: String = ""
    private var isLLMStreamComplete: Bool = false // ← New flag

    // --- Dependencies ---
    private let settingsService: SettingsService
    private var historyService: HistoryService? // Add HistoryService (optional for now)
    private let proxyService: ProxyService
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // 2 minutes
        config.timeoutIntervalForResource = 300 // 5 minutes
        return URLSession(configuration: config)
    }()

    var activeConversationId: UUID? { currentConversation?.id }

    init(settingsService: SettingsService, historyService: HistoryService? = nil, authService: AuthService) {
        self.settingsService = settingsService
        self.historyService = historyService
        self.proxyService = ProxyService(authService: authService, settingsService: settingsService)
        // Start with a new conversation context
        resetConversationContext()
    }
    
    // MARK: - Public Interaction
    func processTranscription(_ transcription: String, provider: LLMProvider) {
        guard !isProcessingLLM else {
            logger.warning("processTranscription called while already processing.")
            return
        }
        // If there's no active conversation, create a new one before proceeding.
        if activeConversationId == nil { // Use the public getter now
            logger.info("No active conversation context found. Creating a new one.")
            resetConversationContext()
            // activeConversationId should now be non-nil after resetConversationContext runs
            guard currentConversation != nil else {
                logger.error("Failed to create a conversation context.")
                return
            }
        }
        
        let userMessage = ChatMessage(id: UUID(), role: "user", content: transcription)
        appendMessageAndUpdateHistory(userMessage) // Use helper to add and save
        
        logger.info("⚙️ Processing transcription with \(provider.rawValue): '\(transcription)'")
        isProcessingLLM = true
        currentFullResponse = "" // Reset accumulator
        isLLMStreamComplete = false // ← Reset flag

        // Start the LLM fetch task
        llmTask = Task { [weak self] in
            guard let self = self else { return }
            await self.fetchLLMResponse(provider: provider)
        }
    }
    
    func appendMessageWithoutProcessing(_ message: ChatMessage) {
        // Append message to chat but don't trigger LLM processing
        // Used for old-session transcriptions that arrive after interrupt
        if activeConversationId == nil {
            logger.info("No active conversation context found. Creating a new one.")
            resetConversationContext()
            guard currentConversation != nil else {
                logger.error("Failed to create a conversation context.")
                return
            }
        }
        appendMessageAndUpdateHistory(message)
        logger.info("Appended message without triggering LLM: '\(message.content)'")
    }

    func cancelProcessing() {
        logger.notice("⏹️ LLM Processing cancellation requested.")

        // Cancel active network session to immediately stop HTTP requests
        activeSession?.invalidateAndCancel()
        activeSession = nil

        // Cancel the processing task
        llmTask?.cancel()
        llmTask = nil
        isProcessingLLM = false
    }
    
    // MARK: - LLM Fetching Logic
    private func fetchLLMResponse(provider: LLMProvider) async {
        var llmError: Error? = nil

        guard currentConversation != nil else {
            logger.error("Cannot fetch LLM response without an active conversation.")
            handleLLMCompletion(error: LlmError.streamingError("No active conversation."))
            return
        }

        do {
            // --- Get ACTIVE settings ---
            guard let activeModelId = settingsService.activeModelId(for: provider) else {
                throw LlmError.apiKeyMissing(provider: "\(provider.rawValue) model selection")
            }
            let activeSystemPrompt = settingsService.activeSystemPromptWithUserProfile
            let activeTemperature = settingsService.activeTemperature
            let activeMaxTokens = settingsService.activeMaxTokens
            // --- End Get ACTIVE settings ---

            let limits = providerLimits(for: provider)
            let useProxy = proxyService.shouldUseProxy(for: provider)
            let context = LLMClientContext(
                messages: sanitizedHistory(),
                systemPrompt: activeSystemPrompt,
                temperature: activeTemperature,
                maxTokens: activeMaxTokens,
                modelId: activeModelId,
                temperatureCap: limits.temperature,
                tokenCap: limits.maxTokens,
                openAIKey: settingsService.openaiAPIKey,
                xaiKey: settingsService.xaiAPIKey,
                anthropicKey: settingsService.anthropicAPIKey,
                geminiKey: settingsService.geminiAPIKey,
                webSearchEnabled: settingsService.webSearchEnabled,
                openAIReasoningEffort: settingsService.openAIReasoningEffortOpt,
                claudeReasoningEnabled: settingsService.claudeReasoningEnabled,
                useProxy: useProxy
            )
            let client = LLMClientFactory.client(for: provider)

            // Determine if we should use proxy or direct call
            let request: URLRequest
            if useProxy {
                // Route through Supabase proxy
                logger.info("Routing \(provider.rawValue) request through proxy")
                let directRequest = try client.makeRequest(with: context)

                // Extract endpoint, headers, and body from the direct request
                guard let url = directRequest.url else {
                    throw LlmError.streamingError("Invalid request URL")
                }

                var headers: [String: String] = [:]
                directRequest.allHTTPHeaderFields?.forEach { headers[$0.key] = $0.value }

                var body: [String: Any] = [:]
                if let httpBody = directRequest.httpBody,
                   let jsonBody = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] {
                    body = jsonBody
                }

                request = try await proxyService.makeProxiedRequest(
                    provider: provider,
                    endpoint: url.absoluteString,
                    method: directRequest.httpMethod ?? "POST",
                    headers: headers,
                    body: body
                )
            } else {
                // Direct call with user's own API key
                logger.info("Using direct \(provider.rawValue) API call with user's key")
                request = try client.makeRequest(with: context)
            }

            let stream = try await makeStream(request: request, decoder: client.decodeChunk)

            // 1) insert one placeholder (no save - will be saved when completed)
            let placeholder = ChatMessage(id: UUID(), role: "assistant_partial", content: "")
            currentConversation?.messages.append(placeholder)

            // 2) pull off the stream until end or cancellation
            for try await chunk in stream {
                try Task.checkCancellation()      // throws CancellationError on cancelProcessing()
                currentFullResponse.append(chunk)
                llmChunkSubject.send(chunk)
            }

        } catch {
            llmError = error
            if !(error is CancellationError) {
                logger.error("🚨 LLM Error (\(provider.rawValue)): \(error.localizedDescription)")
                llmErrorSubject.send(error)
            }
        }

        // If the Task itself was cancelled, force a CancellationError
        isLLMStreamComplete = true
        let errorToHandle: Error? = Task.isCancelled ? CancellationError() : llmError
        handleLLMCompletion(error: errorToHandle)
    }
    
    private func handleLLMCompletion(error: Error?) {
        isProcessingLLM = false

        // Find & update the one assistant_partial placeholder
        guard var conversation = currentConversation,
              let idx = conversation.messages.lastIndex(where: { $0.role == "assistant_partial" })
        else { return }

        var msg = conversation.messages[idx]
        if let err = error {
            msg.role = (err is CancellationError) ? "assistant_partial" : "assistant_error"
        } else {
            msg.role = "assistant"
        }
        msg.content = currentFullResponse
        conversation.messages[idx] = msg
        currentConversation = conversation

        Task { // Ensure historyService call is within a Task for await
            await historyService?.addOrUpdateConversation(conversation)
        }

        if let err = error {
            if err is CancellationError {
                logger.notice("LLM stream cancelled; keeping existing loop state.")
            }
        } else {
            llmCompleteSubject.send()
        }
    }
    
    // MARK: - Unified SSE & Decoding Helpers
    private func makeStream(request: URLRequest, decoder: @escaping (String) -> String?) async throws -> AsyncThrowingStream<String, Error> {
        // Create a dedicated session for this request to enable explicit cancellation
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // 2 minutes
        config.timeoutIntervalForResource = 300 // 5 minutes
        let session = URLSession(configuration: config)
        activeSession = session

        let (bytesSequence, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errorData = Data()
            for try await byte in bytesSequence {
                errorData.append(byte)
            }
            let errorBody = String(data: errorData, encoding: .utf8) ?? "<non-utf8 body>"
            logger.error("❌ HTTP Error : \(errorBody)")
            throw LlmError.invalidResponse(statusCode: http.statusCode, body: errorBody)
        } else if !(response is HTTPURLResponse) {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var buffer = Data()
                    for try await b in bytesSequence {
                        try Task.checkCancellation()
                        buffer.append(b)
                        if b == UInt8(ascii: "\n") {
                            guard let text = String(data: buffer, encoding: .utf8) else { buffer.removeAll(); continue }
                            if text.hasPrefix("data:") {
                                let payload = text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                                if let chunk = decoder(payload) {
                                    continuation.yield(chunk)
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Chat Title Generation
    
    private struct TitleGenerationConfig {
        static let model = "grok-4-fast-non-reasoning"
        static let temperature: Float = 0.5
        static let maxTokens = 50
        static let systemPrompt = """
            You generate concise titles for chat conversations. The title will be displayed in a list to help users identify and find their chats later.
            
            Your task: Create a short, descriptive title (2-6 words) that captures the main topic or intent of the user's message.
            
            CRITICAL RULES:
            - Output ONLY the title text
            - Do NOT answer the user's question
            - Do NOT add quotes, punctuation, or explanations
            - Do NOT prefix with "Title:" or similar
            
            Examples:
            User: "How do I reset my iPhone?" → iPhone Reset Guide
            User: "What's the weather like in Tokyo?" → Tokyo Weather Inquiry
            User: "Can you help me write a resume?" → Resume Writing Help
            """
    }
    
    private func makeNonStreamingXAIRequest(modelId: String, systemPrompt: String, userMessage: String, temperature: Float, maxTokens: Int) async throws -> String {
        let messagesPayload: [[String: Any]] = [
            ["role": "system", "content": [["type": "text", "text": systemPrompt]]],
            ["role": "user", "content": [["type": "text", "text": userMessage]]]
        ]

        let requestBody: [String: Any] = [
            "model": modelId,
            "messages": messagesPayload,
            "temperature": temperature,
            "max_completion_tokens": maxTokens,
            "stream": false
        ]

        let req: URLRequest
        if proxyService.shouldUseProxy(for: .xai) {
            // Route through proxy
            req = try await proxyService.makeProxiedRequest(
                provider: .xai,
                endpoint: "https://api.x.ai/v1/chat/completions",
                method: "POST",
                headers: ["Content-Type": "application/json"],
                body: requestBody
            )
        } else {
            // Direct call with user's key
            guard let key = settingsService.xaiAPIKey, !key.isEmpty else {
                throw LlmError.apiKeyMissing(provider: "xAI")
            }

            guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
                throw LlmError.invalidURL
            }

            var directReq = URLRequest(url: url)
            directReq.httpMethod = "POST"
            directReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
            directReq.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            directReq.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            req = directReq
        }

        // Use urlSession with 120s timeout (configured in lazy var)
        let (data, response) = try await urlSession.data(for: req)
        
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw LlmError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: errorBody)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LlmError.responseDecodingError(NSError(domain: "ChatService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse xAI response"]))
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func generateChatTitle(for userMessage: String) async -> String {
        do {
            return try await makeNonStreamingXAIRequest(
                modelId: TitleGenerationConfig.model,
                systemPrompt: TitleGenerationConfig.systemPrompt,
                userMessage: userMessage,
                temperature: TitleGenerationConfig.temperature,
                maxTokens: TitleGenerationConfig.maxTokens
            )
        } catch {
            logger.warning("LLM title generation failed: \(error.localizedDescription). Using fallback.")
            return generateFallbackTitle(for: userMessage)
        }
    }

    /// Public method to generate a title for an existing conversation
    public func generateTitleForConversation(conversationId: UUID) async -> String? {
        guard let conversation = await historyService?.loadConversationDetail(id: conversationId) else {
            logger.warning("Failed to load conversation \(conversationId) for title generation")
            return nil
        }

        // Get the first user message
        guard let firstUserMessage = conversation.messages.first(where: { $0.role == "user" }) else {
            logger.warning("No user message found in conversation \(conversationId)")
            return nil
        }

        return await generateChatTitle(for: firstUserMessage.content)
    }
    
    private func generateFallbackTitle(for userMessage: String) -> String {
        let words = userMessage.split(separator: " ").prefix(5)
        return words.joined(separator: " ")
    }

    private func applyGeneratedTitle(_ title: String, to conversationId: UUID) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard var conversation = currentConversation, conversation.id == conversationId else {
            return
        }

        conversation.title = trimmed
        currentConversation = conversation

        // Save with in-memory conversation (no disk load needed)
        await historyService?.addOrUpdateConversation(conversation, updateTimestamp: false)
    }

    // MARK: - Conversation Management
    func resetConversationContext(
        messagesToLoad: [ChatMessage]? = nil,
        existingConversationId: UUID? = nil,
        parentId: UUID? = nil,
        initialAudioPaths: [UUID: [String]]? = nil,
        initialTitle: String? = nil
    ) {
        logger.info("Resetting conversation context. Loading messages: \(messagesToLoad?.count ?? 0). Existing ID: \(existingConversationId?.uuidString ?? "New"). Parent ID: \(parentId?.uuidString ?? "None"). Initial Paths: \(initialAudioPaths?.count ?? 0). Title: \(initialTitle ?? "None")")

        // Cancel any in-flight LLM processing
        cancelProcessing()
        isLLMStreamComplete = false

        // Seed a usable conversation immediately so callers can append safely.
        var seededConversation = Conversation(
            id: existingConversationId ?? UUID(),
            messages: messagesToLoad ?? [],
            createdAt: Date(),
            parentConversationId: parentId,
            ttsAudioPaths: initialAudioPaths
        )
        seededConversation.title = initialTitle
        currentConversation = seededConversation

        guard let existingId = existingConversationId else { return }

        // If we were asked to revive an existing conversation, load it in the background
        Task { @MainActor [weak self] in
            guard let self = self,
                  let loadedConv = await self.historyService?.loadConversationDetail(id: existingId) else { return }

            var conversationToSet = loadedConv
            if let messages = messagesToLoad {
                conversationToSet.messages = messages
            }
            if let audioPaths = initialAudioPaths {
                conversationToSet.ttsAudioPaths = audioPaths
            }
            if let title = initialTitle {
                conversationToSet.title = title
            }
            self.currentConversation = conversationToSet
        }
    }
    
    // --- Update message handling ---
    private func appendMessageAndUpdateHistory(_ message: ChatMessage) {
        guard currentConversation != nil else {
            logger.error("Cannot append message: currentConversation is nil. This should never happen.")
            return
        }

        currentConversation?.messages.append(message)
        
        // Generate LLM-based title after first user message (async, non-blocking)
        if let conversation = currentConversation,
           conversation.title == nil,
           message.role == "user",
           conversation.messages.count == 1 {
            let conversationId = conversation.id
            Task { [weak self] in
                guard let self = self else { return }
                let generatedTitle = await self.generateChatTitle(for: message.content)
                await self.applyGeneratedTitle(generatedTitle, to: conversationId)
            }
        }
        
        // Persist intermediate state (e.g., user messages, partial assistant messages)
        if let conversationToSave = currentConversation {
            // logger.debug("Saving intermediate conversation state in appendMessageAndUpdateHistory for message role \(message.role)")
            Task {
                await historyService?.addOrUpdateConversation(conversationToSave)
            }
        }
    }
    
    // --- NEW: Method to update audio paths in local state ---
    func updateAudioPathInCurrentConversation(messageID: UUID, path: String) {
        guard var conversation = currentConversation else {
            logger.error("Cannot add audio path: currentConversation is nil. This should never happen.")
            return
        }

        guard conversation.messages.contains(where: { $0.id == messageID }) else {
            logger.warning("Attempted to add audio path for message \(messageID) not found in current conversation \(conversation.id).")
            return
        }

        var map = conversation.ttsAudioPaths ?? [:]
        var paths = map[messageID] ?? []
        if !paths.contains(path) { paths.append(path) }
        map[messageID] = paths
        conversation.ttsAudioPaths = map
        currentConversation = conversation
        logger.info("Added audio path '\(path)' for message \(messageID).")

        // Trigger final save if LLM is done AND this path is for the last message
        if isLLMStreamComplete, let lastMessage = conversation.messages.last, lastMessage.id == messageID {
            Task {
                await historyService?.addOrUpdateConversation(conversation)
            }
        }
    }
    
    deinit {
        logger.info("ChatService deinit.")
        llmTask?.cancel()
    }

    private func sanitizedHistory() -> [ChatMessage] {
        currentConversation?.messages.filter { $0.role == "user" || $0.role == "assistant" } ?? []
    }

    private func providerLimits(for provider: LLMProvider) -> (temperature: Float, maxTokens: Int) {
        switch provider {
        case .openai:
            return (SettingsService.maxTempOpenAI, SettingsService.maxTokensOpenAI)
        case .claude:
            return (SettingsService.maxTempAnthropic, SettingsService.maxTokensAnthropic)
        case .gemini:
            return (SettingsService.maxTempGemini, SettingsService.maxTokensGemini)
        case .xai:
            return (SettingsService.maxTempXAI, SettingsService.maxTokensXAI)
        case .replicate:
            return (2.0, 4096) // Replicate is TTS-only, not used for LLM
        }
    }
}

struct LLMClientContext {
    let messages: [ChatMessage]
    let systemPrompt: String?
    let temperature: Float
    let maxTokens: Int
    let modelId: String
    let temperatureCap: Float
    let tokenCap: Int
    let openAIKey: String?
    let xaiKey: String?
    let anthropicKey: String?
    let geminiKey: String?
    let webSearchEnabled: Bool
    let openAIReasoningEffort: OpenAIReasoningEffort?
    let claudeReasoningEnabled: Bool
    let useProxy: Bool
}

protocol LLMClient {
    func makeRequest(with context: LLMClientContext) throws -> URLRequest
    func decodeChunk(_ raw: String) -> String?
}

struct OpenAIClient: LLMClient {
    func makeRequest(with context: LLMClientContext) throws -> URLRequest {
        let useProxy = context.useProxy
        let trimmedKey = context.openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !useProxy {
            guard let key = trimmedKey, !key.isEmpty else {
                throw LlmError.apiKeyMissing(provider: "OpenAI")
            }
        }
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw LlmError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !useProxy, let key = trimmedKey {
            req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let inputPayload = context.messages.map { msg -> [String: Any] in
            let type = (msg.role == "assistant") ? "output_text" : "input_text"
            return [
                "role": msg.role,
                "content": [["type": type, "text": msg.content]]
            ]
        }

        var body: [String: Any] = [
            "model": context.modelId,
            "input": inputPayload,
            "stream": true,
            "temperature": min(context.temperature, context.temperatureCap),
            "max_output_tokens": min(context.maxTokens, context.tokenCap)
        ]

        if context.webSearchEnabled,
           ["gpt-4.1", "gpt-4.1-mini", "gpt-5"].contains(where: context.modelId.contains) {
            body["tools"] = [["type": "web_search_preview"]]
        }

        if let sys = context.systemPrompt, !sys.isEmpty {
            body["instructions"] = sys
        }

        if context.modelId.contains("gpt-5"),
           let effort = context.openAIReasoningEffort {
            body["reasoning"] = ["effort": effort.rawValue]
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    func decodeChunk(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONDecoder().decode(OpenAIResponseEvent.self, from: data),
              event.type == "response.output_text.delta"
        else { return nil }
        return event.delta
    }
}

struct XAIClient: LLMClient {
    func makeRequest(with context: LLMClientContext) throws -> URLRequest {
        let useProxy = context.useProxy
        let trimmedKey = context.xaiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !useProxy {
            guard let key = trimmedKey, !key.isEmpty else {
                throw LlmError.apiKeyMissing(provider: "xAI")
            }
        }
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            throw LlmError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !useProxy, let key = trimmedKey {
            req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        var messagesPayload: [[String: Any]] = context.messages.map { message in
            [
                "role": message.role,
                "content": [["type": "text", "text": message.content]]
            ]
        }

        if let sys = context.systemPrompt, !sys.isEmpty {
            messagesPayload.insert([
                "role": "system",
                "content": [["type": "text", "text": sys]]
            ], at: 0)
        }

        var requestBody: [String: Any] = [
            "model": context.modelId,
            "messages": messagesPayload,
            "temperature": min(context.temperature, context.temperatureCap),
            "max_completion_tokens": min(context.maxTokens, context.tokenCap),
            "stream": true,
            "stream_options": ["include_usage": true]
        ]

        if context.webSearchEnabled, context.modelId.contains("grok-4") {
            requestBody["search_parameters"] = ["mode": "auto"]
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        return req
    }

    func decodeChunk(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONDecoder().decode(XAIResponseEvent.self, from: data) else { return nil }
        guard let choices = event.choices, let delta = choices.first?.delta else {
            return nil
        }
        return delta.content
    }
}

struct ClaudeClient: LLMClient {
    func makeRequest(with context: LLMClientContext) throws -> URLRequest {
        let useProxy = context.useProxy
        let trimmedKey = context.anthropicKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !useProxy {
            guard let key = trimmedKey, !key.isEmpty else {
                throw LlmError.apiKeyMissing(provider: "Claude")
            }
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LlmError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !useProxy, let key = trimmedKey {
            req.addValue(key, forHTTPHeaderField: "x-api-key")
        }
        req.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var messagesPayload: [[String: Any]] = context.messages.map { message in
            ["role": message.role, "content": [["type": "text", "text": message.content]]]
        }

        if !messagesPayload.isEmpty {
            var last = messagesPayload.removeLast()
            if var contentArray = last["content"] as? [[String: Any]] {
                contentArray[0]["cache_control"] = ["type": "ephemeral"]
                last["content"] = contentArray
            }
            messagesPayload.append(last)
        }

        let canThink = context.modelId.contains("sonnet-4") || context.modelId.contains("opus-4")
        let isThinking = canThink && context.claudeReasoningEnabled

        var payload: [String: Any] = [
            "model": context.modelId,
            "messages": messagesPayload,
            "max_tokens": min(context.maxTokens, context.tokenCap),
            "stream": true
        ]

        if let sys = context.systemPrompt, !sys.isEmpty {
            payload["system"] = sys
        }
        if !isThinking {
            payload["temperature"] = min(context.temperature, context.temperatureCap)
        }
        if isThinking {
            let thinkingBudget = max(1024, context.maxTokens - 4000)
            payload["thinking"] = [
                "type": "enabled",
                "budget_tokens": thinkingBudget
            ]
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    func decodeChunk(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONDecoder().decode(ClaudeEvent.self, from: data),
              (event.type == "content_block_delta" || event.type == "message_delta"),
              let text = event.delta?.text
        else { return nil }
        return text
    }
}

struct GeminiClient: LLMClient {
    func makeRequest(with context: LLMClientContext) throws -> URLRequest {
        let useProxy = context.useProxy
        let trimmedKey = context.geminiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !useProxy {
            guard let key = trimmedKey, !key.isEmpty else {
                throw LlmError.apiKeyMissing(provider: "Gemini")
            }
        }
        let apiVersion = "v1beta"
        let responseType = "streamGenerateContent"
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/\(apiVersion)/models/\(context.modelId):\(responseType)")
        var queryItems = [URLQueryItem(name: "alt", value: "sse")]
        if !useProxy, let key = trimmedKey {
            queryItems.append(URLQueryItem(name: "key", value: key))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw LlmError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let contents = context.messages.map { message in
            [
                "role": message.role == "user" ? "user" : "model",
                "parts": [["text": message.content]]
            ]
        }

        var generationConfig: [String: Any] = [
            "temperature": min(context.temperature, context.temperatureCap),
            "maxOutputTokens": min(context.maxTokens, context.tokenCap),
            "responseMimeType": "text/plain"
        ]
        if context.modelId.contains("2.5-flash") {
            generationConfig["thinking_config"] = ["thinkingBudget": 0]
        }

        var body: [String: Any] = [
            "contents": contents,
            "safetySettings": GeminiClient.safetySettings(),
            "generationConfig": generationConfig
        ]

        if let sys = context.systemPrompt, !sys.isEmpty {
            body["systemInstruction"] = ["parts": [["text": sys]]]
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    func decodeChunk(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let response = try? JSONDecoder().decode(GeminiResponse.self, from: data),
              let text = response.candidates?.first?.content?.parts?.first?.text
        else { return nil }
        return text
    }

    private static func safetySettings() -> [[String: String]] {
        [
            ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
            ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
            ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
            ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
        ]
    }
}

struct LLMClientFactory {
    static func client(for provider: LLMProvider) -> LLMClient {
        switch provider {
        case .openai:
            return OpenAIClient()
        case .claude:
            return ClaudeClient()
        case .gemini:
            return GeminiClient()
        case .xai:
            return XAIClient()
        case .replicate:
            return OpenAIClient() // Replicate is TTS-only, fallback to OpenAI client
        }
    }
}
