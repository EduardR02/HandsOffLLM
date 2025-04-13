//
//  ContentView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 08.04.25.
//

import SwiftUI
import AVFoundation
import Speech
import OSLog
import ChunkedAudioPlayer
import Combine


struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String // e.g., "user", "assistant"
    let content: String
}

struct ClaudeRequest: Codable {
    let model: String
    let system: String?
    let messages: [MessageParam]
    let stream: Bool
    let max_tokens: Int
    let temperature: Float
}

struct MessageParam: Codable {
    let role: String
    let content: String
}

struct ClaudeStreamEvent: Decodable {
    let type: String
    let delta: Delta?
    let message: ClaudeResponseMessage? // For message_stop event
}
struct Delta: Decodable {
    let type: String?
    let text: String?
}
struct ClaudeResponseMessage: Decodable {
    let id: String
    let role: String
    let usage: UsageData?
}
struct UsageData: Decodable {
    let input_tokens: Int
    let output_tokens: Int
}


struct OpenAITTSRequest: Codable {
    let model: String
    let input: String
    let voice: String
    let response_format: String
    let stream: Bool
    let instructions: String?
}


struct GeminiRequest: Codable {
    let contents: [GeminiContent]
}

struct GeminiContent: Codable {
    let role: String
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String
}

struct GeminiResponseChunk: Decodable {
    let candidates: [GeminiCandidate]?
}
struct GeminiCandidate: Decodable {
    let content: GeminiContent?
}



