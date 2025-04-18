// ChatService.swift
import Foundation
import OSLog
import Combine

@MainActor
class ChatService: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatService")

    // --- Published State ---
    @Published var messages: [ChatMessage] = []
    @Published var isProcessingLLM: Bool = false // True while fetching/streaming LLM response

    // --- Combine Subjects for Communication ---
    let llmChunkSubject = PassthroughSubject<String, Never>()    // Sends LLM text chunks
    let llmErrorSubject = PassthroughSubject<Error, Never>()      // Reports LLM errors
    let llmCompleteSubject = PassthroughSubject<Void, Never>()   // Signals end of LLM stream

    // --- Internal State ---
    private var llmTask: Task<Void, Never>? = nil
    private var currentFullResponse: String = "" // Accumulates the full response for final message

    // --- Dependencies ---
    private let settingsService: SettingsService
    private var historyService: HistoryService? // Add HistoryService (optional for now)
    private var currentConversationId: UUID? // Track the ID of the active conversation
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default)
    }()

    var activeConversationId: UUID? { currentConversationId }

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
        }

        let userMessage = ChatMessage(id: UUID(), role: "user", content: transcription)
        appendMessageAndUpdateHistory(userMessage) // Use helper to add and save

        logger.info("⚙️ Processing transcription with \(provider.rawValue): '\(transcription)'")
        isProcessingLLM = true
        currentFullResponse = "" // Reset accumulator

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
        // isProcessingLLM will be set to false within the fetchLLMResponse cancellation handling block.
        // The final (potentially partial) message is added there too.
    }

    // MARK: - LLM Fetching Logic
    private func fetchLLMResponse(provider: LLMProvider) async {
        var llmError: Error? = nil
        let providerString = provider.rawValue

        do {
            // --- Get ACTIVE settings ---
            guard let activeModelId = settingsService.activeModelId(for: provider) else {
                 throw LlmError.apiKeyMissing(provider: "\(provider.rawValue) model selection") // Reuse error or create new one
            }
            let activeSystemPrompt = settingsService.activeSystemPrompt
            let activeTemperature = settingsService.activeTemperature
            let activeMaxTokens = settingsService.activeMaxTokens
            // --- End Get ACTIVE settings ---


            // 1. Select API Key and prepare stream based on provider
            let stream: AsyncThrowingStream<String, Error>
            switch provider {
            case .gemini:
                guard let apiKey = settingsService.geminiAPIKey, !apiKey.isEmpty, apiKey != "YOUR_GEMINI_API_KEY" else {
                    throw LlmError.apiKeyMissing(provider: "Gemini")
                }
                logger.info("Using Gemini provider (\(activeModelId)). SysPrompt: \(activeSystemPrompt != nil), Temp: \(activeTemperature), MaxTokens: \(activeMaxTokens)")
                stream = try await fetchGeminiStream(apiKey: apiKey, modelId: activeModelId, systemPrompt: activeSystemPrompt, temperature: activeTemperature, maxTokens: activeMaxTokens)
            case .claude:
                guard let apiKey = settingsService.anthropicAPIKey, !apiKey.isEmpty, apiKey != "YOUR_ANTHROPIC_API_KEY" else {
                    throw LlmError.apiKeyMissing(provider: "Claude")
                }
                logger.info("Using Claude provider (\(activeModelId)). SysPrompt: \(activeSystemPrompt != nil), Temp: \(activeTemperature), MaxTokens: \(activeMaxTokens)")
                stream = try await fetchClaudeStream(apiKey: apiKey, modelId: activeModelId, systemPrompt: activeSystemPrompt, temperature: activeTemperature, maxTokens: activeMaxTokens)
            }

            var firstChunkReceived = false
            // 2. Process the stream
            for try await chunk in stream {
                 try Task.checkCancellation() // Check if cancellation was requested

                 if !firstChunkReceived {
                      logger.info("🤖 Received first LLM chunk (\(providerString)).")
                      firstChunkReceived = true
                      // Add assistant_partial message placeholder immediately
                       let partialMsg = ChatMessage(id: UUID(), role: "assistant_partial", content: "")
                       // Check if last message isn't already a partial/error to avoid duplicates during retries/fast streams
                       if messages.last?.role != "assistant_partial" && messages.last?.role != "assistant_error" {
                           appendMessageAndUpdateHistory(partialMsg)
                       }
                 }

                 currentFullResponse.append(chunk) // Accumulate full response

                 // Update the partial message in the main list
                  if var lastMessage = messages.last, lastMessage.role == "assistant_partial" {
                      lastMessage.content = currentFullResponse
                      messages[messages.count - 1] = lastMessage // Update in-place
                      // Don't need to save history on every chunk, wait for completion.
                  }

                 llmChunkSubject.send(chunk)     // Send chunk for immediate TTS processing
            }
             // 3. Stream finished successfully
             logger.info("🤖 LLM stream completed successfully (\(providerString)).")


        } catch is CancellationError {
            logger.notice("⏹️ LLM Task Cancelled.")
            llmError = CancellationError()
        } catch let error as LlmError {
             logger.error("🚨 LLM Service Error (\(providerString)): \(error.localizedDescription)")
             llmError = error
             llmErrorSubject.send(error)
        } catch {
             logger.error("🚨 Unknown LLM Error during stream (\(providerString)): \(error.localizedDescription)")
             llmError = error
             llmErrorSubject.send(error)
        }

        // 4. Cleanup and Final State Update
        handleLLMCompletion(error: llmError)
    }

    private func handleLLMCompletion(error: Error?) {
         isProcessingLLM = false
         llmCompleteSubject.send()

         // Log final response if successful or partially successful
         if !currentFullResponse.isEmpty {
             logger.info("🤖 LLM full response processed (\(self.currentFullResponse.count) chars). Error: \(error?.localizedDescription ?? "None")")
             logger.info("------ LLM FINAL RESPONSE ------\n\(self.currentFullResponse)\n----------------------")
         } else if error == nil {
              logger.info("🤖 LLM response was empty.")
         } else if !(error is CancellationError) {
              logger.error("🚨 LLM fetch failed completely. Error: \(error!.localizedDescription)")
         } // Cancellation logging happened in the catch block


        // Update the final assistant message in the history
        if !currentFullResponse.isEmpty {
             let messageRole: String
             if error == nil { messageRole = "assistant" }
             else if error is CancellationError { messageRole = "assistant_partial" }
             else { messageRole = "assistant_error" }

             // Find the partial message we added and update its role and content
             if let partialIndex = messages.lastIndex(where: { $0.role == "assistant_partial" }) {
                  messages[partialIndex].role = messageRole
                  messages[partialIndex].content = currentFullResponse // Ensure final content is set
                  // Now update history
                   if let convId = currentConversationId, var conversation = historyService?.conversations.first(where: { $0.id == convId }) {
                        conversation.messages = self.messages
                        conversation = historyService?.generateTitleIfNeeded(for: conversation) ?? conversation
                        historyService?.addOrUpdateConversation(conversation)
                   }
                  logger.info("Updated final message in history. Role: \(messageRole)")
             } else {
                 // If no partial message was found (e.g., response was instant?), add a new one.
                 logger.warning("Could not find partial message to update. Adding new final message.")
                  let finalMessage = ChatMessage(id: UUID(), role: messageRole, content: currentFullResponse)
                  appendMessageAndUpdateHistory(finalMessage)
             }

        } else if error != nil && !(error is CancellationError) {
            // Handle error case where no response was generated at all
             let errorMessage = ChatMessage(id: UUID(), role: "assistant_error", content: "Sorry, an error occurred while generating the response.")
              // Remove previous partial if it exists and is empty
             if messages.last?.role == "assistant_partial" && messages.last?.content.isEmpty == true {
                 messages.removeLast()
             }
            appendMessageAndUpdateHistory(errorMessage) // Add the error message and save
        } else if messages.last?.role == "assistant_partial" && messages.last?.content.isEmpty == true {
            // Handle case where stream ends cleanly but empty (no partial message added or empty)
            messages.removeLast() // Remove the empty partial placeholder
            if let convId = currentConversationId, var conversation = historyService?.conversations.first(where: { $0.id == convId }) {
                 conversation.messages = self.messages
                 historyService?.addOrUpdateConversation(conversation)
            }
             logger.info("Removed empty partial message as LLM response was empty.")
        }

        llmTask = nil
        currentFullResponse = ""
    }


    // MARK: - Gemini Implementation (Updated Signature)
    private func fetchGeminiStream(apiKey: String, modelId: String, systemPrompt: String?, temperature: Float, maxTokens: Int) async throws -> AsyncThrowingStream<String, Error> {
         // Use modelId from settings
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelId):streamGenerateContent?key=\(apiKey)&alt=sse") else {
            throw LlmError.invalidURL
        }
        // ... request setup ...
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // --- Build Payload ---
        var conversationHistory: [GeminiContent] = []
        // Use activeSystemPrompt from settings
        if let sysPrompt = systemPrompt, !sysPrompt.isEmpty {
            conversationHistory.append(GeminiContent(role: "user", parts: [GeminiPart(text: sysPrompt)]))
            conversationHistory.append(GeminiContent(role: "model", parts: [GeminiPart(text: "OK.")])) // Keep Gemini's required alternation
        }
        // Use current live messages
        let history = messages.map { msg -> GeminiContent in
            let geminiRole = (msg.role == "user") ? "user" : "model"
            return GeminiContent(role: geminiRole, parts: [GeminiPart(text: msg.content)])
        }
        conversationHistory.append(contentsOf: history)

        // TODO: Add temperature and max_tokens to Gemini request if API supports them in this structure
        // Currently, the GeminiRequest struct doesn't have them. Need to check Gemini API docs
        // for generationConfig settings within the request.
        let payload = GeminiRequest(contents: conversationHistory)
        // --- End Payload ---

        // ... encode payload, make request, process stream (remains the same) ...
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }

        logger.debug("Sending Gemini Request to \(modelId)...")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
             (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
             throw LlmError.networkError(error) // Catch network errors during connection
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            do {
                 for try await byte in bytes { errorBody += String(UnicodeScalar(byte)) }
            } catch {
                 logger.warning("Could not read Gemini error response body: \(error)")
            }
            logger.error("Gemini HTTP Error: \(httpResponse.statusCode). Body: \(errorBody)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody.isEmpty ? nil : errorBody)
        }

        // --- Create AsyncThrowingStream ---
        return AsyncThrowingStream { continuation in
            Task {
                var streamError: Error? = nil
                do {
                    logger.debug("Starting to process Gemini stream...")
                    for try await line in bytes.lines {
                         try Task.checkCancellation() // Allow cancellation during line iteration
                        if line.hasPrefix("data: ") {
                            let jsonDataString = String(line.dropFirst(6))
                             if jsonDataString.isEmpty || jsonDataString == "[DONE]" { continue } // Skip empty data lines

                            guard let jsonData = jsonDataString.data(using: .utf8) else {
                                 logger.warning("Could not convert Gemini JSON string to Data: \(jsonDataString)")
                                 continue
                            }

                            do {
                                let chunk = try JSONDecoder().decode(GeminiResponseChunk.self, from: jsonData)
                                if let text = chunk.candidates?.first?.content?.parts.first?.text {
                                    continuation.yield(text)
                                } else {
                                     logger.debug("Gemini chunk decoded but contained no text.")
                                }
                            } catch {
                                logger.warning("Failed to decode Gemini JSON chunk: \(error.localizedDescription). JSON: \(jsonDataString)")
                            }
                        }
                    }
                     logger.debug("Gemini stream finished processing lines.")
                } catch is CancellationError {
                     logger.debug("Gemini stream processing cancelled.")
                     streamError = CancellationError() // Propagate cancellation
                } catch {
                     logger.error("Error processing Gemini byte stream: \(error.localizedDescription)")
                     streamError = LlmError.networkError(error)
                }
                continuation.finish(throwing: streamError)
            }
        }
    }


    // MARK: - Claude Implementation (Updated Signature)
    private func fetchClaudeStream(apiKey: String, modelId: String, systemPrompt: String?, temperature: Float, maxTokens: Int) async throws -> AsyncThrowingStream<String, Error> {
        // ... URL setup ...
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LlmError.invalidURL
        }

        // ... request setup ...
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")


        // --- Build Payload ---
         let history = messages.map { msg -> MessageParam in
             let claudeRole = (msg.role == "user") ? "user" : "assistant"
             return MessageParam(role: claudeRole, content: msg.content)
         }
         // Use active system prompt
         let systemPromptToUse: String? = (systemPrompt?.isEmpty ?? true) ? nil : systemPrompt

        let payload = ClaudeRequest(
            model: modelId, // Use active model ID
            system: systemPromptToUse,
            messages: history,
            stream: true,
            max_tokens: maxTokens, // Use active max tokens
            temperature: temperature // Use active temperature
        )
         // --- End Payload ---

        // ... encode payload, make request, process stream (remains the same) ...
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }

         logger.debug("Sending Claude Request to \(modelId)...")
         let (bytes, response): (URLSession.AsyncBytes, URLResponse)
         do {
              (bytes, response) = try await urlSession.bytes(for: request)
         } catch {
              throw LlmError.networkError(error)
         }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
             var errorBody = ""
             do {
                  for try await byte in bytes { errorBody += String(UnicodeScalar(byte)) }
             } catch {
                  logger.warning("Could not read Claude error response body: \(error)")
             }
            logger.error("Claude HTTP Error: \(httpResponse.statusCode). Body: \(errorBody)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody.isEmpty ? nil : errorBody)
        }

        // --- Create AsyncThrowingStream ---
        return AsyncThrowingStream { continuation in
            Task {
                var streamError: Error? = nil
                do {
                    logger.debug("Starting to process Claude stream...")
                    var currentEventBuffer = ""
                    for try await line in bytes.lines {
                         try Task.checkCancellation()

                         if line.hasPrefix("data:") {
                             let jsonDataString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                              if jsonDataString.isEmpty { continue }

                             guard let jsonData = jsonDataString.data(using: .utf8) else {
                                 logger.warning("Could not convert Claude JSON string to Data: \(jsonDataString)")
                                 continue
                             }

                             do {
                                 let event = try JSONDecoder().decode(ClaudeStreamEvent.self, from: jsonData)
                                 if event.type == "content_block_delta" {
                                     if let text = event.delta?.text { continuation.yield(text) }
                                 } else if event.type == "message_delta" {
                                     if let text = event.delta?.text { continuation.yield(text) }
                                 } else if event.type == "message_stop" {
                                     logger.debug("Claude stream received message_stop event.")
                                 } else if event.type == "ping" { /* Ignore */ }
                                  else { logger.debug("Received unhandled Claude event type: \(event.type)") }
                             } catch {
                                 logger.warning("Failed to decode Claude JSON event: \(error.localizedDescription). JSON: \(jsonDataString)")
                             }
                         } else if line.isEmpty {
                             currentEventBuffer = ""
                         } else {
                             currentEventBuffer += line
                         }
                    }
                    logger.debug("Claude stream finished processing lines.")
                } catch is CancellationError {
                     logger.debug("Claude stream processing cancelled.")
                     streamError = CancellationError()
                } catch {
                     logger.error("Error processing Claude byte stream: \(error.localizedDescription)")
                     streamError = LlmError.networkError(error)
                }
                continuation.finish(throwing: streamError)
            }
        }
    }

    // --- New method to start/reset conversation ---
    func resetConversationContext(messagesToLoad: [ChatMessage]? = nil, existingConversationId: UUID? = nil, parentId: UUID? = nil) {
         logger.info("Resetting conversation context. Loading messages: \(messagesToLoad?.count ?? 0). Existing ID: \(existingConversationId?.uuidString ?? "New"). Parent ID: \(parentId?.uuidString ?? "None")")
         messages = messagesToLoad ?? [] // Load provided messages or start empty
         currentFullResponse = ""
         llmTask?.cancel() // Cancel any pending LLM task
         llmTask = nil
         isProcessingLLM = false // Ensure processing flag is reset

         if let existingId = existingConversationId {
             currentConversationId = existingId
         } else {
             // Create a new conversation in history if starting fresh or continuing
             let newConversation = Conversation(
                id: UUID(),
                messages: messages, // Start with the loaded messages
                createdAt: Date(),
                parentConversationId: parentId
             )
             currentConversationId = newConversation.id
             // wait for the user message, otherwise will spam history with empty conversations
             //historyService?.addOrUpdateConversation(newConversation)
             logger.info("Created new conversation context with ID: \(newConversation.id)")
         }
    }

    // --- Update message handling ---
     private func appendMessageAndUpdateHistory(_ message: ChatMessage) {
         messages.append(message)
         // Update the corresponding conversation in HistoryService
         if let convId = currentConversationId, var conversation = historyService?.conversations.first(where: { $0.id == convId }) {
             conversation.messages = self.messages // Update messages
             // Generate title only if needed (e.g., after first user/assistant exchange)
             if conversation.title == nil && messages.count > 1 {
                  conversation = historyService?.generateTitleIfNeeded(for: conversation) ?? conversation
             }
             historyService?.addOrUpdateConversation(conversation)
         } else if currentConversationId == nil {
             logger.warning("Tried to update history but currentConversationId is nil.")
             // Optionally create a new conversation here if it doesn't exist yet
             resetConversationContext(messagesToLoad: messages)
         } else {
             logger.warning("Tried to update history but could not find conversation with ID \(self.currentConversationId!)")
         }
     }

    deinit {
        logger.info("ChatService deinit.")
        llmTask?.cancel()
    }
}
