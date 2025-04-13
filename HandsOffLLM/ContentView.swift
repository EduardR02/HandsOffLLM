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
        } else if systemPrompt == "You are a helpful voice assistant. Keep your responses concise and conversational." {
            logger.warning("Using the default placeholder system prompt. Edit Prompts.swift to customize.")
        } else {
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
                }
            }
        }
        
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !granted {
                    self.logger.error("Microphone permission denied.")
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
                // cancelProcessingAndSpeaking() // Old behavior
            }
        }
    }
    
    func cancelProcessingAndSpeaking() {
        // This remains for potential other cancellation paths, but not user tap during TTS.
        logger.notice("⏹️ Cancel requested by user (general cancel).")

        if let task = llmTask {
            task.cancel()
            llmTask = nil
        }

        stopSpeaking() // Calls the full stop/reset including isProcessing = false

        // These might be redundant now depending on stopSpeaking, but ensure clean state
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
            task.cancel() // This cancellationError will be caught in fetchLLMResponse
            llmTask = nil
            logger.debug("Interrupt: Cancelled LLM task.")
        }

        // 5. Handle message log based on LLM completion status BEFORE interruption
        // If LLM was running or hadn't fully finished, remove any partial message added by cancelled fetchLLMResponse
        // Note: We modify fetchLLMResponse's cancellation handler to NOT add partial messages anymore.
        // This check becomes a safeguard or could be removed if confident fetchLLMResponse is clean.
        // Let's keep it as a safeguard for now.
        if wasLLMRunning || !isLLMFinished {
            if messages.last?.role == "assistant_partial" || messages.last?.role == "assistant_error" {
                logger.debug("Interrupt: Removing last partial/error message added before interruption (safeguard).")
                messages.removeLast()
            }
            // Explicitly mark LLM as not finished since it was interrupted.
            isLLMFinished = false
            llmResponseBuffer = "" // Clear buffer if LLM was interrupted.
        } else {
            // If LLM *was* finished, the full 'assistant' message should already be there. Do nothing to messages.
            logger.debug("Interrupt: LLM was already finished. Keeping final assistant message.")
            // llmResponseBuffer is likely needed by findNextTTSChunk if it restarts, but startListening clears it anyway.
        }


        // 6. Reset state variables necessary for a clean startListening transition
        isSpeaking = false
        isProcessing = false // We are going straight to listening
        ttsOutputLevel = 0.0
        // llmResponseBuffer = "" // Handled above based on LLM state
        processedTextIndex = 0
        // isLLMFinished is handled above

        // 6.5 Deactivate audio session before starting to listen again
        deactivateAudioSession()

        // 7. Start listening immediately
        startListening()
    }
    
    // --- Speech Recognition (Listening) ---
    func startListening() {
        guard !audioEngine.isRunning else { return }
        
        isListening = true
        isProcessing = false
        isSpeaking = false
        currentSpokenText = ""
        hasUserStartedSpeakingThisTurn = false
        listeningAudioLevel = -50.0
        logger.notice("🎙️ Listening started...")
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Ensure previous session is inactive before configuring and activating again
            try? audioSession.setActive(false) // Best effort deactivation
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            logger.debug("Audio session configured and activated for listening.")
        } catch {
            logger.error("🚨 Audio session setup error: \(error.localizedDescription)")
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
            return
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.recognitionTask != nil else { return }
                
                var isFinal = false
                
                if let result = result {
                    self.currentSpokenText = result.bestTranscription.formattedString
                    isFinal = result.isFinal
                    
                    if !self.currentSpokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.hasUserStartedSpeakingThisTurn {
                        self.logger.info("🎤 User started speaking. Starting silence timer.")
                        self.hasUserStartedSpeakingThisTurn = true
                        self.startSilenceTimer()
                    } else if self.hasUserStartedSpeakingThisTurn {
                        self.resetSilenceTimer()
                    }

                    if isFinal {
                        self.logger.info("✅ Final transcription received: '\(self.currentSpokenText)'")
                        self.invalidateSilenceTimer()
                        self.stopListeningAndProcess(transcription: self.currentSpokenText)
                        return
                    }
                }
                
                if let error = error {
                     let nsError = error as NSError
                     if !(nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 1107)) {
                         self.logger.warning("🚨 Recognition task error: \(error.localizedDescription)")
                     }
                    self.invalidateSilenceTimer()
                    if !isFinal {
                        self.stopListeningCleanup()
                    }
                }
            }
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] (buffer, time) in
            guard let self = self else { return }
            if !self.isSpeaking { self.recognitionRequest?.append(buffer) }
            self.lastMeasuredAudioLevel = self.calculatePowerLevel(buffer: buffer)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            startAudioLevelTimer()
        } catch {
            logger.error("🚨 Audio engine start error: \(error.localizedDescription)")
            recognitionTask?.cancel()
            recognitionTask = nil
            stopListeningCleanup()
        }
    }
    
    private func calculatePowerLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -50.0 }
        let channelDataValue = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
        var rms: Float = 0.0
        for sample in channelDataValue { rms += sample * sample }
        rms = sqrt(rms / Float(buffer.frameLength))
        let dbValue = (rms > 0) ? (20 * log10(rms)) : -160.0
        let minDb: Float = -50.0
        let maxDb: Float = 0.0
        return max(minDb, min(dbValue, maxDb))
    }
    
    func startAudioLevelTimer() {
        invalidateAudioLevelTimer()
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: audioLevelUpdateRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isListening else {
                    self?.invalidateAudioLevelTimer(); return
                }
                self.listeningAudioLevel = self.lastMeasuredAudioLevel
            }
        }
    }
    
    func invalidateAudioLevelTimer() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }
    
    
    func stopAudioEngine() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        invalidateAudioLevelTimer()
    }
    
    func stopListeningCleanup() {
        stopAudioEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        invalidateSilenceTimer()
        if isListening {
            isListening = false
            listeningAudioLevel = -50.0
            logger.notice("🎙️ Listening stopped.")
        }
        // Deactivate audio session when listening stops
        deactivateAudioSession()
    }
    
    func stopListeningAndProcess(transcription: String? = nil) {
         Task { @MainActor [weak self] in
             guard let self = self else { return }
             guard self.isListening else { return }
             
             self.isProcessing = true
             let textToProcess = transcription ?? self.currentSpokenText
             
             self.stopListeningCleanup()
             
             if !textToProcess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 logger.info("⚙️ Processing transcription: '\(textToProcess)'")
                 let userMessage = ChatMessage(role: "user", content: textToProcess)
                 if self.messages.last?.role != "user" || self.messages.last?.content != userMessage.content {
                     self.messages.append(userMessage)
                 }
                 
                 self.llmTask = Task {
                     await self.fetchLLMResponse(prompt: textToProcess)
                 }
             } else {
                 logger.info("⚙️ No text detected to process.")
                 self.isProcessing = false
                 self.startListening()
             }
         }
     }

    // --- Silence Detection ---
    func resetSilenceTimer() {
        if let timer = silenceTimer {
             timer.fireDate = Date(timeIntervalSinceNow: silenceThreshold)
         }
    }
    
    func startSilenceTimer() {
        invalidateSilenceTimer()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                 guard self.isListening else { return }
                self.logger.notice("⏳ Silence detected by timer. Processing...")
                self.stopListeningAndProcess(transcription: self.currentSpokenText)
            }
        }
    }
    
    func invalidateSilenceTimer() {
        if silenceTimer != nil {
            silenceTimer?.invalidate()
            silenceTimer = nil
        }
    }
    
    // --- LLM Interaction ---
    func fetchLLMResponse(prompt: String) async {
        await MainActor.run { [weak self] in
            guard let self = self else { return }

            // --- Modified Reset Logic at Start of LLM Fetch ---
            // Goal: Stop any *previous* TTS activity without clearing the 'isProcessing=true'
            // state that signifies the transition from listening to processing/speaking.

            self.logger.debug("fetchLLMResponse: Starting, resetting TTS state (keeping isProcessing=true).")

            // 1. Cancel any ongoing TTS fetch task from a previous turn.
            if let task = self.ttsFetchTask {
                task.cancel()
                self.ttsFetchTask = nil
                self.logger.debug("fetchLLMResponse: Cancelled previous TTS fetch task.")
            }
            // 2. Stop the audio player if it was speaking from a previous turn.
            //    The .initial state sink handler should clear the queue.
            if self.isSpeaking || self.internalPlayerState == .playing || self.internalPlayerState == .paused {
                 self.chunkedAudioPlayer.stop()
                 self.logger.debug("fetchLLMResponse: Called chunkedAudioPlayer.stop() for potential previous playback.")
            }
            // 3. Explicitly clear the queue as a safeguard, as the player stop might not immediately trigger the sink.
             if !self.audioStreamQueue.isEmpty {
                 self.audioStreamQueue.removeAll()
                 self.logger.debug("fetchLLMResponse: Cleared audio stream queue safeguard.")
             }


            // Reset LLM buffer/flags for the new response
            self.llmResponseBuffer = ""
            self.processedTextIndex = 0
            self.isLLMFinished = false
            self.hasReceivedFirstLLMChunk = false

            // Ensure speaking state variables are reset, but *keep* isProcessing = true
            if self.isSpeaking { self.isSpeaking = false }
            if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }

            // --- End Modified Reset Logic ---
        }
        
        var fullResponseAccumulator = ""
        var llmError: Error? = nil
        
        do {
            try Task.checkCancellation()
            
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
            
            for try await chunk in stream {
                try Task.checkCancellation()
                fullResponseAccumulator += chunk
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.llmResponseBuffer.append(chunk) // Add new text

                    if !self.hasReceivedFirstLLMChunk {
                        self.logger.info("🤖 Received first LLM chunk (\(providerString)).")
                         self.hasReceivedFirstLLMChunk = true
                    }
                    // Attempt to fetch/buffer the next chunk based on the updated buffer
                    self.fetchAndBufferNextChunkIfNeeded()
                }
            }
            
        } catch is CancellationError {
            logger.notice("⏹️ LLM Task Cancelled.")
            llmError = CancellationError()
            // Do *not* call stopSpeaking() here automatically.
            // If cancelled by interruptTTSAndStartListening, that function handles the state transition.
            // If cancelled by other means (e.g., view disappear), stopSpeaking might be called elsewhere.
            // This avoids transitioning to idle if the user interrupt intended to go to listening.
             await MainActor.run { [weak self] in
                 // Only log, don't trigger state changes from here.
                 self?.logger.debug("LLM Task caught CancellationError. State transition handled elsewhere (e.g., interrupt or cleanup).")
             }
            // Ensure NO partial message is added on cancellation.
        } catch {
            // Handle other errors
            if !(error is CancellationError) {
                 logger.error("🚨 LLM Error during stream: \(error.localizedDescription)")
                 llmError = error
                 // On non-cancellation error, stop everything and go towards idle/error state.
                 await MainActor.run { [weak self] in self?.stopSpeaking() }
             }
        }

        // --- LLM Stream Finished ---
        await MainActor.run { [weak self] in
            guard let self = self else { return }

            // Only proceed with final message logic if the task wasn't cancelled.
            if !(llmError is CancellationError) {
                 self.isLLMFinished = true // Mark LLM as done ONLY if not cancelled externally
                 self.logger.info("🤖 LLM full response received (\(fullResponseAccumulator.count) chars).")
                 print("--- LLM FINAL RESPONSE ---")
                 print(fullResponseAccumulator)
                 print("--------------------------")

                // Append final assistant message ONLY on successful completion
                if !fullResponseAccumulator.isEmpty && llmError == nil {
                    let assistantMessage = ChatMessage(role: "assistant", content: fullResponseAccumulator)
                    // Avoid duplicates
                    if self.messages.last?.role != "assistant" || self.messages.last?.content != assistantMessage.content {
                         self.messages.append(assistantMessage)
                     }
                } else if llmError != nil { // Handle non-cancellation errors reported by LLM API itself
                    let errorMessageContent = "Sorry, an error occurred processing the response."
                    let errorMessage = ChatMessage(role: "assistant_error", content: errorMessageContent)
                     if self.messages.last?.content != errorMessageContent { // Avoid duplicate errors
                        self.messages.append(errorMessage)
                     }
                }
                 self.llmTask = nil // Clear task reference on successful completion or API error

                // Try fetching the final TTS chunk ONLY if LLM finished successfully
                 self.fetchAndBufferNextChunkIfNeeded()

                // Check completion state *only* if the player is already idle AND LLM finished successfully.
                 if (self.internalPlayerState == .some(.initial) || self.internalPlayerState == .some(.completed)) {
                      self.checkCompletionAndTransition()
                 } else {
                     self.logger.debug("LLM finished successfully, but player is busy (\(String(describing: self.internalPlayerState))). Waiting for player completion to check final state.")
                 }

            } else {
                // LLM Task was cancelled (likely by user interrupt).
                // interruptTTSAndStartListening handles state/message cleanup & transition to listening.
                self.logger.info("🤖 LLM Task was cancelled externally. Not adding final message or checking completion here.")
                self.llmTask = nil // Clear task reference
                // Do NOT call fetchAndBufferNextChunkIfNeeded or checkCompletionAndTransition here.
            }
        }
    }
    
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
        let systemPromptToUse: String?
        if let sysPrompt = self.systemPrompt, !sysPrompt.isEmpty {
            systemPromptToUse = sysPrompt
        } else {
            systemPromptToUse = nil
        }
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
                                }
                            } catch { }
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
        // Don't fetch if a fetch is already running OR if the queue has enough buffered (e.g., 1 ahead)
        guard ttsFetchTask == nil else {
            logger.trace("Skipping fetch: A TTS fetch task is already running.")
                return
            }
        // Allow buffering 1 chunk ahead. Adjust '1' if more buffering is desired.
        guard audioStreamQueue.count < 1 else {
            logger.trace("Skipping fetch: Audio queue has \(self.audioStreamQueue.count) item(s) already buffered.")
            return
        }

        // Find the next chunk of text
            let (chunk, nextIndex) = findNextTTSChunk(text: llmResponseBuffer, startIndex: processedTextIndex, isComplete: isLLMFinished)

            if chunk.isEmpty {
            logger.trace("Skipping fetch: No suitable text chunk found at index \(self.processedTextIndex). LLM finished: \(self.isLLMFinished)")
            if isLLMFinished {
                checkCompletionAndTransition()
                }
                return
            }

        logger.info("➡️ Found TTS chunk (\(chunk.count) chars). Starting fetch...")
            self.processedTextIndex = nextIndex

            guard let apiKey = self.openaiAPIKey else {
                 logger.error("🚨 OpenAI API Key missing, cannot fetch TTS.")
                 return
            }

        // Cancel previous fetch task only. Don't cancel streamers directly here.
        ttsFetchTask?.cancel()

        ttsFetchTask = Task { [weak self] in
            guard let self = self else { return }

            var streamResult: Result<AsyncThrowingStream<Data, Error>, Error>?
            var streamerInstanceForCapture: TTSStreamer? // Hold streamer temporarily for closure capture

            do {
                 // Create streamer and stream using the helper
                 let (streamer, stream) = try self.createStreamAndStreamer(apiKey: apiKey, text: chunk)
                 streamerInstanceForCapture = streamer // Hold for termination closure

                    try Task.checkCancellation()
                 streamResult = .success(stream)
                 logger.info("✅ TTS stream fetched/created successfully for chunk.")

            } catch is CancellationError {
                logger.notice("⏹️ TTS Fetch task initiation cancelled.")
                streamResult = .failure(CancellationError())
                 // Attempt to cancel the streamer if it was created before cancellation
                 await MainActor.run { streamerInstanceForCapture?.cancel() }
            } catch {
                logger.error("🚨 Failed to create TTS stream: \(error.localizedDescription)")
                streamResult = .failure(error)
                 // No streamer to cancel if creation failed
            }

            // --- Handle Fetch Result ---
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                self.ttsFetchTask = nil // Mark task as finished

                switch streamResult {
                case .success(let stream):
                    // ONLY add to queue. Do NOT trigger playback or checks from here.
                    self.audioStreamQueue.append(stream)
                    self.logger.debug("Appended fetched stream to queue. Queue size: \(self.audioStreamQueue.count)")
                    // If the player happens to be idle, the .initial or .completed state handler
                    // in the sink should eventually call playBufferedStreamIfReady and find this stream.

                case .failure(let error):
                     // Log the error. Let the player state transitions or LLM completion handle what happens next.
                     // If the player was idle and waiting for this, it might get stuck.
                     // We need a way to recover. Maybe checkCompletion ONLY if player is idle?
                     if !(error is CancellationError) {
                         self.logger.error("TTS Stream Creation Failed: \(error.localizedDescription)")
                     }
                    // Check completion *only* if the player is currently idle and might be waiting for this failed fetch.
                    if self.internalPlayerState == .some(.initial) || self.internalPlayerState == .some(.completed) {
                        self.checkCompletionAndTransition()
                    }

                case .none:
                     self.logger.warning("TTS Fetch task finished with no result.")
                     // Similar to failure, check completion only if player is idle.
                     if self.internalPlayerState == .some(.initial) || self.internalPlayerState == .some(.completed) {
                         self.checkCompletionAndTransition()
                     }
                }
            } // End MainActor.run
        } // End Task
    }

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

        // Create the streamer instance
        let streamer = TTSStreamer(request: request, logger: logger)

        // Create the stream
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            streamer.continuation = continuation
            continuation.onTermination = { @Sendable [weak self, weak streamer] terminationReason in
                 // Capture streamer weakly, but it should live as long as needed because
                 // the Task retains the stream, which retains the continuation,
                 // which retains this closure, which weakly retains the streamer.
                 // The strong capture might happen implicitly by the system if needed.
                 Task { @MainActor [weak self, weak streamer] in
                     self?.logger.debug("TTS Stream terminated (\(String(describing: terminationReason))). Cancelling associated streamer.")
                     streamer?.cancel() // Ensure streamer is cancelled on termination
                     // REMOVED: No longer triggering fetch from here. Player state handles it.
                     // self?.fetchAndBufferNextChunkIfNeeded()
                 }
            }
            streamer.start()
        }
        return (streamer, stream)
    }

    @MainActor
    private func playBufferedStreamIfReady() {
        // Check if player is idle (initial or completed)
        guard internalPlayerState == .some(.initial) || internalPlayerState == .some(.completed) else {
            logger.trace("Player not ready (State: \(String(describing: self.internalPlayerState))), deferring playback attempt.")
            return
        }
        // Check if there's a stream in the queue
        guard !audioStreamQueue.isEmpty else {
            logger.trace("No buffered stream available. Calling checkCompletionAndTransition.")
            // If the queue is empty, check if the whole process is finished.
            checkCompletionAndTransition()
            return
        }

        // Dequeue the next stream
        let streamToPlay = audioStreamQueue.removeFirst()
        logger.info("▶️ Player ready, dequeuing and playing next stream. Queue size now: \(self.audioStreamQueue.count)")

        do {
            // --- Configure Audio Session & Start Playback ---
            let audioSession = AVAudioSession.sharedInstance()
            // Ensure previous session is inactive before configuring and activating again
            try? audioSession.setActive(false) // Best effort deactivation
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetoothA2DP]) // Use .playback for TTS
            let isBluetoothConnected = audioSession.currentRoute.outputs.contains { $0.portType == .bluetoothA2DP }
            self.logger.info("🎧 Bluetooth A2DP Connected: \(isBluetoothConnected)")
            if !isBluetoothConnected {
                 try audioSession.overrideOutputAudioPort(.speaker)
                self.logger.info("🔊 Audio output forced to Speaker for TTS.")
            } else {
                try audioSession.overrideOutputAudioPort(.none)
                self.logger.info("🎧 Audio output route left to system (Bluetooth expected) for TTS.")
            }
            try audioSession.setActive(true)
            logger.debug("Audio session configured and activated for playback.")
            // --- End Audio Session Config ---

            // --- Start Playback ---
            self.logger.debug("Setting player rate to \(self.ttsRate) before start.")
            self.chunkedAudioPlayer.rate = self.ttsRate
            self.chunkedAudioPlayer.volume = 1.0 // Ensure volume is set
            self.chunkedAudioPlayer.start(streamToPlay, type: kAudioFileWAVEType)

            // --- Apply Rate Post-Start (Keep this task for robustness) ---
            Task { @MainActor [weak self] in
                 guard let self = self else { return }
                 // Small delay might help ensure player is fully ready for rate change
                 try? await Task.sleep(for: .milliseconds(50))
                 self.logger.trace("Applying rate \(self.ttsRate) shortly after start.")
                 self.chunkedAudioPlayer.rate = self.ttsRate
            }
            // --- End Apply Rate Post-Start ---

        } catch {
            logger.error("🚨 Failed to configure AudioSession or start player: \(error.localizedDescription)")
            // Put stream back? Or just log and check completion? Let's log and check completion.
            // If session failed, retrying might not help.
            audioStreamQueue.removeAll() // Clear queue on failure to avoid retrying bad state
            if self.isProcessing { self.isProcessing = false } // End processing on failure
            if self.isSpeaking { self.isSpeaking = false }
             deactivateAudioSession() // Ensure session is off on failure
            checkCompletionAndTransition()
        }
    }

    private func checkCompletionAndTransition() {
        logger.trace("Checking completion/transition. LLM Finished: \(self.isLLMFinished), Processed Idx: \(self.processedTextIndex)/\(self.llmResponseBuffer.count), Queue: \(self.audioStreamQueue.count), Player: \(String(describing: self.internalPlayerState)), Fetching: \(self.ttsFetchTask != nil)")

         // Condition 1: Everything truly finished
         let isWorkDone = isLLMFinished &&
                          processedTextIndex == llmResponseBuffer.count &&
                          audioStreamQueue.isEmpty &&
                          ttsFetchTask == nil
         let isPlayerIdle = (internalPlayerState == .some(.initial) || internalPlayerState == .some(.completed))

         if isWorkDone && isPlayerIdle {
             logger.info("✅ All TTS processed and played. LLM finished.")
             if self.isProcessing { self.isProcessing = false } // Stop processing indicator
             if self.isSpeaking { self.isSpeaking = false } // Ensure speaking is off
             // Deactivate audio session *before* starting to listen again
             deactivateAudioSession()
             self.autoStartListeningAfterDelay() // Transition back to listening
         }
         // Condition 2: Player is idle, but more work might exist (more text or items in queue)
         else if isPlayerIdle {
             // Player became idle, but we are not finished overall.
             // Try playing next item from queue first.
             if !audioStreamQueue.isEmpty {
                 logger.debug("Player Idle, attempting to play next from queue.")
                 self.playBufferedStreamIfReady()
             }
             // If queue is empty, but more text exists and no fetch is running, try fetching.
             else if processedTextIndex < llmResponseBuffer.count && ttsFetchTask == nil {
                 logger.debug("Player Idle & Queue Empty, checking for more text to fetch.")
                 self.fetchAndBufferNextChunkIfNeeded()
             }
             // If queue is empty, text is done, but LLM is NOT finished, just wait.
             else if !isLLMFinished {
                 logger.debug("Player Idle, Queue Empty, Text Processed, but waiting for LLM to finish.")
             }
             // If queue empty, text done, LLM done, but fetch task is somehow still running? (Shouldn't happen often) - Wait or log error? Let's wait.
             else if ttsFetchTask != nil {
                 logger.debug("Player Idle, Queue Empty, Text Processed, LLM Done, but waiting for final TTS fetch task.")
             }
         }
         // Condition 3: Player is busy (.playing, .paused). No transition needed now.
         else {
              logger.trace("Player is busy (\(String(describing: self.internalPlayerState))). No transition action needed now.")
         }
    }

    private func findNextTTSChunk(text: String, startIndex: Int, isComplete: Bool) -> (String, Int) {
        // Get the portion of the text buffer that hasn't been processed yet
        let remainingText = text.suffix(from: text.index(text.startIndex, offsetBy: startIndex))
        if remainingText.isEmpty { return ("", startIndex) } // No more text

        // If the LLM has finished streaming, just take the rest (up to max length)
        if isComplete {
            let endIndex = min(remainingText.count, maxTTSChunkLength)
            let chunk = String(remainingText.prefix(endIndex))
            // Return the chunk and the new index (start + length of this chunk)
            return (chunk, startIndex + chunk.count)
        }

        // If LLM is ongoing, try to find a good split point within the max length
        let potentialChunk = remainingText.prefix(maxTTSChunkLength)
        var bestSplitIndex = potentialChunk.endIndex // Default to end of potential chunk

        // Prefer splitting at sentence endings if near the end or chunk is short
        if let lastSentenceEnd = potentialChunk.lastIndex(where: { ".!?".contains($0) }) {
            let distanceToEnd = potentialChunk.distance(from: lastSentenceEnd, to: potentialChunk.endIndex)
            // Split after sentence end if it's close to max length or chunk is short
            if distanceToEnd < 150 || potentialChunk.count < 200 {
                 bestSplitIndex = potentialChunk.index(after: lastSentenceEnd)
            }
        // Otherwise, try splitting at commas if near the end or chunk is short
        } else if let lastComma = potentialChunk.lastIndex(where: { ",".contains($0) }) {
             let distanceToEnd = potentialChunk.distance(from: lastComma, to: potentialChunk.endIndex)
             if distanceToEnd < 150 || potentialChunk.count < 200 {
                 bestSplitIndex = potentialChunk.index(after: lastComma)
             }
        }
        // If no good split found near the end, bestSplitIndex remains potentialChunk.endIndex

        // Calculate the actual length of the chunk based on the split point
        let chunkLength = potentialChunk.distance(from: potentialChunk.startIndex, to: bestSplitIndex)

        // --- Minimum Length Checks (to avoid tiny initial chunks) ---
        let minInitialChunkLength = 80 // Require a decent amount for the very first utterance
        let minSubsequentChunkLength = 100 // Can be slightly larger for follow-up chunks

        // If it's the very first chunk (startIndex is 0) and it's too short, wait for more text
        if startIndex == 0 && chunkLength < minInitialChunkLength && !isComplete {
            logger.trace("findNextTTSChunk: Initial chunk too short (\(chunkLength)/\(minInitialChunkLength)), waiting.")
            return ("", startIndex) // Return empty, indicating no suitable chunk yet
        }
        // If it's a subsequent chunk, potentially the *last* partial chunk, and too short, wait.
        // (Check potentialChunk.count == remainingText.count ensures it's the end of the buffer so far)
        if startIndex > 0 && chunkLength < minSubsequentChunkLength && potentialChunk.count == remainingText.count && !isComplete {
             logger.trace("findNextTTSChunk: Subsequent partial chunk too short (\(chunkLength)/\(minSubsequentChunkLength)), waiting.")
            return ("", startIndex)
        }
        // --- End Minimum Length Checks ---

        // Extract the final chunk based on the determined split index
        let finalChunk = String(potentialChunk[..<bestSplitIndex])
        // Return the chunk and the new index
        return (finalChunk, startIndex + finalChunk.count)
    }

    // --- Speech Recognizer Delegate ---
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !available {
                self.logger.error("🚨 Speech recognizer not available.")
                self.stopListeningCleanup()
              }
         }
     }

    // --- Auto-Restart Listening ---
    func autoStartListeningAfterDelay() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Guard against starting if state changed unexpectedly while this task was queued
            guard !self.isSpeaking && !self.isProcessing && !self.isListening else {
                self.logger.warning("🎤 Aborted auto-start: State changed before execution (isListening=\(self.isListening), isSpeaking=\(self.isSpeaking), isProcessing=\(self.isProcessing)).")
                return
            }
            
            logger.info("🎙️ TTS finished. Transitioning back to listening.")
            // No artificial delay needed, startListening handles setup.
            // Ensure isProcessing is false before starting (should be false already if called from checkCompletion)
            if self.isProcessing { self.isProcessing = false }

            // Start listening immediately.
            self.startListening()
        }
    }
    
    // --- Cleanup ---
    deinit {
        // Perform cleanup if needed, though onDisappear is usually sufficient for SwiftUI views
        logger.notice("ChatViewModel deinit.")
        // Ensure main actor calls are dispatched correctly from deinit
        Task { @MainActor [weak self] in
            self?.chunkedAudioPlayer.stop()
            self?.deactivateAudioSession() // Ensure session is off
        }
        // Task cancellations can be done synchronously
        llmTask?.cancel()
        ttsFetchTask?.cancel()

    }
    
    func cleanupOnDisappear() {
        logger.info("ContentView disappeared. Cleaning up.")
        stopListeningCleanup() // Also deactivates session
        // Explicitly cancel LLM and TTS tasks and stop player
        llmTask?.cancel()
        llmTask = nil
        ttsFetchTask?.cancel()
        ttsFetchTask = nil
        chunkedAudioPlayer.stop()
        // Reset states fully
        isProcessing = false
        isSpeaking = false
        ttsOutputLevel = 0.0
        llmResponseBuffer = ""
        processedTextIndex = 0
        isLLMFinished = false
        audioStreamQueue.removeAll()
        // Session should be deactivated by stopListeningCleanup or player stop->initial state->checkCompletion->deactivate
        deactivateAudioSession() // Belt-and-suspenders deactivation
    }
    
    @MainActor
    func stopSpeaking() {
         // For explicit cancellation/cleanup.
         logger.notice("⏹️ stopSpeaking called (explicit cancellation/cleanup).")

         // 1. Stop the audio player.
         chunkedAudioPlayer.stop() // This should trigger state change to .initial

         // 2. Cancel any ongoing TTS fetch task.
         if let task = self.ttsFetchTask {
             task.cancel()
             self.ttsFetchTask = nil
             logger.debug("Cancelled ongoing TTS fetch task.")
         }

         // 3. Clear the audio stream queue.
         if !audioStreamQueue.isEmpty {
             audioStreamQueue.removeAll()
             logger.debug("Cleared audio stream queue.")
         }

         // 4. Update state variables
         if isProcessing { isProcessing = false }
         if isSpeaking { isSpeaking = false }
         if ttsOutputLevel != 0.0 { ttsOutputLevel = 0.0 }

         // 5. Reset LLM state flags (important for clean state)
         self.llmResponseBuffer = ""
         self.processedTextIndex = 0
         self.isLLMFinished = false // Assume interruption means LLM sequence isn't complete

         // 6. Deactivate audio session
         deactivateAudioSession()

         // 7. Check completion state *after* everything is stopped/reset.
         // This might not be needed as state is fully reset, but doesn't hurt.
         checkCompletionAndTransition()
    }

    private func setupAudioPlayerSubscriptions() {
         chunkedAudioPlayer.$currentState
             .receive(on: DispatchQueue.main)
             .sink { [weak self] (state: AudioPlayerState?) in
                 guard let self = self else { return }
                 let previousState = self.internalPlayerState
                 self.internalPlayerState = state // Update internal state FIRST
                 self.logger.debug("AudioPlayer State Changed: \(String(describing: previousState)) -> \(String(describing: state))")

                 switch state {
                 case .initial, .completed: // Player is idle (stopped, finished, or never started)
                     if self.isSpeaking { self.isSpeaking = false }
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
                     self.logger.debug("Player Idle (State: \(String(describing: state))). Calling playBufferedStreamIfReady/checkCompletion.")
                     // Try playing the next chunk or check if we're fully done.
                     // `playBufferedStreamIfReady` calls `checkCompletionAndTransition` if queue is empty.
                     self.playBufferedStreamIfReady()

                 case .playing:
                     if !self.isSpeaking { self.isSpeaking = true }
                     // Ensure processing is true while playing, unless LLM is fully done.
                     if !self.isLLMFinished && !self.isProcessing {
                         self.isProcessing = true
                         self.logger.debug("Player playing, ensuring isProcessing=true.")
                     }
                     // Set visual feedback for TTS level (adjust value as needed)
                     if self.ttsOutputLevel == 0.0 { self.ttsOutputLevel = 0.7 }
                     // Player is busy playing a chunk, proactively fetch the *next* TTS chunk.
                     self.logger.trace("Player playing, proactively fetching next TTS chunk.")
                     self.fetchAndBufferNextChunkIfNeeded()

                 case .paused:
                     // Paused state might need visual update or specific handling if pause is intended.
                     if self.isSpeaking { self.isSpeaking = false } // Reflect paused state visually if needed
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
                     // No action needed for queue/fetching on pause in this app.

                 case .failed:
                     self.logger.error("🚨 AudioPlayer Failed (See $currentError). Resetting TTS state.")
                     if self.isSpeaking { self.isSpeaking = false }
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
                     // Clear the queue as the player or streams might be in a bad state.
                     if !self.audioStreamQueue.isEmpty {
                         self.audioStreamQueue.removeAll()
                         self.logger.debug("Cleared audio queue due to player failure.")
                     }
                     // Cancel any pending TTS fetch as well.
                     if let task = self.ttsFetchTask {
                         task.cancel()
                         self.ttsFetchTask = nil
                         self.logger.debug("Cancelled TTS fetch task due to player failure.")
                     }
                     // Deactivate audio session on failure
                     self.deactivateAudioSession()
                     // Check overall state - likely transition back to idle/listening if LLM done.
                     self.checkCompletionAndTransition()

                 case .none: // Add this case to handle nil
                     // Handle the nil case, e.g., log it or do nothing if it's expected
                     self.logger.trace("AudioPlayer State became nil.")
                     // You might want to ensure state variables reflect this if needed
                     if self.isSpeaking { self.isSpeaking = false }
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
                     // Consider if checkCompletionAndTransition is needed here too
                     // self.checkCompletionAndTransition() 
                 }
             }
             .store(in: &cancellables)

         // Keep $currentError subscription
         chunkedAudioPlayer.$currentError
             .receive(on: DispatchQueue.main)
             .compactMap { $0 }
             .sink { [weak self] (error: Error) in
                 let errorMessage = "🚨 AudioPlayer Error Detail: \(error.localizedDescription)"
                 self?.logger.error("\(errorMessage)")
                 // Error state is handled by the .failed case in the state sink.
             }
             .store(in: &cancellables)
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            logger.debug("Audio session deactivated.")
        } catch {
            logger.error("🚨 Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
}

// --- TTSStreamer Modification ---
private class TTSStreamer: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let logger: Logger
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var accumulatedData = Data()
    // Make continuation optional and a var so it can be assigned later
    var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    // Remove continuation from init
    init(request: URLRequest, logger: Logger) {
        self.request = request
        self.logger = logger
        super.init()
    }

    func start() {
        // Only start if continuation has been set
        guard continuation != nil else {
            logger.warning("TTSStreamer start called without a continuation.")
            return
        }
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil) // Use background queue
        self.session?.dataTask(with: request).resume()
        Task { @MainActor [logger] in logger.debug("TTS URLSessionDataTask started.") }
    }

    func cancel() {
        session?.invalidateAndCancel()
        // Use optional chaining to finish continuation if it exists
        continuation?.finish(throwing: CancellationError())
        continuation = nil // Clear it after finishing
        Task { @MainActor [logger] in logger.debug("TTSStreamer explicitly cancelled.") }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            Task { @MainActor [logger] in logger.error("🚨 TTS Error: Did not receive HTTPURLResponse.") }
            completionHandler(.cancel)
            // Use optional chaining
            continuation?.finish(throwing: ChatViewModel.LlmError.networkError(URLError(.badServerResponse)))
            continuation = nil // Clear after finishing
            return
        }

        self.response = httpResponse
        Task { @MainActor [logger, httpResponse] in logger.debug("TTS Received response headers. Status: \(httpResponse.statusCode)") }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
         // Use optional chaining for continuation
         if let httpResponse = self.response, (200...299).contains(httpResponse.statusCode) {
             continuation?.yield(data)
         } else {
             accumulatedData.append(data)
         }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
         // Use optional chaining for continuation
         if let error = error {
             Task { @MainActor [logger, error] in logger.error("🚨 TTS Network Error: \(error.localizedDescription)") }
             continuation?.finish(throwing: ChatViewModel.LlmError.networkError(error))
         } else if let httpResponse = self.response, !(200...299).contains(httpResponse.statusCode) {
             let errorBody = String(data: accumulatedData, encoding: .utf8) ?? "Could not decode error body"
             Task { @MainActor [logger, httpResponse, errorBody] in logger.error("🚨 TTS API Error: Status \(httpResponse.statusCode). Body: \(errorBody)") }
             continuation?.finish(throwing: ChatViewModel.LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody))
         } else {
             Task { @MainActor [logger] in logger.debug("TTS Stream finished successfully.") }
             continuation?.finish() // Success
         }
         // Invalidate session AND clear continuation after finishing
         self.session?.finishTasksAndInvalidate()
         continuation = nil // Ensure it's cleared
    }
}

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
            // Start listening immediately when the view appears
            viewModel.startListening()
            // viewModel.logger.info("ContentView appeared.") // We log startListening now
        }
        .onDisappear {
            viewModel.logger.info("ContentView disappeared.")
            viewModel.cleanupOnDisappear()
        }
    }
}


#Preview {
    ContentView()
}