@MainActor
class ChatViewModel: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")
    
    enum LLMProvider { case gemini, claude }

    @Published var messages: [ChatMessage] = []
    @Published var isListening: Bool = false
    @Published var isProcessing: Bool = false // Thinking/Waiting for LLM
    @Published var isSpeaking: Bool = false   // TTS playback is active
    @Published var ttsRate: Float = 2.0 {
        didSet {
            chunkedAudioPlayer.rate = ttsRate
        }
    }
    @Published var listeningAudioLevel: Float = -50.0 // Audio level dBFS (-50 silence, 0 max)
    @Published var ttsOutputLevel: Float = 0.0      // Restored TTS output level (0-1)
    @Published var selectedProvider: LLMProvider = .claude // LLM Provider

    // --- Internal State ---
    private var llmTask: Task<Void, Never>? = nil
    private var isLLMFinished: Bool = false
    private var llmResponseBuffer: String = ""
    private var processedTextIndex: Int = 0 // Index up to which text has been *sent* for TTS fetching
    private var currentSpokenText: String = ""
    private var hasUserStartedSpeakingThisTurn: Bool = false
    private var hasReceivedFirstLLMChunk: Bool = false
    private var ttsFetchTask: Task<Void, Never>? = nil // Task for fetching the *next* audio stream
    private var audioStreamQueue: [AsyncThrowingStream<Data, Error>] = [] // Queue for streams
    private var internalPlayerState: AudioPlayerState? = .initial // Initialize to initial

    // --- Audio Components ---
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let chunkedAudioPlayer = AudioPlayer()
    private var cancellables = Set<AnyCancellable>()

    // --- Configuration & Timers ---
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 1.5
    private let audioLevelUpdateRate: TimeInterval = 0.1
    private var audioLevelTimer: Timer?
    private let claudeModel = "claude-3-7-sonnet-20250219"
    private let geminiModel = "gemini-2.0-flash"
    private let openAITTSModel = "gpt-4o-mini-tts"
    private let openAITTSVoice = "nova"
    private let openAITTSFormat = "wav"
    private let maxTTSChunkLength = 4000
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config)
    }()

    // --- API Keys & Prompt ---
    private var anthropicAPIKey: String?
    private var geminiAPIKey: String?
    private var openaiAPIKey: String?
    private var systemPrompt: String?
    private var lastMeasuredAudioLevel: Float = -50.0

    override init() {
        super.init()
        speechRecognizer.delegate = self
        
        self.anthropicAPIKey = APIKeys.anthropic
        self.geminiAPIKey = APIKeys.gemini
        self.openaiAPIKey = APIKeys.openai
        
        if anthropicAPIKey == nil || anthropicAPIKey!.isEmpty || anthropicAPIKey == "YOUR_ANTHROPIC_API_KEY" {
             logger.warning("Anthropic API Key is not set in APIKeys.swift.")
         }
         if geminiAPIKey == nil || geminiAPIKey!.isEmpty || geminiAPIKey == "YOUR_GEMINI_API_KEY" {
             logger.warning("Gemini API Key is not set in APIKeys.swift.")
         }
         if openaiAPIKey == nil || openaiAPIKey!.isEmpty || openaiAPIKey == "YOUR_OPENAI_API_KEY" {
             logger.warning("OpenAI API Key is not set in APIKeys.swift.")
         }
        
        self.systemPrompt = Prompts.chatPrompt
        if systemPrompt == nil || systemPrompt!.isEmpty {
             logger.warning("System Prompt is empty in Prompts.swift.")
        } else if systemPrompt == "You are a helpful voice assistant. Keep your responses concise and conversational." {
            logger.warning("Using the default placeholder system prompt. Edit Prompts.swift to customize.")
        } else {
            logger.debug("Custom system prompt loaded.")
        }
        
        // Set the initial player rate based on the default ttsRate
        chunkedAudioPlayer.rate = ttsRate
        logger.debug("Initial player rate set to: \(self.ttsRate)")
        
        requestPermissions()
        setupAudioPlayerSubscriptions()
    }
    
    // --- Permission Request ---
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if authStatus != .authorized {
                    self.logger.error("Speech recognition authorization denied.")
                    // Consider adding UI feedback for the user here
                }
            }
        }
        
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !granted {
                    self.logger.error("Microphone permission denied.")
                    // Consider adding UI feedback for the user here
                }
            }
        }
    }
    
    // --- State Control ---
    func cycleState() {
        Task { @MainActor in
            if !isListening && !isProcessing && !isSpeaking {
                // Currently idle -> Start listening
                startListening()
            } else if isListening {
                // Currently listening -> Stop listening and process speech
                stopListeningAndProcess()
            } else if isProcessing || isSpeaking {
                // Currently processing or speaking -> Interrupt TTS and go back to listening
                interruptTTSAndStartListening()
            }
        }
    }
    
    // General purpose cancellation/reset, might be called by system events or future UI elements
    func cancelProcessingAndSpeaking() {
        logger.notice("⏹️ General cancel requested (not user TTS interrupt).")
        llmTask?.cancel()
        llmTask = nil
        stopSpeaking() // Calls the full stop/reset
        // Ensure clean state (likely redundant due to stopSpeaking, but safe)
        if self.isProcessing { isProcessing = false }
        self.llmResponseBuffer = ""
        self.processedTextIndex = 0
        self.isLLMFinished = false
    }
    
    @MainActor
    func interruptTTSAndStartListening() {
        logger.notice("⏹️ User interrupted TTS. Stopping TTS and switching to listening.")

        // 1. Stop audio playback immediately
        chunkedAudioPlayer.stop()
        logger.debug("Interrupt: Called chunkedAudioPlayer.stop().")

        // 2. Cancel any ongoing/pending TTS fetch
        if let task = ttsFetchTask {
            task.cancel()
            ttsFetchTask = nil
            logger.debug("Interrupt: Cancelled TTS fetch task.")
        }

        // 3. Clear the audio queue
        if !audioStreamQueue.isEmpty {
            audioStreamQueue.removeAll()
            logger.debug("Interrupt: Cleared audio stream queue.")
        }

        // 4. Check if LLM is still running and cancel it
        let wasLLMRunning = (llmTask != nil)
        if let task = llmTask {
            task.cancel()
            llmTask = nil
            logger.debug("Interrupt: Cancelled LLM task.")
        }

        // 5. Handle message log (no change needed here, logic is sound)
        if wasLLMRunning || !isLLMFinished {
            if messages.last?.role == "assistant_partial" || messages.last?.role == "assistant_error" {
                logger.debug("Interrupt: Removing last partial/error message added before interruption (safeguard).")
                messages.removeLast()
            }
            isLLMFinished = false
            llmResponseBuffer = ""
        } else {
            logger.debug("Interrupt: LLM was already finished. Keeping final assistant message.")
        }

        // 6. Reset state variables
        isSpeaking = false
        isProcessing = false // Go straight to listening
        ttsOutputLevel = 0.0
        processedTextIndex = 0

        // 7. Deactivate audio session
        deactivateAudioSession()

        // 8. Start listening immediately
        startListening()
    }
    
    // --- Speech Recognition (Listening) ---
    func startListening() {
        guard !audioEngine.isRunning else {
             logger.warning("Attempted to start listening while audio engine was already running.")
             return
        }
        
        // Reset states for listening
        isListening = true
        isProcessing = false
        isSpeaking = false
        currentSpokenText = ""
        hasUserStartedSpeakingThisTurn = false
        listeningAudioLevel = -50.0
        logger.notice("🎙️ Listening started...")
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try? audioSession.setActive(false) // Ensure previous session is inactive
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            logger.debug("Audio session configured and activated for listening.")
        } catch {
            logger.error("🚨 Audio session setup error during listening start: \(error.localizedDescription)")
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
        
        guard speechRecognizer.isAvailable else {
            logger.error("🚨 Speech recognizer is not available right now.")
            isListening = false
            // Maybe show UI feedback here?
            return
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Ensure task hasn't been cancelled or stopped elsewhere
                guard self.recognitionTask != nil else { return }
                
                var isFinal = false
                
                if let result = result {
                    self.currentSpokenText = result.bestTranscription.formattedString
                    isFinal = result.isFinal
                    
                    // Start/Reset silence timer based on speech detection
                    if !self.currentSpokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.hasUserStartedSpeakingThisTurn {
                        // logger.info("🎤 User started speaking. Starting silence timer.") // Too verbose
                        self.hasUserStartedSpeakingThisTurn = true
                        self.startSilenceTimer()
                    } else if self.hasUserStartedSpeakingThisTurn {
                        self.resetSilenceTimer() // Keep resetting timer while user speaks
                    }

                    if isFinal {
                        self.logger.info("✅ Final transcription received: '\(self.currentSpokenText)'")
                        self.invalidateSilenceTimer()
                        // Process the final result
                        self.stopListeningAndProcess(transcription: self.currentSpokenText)
                        return // Important: exit early as stopListeningAndProcess handles cleanup
                    }
                }
                
                if let error = error {
                     let nsError = error as NSError
                     // Ignore specific common, usually non-fatal errors (e.g., speech endpointing)
                     if !(nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 1107)) {
                         self.logger.warning("🚨 Recognition task error: \(error.localizedDescription)")
                     }
                    self.invalidateSilenceTimer()
                    // Only cleanup if recognition hasn't already finalized
                    if !isFinal {
                        self.stopListeningCleanup()
                    }
                    // Potentially add logic here to process any partially recognized text if desired on error?
                }
            }
        }
        
        // Feed audio buffer to the recognizer
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] (buffer, time) in
            guard let self = self else { return }
            // Only process audio if listening and not speaking (avoids feedback loop)
            if self.isListening && !self.isSpeaking {
                 self.recognitionRequest?.append(buffer)
                 self.lastMeasuredAudioLevel = self.calculatePowerLevel(buffer: buffer)
            }
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            startAudioLevelTimer() // Start monitoring audio level for UI
        } catch {
            logger.error("🚨 Audio engine start error: \(error.localizedDescription)")
            // Ensure cleanup happens if engine fails to start
            recognitionTask?.cancel()
            recognitionTask = nil
            stopListeningCleanup()
        }
    }
    
    // Calculates RMS power and converts to dBFS for UI meter
    private func calculatePowerLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -50.0 }
        let channelDataValue = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
        let rms = sqrt(channelDataValue.reduce(0.0) { $0 + ($1 * $1) } / Float(buffer.frameLength))
        let dbValue = (rms > 0) ? (20 * log10(rms)) : -160.0 // Use -160 for true silence representation
        let minDb: Float = -50.0 // Floor for UI visualization
        return max(minDb, dbValue)
    }
    
    // Timer for updating the audio level UI
    func startAudioLevelTimer() {
        invalidateAudioLevelTimer() // Ensure no duplicate timers
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: audioLevelUpdateRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isListening else {
                    self?.invalidateAudioLevelTimer(); return // Stop timer if not listening
                }
                self.listeningAudioLevel = self.lastMeasuredAudioLevel
            }
        }
    }
    
    func invalidateAudioLevelTimer() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }
    
    // Stops the audio engine if it's running
    func stopAudioEngine() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        invalidateAudioLevelTimer() // Stop UI updates
        logger.debug("Audio engine stopped.")
    }
    
    // Comprehensive cleanup for the listening state
    func stopListeningCleanup() {
        stopAudioEngine() // Stop engine first
        recognitionRequest?.endAudio() // Signal end of audio to request
        recognitionTask?.cancel() // Cancel the task
        recognitionTask = nil
        recognitionRequest = nil
        invalidateSilenceTimer() // Stop silence detection
        if isListening { // Only log and update state if we were actually listening
            isListening = false
            listeningAudioLevel = -50.0 // Reset UI level
            logger.notice("🎙️ Listening stopped.")
        }
        deactivateAudioSession() // Release audio session
    }
    
    // Called when listening should stop and recognized text should be processed
    func stopListeningAndProcess(transcription: String? = nil) {
         Task { @MainActor [weak self] in
             guard let self = self else { return }
             guard self.isListening else { return } // Only process if currently listening
             
             self.isProcessing = true // Indicate we are now processing
             let textToProcess = transcription ?? self.currentSpokenText // Use provided final transcription or current best
             
             self.stopListeningCleanup() // Perform all listening cleanup
             
             // Only proceed if there's actual text to process
             if !textToProcess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 logger.info("⚙️ Processing transcription: '\(textToProcess)'")
                 let userMessage = ChatMessage(role: "user", content: textToProcess)
                 // Avoid adding duplicate messages if processing triggers rapidly
                 if self.messages.last?.role != "user" || self.messages.last?.content != userMessage.content {
                     self.messages.append(userMessage)
                 }
                 
                 // Start the LLM fetch task
                 self.llmTask = Task {
                     await self.fetchLLMResponse(prompt: textToProcess)
                 }
             } else {
                 logger.info("⚙️ No text detected to process. Returning to listening.")
                 self.isProcessing = false // Reset processing flag
                 // Optionally, start listening again immediately or wait for user interaction
                 self.startListening() // Restart listening if no text was detected
             }
         }
     }

    // --- Silence Detection ---
    func resetSilenceTimer() {
        // Simply reset the fire date of the existing timer
        silenceTimer?.fireDate = Date(timeIntervalSinceNow: silenceThreshold)
    }
    
    func startSilenceTimer() {
        invalidateSilenceTimer() // Ensure no duplicate timers
        silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                 // Only trigger if still listening (timer might fire after stop)
                 guard self.isListening else { return }
                self.logger.notice("⏳ Silence detected by timer. Processing...")
                self.stopListeningAndProcess(transcription: self.currentSpokenText)
            }
        }
    }
    
    func invalidateSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
    
    // --- LLM Interaction ---
    func fetchLLMResponse(prompt: String) async {
        // Initial cleanup on MainActor
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            logger.debug("fetchLLMResponse: Starting, resetting TTS state (keeping isProcessing=true).")

            // Stop any *previous* TTS activity (player, fetch task, queue)
            ttsFetchTask?.cancel()
            ttsFetchTask = nil
            if isSpeaking || internalPlayerState == .playing || internalPlayerState == .paused {
                chunkedAudioPlayer.stop()
            }
            if !audioStreamQueue.isEmpty {
                audioStreamQueue.removeAll()
            }

            // Reset LLM/TTS state for the new response
            llmResponseBuffer = ""
            processedTextIndex = 0
            isLLMFinished = false
            hasReceivedFirstLLMChunk = false
            if isSpeaking { isSpeaking = false }
            if ttsOutputLevel != 0.0 { ttsOutputLevel = 0.0 }
        }
        
        var fullResponseAccumulator = ""
        var llmError: Error? = nil
        
        do {
            try Task.checkCancellation() // Check before network call
            
            // Select provider and get stream (No changes to API logic requested)
            let stream: AsyncThrowingStream<String, Error>
            let providerString = String(describing: selectedProvider)
            switch selectedProvider {
            case .gemini:
                guard let apiKey = self.geminiAPIKey else { throw LlmError.apiKeyMissing(provider: "Gemini") }
                stream = try await fetchGeminiResponse(apiKey: apiKey, prompt: prompt)
            case .claude:
                guard let apiKey = self.anthropicAPIKey else { throw LlmError.apiKeyMissing(provider: "Claude") }
                stream = try await fetchClaudeResponse(apiKey: apiKey, prompt: prompt)
            }
            
            // Process the stream
            for try await chunk in stream {
                try Task.checkCancellation() // Check frequently during streaming
                fullResponseAccumulator += chunk
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.llmResponseBuffer.append(chunk) // Append to internal buffer

                    if !self.hasReceivedFirstLLMChunk {
                        self.logger.info("🤖 Received first LLM chunk (\(providerString)).")
                         self.hasReceivedFirstLLMChunk = true
                    }
                    // Trigger TTS buffering for the newly received text
                    self.fetchAndBufferNextChunkIfNeeded()
                }
            }
            
        } catch is CancellationError {
            logger.notice("⏹️ LLM Task Cancelled.")
            llmError = CancellationError()
            // State transition is handled by the caller (interruptTTSAndStartListening or cleanupOnDisappear)
        } catch {
            logger.error("🚨 LLM Error during stream: \(error.localizedDescription)")
            llmError = error
            // On non-cancellation error, stop TTS playback and reset state
            await MainActor.run { [weak self] in self?.stopSpeaking() }
        }

        // --- LLM Stream Finished ---
        await MainActor.run { [weak self] in
            guard let self = self else { return }

            // Only finalize if the task wasn't cancelled externally
            if !(llmError is CancellationError) {
                 self.isLLMFinished = true // Mark LLM as fully received
                 self.logger.info("🤖 LLM full response received (\(fullResponseAccumulator.count) chars).")
                 // print("--- LLM FINAL RESPONSE ---\n\(fullResponseAccumulator)\n--------------------------") // Keep for debugging if needed

                // Append final assistant message or error message
                if llmError == nil {
                    if !fullResponseAccumulator.isEmpty {
                        let assistantMessage = ChatMessage(role: "assistant", content: fullResponseAccumulator)
                        if self.messages.last?.role != "assistant" || self.messages.last?.content != assistantMessage.content {
                             self.messages.append(assistantMessage)
                         }
                    } else {
                         logger.warning("LLM finished successfully but response was empty.")
                    }
                } else {
                    let errorMessageContent = "Sorry, an error occurred processing the response."
                    let errorMessage = ChatMessage(role: "assistant_error", content: errorMessageContent)
                     if self.messages.last?.content != errorMessageContent {
                        self.messages.append(errorMessage)
                     }
                }
                 self.llmTask = nil // Clear task reference

                // Attempt to fetch the final TTS chunk if needed
                 self.fetchAndBufferNextChunkIfNeeded()

                // Check if the entire process (LLM + TTS) is complete only if the player is idle
                 if (self.internalPlayerState == .some(.initial) || self.internalPlayerState == .some(.completed)) {
                      self.checkCompletionAndTransition()
                 }
                 // Otherwise, the player state sink will handle the check upon completion/idle
            } else {
                // LLM Task was cancelled externally, cleanup handled elsewhere
                self.logger.info("🤖 LLM Task was cancelled externally. Finalization skipped.")
                self.llmTask = nil
            }
        }
    }
    
    // Custom Error enum for LLM interactions
    enum LlmError: Error, LocalizedError {
        case apiKeyMissing(provider: String)
        case invalidURL
        case requestEncodingError(Error)
        case networkError(Error)
        case invalidResponse(statusCode: Int, body: String?)
        case responseDecodingError(Error)
        case streamingError(String)
        
        var errorDescription: String? {
            switch self {
            case .apiKeyMissing(let provider): return "\(provider) API Key is missing."
            case .invalidURL: return "Invalid API endpoint URL."
            case .requestEncodingError(let error): return "Failed to encode request: \(error.localizedDescription)"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .invalidResponse(let statusCode, let body): return "Invalid response from server: Status \(statusCode). Body: \(body ?? "N/A")"
            case .responseDecodingError(let error): return "Failed to decode response: \(error.localizedDescription)"
            case .streamingError(let message): return "Streaming error: \(message)"
            }
        }
    }
    
    // --- API Fetching Functions (No changes requested) ---
    func fetchGeminiResponse(apiKey: String, prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(geminiModel):streamGenerateContent?key=\(apiKey)&alt=sse") else {
            throw LlmError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var conversationHistory: [GeminiContent] = []
        if let sysPrompt = self.systemPrompt, !sysPrompt.isEmpty {
            conversationHistory.append(GeminiContent(role: "user", parts: [GeminiPart(text: sysPrompt)]))
            conversationHistory.append(GeminiContent(role: "model", parts: [GeminiPart(text: "OK.")]))
        }
        let history = messages.map { GeminiContent(role: $0.role == "user" ? "user" : "model", parts: [GeminiPart(text: $0.content)]) }
        conversationHistory.append(contentsOf: history)
        let payload = GeminiRequest(contents: conversationHistory)
        
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }
        
        let (bytes, response): (URLSession.AsyncBytes, URLResponse) = try await urlSession.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await byte in bytes { errorBody += String(UnicodeScalar(byte)) }
            logger.error("Gemini Error Body: \(errorBody)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody)
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                var streamError: Error? = nil
                do {
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonData = Data(line.dropFirst(6).utf8)
                            if jsonData.isEmpty { continue }
                            do {
                                let chunk = try JSONDecoder().decode(GeminiResponseChunk.self, from: jsonData)
                                if let text = chunk.candidates?.first?.content?.parts.first?.text {
                                    continuation.yield(text)
                                }
                            } catch {
                                logger.warning("Failed to decode Gemini JSON chunk: \(error)")
                            }
                        }
                    }
                } catch { streamError = error }
                continuation.finish(throwing: streamError)
            }
        }
    }
    
    func fetchClaudeResponse(apiKey: String, prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LlmError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let history = messages.map { MessageParam(role: $0.role, content: $0.content) }
        let systemPromptToUse: String? = (self.systemPrompt?.isEmpty ?? true) ? nil : self.systemPrompt
        
        let payload = ClaudeRequest(
            model: claudeModel,
            system: systemPromptToUse,
            messages: history,
            stream: true,
            max_tokens: 8000,
            temperature: 1.0
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }
        
        let (bytes, response): (URLSession.AsyncBytes, URLResponse) = try await urlSession.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await byte in bytes { errorBody += String(UnicodeScalar(byte)) }
            logger.error("Claude Error Body: \(errorBody)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody)
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                var streamError: Error? = nil
                do {
                    for try await line in bytes.lines {
                        if line.hasPrefix("data:") {
                            let jsonData = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                            if jsonData.isEmpty { continue }
                            do {
                                let event = try JSONDecoder().decode(ClaudeStreamEvent.self, from: jsonData)
                                if event.type == "content_block_delta" || event.type == "message_delta" {
                                    if let text = event.delta?.text {
                                        continuation.yield(text)
                                    }
                                } else if event.type == "message_stop" {
                                     // Optionally log usage data here if needed
                                     // if let usage = event.message?.usage {
                                     //     logger.debug("Claude usage: In=\(usage.input_tokens), Out=\(usage.output_tokens)")
                                     // }
                                }
                            } catch {
                                 logger.warning("Failed to decode Claude JSON event: \(error)")
                            }
                        }
                    }
                } catch { streamError = error }
                continuation.finish(throwing: streamError)
            }
        }
    }
    
    // --- TTS Chunking, Fetching, Buffering, and Playback ---

    @MainActor
    private func fetchAndBufferNextChunkIfNeeded() {
        // Guard conditions: Don't fetch if already fetching or if queue has items (simple 1-ahead buffering)
        guard ttsFetchTask == nil else { return }
        guard audioStreamQueue.isEmpty else { return } // Only buffer one chunk ahead

        // Find the next chunk of text suitable for TTS
        let (chunk, nextIndex) = findNextTTSChunk(text: llmResponseBuffer, startIndex: processedTextIndex, isComplete: isLLMFinished)

        // If no chunk found (e.g., waiting for more text), check completion state if LLM is done
        if chunk.isEmpty {
            if isLLMFinished {
                checkCompletionAndTransition()
            }
            return
        }

        // Mark this text segment as processed (sent for fetching)
        self.processedTextIndex = nextIndex
        logger.info("➡️ Found TTS chunk (\(chunk.count) chars). Starting fetch...")

        guard let apiKey = self.openaiAPIKey else {
             logger.error("🚨 OpenAI API Key missing, cannot fetch TTS.")
             // Potentially add error message to UI?
             return
        }

        // Start the TTS fetch task
        ttsFetchTask = Task { [weak self] in
            guard let self = self else { return }

            var streamResult: Result<AsyncThrowingStream<Data, Error>, Error>?
            var streamerInstanceForCapture: TTSStreamer? // Temporary hold for potential cancellation

            do {
                 // Create the streamer and the async stream it manages
                 let (streamer, stream) = try self.createStreamAndStreamer(apiKey: apiKey, text: chunk)
                 streamerInstanceForCapture = streamer // Capture for potential cancellation

                 try Task.checkCancellation() // Check if fetch task itself was cancelled before stream creation finished
                 streamResult = .success(stream)
                 logger.info("✅ TTS stream fetched/created successfully for chunk.")

            } catch is CancellationError {
                logger.notice("⏹️ TTS Fetch task initiation cancelled.")
                streamResult = .failure(CancellationError())
                 // Ensure the streamer (if created) is cancelled
                 await MainActor.run { streamerInstanceForCapture?.cancel() }
            } catch {
                logger.error("🚨 Failed to create TTS stream: \(error.localizedDescription)")
                streamResult = .failure(error)
            }

            // --- Handle Fetch Result (on MainActor) ---
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.ttsFetchTask = nil // Mark fetch task as complete

                switch streamResult {
                case .success(let stream):
                    // Add the successfully created stream to the queue
                    self.audioStreamQueue.append(stream)
                    logger.debug("Appended fetched stream to queue. Queue size: \(self.audioStreamQueue.count)")
                    // Player state sink will handle triggering playback if player is idle

                case .failure(let error):
                     if !(error is CancellationError) {
                         logger.error("TTS Stream Creation Failed: \(error.localizedDescription)")
                         // Maybe add error message to chat?
                     }
                    // If fetch failed, check completion state only if player might be waiting
                    if self.internalPlayerState == .some(.initial) || self.internalPlayerState == .some(.completed) {
                        self.checkCompletionAndTransition()
                    }
                case .none: // Should not happen in this structure, but handle defensively
                     logger.warning("TTS Fetch task finished with no result.")
                     if self.internalPlayerState == .some(.initial) || self.internalPlayerState == .some(.completed) {
                         self.checkCompletionAndTransition()
                     }
                }
            }
        }
    }

    // Creates the TTSStreamer and the AsyncThrowingStream it populates
    private func createStreamAndStreamer(apiKey: String, text: String) throws -> (TTSStreamer, AsyncThrowingStream<Data, Error>) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LlmError.streamingError("Cannot synthesize empty text")
        }
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw LlmError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = OpenAITTSRequest(
            model: openAITTSModel, input: text, voice: openAITTSVoice,
            response_format: openAITTSFormat, stream: true, instructions: Prompts.ttsInstructions
        )

        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LlmError.requestEncodingError(error) }

        let streamer = TTSStreamer(request: request, logger: logger)

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            streamer.continuation = continuation // Assign continuation to the streamer
            continuation.onTermination = { @Sendable [weak streamer] terminationReason in
                 // Ensure the underlying URLSession task is cancelled when the stream terminates
                 Task { @MainActor [weak streamer] in
                     // logger.debug("TTS Stream terminated (\(String(describing: terminationReason))). Cancelling associated streamer.")
                     streamer?.cancel() // Use weak reference to avoid retain cycles
                 }
            }
            streamer.start() // Start the URLSession task
        }
        return (streamer, stream)
    }

    // Plays the next buffered audio stream if the player is ready
    @MainActor
    private func playBufferedStreamIfReady() {
        guard internalPlayerState == .some(.initial) || internalPlayerState == .some(.completed) else { return }
        guard !audioStreamQueue.isEmpty else {
            checkCompletionAndTransition() // No streams left, check if finished
            return
        }

        let streamToPlay = audioStreamQueue.removeFirst()
        let audioSession = AVAudioSession.sharedInstance()

        Task { // Use Task to allow async operations (sleep, session activation)
            do {
                // --- Configure Audio Session ONCE for Playback ---
                if audioSession.category != .playback {
                    logger.debug("Audio session category is not .playback, setting up for TTS...")
                    do {
                        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                        logger.debug("Previous audio session deactivated.")
                    } catch {
                        logger.warning("Could not deactivate previous audio session: \(error.localizedDescription)")
                    }
                    try? await Task.sleep(for: .milliseconds(50)) // Brief delay
                    try audioSession.setCategory(.playback, mode: .spokenAudio) // Simplified - no options
                    logger.debug("Audio category set to .playback, mode .spokenAudio.")
                    try audioSession.setActive(true)
                    logger.debug("Audio session activated for playback.")
                } else {
                     logger.debug("Audio session already configured for playback. Skipping setup.")
                     // Safety check: Ensure session is active if expected to be
                     if !audioSession.isOtherAudioPlaying {
                         try? audioSession.setActive(true)
                     }
                }

                // --- Start Playback ---
                // logger.debug("Setting player rate to \(self.ttsRate) before start.") // Redundant with log below
                self.chunkedAudioPlayer.rate = self.ttsRate
                self.chunkedAudioPlayer.volume = 1.0
                self.chunkedAudioPlayer.start(streamToPlay, type: kAudioFileWAVEType)
                logger.info("▶️ Player start() called with stream. Queue size now: \(self.audioStreamQueue.count)")

                // --- Apply Rate Post-Start (Robustness) ---
                Task { @MainActor [weak self] in
                     guard let self = self else { return }
                     try? await Task.sleep(for: .milliseconds(50))
                     // Only apply if player is still playing (might have finished very quickly)
                     if self.internalPlayerState == .playing {
                         // logger.trace("Applying rate \(self.ttsRate) shortly after start.") // Too verbose
                         self.chunkedAudioPlayer.rate = self.ttsRate
                     }
                }

            } catch {
                logger.error("🚨 Failed during audio session setup or player start: \(error.localizedDescription)")
                if let nsError = error as NSError? {
                     logger.error("Error details: Domain=\(nsError.domain), Code=\(nsError.code), UserInfo=\(nsError.userInfo)")
                }
                // Cleanup on failure
                audioStreamQueue.removeAll()
                if self.isProcessing { self.isProcessing = false }
                if self.isSpeaking { self.isSpeaking = false }
                deactivateAudioSession()
                checkCompletionAndTransition()
            }
        }
    }

    // Checks if LLM and TTS are finished and transitions state accordingly
    private func checkCompletionAndTransition() {
        // logger.trace("Checking completion/transition...") // Too verbose

         // Condition 1: All work done (LLM finished, all text processed, queue empty, no fetch running)
         //              AND Player is idle
         let isWorkDone = isLLMFinished &&
                          processedTextIndex == llmResponseBuffer.count &&
                          audioStreamQueue.isEmpty &&
                          ttsFetchTask == nil
         let isPlayerIdle = (internalPlayerState == .some(.initial) || internalPlayerState == .some(.completed))

         if isWorkDone && isPlayerIdle {
             logger.info("✅ All TTS processed and played. LLM finished.")
             if self.isProcessing { self.isProcessing = false }
             if self.isSpeaking { self.isSpeaking = false }
             deactivateAudioSession() // Deactivate playback session
             logger.debug("Deactivated playback audio session before transitioning to listen.")
             self.autoStartListeningAfterDelay() // Go back to listening
         }
         // Condition 2: Player is idle, but more work might exist
         else if isPlayerIdle {
             if !audioStreamQueue.isEmpty {
                 logger.debug("Player Idle, attempting to play next from queue.")
                 self.playBufferedStreamIfReady()
             } else if processedTextIndex < llmResponseBuffer.count && ttsFetchTask == nil {
                 logger.debug("Player Idle & Queue Empty, checking for more text to fetch.")
                 self.fetchAndBufferNextChunkIfNeeded()
             } else if !isLLMFinished {
                 logger.debug("Player Idle, Queue Empty, Text Processed, but waiting for LLM to finish.")
             } else if ttsFetchTask != nil {
                 // This case should be rare if logic is correct, but indicates waiting for the final fetch
                 logger.debug("Player Idle, Queue Empty, Text Processed, LLM Done, but waiting for final TTS fetch task.")
             }
         }
         // Condition 3: Player is busy - No action needed, wait for player state change
         // else { logger.trace("Player is busy. No transition action needed now.") } // Too verbose
    }

    // Finds the next segment of text for TTS, considering sentence/clause breaks
    private func findNextTTSChunk(text: String, startIndex: Int, isComplete: Bool) -> (String, Int) {
        let currentIndex = text.index(text.startIndex, offsetBy: startIndex)
        let remainingText = text.suffix(from: currentIndex)
        if remainingText.isEmpty { return ("", startIndex) }

        // If LLM is done, send the whole remaining text (up to max length)
        if isComplete {
            let chunk = String(remainingText.prefix(maxTTSChunkLength))
            return (chunk, startIndex + chunk.count)
        }

        // If LLM ongoing, find a suitable split point within the next potential chunk
        let potentialChunk = remainingText.prefix(maxTTSChunkLength)
        var bestSplitIndex = potentialChunk.endIndex // Default to end of potential chunk

        // Prefer splitting after sentence endings (.!?) if near the end or chunk is short
        let sentenceEndCharacters = ".!?"
        if let lastSentenceEnd = potentialChunk.lastIndex(where: { sentenceEndCharacters.contains($0) }) {
            let distanceToEnd = potentialChunk.distance(from: lastSentenceEnd, to: potentialChunk.endIndex)
            let splitAfterSentenceEnd = potentialChunk.index(after: lastSentenceEnd)
            // Use this split if it's close to the max length, or if the chunk is relatively short anyway
            if distanceToEnd < 150 || potentialChunk.count < 200 {
                 bestSplitIndex = splitAfterSentenceEnd
            }
        // Otherwise, try splitting after commas if near the end or chunk is short
        } else if let lastComma = potentialChunk.lastIndex(of: ",") {
             let distanceToEnd = potentialChunk.distance(from: lastComma, to: potentialChunk.endIndex)
             let splitAfterComma = potentialChunk.index(after: lastComma)
             if distanceToEnd < 150 || potentialChunk.count < 200 {
                 bestSplitIndex = splitAfterComma
             }
        }

        let chunkLength = potentialChunk.distance(from: potentialChunk.startIndex, to: bestSplitIndex)

        // Minimum length checks to avoid very short, awkward chunks, especially at the beginning
        let minInitialChunkLength = 80
        let minSubsequentChunkLength = 50 // Allow slightly shorter subsequent chunks

        if startIndex == 0 && chunkLength < minInitialChunkLength && !isComplete {
            // logger.trace("Initial chunk too short (\(chunkLength)/\(minInitialChunkLength)), waiting.") // Too verbose
            return ("", startIndex) // Wait for more text
        }
        // If it's potentially the *last partial* chunk and too short, wait
        let isLastPartialChunk = (potentialChunk.endIndex == remainingText.endIndex)
        if startIndex > 0 && chunkLength < minSubsequentChunkLength && isLastPartialChunk && !isComplete {
             // logger.trace("Subsequent partial chunk too short (\(chunkLength)/\(minSubsequentChunkLength)), waiting.") // Too verbose
            return ("", startIndex) // Wait for more text
        }

        let finalChunk = String(potentialChunk[..<bestSplitIndex])
        return (finalChunk, startIndex + finalChunk.count)
    }

    // --- Speech Recognizer Delegate ---
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            if !available {
                self?.logger.error("🚨 Speech recognizer became unavailable.")
                self?.stopListeningCleanup() // Stop listening if recognizer fails
                // Consider showing UI feedback
              }
         }
     }

    // --- Auto-Restart Listening ---
    func autoStartListeningAfterDelay() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Double-check state before starting, in case something changed rapidly
            guard !self.isSpeaking && !self.isProcessing && !self.isListening else {
                self.logger.warning("🎤 Aborted auto-start: State changed before execution (isListening=\(self.isListening), isSpeaking=\(self.isSpeaking), isProcessing=\(self.isProcessing)).")
                return
            }
            
            logger.info("🎙️ TTS finished. Transitioning back to listening.")
            if self.isProcessing { self.isProcessing = false } // Ensure processing flag is off
            self.startListening() // Start immediately
        }
    }
    
    // --- Cleanup ---
    deinit {
        logger.notice("ChatViewModel deinit.")
        // Cancel tasks synchronously
        llmTask?.cancel()
        ttsFetchTask?.cancel()
        // Stop player and deactivate session on main thread
        Task { @MainActor [weak self] in
            self?.chunkedAudioPlayer.stop()
            self?.deactivateAudioSession()
        }
    }
    
    func cleanupOnDisappear() {
        logger.info("ContentView disappeared. Cleaning up audio and tasks.")
        stopListeningCleanup() // Handles listening state, engine, tasks, session
        // Explicitly cancel LLM/TTS tasks and stop player again as belt-and-suspenders
        llmTask?.cancel()
        llmTask = nil
        ttsFetchTask?.cancel()
        ttsFetchTask = nil
        chunkedAudioPlayer.stop() // This should trigger state sink -> playBufferedStreamIfReady -> checkCompletion -> deactivate
        // Reset all relevant states
        isProcessing = false
        isSpeaking = false
        ttsOutputLevel = 0.0
        llmResponseBuffer = ""
        processedTextIndex = 0
        isLLMFinished = false
        audioStreamQueue.removeAll()
        deactivateAudioSession() // Ensure session is off
    }
    
    // Stops TTS playback and resets related state, including audio session
    @MainActor
    func stopSpeaking() {
         logger.notice("⏹️ stopSpeaking called (explicit stop/cleanup).")
         chunkedAudioPlayer.stop() // Should trigger state sink -> .initial
         ttsFetchTask?.cancel()
         ttsFetchTask = nil
         audioStreamQueue.removeAll()
         // Reset flags
         if isProcessing { isProcessing = false }
         if isSpeaking { isSpeaking = false }
         ttsOutputLevel = 0.0
         llmResponseBuffer = "" // Clear buffer on explicit stop
         processedTextIndex = 0
         isLLMFinished = false // Assume stop means LLM sequence is incomplete/interrupted
         deactivateAudioSession() // Ensure session is deactivated
         // The player state change to .initial should trigger checkCompletionAndTransition if needed
    }

    // Setup subscriptions to the audio player's state and errors
    private func setupAudioPlayerSubscriptions() {
         chunkedAudioPlayer.$currentState
             .receive(on: DispatchQueue.main) // Ensure UI updates on main thread
             .sink { [weak self] (state: AudioPlayerState?) in
                 guard let self = self else { return }
                 let previousState = self.internalPlayerState
                 self.internalPlayerState = state // Update internal tracking
                 logger.debug("AudioPlayer State Changed: \(String(describing: previousState)) -> \(String(describing: state))")

                 switch state {
                 case .initial, .completed: // Player is idle
                     if self.isSpeaking { self.isSpeaking = false } // Update UI state
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 } // Reset TTS UI level
                     logger.debug("Player Idle (State: \(String(describing: state))). Checking for next action...")
                     // Try playing next buffered chunk or check if all processing is complete
                     self.playBufferedStreamIfReady()

                 case .playing:
                     if !self.isSpeaking { self.isSpeaking = true } // Update UI state
                     // Ensure processing indicator is on while playing, unless LLM is fully done
                     if !self.isLLMFinished && !self.isProcessing {
                         self.isProcessing = true
                         // logger.debug("Player playing, ensuring isProcessing=true.") // Can be inferred
                     }
                     if self.ttsOutputLevel == 0.0 { self.ttsOutputLevel = 0.7 } // Show TTS activity level
                     // Proactively fetch the next TTS chunk while current one plays
                     // logger.trace("Player playing, proactively fetching next TTS chunk.") // A bit noisy
                     self.fetchAndBufferNextChunkIfNeeded()

                 case .paused: // Handle pause if needed (currently unused)
                     if self.isSpeaking { self.isSpeaking = false }
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }

                 case .failed:
                     logger.error("🚨 AudioPlayer Failed (See $currentError). Resetting TTS state.")
                     if self.isSpeaking { self.isSpeaking = false }
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
                     // Clear queue and cancel fetch on player failure
                     audioStreamQueue.removeAll()
                     ttsFetchTask?.cancel()
                     ttsFetchTask = nil
                     deactivateAudioSession() // Ensure session is off
                     checkCompletionAndTransition() // Check overall state

                 case .none: // Should ideally not happen, but handle defensively
                     logger.trace("AudioPlayer State became nil.")
                     if self.isSpeaking { self.isSpeaking = false }
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
                 }
             }
             .store(in: &cancellables)

         // Log any errors published by the player
         chunkedAudioPlayer.$currentError
             .receive(on: DispatchQueue.main)
             .compactMap { $0 } // Ignore nil errors
             .sink { [weak self] (error: Error) in
                 self?.logger.error("🚨 AudioPlayer Error Detail: \(error.localizedDescription)")
                 // State transition is handled by the .failed case in the state sink
             }
             .store(in: &cancellables)
    }

    // Deactivates the shared audio session
    private func deactivateAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        // Only attempt deactivation if the session is not shared (i.e., we configured it)
        // Note: Checking category might not be sufficient if other apps use the same category.
        // A simple deactivation attempt is usually safe.
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            logger.debug("Audio session deactivated.")
        } catch {
            // This can happen if the session is already inactive, usually not critical.
            logger.warning("🚨 Failed to deactivate audio session (may already be inactive): \(error.localizedDescription)")
        }
    }
}

