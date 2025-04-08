//
//  ContentView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 08.04.25.
//

import SwiftUI
import AVFoundation
import Speech
import OSLog // For better logging

// Placeholder for messages (still needed for logic, not UI)
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String // e.g., "user", "assistant"
    let content: String
}

// MARK: - LLM Data Structures

// --- Claude ---
struct ClaudeRequest: Codable {
    let model: String
    let messages: [MessageParam]
    let stream: Bool
    let max_tokens: Int
    let temperature: Float
}

struct MessageParam: Codable {
    let role: String
    let content: String
}

// Structures to decode Claude SSE stream events
struct ClaudeStreamEvent: Decodable {
    let type: String
    // We only care about message_delta and content_block_delta for streaming text
    let delta: Delta?
    let message: ClaudeResponseMessage? // For message_stop event
}
struct Delta: Decodable {
    let type: String? // e.g., "text_delta", "input_tokens"
    let text: String?
}
// Structure for the final message in message_stop event
struct ClaudeResponseMessage: Decodable {
    let id: String
    let role: String
    // content might be more complex, but we only stored text so far
    let usage: UsageData?
}
struct UsageData: Decodable {
    let input_tokens: Int
    let output_tokens: Int
}


// --- Gemini ---
struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    // Add generationConfig if needed (temperature, topP, etc.)
    // let generationConfig: GenerationConfig?
}

struct GeminiContent: Codable {
    let role: String // "user" or "model"
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String
}

// Structure to decode Gemini stream chunks
struct GeminiResponseChunk: Decodable {
    let candidates: [GeminiCandidate]?
}
struct GeminiCandidate: Decodable {
    let content: GeminiContent?
    // Add finishReason, safetyRatings if needed
}

// MARK: - ViewModel

@MainActor
class ChatViewModel: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {

    // Add a logger for better debugging
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")

    @Published var messages: [ChatMessage] = []
    @Published var isListening: Bool = false
    @Published var isProcessing: Bool = false // Thinking/Waiting for LLM
    @Published var isSpeaking: Bool = false   // TTS playback
    @Published var ttsRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var llmTask: Task<Void, Never>? = nil // <-- ADD THIS

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 1.5

    // --- LLM ---
    enum LLMProvider { case gemini, claude }
    @Published var selectedProvider: LLMProvider = .claude // Default to Claude
    private var anthropicAPIKey: String?
    private var geminiAPIKey: String?
    // Define models
    private let claudeModel = "claude-3-7-sonnet-20250219" // Or another Claude model
    private let geminiModel = "gemini-2.0-flash" // Or another Gemini model


    // --- TTS ---
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var ttsQueue = [String]() // Queue of chunks TO BE spoken
    private var llmResponseBuffer: String = "" // Buffer for incoming LLM text
    private var currentSpokenText: String = "" // Store latest transcript for silence detection

