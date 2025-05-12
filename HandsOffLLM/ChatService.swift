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
    private var currentFullResponse: String = ""
    private var isLLMStreamComplete: Bool = false // ← New flag
    
    // --- Dependencies ---
    private let settingsService: SettingsService
    private var historyService: HistoryService? // Add HistoryService (optional for now)
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default)
    }()
    
    var activeConversationId: UUID? { currentConversation?.id }
    
    init(settingsService: SettingsService, historyService: HistoryService? = nil) {
        self.settingsService = settingsService
        self.historyService = historyService
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
    
    func cancelProcessing() {
        logger.notice("⏹️ LLM Processing cancellation requested.")
        llmTask?.cancel()
        llmTask = nil
        isProcessingLLM = false
    }
    
    // MARK: - LLM Fetching Logic
    private func fetchLLMResponse(provider: LLMProvider) async {
        var llmError: Error? = nil
        let providerString = provider.rawValue
        
        guard currentConversation != nil else {
            logger.error("Cannot fetch LLM response without an active conversation.")
            llmError = LlmError.streamingError("No active conversation.")
            handleLLMCompletion(error: llmError)
            return
        }
        
        do {
            // --- Get ACTIVE settings ---
            guard let activeModelId = settingsService.activeModelId(for: provider) else {
                throw LlmError.apiKeyMissing(provider: "\(provider.rawValue) model selection") // Reuse error or create new one
            }
            let activeSystemPrompt = settingsService.activeSystemPrompt
            let activeTemperature = settingsService.activeTemperature
            let activeMaxTokens = settingsService.activeMaxTokens
            // --- End Get ACTIVE settings ---
            
            // 1. Build request and unified stream
            let request = try buildRequest(for: provider,
                                           modelId: activeModelId,
                                           systemPrompt: activeSystemPrompt,
                                           temperature: activeTemperature,
                                           maxTokens: activeMaxTokens)
            let stream = try await makeStream(for: provider, request: request)
            
            var firstChunkReceived = false
            // 2. Process the stream
            for try await chunk in stream {
                try Task.checkCancellation() // Check if cancellation was requested
                
                if !firstChunkReceived {
                    logger.info("🤖 Received first LLM chunk (\(providerString)).")
                    firstChunkReceived = true
                    // Add assistant_partial message placeholder immediately
                    let partialMsg = ChatMessage(id: UUID(), role: "assistant_partial", content: "")
                    if currentConversation?.messages.last?.role != "assistant_partial" && currentConversation?.messages.last?.role != "assistant_error" {
                        appendMessageAndUpdateHistory(partialMsg)
                    }
                }
                
                currentFullResponse.append(chunk) // Accumulate full response
                
                if var lastMessage = currentConversation?.messages.last, lastMessage.role == "assistant_partial" {
                    lastMessage.content = currentFullResponse
                    currentConversation?.messages[currentConversation!.messages.count - 1] = lastMessage
                }
                
                llmChunkSubject.send(chunk)     // Send chunk for immediate TTS processing
            }
            // 3. Stream finished successfully
            logger.info("🤖 LLM stream completed successfully (\(providerString)).")
            
        } catch let error {
            if error is CancellationError {
                logger.notice("⏹️ LLM Task Cancelled.")
            } else {
                logger.error("🚨 LLM Error (\(providerString)): \(error.localizedDescription)")
                llmErrorSubject.send(error)
            }
            llmError = error
        }
        
        // 4. Cleanup and Final State Update
        handleLLMCompletion(error: llmError)
    }
    
    private func handleLLMCompletion(error: Error?) {
        isProcessingLLM = false
        
        // Log final response if successful or partially successful
        if !currentFullResponse.isEmpty {
            logger.info("🤖 LLM full response processed (\(self.currentFullResponse.count) chars). Error: \(error?.localizedDescription ?? "None")")
            logger.info("------ LLM FINAL RESPONSE ------\n\(self.currentFullResponse)\n----------------------")
        } else if error == nil {
            logger.info("🤖 LLM response was empty.")
        } else if !(error is CancellationError) {
            logger.error("🚨 LLM fetch failed completely. Error: \(error!.localizedDescription)")
        }
        
        // Update the final assistant message in the history
        if !currentFullResponse.isEmpty {
            let messageRole = error == nil ? "assistant" : (error is CancellationError ? "assistant_partial" : "assistant_error")
            
            if var conversation = currentConversation,
               let lastMsgIndex = conversation.messages.lastIndex(where: { $0.role == "assistant_partial" }) {
                
                // Update the message directly in the currentConversation
                conversation.messages[lastMsgIndex].role = messageRole
                conversation.messages[lastMsgIndex].content = currentFullResponse
                
                // Generate title if needed
                let updatedConv = historyService?.generateTitleIfNeeded(for: conversation) ?? conversation
                currentConversation = updatedConv // Update local state
                
                logger.info("Updated final message in history. Role: \(messageRole). Awaiting final audio path for save.")
                
            } else {
                logger.warning("Could not find partial message to update.")
                let finalMessage = ChatMessage(id: UUID(), role: messageRole, content: currentFullResponse)
                appendMessageAndUpdateHistory(finalMessage) // This already saves
            }
            
        } else if error == nil {
            // Handle empty response case if necessary
            logger.info("🤖 LLM response was empty.")
            // We might still need to save if title generation happened on an earlier message?
            // If the conversation only had a user message and got an empty LLM response,
            // title generation wouldn't run, and no save would occur. Let's ensure a save.
            if let conversationToSave = currentConversation {
                logger.info("Saving conversation state after empty LLM response.")
                historyService?.addOrUpdateConversation(conversationToSave)
            }
        }
        // Error cases don't need a special save here, the state before error is likely saved.
        
        isLLMStreamComplete = true
        llmCompleteSubject.send()
    }
    
    // MARK: - Unified SSE & Decoding Helpers
    private func makeStream(for provider: LLMProvider, request: URLRequest) async throws -> AsyncThrowingStream<String, Error> {
        let (bytesSequence, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let (data, _) = try await urlSession.data(for: request)
            let errorBody = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            logger.error("❌ HTTP Error : \(errorBody)")
            throw LlmError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: errorBody)
        }
        let decode = sseDecoders[provider]!
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
                                if let chunk = decode(payload) {
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

    // MARK: - Request Builders

    /// Build URLRequest for the given provider
    private func buildRequest(for provider: LLMProvider,
                              modelId: String,
                              systemPrompt: String?,
                              temperature: Float,
                              maxTokens: Int) throws -> URLRequest {
        switch provider {
        case .gemini:
            return try makeGeminiRequest(modelId: modelId, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        case .claude:
            return try makeClaudeRequest(modelId: modelId, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        case .openai:
            return try makeOpenAIRequest(modelId: modelId, systemPrompt: systemPrompt, temperature: temperature, maxTokens: maxTokens)
        }
    }

    /// Construct OpenAI /v1/responses request
    private func makeOpenAIRequest(modelId: String, systemPrompt: String?, temperature: Float, maxTokens: Int) throws -> URLRequest {
        guard let key = settingsService.openaiAPIKey, !key.isEmpty else {
            throw LlmError.apiKeyMissing(provider: "OpenAI")
        }
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw LlmError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Prepare input messages with input_text/output_text content
        let input = currentConversation?.messages.map { msg -> [String: Any] in
            let type = (msg.role == "assistant") ? "output_text" : "input_text"
            return ["role": msg.role, "content": [["type": type, "text": msg.content]]]
        } ?? []

        var body: [String: Any] = [
            "model": modelId,
            "input": input,
            "stream": true,
            "temperature": min(temperature, SettingsService.maxTempOpenAI),
            "max_output_tokens": min(maxTokens, SettingsService.maxTokensOpenAI)
        ]
        // Include web search if enabled and supported model
        if settingsService.webSearchEnabled,
           ["gpt-4.1", "gpt-4.1-mini"].contains(where: modelId.contains) {
            body["tools"] = [["type": "web_search_preview"]]
        }

        // Include instructions if provided
        if let sys = systemPrompt, !sys.isEmpty {
            body["instructions"] = sys
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Construct Anthropic /v1/messages request
    private func makeClaudeRequest(modelId: String, systemPrompt: String?, temperature: Float, maxTokens: Int) throws -> URLRequest {
        guard let key = settingsService.anthropicAPIKey, !key.isEmpty else {
            throw LlmError.apiKeyMissing(provider: "Claude")
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LlmError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue(key, forHTTPHeaderField: "x-api-key")
        req.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Corrected: Transforming [ChatMessage] to [[String: Any]]
        var messagesPayload: [[String: Any]] = currentConversation?.messages.map { message in
            // Explicitly cast to [String: Any] to be able to add cache_control
            return ["role": message.role, "content": message.content] as [String : Any]
        } ?? []
        // Tag last message for ephemeral caching
        if !messagesPayload.isEmpty {
            var last = messagesPayload.removeLast()
            last["cache_control"] = ["type": "ephemeral"]
            messagesPayload.append(last)
        }

        // Thinking not supported
        var payload: [String: Any] = [
            "model": modelId,
            "messages": messagesPayload,
            "max_tokens": min(maxTokens, SettingsService.maxTokensAnthropic),
            "temperature": min(temperature, SettingsService.maxTempAnthropic),
            "stream": true
        ]
        // Include instructions if provided
        if let sys = systemPrompt, !sys.isEmpty {
            payload["system"] = sys
        }


        /* Removed web-search tool for claude for now as claude likes to search wayyy too much even when not necessary, worsening response quality / adherence to system prompt
        // Add web-search tool if enabled and model is compatible
        let webSearchCompatibleModelSubstrings = ["claude-3-7-sonnet", "claude-3-5-sonnet-latest", "claude-3-5-haiku-latest"]
        if settingsService.webSearchEnabled, webSearchCompatibleModelSubstrings.contains(where: { modelId.contains($0) }) {
            payload["tools"] = [
                ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]
            ]
        }
        */

        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// Construct Gemini request with safety and generationConfig
    private func makeGeminiRequest(modelId: String, systemPrompt: String?, temperature: Float, maxTokens: Int) throws -> URLRequest {
        guard let key = settingsService.geminiAPIKey, !key.isEmpty else {
            throw LlmError.apiKeyMissing(provider: "Gemini")
        }
        // Use stable API version for text-only voice app
        let apiVersion = "v1beta"
        let responseType = "streamGenerateContent"
        let urlString = "https://generativelanguage.googleapis.com/\(apiVersion)/models/\(modelId):\(responseType)?alt=sse&key=\(key)"
        guard let url = URL(string: urlString) else { throw LlmError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Prepare contents array (only messages)
        let contents = currentConversation?.messages.map { message in
            [
                "role": message.role == "user" ? "user" : "model",
                "parts": [["text": message.content]]
            ]
        } ?? []

        // Build generationConfig, disabling thinking for flash model
        var generationConfig: [String: Any] = [
            "temperature": min(temperature, SettingsService.maxTempGemini),
            "maxOutputTokens": min(maxTokens, SettingsService.maxTokensGemini),
            "responseMimeType": "text/plain"
        ]
        if modelId.contains("2.5-flash") {
            generationConfig["thinking_config"] = ["thinkingBudget": 0]
        }
        var body: [String: Any] = [
            "contents": contents,
            "safetySettings": getGeminiSafetySettings(),
            "generationConfig": generationConfig
        ]

        if let sys = systemPrompt, !sys.isEmpty {
            body["systemInstruction"] = ["parts": [["text": sys]]]
        }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Provide Gemini safety settings
    private func getGeminiSafetySettings() -> [[String: String]] {
        [
            ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
            ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
            ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
            ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
        ]
    }
    
    // MARK: - SSE Decoding

    /// Decode a raw SSE chunk from Gemini into text
    private func decodeGeminiChunk(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
            let response = try? JSONDecoder().decode(GeminiResponse.self, from: data),
              let text = response.candidates?.first?.content?.parts?.first?.text
        else { return nil }
        return text
    }

    /// Decode a raw SSE chunk from Claude into text
    private func decodeClaudeChunk(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONDecoder().decode(ClaudeEvent.self, from: data),
              (event.type == "content_block_delta" || event.type == "message_delta"),
              let text = event.delta?.text
        else { return nil }
        return text
    }

    /// Decode a raw SSE chunk from OpenAI into text
    private func decodeOpenAIChunk(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
            let event = try? JSONDecoder().decode(OpenAIResponseEvent.self, from: data),
            event.type == "response.output_text.delta"
        else { return nil }
        return event.delta
    }

    /// Map each provider to its SSE decoder
    private lazy var sseDecoders: [LLMProvider: (String) -> String?] = [
        .gemini: decodeGeminiChunk,
        .claude: decodeClaudeChunk,
        .openai: decodeOpenAIChunk
    ]
    
    // MARK: - Conversation Management
    func resetConversationContext(
        messagesToLoad: [ChatMessage]? = nil,
        existingConversationId: UUID? = nil,
        parentId: UUID? = nil,
        initialAudioPaths: [UUID: [String]]? = nil // ← New parameter
    ) {
        logger.info("Resetting conversation context. Loading messages: \(messagesToLoad?.count ?? 0). Existing ID: \(existingConversationId?.uuidString ?? "New"). Parent ID: \(parentId?.uuidString ?? "None"). Initial Paths: \(initialAudioPaths?.count ?? 0)")
        
        // Cancel any in-flight LLM processing
        cancelProcessing()
        isLLMStreamComplete = false
        
        // Perform async load inside Task to keep API sync
        Task { @MainActor in
            var conversationToSet: Conversation?
            
            if let existingId = existingConversationId {
                if let loadedConv = await historyService?.loadConversationDetail(id: existingId) {
                    conversationToSet = loadedConv
                }
            }
            
            // Overwrite messages if provided
            if let messages = messagesToLoad {
                conversationToSet?.messages = messages
            }
            
            // Inject audio paths if provided
            if let audioPaths = initialAudioPaths {
                conversationToSet?.ttsAudioPaths = audioPaths
            }
            
            if conversationToSet == nil {
                conversationToSet = Conversation(
                    id: UUID(),
                    messages: messagesToLoad ?? [],
                    createdAt: Date(),
                    parentConversationId: parentId,
                    ttsAudioPaths: initialAudioPaths
                )
            }
            currentConversation = conversationToSet
        }
    }
    
    // --- Update message handling ---
    private func appendMessageAndUpdateHistory(_ message: ChatMessage) {
        // Check if conversation is nil and attempt recovery first
        if currentConversation == nil {
            logger.error("Critical error: Tried to append message but currentConversation is nil. Attempting recovery.")
            resetConversationContext()
            // Check *again* after attempting recovery
            guard currentConversation != nil else {
                logger.error("Recovery failed: Could not create a conversation context after reset.")
                return // Exit if recovery failed
            }
            logger.warning("appendMessageAndUpdateHistory: Recovered by creating new context.")
            // If recovery succeeded, execution continues below
        }
        
        // Now we are sure currentConversation is non-nil
        // Append directly to the @Published property's messages
        currentConversation?.messages.append(message)
        
        // Generate title if needed (operates on the @Published property)
        if var conversation = currentConversation, conversation.title == nil && conversation.messages.count > 1 {
            let updatedConv = historyService?.generateTitleIfNeeded(for: conversation) ?? conversation
            if updatedConv.title != conversation.title {
                currentConversation = updatedConv // Update @Published if title changed
            }
            // Use updated for persistence check below
            conversation = updatedConv
        }
        
        // Persist intermediate state (e.g., user messages, partial assistant messages)
        if let conversationToSave = currentConversation {
            logger.debug("Saving intermediate conversation state in appendMessageAndUpdateHistory for message role \(message.role)")
            historyService?.addOrUpdateConversation(conversationToSave)
        }
    }
    
    // --- NEW: Method to update audio paths in local state ---
    func updateAudioPathInCurrentConversation(messageID: UUID, path: String) {
        guard currentConversation != nil else {
            logger.error("Cannot add audio path: currentConversation is nil.")
            return
        }
        // Check if the message ID exists in the current conversation's messages
        // This ensures we don't try to add paths to messages not part of the active context.
        guard currentConversation!.messages.contains(where: { $0.id == messageID }) else {
            logger.warning("Attempted to add audio path for message \(messageID) not found in current conversation \(self.currentConversation!.id).")
            return
        }
        
        // Add the path
        var map = currentConversation!.ttsAudioPaths ?? [:]
        var paths = map[messageID] ?? []
        if !paths.contains(path) { paths.append(path) }
        map[messageID] = paths
        currentConversation!.ttsAudioPaths = map
        logger.info("Added audio path '\(path)' for message \(messageID).")
        
        // --- NEW: Trigger final save ---
        // Check if LLM is done AND this path is for the *last* message
        if isLLMStreamComplete, let lastMessage = currentConversation!.messages.last, lastMessage.id == messageID {
            logger.info("✅ Final audio path received for completed LLM stream. Triggering final save.")
            if let conversationToSave = currentConversation {
                historyService?.addOrUpdateConversation(conversationToSave)
            }
        }
    }
    
    deinit {
        logger.info("ChatService deinit.")
        llmTask?.cancel()
    }
}
