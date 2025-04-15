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
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default)
    }()

    init(settingsService: SettingsService) {
        self.settingsService = settingsService
    }

    // MARK: - Public Interaction
    func processTranscription(_ transcription: String, provider: LLMProvider) {
        guard !isProcessingLLM else {
            logger.warning("processTranscription called while already processing.")
            return
        }

        let userMessage = ChatMessage(role: "user", content: transcription)
        // Avoid adding duplicate user messages if called rapidly
        if messages.last?.role != "user" || messages.last?.content != userMessage.content {
            messages.append(userMessage)
        }

        logger.info("⚙️ Processing transcription with \(provider.rawValue): '\(transcription)'")
        isProcessingLLM = true
        currentFullResponse = "" // Reset accumulator

        // Start the LLM fetch task
        llmTask = Task { [weak self] in
             guard let self = self else { return }
             await self.fetchLLMResponse(provider: provider)
             // Task completion (success, error, cancellation) is handled within fetchLLMResponse
             // isProcessingLLM is set to false there.
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
            // 1. Select API Key and prepare stream based on provider
            let stream: AsyncThrowingStream<String, Error>
            switch provider {
            case .gemini:
                guard let apiKey = settingsService.geminiAPIKey, !apiKey.isEmpty, apiKey != "YOUR_GEMINI_API_KEY" else {
                    throw LlmError.apiKeyMissing(provider: "Gemini")
                }
                logger.info("Using Gemini provider.")
                stream = try await fetchGeminiStream(apiKey: apiKey)
            case .claude:
                guard let apiKey = settingsService.anthropicAPIKey, !apiKey.isEmpty, apiKey != "YOUR_ANTHROPIC_API_KEY" else {
                    throw LlmError.apiKeyMissing(provider: "Claude")
                }
                 logger.info("Using Claude provider.")
                stream = try await fetchClaudeStream(apiKey: apiKey)
            }

            var firstChunkReceived = false
            // 2. Process the stream
            for try await chunk in stream {
                 try Task.checkCancellation() // Check if cancellation was requested

                 if !firstChunkReceived {
                      logger.info("🤖 Received first LLM chunk (\(providerString)).")
                      firstChunkReceived = true
                 }

                 currentFullResponse.append(chunk) // Accumulate full response
                 llmChunkSubject.send(chunk)     // Send chunk for immediate TTS processing
            }
             // 3. Stream finished successfully
             logger.info("🤖 LLM stream completed successfully (\(providerString)).")

        } catch is CancellationError {
            logger.notice("⏹️ LLM Task Cancelled.")
            llmError = CancellationError()
            // Don't send llmErrorSubject for cancellation, handle state below
        } catch let error as LlmError {
             logger.error("🚨 LLM Service Error (\(providerString)): \(error.localizedDescription)")
             llmError = error
             llmErrorSubject.send(error) // Send specific LlmError
        } catch {
             logger.error("🚨 Unknown LLM Error during stream (\(providerString)): \(error.localizedDescription)")
             llmError = error
             llmErrorSubject.send(error) // Send generic error
        }

        // 4. Cleanup and Final State Update (Runs on MainActor due to class annotation)
        handleLLMCompletion(error: llmError)
    }

    private func handleLLMCompletion(error: Error?) {
         isProcessingLLM = false // Mark processing as finished
         llmCompleteSubject.send() // Signal completion (used by AudioService/ViewModel)

        // Log final response if successful or partially successful
         if !currentFullResponse.isEmpty {
             logger.info("🤖 LLM full response processed (\(self.currentFullResponse.count) chars). Error: \(error?.localizedDescription ?? "None")")
             logger.info("------ LLM FINAL RESPONSE ------\n\(self.currentFullResponse)\n----------------------")
         } else if error == nil {
              logger.info("🤖 LLM response was empty.")
         } else if !(error is CancellationError) {
              logger.error("🚨 LLM fetch failed completely. Error: \(error!.localizedDescription)")
         } // Cancellation logging happened in the catch block


        // Add the final assistant message to the history
         if !currentFullResponse.isEmpty {
             let messageRole: String
             if error == nil {
                 messageRole = "assistant"
             } else if error is CancellationError {
                 messageRole = "assistant_partial" // Indicate partial response due to cancellation
             } else {
                 messageRole = "assistant_error" // Indicate error during generation
             }
             let assistantMessage = ChatMessage(role: messageRole, content: currentFullResponse)

             // Avoid duplicates if completion handler runs close to message appends elsewhere
             if messages.last?.role != messageRole || messages.last?.content != assistantMessage.content {
                  messages.append(assistantMessage)
             }
         } else if error != nil && !(error is CancellationError) {
             // If there was an error and no response, add an error message
             let errorMessage = ChatMessage(role: "assistant_error", content: "Sorry, an error occurred while generating the response.")
              if messages.last?.role != "assistant_error" { // Avoid duplicate errors
                  messages.append(errorMessage)
              }
         }

         llmTask = nil // Clear the task reference
         currentFullResponse = "" // Clear buffer for next run
    }


    // MARK: - Gemini Implementation
    private func fetchGeminiStream(apiKey: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(settingsService.geminiModel):streamGenerateContent?key=\(apiKey)&alt=sse") else {
            throw LlmError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // --- Build Payload ---
        var conversationHistory: [GeminiContent] = []
        // Add System Prompt if available
        if let sysPrompt = settingsService.systemPrompt, !sysPrompt.isEmpty {
            conversationHistory.append(GeminiContent(role: "user", parts: [GeminiPart(text: sysPrompt)]))
            // Gemini requires alternating roles, add a simple model response for the system prompt.
            conversationHistory.append(GeminiContent(role: "model", parts: [GeminiPart(text: "OK.")]))
        }
        // Add message history, mapping roles
        let history = messages.map { msg -> GeminiContent in
            // Map our roles ("user", "assistant", "assistant_partial", "assistant_error") to Gemini's ("user", "model")
            let geminiRole = (msg.role == "user") ? "user" : "model"
            return GeminiContent(role: geminiRole, parts: [GeminiPart(text: msg.content)])
        }
        conversationHistory.append(contentsOf: history)
        let payload = GeminiRequest(contents: conversationHistory)
        // --- End Payload ---


        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }

        logger.debug("Sending Gemini Request...")
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
            // Try to read the error body
            // This needs to be done carefully with async bytes
            // This simple approach might not capture the full body if the loop breaks early
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
                                // Extract text from the first candidate/part
                                if let text = chunk.candidates?.first?.content?.parts.first?.text {
                                    continuation.yield(text)
                                } else {
                                     logger.debug("Gemini chunk decoded but contained no text.")
                                }
                            } catch {
                                logger.warning("Failed to decode Gemini JSON chunk: \(error.localizedDescription). JSON: \(jsonDataString)")
                                // Don't fail the whole stream for one bad chunk, just log it.
                                // streamError = LlmError.responseDecodingError(error) // Or potentially throw?
                            }
                        }
                    }
                     logger.debug("Gemini stream finished processing lines.")
                } catch is CancellationError {
                     logger.debug("Gemini stream processing cancelled.")
                     streamError = CancellationError() // Propagate cancellation
                } catch {
                     logger.error("Error processing Gemini byte stream: \(error.localizedDescription)")
                     streamError = LlmError.networkError(error) // Treat stream reading errors as network errors
                }
                // Finish the continuation with error or nil
                continuation.finish(throwing: streamError)
            }
        }
        // --- End AsyncThrowingStream ---
    }


    // MARK: - Claude Implementation
    private func fetchClaudeStream(apiKey: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LlmError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version") // Keep specific version


        // --- Build Payload ---
         // Map messages to Claude's format
         let history = messages.map { msg -> MessageParam in
             // Map our roles ("user", "assistant", "assistant_partial", "assistant_error") to Claude's ("user", "assistant")
             let claudeRole = (msg.role == "user") ? "user" : "assistant"
             return MessageParam(role: claudeRole, content: msg.content)
         }
         let systemPromptToUse: String?
         if let sysPrompt = settingsService.systemPrompt, !sysPrompt.isEmpty {
             systemPromptToUse = sysPrompt
         } else {
             systemPromptToUse = nil // Ensure nil is passed if empty
         }
        let payload = ClaudeRequest(
            model: settingsService.claudeModel,
            system: systemPromptToUse,
            messages: history,
            stream: true,
            max_tokens: 8000, // Keep existing parameter
            temperature: 1.0 // Keep existing parameter
        )
         // --- End Payload ---

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }

         logger.debug("Sending Claude Request...")
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
                    var currentEventBuffer = "" // Buffer for multi-line events if they occur
                    for try await line in bytes.lines {
                         try Task.checkCancellation()

                         // Simple SSE parsing (assumes event data is on lines starting with "data:")
                         if line.hasPrefix("data:") {
                             let jsonDataString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                              if jsonDataString.isEmpty { continue }

                             guard let jsonData = jsonDataString.data(using: .utf8) else {
                                 logger.warning("Could not convert Claude JSON string to Data: \(jsonDataString)")
                                 continue
                             }

                             do {
                                 let event = try JSONDecoder().decode(ClaudeStreamEvent.self, from: jsonData)
                                 // Process relevant event types
                                 if event.type == "content_block_delta" {
                                     if let text = event.delta?.text {
                                         continuation.yield(text)
                                     }
                                 } else if event.type == "message_delta" {
                                     // Sometimes delta might be nested under message_delta
                                     if let text = event.delta?.text {
                                         continuation.yield(text)
                                     }
                                     // You might also look at event.message.usage here if needed
                                 } else if event.type == "message_stop" {
                                     logger.debug("Claude stream received message_stop event.")
                                     // This indicates the end from Claude's side. The stream loop will naturally end.
                                 } else if event.type == "ping" {
                                      // Ignore ping events
                                 } else {
                                      logger.debug("Received unhandled Claude event type: \(event.type)")
                                 }
                             } catch {
                                 logger.warning("Failed to decode Claude JSON event: \(error.localizedDescription). JSON: \(jsonDataString)")
                                 // Don't fail the whole stream for one bad event
                             }
                         } else if line.isEmpty {
                             // End of an event, process buffer if needed (not strictly necessary with current simple parsing)
                             currentEventBuffer = ""
                         } else {
                             // Append to buffer if line doesn't start with "data:" (might handle multi-line data if needed)
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
                // Finish the continuation
                continuation.finish(throwing: streamError)
            }
        }
        // --- End AsyncThrowingStream ---
    }

    deinit {
        logger.info("ChatService deinit.")
        // Cancel any ongoing task when the service is deallocated
        llmTask?.cancel()
    }
}