    // --- URLSession ---
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        // Configure timeouts, caching etc. if needed
        return URLSession(configuration: config)
    }()


    override init() {
        super.init()
        speechRecognizer.delegate = self
        speechSynthesizer.delegate = self

        // Load API Keys from Environment Variables
        anthropicAPIKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        geminiAPIKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]

        if anthropicAPIKey == nil {
            logger.warning("ANTHROPIC_API_KEY environment variable not set.")
            // Handle missing key - maybe disable Claude option?
        }
        if geminiAPIKey == nil {
            logger.warning("GEMINI_API_KEY environment variable not set.")
            // Handle missing key - maybe disable Gemini option?
        }

        requestPermissions()
    }

    // --- Permission Handling ---
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
             Task { @MainActor [weak self] in
                 guard let self = self else { return }
                if authStatus != .authorized {
                    self.logger.error("Speech recognition authorization denied.")
                    // Handle denial (e.g., show an alert)
                } else {
                    self.logger.info("Speech recognition authorized.")
                }
            }
        }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
             Task { @MainActor [weak self] in
                 guard let self = self else { return }
                if !granted {
                    self.logger.error("Microphone permission denied.")
                    // Handle denial
                } else {
                     self.logger.notice("Microphone permission granted.")
                }
            }
        }
    }

    // --- Core Logic ---
    func cycleState() {
         Task { @MainActor in
             if !isListening && !isProcessing && !isSpeaking {
                 logger.notice("CycleState: Requesting startListening()")
                 startListening()
             } else if isListening {
                 logger.notice("CycleState: Requesting stopListeningAndProcess()")
                 stopListeningAndProcess() // This implicitly stops listening first
             } else if isProcessing || isSpeaking { // <-- MODIFIED CONDITION
                 logger.notice("CycleState: Requesting cancelProcessingAndSpeaking()")
                 cancelProcessingAndSpeaking() // <-- CALL NEW FUNCTION
             }
             // Removed redundant checks for isProcessing/isSpeaking here
         }
     }

    // NEW FUNCTION TO HANDLE CANCELLATION
    func cancelProcessingAndSpeaking() {
        logger.notice("⚡️ Cancellation requested. Current State: isProcessing=\(self.isProcessing), isSpeaking=\(self.isSpeaking)")

        logger.notice("⚡️ Calling stopSpeaking() from cancelProcessingAndSpeaking.")
        stopSpeaking()
        logger.notice("⚡️ Returned from stopSpeaking(). Current State: isProcessing=\(self.isProcessing), isSpeaking=\(self.isSpeaking)")

        if let task = llmTask {
            logger.notice("⚡️ Cancelling LLM Task.")
            task.cancel()
            llmTask = nil
        } else {
             logger.warning("⚡️ Cancellation requested, but no active LLM task found (might have completed normally).")
        }

        if self.isProcessing {
            isProcessing = false
            logger.notice("Set isProcessing = false (Cancellation)")
        } else {
            logger.notice("isProcessing was already false during cancellation.")
        }

        logger.notice("⚡️ Cancellation finished. Final State: isProcessing=\(self.isProcessing), isSpeaking=\(self.isSpeaking)")
    }

    // --- Speech Recognition Functions ---
    func startListening() {
        guard !audioEngine.isRunning else {
            logger.warning("Audio engine already running. Ignoring startListening request.")
            return
        }
        logger.notice("Attempting to start listening process...")

        isListening = true
        isProcessing = false
        isSpeaking = false
        currentSpokenText = ""
        logger.notice("Set isListening = true")

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            logger.info("Audio session activated.")
        } catch {
            logger.error("🚨 Audio session setup error: \(error.localizedDescription)")
             // Add explicit permission status logging on error
             logger.error("Speech Auth Status: \(SFSpeechRecognizer.authorizationStatus().rawValue), Mic Auth Status: \(AVAudioApplication.shared.recordPermission.rawValue)")
            isListening = false
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
             logger.critical("Unable to create SFSpeechAudioBufferRecognitionRequest object")
             isListening = false
             return
        }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode

        // Check speech recognizer availability *before* creating the task
        guard speechRecognizer.isAvailable else {
             logger.error("🚨 Speech recognizer is not available right now.")
             isListening = false
             // Optionally deactivate audio session here if needed
             return
        }


        // --- Recognition Task ---
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            // This handler runs on a background queue initially.

            // Need to capture result and error *before* jumping to MainActor
            let currentResult = result
            let currentError = error

            Task { @MainActor [weak self] in
                // This block runs on the MainActor
                guard let self = self else { return } // 'self' IS used here

                var isFinal = false // Declare inside Task scope
                var transcribedText: String? = nil // Declare inside Task scope

                if let recognizedResult = currentResult { // Use the captured result
                    transcribedText = recognizedResult.bestTranscription.formattedString
                    isFinal = recognizedResult.isFinal
                    // logger.info("Transcript update: \(transcribedText ?? "N/A")") // Keep info or debug
                     // Use transcribedText here:
                    self.currentSpokenText = transcribedText ?? ""
                    self.resetSilenceTimer() // Okay on MainActor
                     // logger.info("Updated currentSpokenText and reset silence timer.") // Keep info/debug
                }

                // Check error or final state (use captured error and calculated isFinal)
                if currentError != nil || isFinal {
                    // Log elevated here since it's an important transition
                    self.logger.notice("Recognition task finished or error: \(currentError?.localizedDescription ?? "Final Result")")

                    // These modify state and must be on MainActor
                    self.stopAudioEngine()
                    self.recognitionRequest = nil
                    self.recognitionTask = nil

                    // Process if we were still listening (use isFinal here)
                    if self.isListening {
                        self.logger.notice("Recognition ended while listening: Processing final transcription.") // Elevate
                        // Pass the most recently captured text
                        self.stopListeningAndProcess(transcription: self.currentSpokenText) // Calls another MainActor func
                    } else {
                         self.logger.notice("Recognition task finished, but processing likely already triggered.") // Elevate
                    }
                }

                // Specific error check for permissions (use captured error)
                 if let nsError = currentError as NSError?, nsError.domain == "kLSRErrorDomain", nsError.code == 203 {
                     self.logger.error("🚨 Speech recognition failed - likely permission denied.")
                 } else if currentError != nil && !isFinal { // Don't log finalization as an error unless it IS an error
                     self.logger.error("🚨 Recognition task error (not final): \(currentError!.localizedDescription)")
                 }
            } // End Task @MainActor
        } // End recognitionTask closure


        // --- Audio Tap ---
        let recordingFormat = inputNode.outputFormat(forBus: 0)
         guard recordingFormat.sampleRate > 0 else {
             logger.error("🚨 Invalid recording format sample rate: \(recordingFormat.sampleRate)")
             stopListeningCleanup()
             return
         }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, time) in
            self.recognitionRequest?.append(buffer)
        }

        // --- Start Audio Engine ---
        audioEngine.prepare()
        do {
            // This call *might* trigger the Microphone permission prompt if status is .notDetermined
            try audioEngine.start()
            logger.notice("🎙️ Audio engine started")
            startSilenceTimer() // Start timer
        } catch {
            logger.error("🚨 Audio engine start error: \(error.localizedDescription)")
             // Log permission status if engine fails to start
             logger.error("Mic Auth Status on engine start fail: \(AVAudioApplication.shared.recordPermission.rawValue)")
            stopListeningCleanup()
        }
    } // End startListening

    // Make sure stopAudioEngine can be called from MainActor context
     func stopAudioEngine() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0) // Important to remove the tap
        logger.info("⏹️ Audio engine stopped")

        // Deactivate audio session when completely done with audio (listening AND speaking)
        // Consider moving this to *after* TTS finishes if startListening isn't called immediately.
        /*
        Task { // Deactivation can take time, do it async
            do {
                try AVAudioSession.sharedInstance().setActive(false)
                logger.info("Audio session deactivated.")
            } catch {
                logger.error("🚨 Audio session deactivation error: \(error.localizedDescription)")
            }
        }
        */
    }

    // Ensure cleanup runs on MainActor
     func stopListeningCleanup() {
        logger.notice("🧹 Performing stopListeningCleanup...")
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        invalidateSilenceTimer()
        if isListening {
            isListening = false
            logger.notice("👂 Set isListening = false")
        } else {
             logger.warning("🧹 stopListeningCleanup called but isListening was already false.")
        }
    }

    // This function initiates processing, potentially from background threads (timer, recognition task)
    // or main thread (cycleState). It needs to manage its context.
    func stopListeningAndProcess(transcription: String? = nil) {
         Task { @MainActor [weak self] in
             guard let self = self else { return }
             self.logger.notice("➡️ Entered stopListeningAndProcess.")

             guard self.isListening else {
                  self.logger.warning("⚠️ stopListeningAndProcess called but not in listening state. Ignoring.")
                  return
             }

             let textToProcess = transcription ?? self.currentSpokenText
             self.logger.info("👂 Stopping listening via stopListeningAndProcess, processing text: '\(textToProcess)'")
             self.stopListeningCleanup() // Perform cleanup (sets isListening = false)

             // Rest of the processing logic...
             if !textToProcess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 // ... set isProcessing = true, append message ...
                 self.isProcessing = true // Explicitly set *after* cleanup confirms listening stopped
                 let userMessage = ChatMessage(role: "user", content: textToProcess)
                 self.messages.append(userMessage)
                 self.logger.info("User said: \(textToProcess)")

                 // Store the LLM Task handle
                 self.llmTask = Task { // <-- STORE THE TASK
                      await self.fetchLLMResponse(prompt: textToProcess)
                      // Clear the task handle *only* on normal completion
                      await MainActor.run { [weak self] in // Ensure MainActor for property access
                          self?.llmTask = nil
                           self?.logger.info("LLM Task completed normally, handle cleared.")
                      }
                 }
             } else {
                  // ... handle no text ...
                 self.logger.info("No text detected to process.")
                 self.isProcessing = false
                 // isListening is already false from stopListeningCleanup()
                 self.isSpeaking = false
             }
         }
    }


    // --- Silence Detection (Timer runs on RunLoop, ensure handler is on MainActor) ---
     func startSilenceTimer() {
        invalidateSilenceTimer()
        logger.notice("⏱️ Starting silence timer (\(self.silenceThreshold)s)")
        silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceThreshold, repeats: false) { [weak self] _ in
             self?.logger.notice("⏱️ Silence timer fired!")
             Task { @MainActor [weak self] in
                  guard let self = self, self.isListening else {
                       self?.logger.warning("⏱️ Silence timer fired, but self is nil or not listening anymore.")
                       return
                  }
                  self.logger.notice("⏳ Silence detected by timer. Processing...")
                  self.stopListeningAndProcess(transcription: self.currentSpokenText)
             }
        }
    }

     func resetSilenceTimer() {
        // logger.debug("⏱️ Resetting silence timer.") // Noisy
        silenceTimer?.fireDate = Date(timeIntervalSinceNow: silenceThreshold)
    }

     func invalidateSilenceTimer() {
        if silenceTimer != nil {
            // logger.debug("⏱️ Invalidating silence timer.") // Noisy
            silenceTimer?.invalidate()
            silenceTimer = nil
        }
    }

    // --- LLM Interaction ---
    func fetchLLMResponse(prompt: String) async {
        let providerString = String(describing: selectedProvider)
        logger.notice("🤖 Fetching LLM Response (\(providerString))...")

        await MainActor.run { [weak self] in
             guard let self = self else { return }
             self.isProcessing = true
             self.llmResponseBuffer = "" // Clear buffer at start of new request
             self.logger.notice("Set isProcessing = true (LLM fetch started), cleared buffer.")
         }

        var fullResponseAccumulator = "" // Still accumulate for logging/history
        var llmError: Error? = nil

        do {
            try Task.checkCancellation()
            logger.info("🤖 LLM Task not cancelled, proceeding.")

            switch selectedProvider {
            case .gemini:
                guard let apiKey = geminiAPIKey else { throw LlmError.apiKeyMissing(provider: "Gemini") }
                let stream = try await fetchGeminiResponse(apiKey: apiKey, prompt: prompt)
                for try await chunk in stream {
                     try Task.checkCancellation()
                     fullResponseAccumulator += chunk
                     await self.bufferAndTrySpeak(text: chunk) // Buffer and potentially speak
                }
            case .claude:
                guard let apiKey = anthropicAPIKey else { throw LlmError.apiKeyMissing(provider: "Claude") }
                 let stream = try await fetchClaudeResponse(apiKey: apiKey, prompt: prompt)
                 for try await chunk in stream {
                      try Task.checkCancellation()
                      fullResponseAccumulator += chunk
                       await self.bufferAndTrySpeak(text: chunk) // Buffer and potentially speak
                 }
            }
             if !Task.isCancelled { logger.info("🤖 LLM Stream Finished normally.") }

        } catch is CancellationError {
             logger.notice("⚡️ LLM Task Cancelled during fetch/stream processing.")
             llmError = CancellationError() // Mark as cancelled for final processing
        } catch {
             if !(error is CancellationError) {
                 logger.error("🚨 LLM Error: \(error.localizedDescription)")
                 llmError = error
                 // Add error message directly to buffer to be spoken
                 await self.bufferAndTrySpeak(text: "Sorry, I had trouble processing that.")
             }
        }

        // --- Final Processing after Stream Ends/Errors/Cancels ---
        let finalAccumulatedResponse = fullResponseAccumulator // Capture final value

        await MainActor.run { [weak self] in
            guard let self = self else { return }

            // Always try to speak any remaining buffered text, regardless of error/cancel
            // unless it was a cancellation AND we didn't get any response
            if !(llmError is CancellationError && finalAccumulatedResponse.isEmpty) {
                self.logger.notice("🤖 LLM Task finished/cancelled/errored. Flushing remaining buffer...")
                self.trySpeakBufferedChunks(flushAll: true) // Force speaking remaining buffer
            } else {
                 self.logger.notice("🤖 LLM Task cancelled with no response, not flushing buffer.")
            }


            // Log the full accumulated message (useful for debugging)
            print("--- LLM FINAL ACCUMULATED RESPONSE ---")
            print(finalAccumulatedResponse)
            print("---------------------------------------")

            // Add to message history (only if not cancelled or if partially successful)
             if !finalAccumulatedResponse.isEmpty {
                let messageRole: String
                if llmError == nil {
                    messageRole = "assistant"
                    self.logger.info("🤖 LLM Full Response logged to history.")
                } else if !(llmError is CancellationError) {
                     messageRole = "assistant_error"
                     self.logger.info("🤖 LLM Partial Response logged to history (due to error).")
                } else {
                    messageRole = "assistant_partial"
                     self.logger.info("🤖 LLM Partial Response logged to history (due to cancellation).")
                }
                 let assistantMessage = ChatMessage(role: messageRole, content: finalAccumulatedResponse)
                 self.messages.append(assistantMessage)
             }


             // Reset processing state (speaking state is handled by TTS delegates/buffer logic)
             if self.isProcessing {
                  self.isProcessing = false
                  self.logger.notice("Set isProcessing = false (LLM fetch processing complete/error/cancelled)")
             }

             // TTS state check (isSpeaking) should now primarily be driven by
             // speakNextChunk starting and didFinish completing the queue.
             // We don't necessarily set isSpeaking = false here anymore.
              if !self.speechSynthesizer.isSpeaking && self.ttsQueue.isEmpty {
                   if self.isSpeaking {
                       self.isSpeaking = false
                       self.logger.notice("Set isSpeaking = false (Synthesizer idle and queue empty after LLM completion)")
                   }
              } else {
                   self.logger.notice("Synthesizer or TTS queue still active after LLM completion. isSpeaking remains \(self.isSpeaking)")
              }
         }
    }

    // Error enum for LLM issues
    enum LlmError: Error, LocalizedError {
        case apiKeyMissing(provider: String)
        case invalidURL
        case requestEncodingError(Error)
        case networkError(Error)
        case invalidResponse(statusCode: Int)
        case responseDecodingError(Error)
        case streamingError(String)

        var errorDescription: String? {
            switch self {
            case .apiKeyMissing(let provider): return "\(provider) API Key is missing."
            case .invalidURL: return "Invalid API endpoint URL."
            case .requestEncodingError(let error): return "Failed to encode request: \(error.localizedDescription)"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .invalidResponse(let statusCode): return "Invalid response from server: Status \(statusCode)"
            case .responseDecodingError(let error): return "Failed to decode response: \(error.localizedDescription)"
            case .streamingError(let message): return "Streaming error: \(message)"
            }
        }
    }

    // --- Gemini API Call ---
    func fetchGeminiResponse(apiKey: String, prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(geminiModel):streamGenerateContent?key=\(apiKey)&alt=sse") else {
            throw LlmError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Construct messages
         let history = messages.map { GeminiContent(role: $0.role == "user" ? "user" : "model", parts: [GeminiPart(text: $0.content)]) }
         let currentMessage = GeminiContent(role: "user", parts: [GeminiPart(text: prompt)])
         let payload = GeminiRequest(contents: history + [currentMessage])

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }

        logger.info("Gemini Request: Sending to \(url)")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }

        logger.info("Gemini Response Status: \(httpResponse.statusCode)")
        guard (200...299).contains(httpResponse.statusCode) else {
             var errorBody = ""
             for try await byte in bytes { errorBody += String(UnicodeScalar(byte)) }
             logger.error("Gemini Error Body: \(errorBody)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        return AsyncThrowingStream { continuation in
            Task {
                var streamError: Error? = nil // Variable to hold error within the task scope
                do {
                     // Process Server-Sent Events (SSE) style response from Gemini (?alt=sse)
                    for try await line in bytes.lines {
                         // logger.debug("Gemini Raw Line: \(line)")
                        if line.hasPrefix("data: ") {
                            let jsonData = Data(line.dropFirst(6).utf8) // Remove "data: "
                            do {
                                let chunk = try JSONDecoder().decode(GeminiResponseChunk.self, from: jsonData)
                                if let text = chunk.candidates?.first?.content?.parts.first?.text {
                                     // logger.debug("Gemini Yielding Chunk: \(text)")
                                    continuation.yield(text)
                                }
                            } catch {
                                logger.error("🚨 Gemini JSON decoding error: \(error.localizedDescription) for line: \(line)")
                                // Decide if this is fatal or ignorable
                            }
                        } else if line.isEmpty {
                             // Empty line might signify end of an event block in SSE, ignore here
                        }
                    }
                     continuation.finish() // Indicate stream completion
                     logger.info("Gemini Stream processing finished normally.") // Log normal finish
                } catch {
                    // Capture the error but finish the stream
                    streamError = error
                    if error is CancellationError {
                         logger.notice("⚡️ Gemini stream processing cancelled.")
                    } else {
                         logger.error("🚨 Gemini stream processing error: \(error.localizedDescription)")
                    }
                }
                // Finish the stream, throwing the captured error if one occurred (or nil)
                continuation.finish(throwing: streamError)
            }
        }
    }


    // --- Claude API Call ---
    func fetchClaudeResponse(apiKey: String, prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LlmError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Construct messages, including history
         let history = messages.map { MessageParam(role: $0.role, content: $0.content) }
         let currentMessage = MessageParam(role: "user", content: prompt)
         let payload = ClaudeRequest(model: claudeModel, messages: history + [currentMessage], stream: true, max_tokens: 8000, temperature: 1.0)

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }

        logger.info("Claude Request: Sending to \(url)")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }

        logger.info("Claude Response Status: \(httpResponse.statusCode)")
        guard (200...299).contains(httpResponse.statusCode) else {
             var errorBody = ""
             for try await byte in bytes { errorBody += String(UnicodeScalar(byte)) }
             logger.error("Claude Error Body: \(errorBody)")
             throw LlmError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        return AsyncThrowingStream { continuation in
             Task {
                 var streamError: Error? = nil // Variable to hold error within the task scope
                 do {
                     // Process Server-Sent Events (SSE)
                     for try await line in bytes.lines {
                         // logger.debug("Claude Raw Line: \(line)")
                         if line.hasPrefix("data:") {
                             let jsonData = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                             if jsonData.isEmpty { continue } // Skip empty data lines if they occur

                             do {
                                 let event = try JSONDecoder().decode(ClaudeStreamEvent.self, from: jsonData)
                                 if event.type == "content_block_delta" || event.type == "message_delta" { // Handle both types just in case
                                     if let text = event.delta?.text {
                                         // logger.debug("Claude Yielding Chunk: \(text)")
                                         continuation.yield(text)
                                     }
                                 } else if event.type == "message_stop" {
                                      logger.info("Claude message_stop event received.")
                                      // Log usage if needed: event.message?.usage
                                      break // Stop processing on message_stop
                                 }
                             } catch {
                                 logger.error("🚨 Claude JSON decoding error: \(error) for line: \(line)")
                                 // Decide whether to continue or fail
                             }
                         }
                     }
                     logger.info("Claude Stream processing finished normally.") // Log normal finish
                 } catch {
                     // Capture the error but finish the stream
                     streamError = error
                     if error is CancellationError {
                          logger.notice("⚡️ Claude stream processing cancelled.")
                     } else {
                          logger.error("🚨 Claude stream processing error: \(error.localizedDescription)")
                     }
                 }
                 // Finish the stream, throwing the captured error if one occurred (or nil)
                 continuation.finish(throwing: streamError)
             }
         }
    }

    // --- TTS Functions ---

    // New function to handle buffering and triggering speech
    private func bufferAndTrySpeak(text: String) async {
        guard !text.isEmpty else { return }

        await MainActor.run { [weak self] in
            guard let self = self else { return }
            self.llmResponseBuffer.append(text)
            // logger.debug("Appended to buffer. New size: \(self.llmResponseBuffer.count)")
            self.trySpeakBufferedChunks() // Try to speak if possible
        }
    }

    // New function to process the buffer and speak if idle
    private func trySpeakBufferedChunks(flushAll: Bool = false) {
        guard Thread.isMainThread else {
            logger.warning("trySpeakBufferedChunks called off main thread, dispatching.")
            Task { @MainActor [weak self] in self?.trySpeakBufferedChunks(flushAll: flushAll) }
            return
        }

        logger.debug("➡️ [trySpeakBufferedChunks] Entered. flushAll=\(flushAll), State: isSpeaking=\(self.isSpeaking), synthSpeaking=\(self.speechSynthesizer.isSpeaking), bufferEmpty=\(self.llmResponseBuffer.isEmpty), queueEmpty=\(self.ttsQueue.isEmpty)")

        // Speak only if the synthesizer is NOT currently speaking AND
        // (we are flushing OR the buffer has content ready)
        if !self.speechSynthesizer.isSpeaking, !self.llmResponseBuffer.isEmpty {
            let textToSpeak = self.llmResponseBuffer
            self.llmResponseBuffer = "" // Clear the buffer

            logger.notice("🗣️ [trySpeakBufferedChunks] Synthesizer idle, moving buffer (\(textToSpeak.count) chars) to TTS queue.")
            self.ttsQueue.append(textToSpeak)
            self.speakNextChunk() // Start speaking the newly added chunk
        } else if flushAll && !self.llmResponseBuffer.isEmpty && self.speechSynthesizer.isSpeaking {
             // If flushing, synthesizer is busy, but buffer has content, queue it anyway.
             // It will be picked up by didFinish -> speakNextChunk later.
             let textToSpeak = self.llmResponseBuffer
             self.llmResponseBuffer = "" // Clear the buffer
             logger.notice("🗣️ [trySpeakBufferedChunks] Flushing buffer while synthesizer busy. Adding (\(textToSpeak.count) chars) to queue.")
             self.ttsQueue.append(textToSpeak)
        } else if flushAll && !self.llmResponseBuffer.isEmpty && !self.speechSynthesizer.isSpeaking {
             // Edge case: Flushing, synth idle, buffer has content (should have been caught above, but safe)
             let textToSpeak = self.llmResponseBuffer
             self.llmResponseBuffer = ""
             logger.notice("🗣️ [trySpeakBufferedChunks] Flushing buffer (edge case). Moving (\(textToSpeak.count) chars) to TTS queue.")
             self.ttsQueue.append(textToSpeak)
             self.speakNextChunk()
        }
         logger.debug("⬅️ [trySpeakBufferedChunks] Exiting. State: isSpeaking=\(self.isSpeaking), synthSpeaking=\(self.speechSynthesizer.isSpeaking), bufferEmpty=\(self.llmResponseBuffer.isEmpty), queueEmpty=\(self.ttsQueue.isEmpty)")

    }


    // This must be called on the MainActor because it interacts with AVSpeechSynthesizer
     func speakNextChunk() {
        guard Thread.isMainThread else {
            logger.warning("speakNextChunk called off main thread, dispatching.")
            Task { @MainActor [weak self] in self?.speakNextChunk() }
            return
        }

        logger.debug("➡️ [speakNextChunk] Entered. State Before Guard: isSpeaking=\(self.isSpeaking), synthSpeaking=\(self.speechSynthesizer.isSpeaking), queueEmpty=\(self.ttsQueue.isEmpty)")

        // Speak if synthesizer is idle AND the queue has items
        guard !self.speechSynthesizer.isSpeaking, !self.ttsQueue.isEmpty else {
             logger.warning("speakNextChunk: Condition failed. isSpeaking=\(self.isSpeaking), synthSpeaking=\(self.speechSynthesizer.isSpeaking), queueEmpty=\(self.ttsQueue.isEmpty). Returning.")
            return
        }

        let textToSpeak = self.ttsQueue.removeFirst()
        logger.debug("speakNextChunk: Dequeued chunk. Queue count now: \(self.ttsQueue.count)")
        let utterance = AVSpeechUtterance(string: textToSpeak)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        // --- Calculate Actual Synthesizer Rate ---
        // Log the system-defined min/max rates
        logger.debug("System Rates: Min=\(AVSpeechUtteranceMinimumSpeechRate), Max=\(AVSpeechUtteranceMaximumSpeechRate), Default=\(AVSpeechUtteranceDefaultSpeechRate)")

        let rateSliderValue = self.ttsRate // Value from slider [0.0, 1.0]
        let defaultSynthRate = AVSpeechUtteranceDefaultSpeechRate // 0.5 (target for slider min, should be ~1x perceived)
        let maxSynthRate = AVSpeechUtteranceMaximumSpeechRate     // 1.0 (target for slider max, sounds like >2x for user)

        // Map slider [0.0, 1.0] -> synthesizer rate [0.5, 1.0]
        // Formula: synthRate = defaultSynthRate + sliderValue * (maxSynthRate - defaultSynthRate)
        let calculatedSynthRate = defaultSynthRate + rateSliderValue * (maxSynthRate - defaultSynthRate)

        // Clamp just to be safe, although the formula ensures it's within [0.5, 1.0]
        // Clamping might be redundant now but harmless.
        let clampedSynthRate = max(defaultSynthRate, min(calculatedSynthRate, maxSynthRate))

        utterance.rate = clampedSynthRate // Use the calculated synthesizer rate within the documented range [0.5, 1.0]

        // Log slider value, calculated synth rate, and display multiplier for comparison
        logger.debug("Slider Value: \(rateSliderValue, format: .fixed(precision: 2)), Calculated Synth Rate: \(clampedSynthRate, format: .fixed(precision: 2)), Display Multiplier: \(self.ttsDisplayMultiplier, format: .fixed(precision: 1))x")
        // --- End Rate Calculation ---


        if utterance.voice == nil {
             logger.warning("TTS voice for en-US not available, using default.")
             utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }

        // Set speaking state *before* calling speak
        if !self.isSpeaking {
            logger.notice("🗣️ [speakNextChunk] Setting isSpeaking = true before calling speak.")
            self.isSpeaking = true // Set state based on starting speech
        }
        // isProcessing is managed by LLM fetch start/end


        let shortUtteranceToSpeak = String(textToSpeak.prefix(80)) + (textToSpeak.count > 80 ? "..." : "")
        logger.notice("🗣️ [speakNextChunk] Attempting to speak chunk: \"\(shortUtteranceToSpeak)\"")
        self.speechSynthesizer.speak(utterance)
        logger.debug("⬅️ [speakNextChunk] Exiting after calling speak.")
    }

    // Needs to run on MainActor
     func stopSpeaking() {
        guard Thread.isMainThread else {
            logger.warning("stopSpeaking called off main thread, dispatching.")
            Task { @MainActor [weak self] in self?.stopSpeaking() }
            return
        }

        logger.notice("🗣️ Entering stopSpeaking. Current State: isSpeaking=\(self.isSpeaking), synthesizer.isSpeaking=\(self.speechSynthesizer.isSpeaking), bufferCount=\(self.llmResponseBuffer.count)")

        // Clear the LLM buffer as well when stopping speech explicitly
        if !self.llmResponseBuffer.isEmpty {
             logger.notice("🗣️ Clearing LLM response buffer during stopSpeaking.")
             self.llmResponseBuffer = ""
        }

        if self.speechSynthesizer.isSpeaking {
            logger.notice("🗣️ Stopping TTS requested (synthesizer was speaking). Queue count before clear: \(self.ttsQueue.count)")
            self.speechSynthesizer.stopSpeaking(at: .immediate)
            self.ttsQueue.removeAll()
            logger.notice("🗣️ Synthesizer stopped, queue cleared.")

            if !self.isProcessing, let task = self.llmTask {
                 logger.notice("⚡️ TTS stopped while not processing, cancelling potentially lingering LLM task.")
                 task.cancel()
                 self.llmTask = nil
            }

            if self.isSpeaking {
                 isSpeaking = false
                 logger.notice("🗣️ Set isSpeaking = false (TTS stopped)")
            } else {
                logger.notice("🗣️ Synthesizer stopped, but isSpeaking was already false.")
            }
        } else {
             logger.notice("🗣️ stopSpeaking called, but synthesizer was not speaking.")
             // Still clear queue in case something was pending but hadn't started
             if !self.ttsQueue.isEmpty {
                 self.ttsQueue.removeAll()
                 logger.notice("🗣️ Cleared TTS queue even though synthesizer wasn't speaking.")
             }
             if self.isSpeaking {
                 isSpeaking = false
                  logger.notice("🗣️ Synthesizer wasn't speaking, but isSpeaking was true. Set isSpeaking = false.")
             }
        }
        logger.notice("🗣️ Exiting stopSpeaking. Final State: isSpeaking=\(self.isSpeaking)")
    }

    // --- AVSpeechSynthesizerDelegate Methods ---
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
         Task { @MainActor [weak self] in
             guard let self = self else { return } // First guard unwraps optional self
             let shortUtterance = String(utterance.speechString.prefix(80)) + (utterance.speechString.count > 80 ? "..." : "")
             self.logger.notice("🗣️ [didFinish] Finished: \"\(shortUtterance)\". State Before Check: isSpeaking=\(self.isSpeaking), synthSpeaking=\(synthesizer.isSpeaking), queueEmpty=\(self.ttsQueue.isEmpty), bufferEmpty=\(self.llmResponseBuffer.isEmpty)")

             self.logger.notice("🗣️ [didFinish] Applying tiny delay before checking queue/buffer...")
             try? await Task.sleep(nanoseconds: 50_000_000) // 50ms delay

             // Now 'self' is definitely valid here if the first guard passed.
             self.logger.notice("🗣️ [didFinish Delay] Delay finished. Checking queue/buffer again...")

             // Check queue first
             if !self.ttsQueue.isEmpty {
                  self.logger.notice("🗣️ [didFinish Delay] More chunks in queue (\(self.ttsQueue.count)), calling speakNextChunk...")
                  self.speakNextChunk()
             } else if !self.llmResponseBuffer.isEmpty {
                 self.logger.notice("🗣️ [didFinish Delay] TTS Queue empty, but buffer has content. Calling trySpeakBufferedChunks...")
                 self.trySpeakBufferedChunks()
             } else {
                 self.logger.notice("🗣️ [didFinish Delay] All TTS finished (queue and buffer empty).")
                 if self.isSpeaking {
                    self.isSpeaking = false
                    self.logger.notice("🗣️ [didFinish Delay] Set isSpeaking = false.")
                 } else {
                     self.logger.notice("🗣️ [didFinish Delay] isSpeaking was already false.")
                 }
             }
             self.logger.notice("🗣️ [didFinish Delay] Exiting delegate method task. State After: isSpeaking=\(self.isSpeaking), synthSpeaking=\(synthesizer.isSpeaking), queueEmpty=\(self.ttsQueue.isEmpty), bufferEmpty=\(self.llmResponseBuffer.isEmpty)")
         }
    }

     // Also add log to cancel delegate
     nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
         Task { @MainActor [weak self] in
             guard let self = self else { return }
             let shortUtterance = String(utterance.speechString.prefix(80)) + (utterance.speechString.count > 80 ? "..." : "")
             self.logger.warning("🗣️ [didCancel] Cancelled speaking: \"\(shortUtterance)\". Current State: isSpeaking=\(self.isSpeaking)")
              // Reset speaking state if cancellation happened externally? Should be handled by stopSpeaking.
               if self.isSpeaking {
                    // self.isSpeaking = false // Let stopSpeaking handle this
                    // self.logger.warning("🗣️ [didCancel] Setting isSpeaking = false.")
               }
         }
     }

    // --- SFSpeechRecognizerDelegate Methods ---
    // This can be called on a background thread.
     nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
         Task { @MainActor [weak self] in
             guard let self = self else { return }
             if !available {
                 self.logger.error("🚨 Speech recognizer not available.")
                 // Handle unavailability, maybe disable listening feature
                 self.stopListeningCleanup() // Ensure cleanup on main actor
             } else {
                 self.logger.info("✅ Speech recognizer available.")
             }
         }
    }

    // --- Cleanup ---
    deinit {
        logger.info("ViewModel deinited.")
        // Removed calls to main actor isolated functions
        // rely on cleanupOnDisappear instead.
        // stopAudioEngine() // REMOVED
        // invalidateSilenceTimer() // REMOVED
    }

     func cleanupOnDisappear() {
         logger.info("Cleaning up on disappear...")
         stopListeningCleanup()
         stopSpeaking()
     }

    // COMPUTED PROPERTY for display multiplier
    var ttsDisplayMultiplier: Float {
        let rate = self.ttsRate // Current slider value (0.0 to 1.0)

        // Map slider range [0.0, 1.0] to display range [1.0x, 4.0x]
        let minDisplay: Float = 1.0
        let maxDisplay: Float = 4.0
        // Linear interpolation: display = min + (rate - rateMin) * (displayRange / rateRange)
        // Since rate range is [0.0, 1.0], rateRange = 1.0 and (rate - rateMin) = rate
        // display = 1.0 + rate * (4.0 - 1.0) / (1.0 - 0.0)
        // display = 1.0 + rate * 3.0
        return minDisplay + rate * (maxDisplay - minDisplay)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        VStack {
            Spacer()

            VoiceIndicatorView(
                isListening: $viewModel.isListening,
                isProcessing: $viewModel.isProcessing,
                isSpeaking: $viewModel.isSpeaking
            )
            .onTapGesture {
                // Wrap the call that initiates async work in a Task
                Task { // Start asynchronous work here
                    viewModel.cycleState() // Call the function within the Task
                }
            }

            HStack {
                Text("Speed:")
                    .foregroundColor(.white)
                Slider(value: $viewModel.ttsRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate, step: 0.05)
                // Display the multiplier (Default rate 0.5 = 1.0x)
                Text(String(format: "%.1fx", viewModel.ttsDisplayMultiplier))
                    .foregroundColor(.white)
                    .frame(width: 40, alignment: .leading) // Align text
            }
            .padding()
             // .disabled(viewModel.isSpeaking) // REMOVED: Allow adjustment while speaking

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .onAppear {
             // viewModel.logger.critical("🚨 ContentView onAppear - TESTING LOG OUTPUT 🚨") // Comment out or remove logger call
             viewModel.logger.info("ContentView appeared.") // Keep this one for now
            // Optional: Automatically start listening when the view appears
            // viewModel.startListening()
        }
        .onDisappear {
             viewModel.logger.info("ContentView disappeared.")
             // Ensure cleanup when the view is no longer visible
             viewModel.cleanupOnDisappear()
        }
    }
}

// --- Previews ---
#Preview {
    ContentView()
}