// --- TTSStreamer (Handles fetching TTS data stream) ---
private class TTSStreamer: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let logger: Logger
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var accumulatedData = Data() // Used only for buffering error response body
    var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    init(request: URLRequest, logger: Logger) {
        self.request = request
        self.logger = logger
        super.init()
    }

    // Starts the URLSession data task
    func start() {
        guard continuation != nil else {
            logger.warning("TTSStreamer start called without a continuation assigned.")
            return
        }
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData // Ensure fresh data
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil) // Background queue
        self.session?.dataTask(with: request).resume()
        // logger.debug("TTS URLSessionDataTask started.") // Maybe too verbose
    }

    // Cancels the URLSession and finishes the continuation with cancellation
    func cancel() {
        session?.invalidateAndCancel() // Cancel network task
        continuation?.finish(throwing: CancellationError()) // Finish stream
        continuation = nil // Avoid dangling reference
        logger.debug("TTSStreamer explicitly cancelled.")
    }

    // MARK: - URLSessionDataDelegate

    // Handle initial response headers
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("🚨 TTS Error: Did not receive HTTPURLResponse.")
            continuation?.finish(throwing: ChatViewModel.LlmError.networkError(URLError(.badServerResponse)))
            continuation = nil
            completionHandler(.cancel); return
        }
        self.response = httpResponse
        logger.debug("TTS Received response headers. Status: \(httpResponse.statusCode)")
        // Allow receiving data if status code looks okay initially (OpenAI streams data even on some errors initially)
        completionHandler(.allow)
    }

    // Handle received data chunks
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
         // Only yield data if the response status code was success (2xx)
         if let httpResponse = self.response, (200...299).contains(httpResponse.statusCode) {
             continuation?.yield(data)
         } else {
             // If status code indicates error, buffer data to potentially show error body later
             accumulatedData.append(data)
         }
    }

    // Handle task completion (error or success)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
         if let error = error { // Network-level error
             // Don't log cancellation errors verbosely if initiated by `cancel()`
             if (error as? URLError)?.code != .cancelled {
                 logger.error("🚨 TTS Network Error: \(error.localizedDescription)")
             }
             continuation?.finish(throwing: ChatViewModel.LlmError.networkError(error))
         } else if let httpResponse = self.response, !(200...299).contains(httpResponse.statusCode) { // API-level error
             let errorBody = String(data: accumulatedData, encoding: .utf8) ?? "Could not decode error body"
             logger.error("🚨 TTS API Error: Status \(httpResponse.statusCode). Body: \(errorBody)")
             continuation?.finish(throwing: ChatViewModel.LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody))
         } else { // Success
             // logger.debug("TTS Stream finished successfully.") // Can be inferred from termination log
             continuation?.finish()
         }
         // Invalidate session and clear continuation reference
         self.session?.finishTasksAndInvalidate()
         continuation = nil
    }
}

// --- SwiftUI View ---
struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    
    var body: some View {
        VStack {
            Spacer()
            
            VoiceIndicatorView(
                isListening: $viewModel.isListening,
                isProcessing: $viewModel.isProcessing,
                isSpeaking: $viewModel.isSpeaking,
                audioLevel: $viewModel.listeningAudioLevel,
                ttsLevel: $viewModel.ttsOutputLevel
            )
            .onTapGesture {
                Task {
                    viewModel.cycleState()
                }
            }
            
            HStack {
                Text("Speed:")
                    .foregroundColor(.white)
                Slider(value: $viewModel.ttsRate, in: 0.2...4.0, step: 0.1)
                Text(String(format: "%.1fx", viewModel.ttsRate))
                    .foregroundColor(.white)
                    .frame(width: 40, alignment: .leading)
            }
            .padding()
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .onAppear {
            // Start listening when the view appears
            viewModel.startListening()
        }
        .onDisappear {
            // Perform cleanup when the view disappears
            viewModel.cleanupOnDisappear()
        }
    }
}


#Preview {
    ContentView()
}