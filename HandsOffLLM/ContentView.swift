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
class ChatViewModel: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVAudioPlayerDelegate {
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")
    
    enum LLMProvider { case gemini, claude }

    @Published var messages: [ChatMessage] = []
    @Published var isListening: Bool = false
    @Published var isProcessing: Bool = false // Thinking/Waiting for LLM
    @Published var isSpeaking: Bool = false   // TTS playback is active
    @Published var ttsRate: Float = 2.0 {
        didSet {
            Task { @MainActor [weak self] in
                guard let self = self, let player = self.currentAudioPlayer else { return }
                if player.enableRate {
                    player.rate = self.ttsRate
                } else {
                }
            }
        }
    }
    @Published var listeningAudioLevel: Float = -50.0 // Audio level dBFS (-50 silence, 0 max)
    @Published var ttsOutputLevel: Float = 0.0      // Normalized TTS output level (0-1)
    @Published var selectedProvider: LLMProvider = .claude // LLM Provider

    // --- Internal State ---
    private var llmTask: Task<Void, Never>? = nil
    private var ttsFetchTask: Task<Void, Never>? = nil
    private var isLLMFinished: Bool = false
    private var llmResponseBuffer: String = ""
    private var processedTextIndex: Int = 0
    private var nextAudioData: Data? = nil
    private var currentSpokenText: String = ""
    private var isFetchingTTS: Bool = false
    private var hasUserStartedSpeakingThisTurn: Bool = false
    private var hasReceivedFirstLLMChunk: Bool = false

    // --- Audio Components ---
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var currentAudioPlayer: AVAudioPlayer?
    private var ttsLevelTimer: Timer?

    // --- Configuration & Timers ---
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 1.5
    private let audioLevelUpdateRate: TimeInterval = 0.1
    private var audioLevelTimer: Timer?
    private let ttsLevelUpdateRate: TimeInterval = 0.05
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
        
        requestPermissions()
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
            if isListening {
                // User tapped while listening: Reset listening, go to idle (grey)
                resetListening()
            } else if isProcessing || isSpeaking {
                // User tapped while processing/speaking: Cancel and immediately start listening
                cancelProcessingAndSpeaking()
            } else {
                // User tapped while idle (grey): Start listening
                startListening()
            }
        }
    }
    
    func resetListening() {
        logger.notice("🎙️ Listening reset requested by user.")
        stopListeningCleanup() // Stops engine, cancels tasks, sets isListening = false
        currentSpokenText = "" // Clear any partial transcription
        // Ensure other states are false (stopListeningCleanup should handle isListening)
        isProcessing = false
        isSpeaking = false
        listeningAudioLevel = -50.0
        // No need to start listening here, stays idle until next tap
    }
    
    func cancelProcessingAndSpeaking() {
        logger.notice("⏹️ Cancel requested by user during processing/speaking.")

        llmTask?.cancel()
        llmTask = nil

        stopSpeaking() // Stops TTS playback and fetch task

        // Explicitly set states to false before potentially restarting listening
        isProcessing = false
        // isSpeaking is handled by stopSpeaking() which sets it to false

        self.llmResponseBuffer = ""
        self.processedTextIndex = 0
        self.isLLMFinished = false
        self.nextAudioData = nil
        self.isFetchingTTS = false
        self.hasReceivedFirstLLMChunk = false

        // If cancellation happened, immediately go back to listening
        logger.info("🎤 Immediately transitioning back to listening after cancellation.")
        startListening()
    }
    
    // --- Speech Recognition (Listening) ---
    func startListening() {
        // Add a guard to prevent starting if already in a non-idle state
        guard !isListening && !isProcessing && !isSpeaking else {
            logger.warning("Attempted to start listening while already active (\(self.isListening), \(self.isProcessing), \(self.isSpeaking)). Ignoring.")
            return
        }
        guard !audioEngine.isRunning else {
             logger.warning("Audio engine is already running, cannot start listening again yet.")
             return
        }

        isListening = true
        isProcessing = false // Ensure processing is false when listening starts
        isSpeaking = false   // Ensure speaking is false when listening starts
        currentSpokenText = ""
        hasUserStartedSpeakingThisTurn = false
        listeningAudioLevel = -50.0
        logger.notice("🎙️ Listening started...")
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
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
        let wasListening = isListening // Check state before modification
        stopAudioEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel() // Use cancel instead of finish, as we might interrupt it
        recognitionTask = nil
        recognitionRequest = nil
        invalidateSilenceTimer()
        if wasListening { // Only log and update state if we were actually listening
            isListening = false
            listeningAudioLevel = -50.0
            logger.notice("🎙️ Listening stopped (Cleanup).")
        }
    }
    
    func stopListeningAndProcess(transcription: String? = nil) {
         Task { @MainActor [weak self] in
             guard let self = self else { return }
             // Don't process if not listening or already processing/speaking
             guard self.isListening else {
                 logger.warning("stopListeningAndProcess called but not in listening state.")
                 return
             }
             // Prevent triggering processing if already processing/speaking (e.g., silence timer fires after manual stop)
             guard !self.isProcessing && !self.isSpeaking else {
                 logger.warning("stopListeningAndProcess called but already processing or speaking.")
                 self.stopListeningCleanup() // Ensure listening stops cleanly
                 return
             }

             self.isProcessing = true // Set processing TRUE first
             let textToProcess = transcription ?? self.currentSpokenText

             self.stopListeningCleanup() // Now, cleanup listening state (sets isListening FALSE)

             if !textToProcess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 logger.info("⚙️ Processing transcription: '\(textToProcess)'")
                 let userMessage = ChatMessage(role: "user", content: textToProcess)
                 // Avoid adding duplicate user messages if processing gets triggered multiple times rapidly
                 if self.messages.last?.role != "user" || self.messages.last?.content != userMessage.content {
                     self.messages.append(userMessage)
                 }

                 self.llmTask = Task {
                     await self.fetchLLMResponse(prompt: textToProcess)
                 }
             } else {
                 logger.info("⚙️ No text detected to process. Returning to listening.")
                 self.isProcessing = false // Reset processing flag
                 self.startListening() // Go back to listening state
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
            self.llmResponseBuffer = ""
            self.processedTextIndex = 0
            self.isLLMFinished = false
            self.nextAudioData = nil
            self.isFetchingTTS = false
            self.ttsFetchTask?.cancel()
            self.ttsFetchTask = nil
            self.hasReceivedFirstLLMChunk = false
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
                    if !self.hasReceivedFirstLLMChunk {
                         logger.info("🤖 Received first LLM chunk (\(providerString)).")
                         self.hasReceivedFirstLLMChunk = true
                    }
                    self.llmResponseBuffer.append(chunk)
                    self.manageTTSPlayback()
                }
            }
            
        } catch is CancellationError {
            logger.notice("⏹️ LLM Task Cancelled.")
            llmError = CancellationError()
            await MainActor.run { [weak self] in self?.stopSpeaking() }
        } catch {
            if !(error is CancellationError) {
                 logger.error("🚨 LLM Error during stream: \(error.localizedDescription)")
                 llmError = error
                 await MainActor.run { [weak self] in self?.stopSpeaking() }
             }
        }
        
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            
            self.isLLMFinished = true
            
            self.manageTTSPlayback()
            
            if llmError == nil || !(llmError is CancellationError) {
                 logger.info("🤖 LLM full response received (\(fullResponseAccumulator.count) chars).")
                 print("--- LLM FINAL RESPONSE ---")
                 print(fullResponseAccumulator)
                 print("--------------------------")
            }

            if !fullResponseAccumulator.isEmpty {
                let messageRole = (llmError == nil) ? "assistant" : ((llmError is CancellationError) ? "assistant_partial" : "assistant_error")
                let assistantMessage = ChatMessage(role: messageRole, content: fullResponseAccumulator)
                if self.messages.last?.role != messageRole || self.messages.last?.content != assistantMessage.content {
                     self.messages.append(assistantMessage)
                 }
            } else if llmError != nil && !(llmError is CancellationError) {
                let errorMessage = ChatMessage(role: "assistant_error", content: "Sorry, an error occurred.")
                self.messages.append(errorMessage)
            }
            
            self.llmTask = nil
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
    
    // --- New TTS Playback Logic ---

    @MainActor
    private func manageTTSPlayback() {
        guard !isFetchingTTS else { return }

        if currentAudioPlayer == nil {
            if let dataToPlay = nextAudioData {
                self.nextAudioData = nil
                playAudioData(dataToPlay)
                return
            }
        }

        let unprocessedText = llmResponseBuffer.suffix(from: llmResponseBuffer.index(llmResponseBuffer.startIndex, offsetBy: processedTextIndex))

        let shouldFetchInitial = currentAudioPlayer == nil && !unprocessedText.isEmpty && (isLLMFinished || unprocessedText.count > 5)
        let shouldFetchNext = currentAudioPlayer != nil && !unprocessedText.isEmpty

        if shouldFetchInitial || shouldFetchNext {
             guard nextAudioData == nil else { return }

            let (chunk, nextIndex) = findNextTTSChunk(text: llmResponseBuffer, startIndex: processedTextIndex, isComplete: isLLMFinished)

            if chunk.isEmpty {
                if isLLMFinished && processedTextIndex == llmResponseBuffer.count && currentAudioPlayer == nil && nextAudioData == nil && !isListening {
                    if isProcessing {
                        isProcessing = false
                        logger.info("⚙️ Processing finished (LLM & TTS Idle).")
                    }
                    logger.info("🎤 Directly transitioning to listening.")
                    startListening()
                }
                return
            }

            logger.info("➡️ Sending chunk (\(chunk.count) chars) to TTS API...")
            self.processedTextIndex = nextIndex
            self.isFetchingTTS = true

            guard let apiKey = self.openaiAPIKey else {
                 logger.error("🚨 OpenAI API Key missing, cannot fetch TTS.")
                 self.isFetchingTTS = false
                 return
            }

            self.ttsFetchTask = Task { [weak self] in
                do {
                    let fetchedData = try await self?.fetchOpenAITTSAudio(apiKey: apiKey, text: chunk)
                    try Task.checkCancellation()

                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.isFetchingTTS = false
                        self.ttsFetchTask = nil

                        guard let data = fetchedData else {
                            logger.warning("TTS fetch returned no data for chunk.")
                            self.manageTTSPlayback()
                            return
                        }
                        
                        logger.info("⬅️ Received TTS audio (\(data.count) bytes).")

                        if self.currentAudioPlayer == nil {
                            self.playAudioData(data)
                        } else {
                            self.nextAudioData = data
                        }
                    }
                } catch is CancellationError {
                    await MainActor.run { [weak self] in
                        self?.logger.notice("⏹️ TTS Fetch task cancelled.")
                        self?.isFetchingTTS = false
                        self?.ttsFetchTask = nil
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.logger.error("🚨 TTS Fetch failed: \(error.localizedDescription)")
                        self?.isFetchingTTS = false
                        self?.ttsFetchTask = nil
                         self?.manageTTSPlayback()
                    }
                }
            }
        } else if isLLMFinished && processedTextIndex == llmResponseBuffer.count && currentAudioPlayer == nil && nextAudioData == nil && !isListening {
            if isProcessing {
                isProcessing = false
                logger.info("⚙️ Processing finished (LLM & TTS Idle).")
            }
            logger.info("🎤 Directly transitioning to listening.")
            startListening()
        }
    }


    private func findNextTTSChunk(text: String, startIndex: Int, isComplete: Bool) -> (String, Int) {
        let remainingText = text.suffix(from: text.index(text.startIndex, offsetBy: startIndex))
        if remainingText.isEmpty { return ("", startIndex) }

        if isComplete {
            let endIndex = min(remainingText.count, maxTTSChunkLength)
            let chunk = String(remainingText.prefix(endIndex))
            return (chunk, startIndex + chunk.count)
        }

        let potentialChunk = remainingText.prefix(maxTTSChunkLength)
        var bestSplitIndex = potentialChunk.endIndex
        let lookaheadMargin = 75 // Reduced margin for finding a boundary

        // Try to find a sentence-ending punctuation mark first
        if let lastSentenceEnd = potentialChunk.lastIndex(where: { ".!?".contains($0) }) {
            let distanceToEnd = potentialChunk.distance(from: lastSentenceEnd, to: potentialChunk.endIndex)
            // If the boundary is within the lookahead margin, split after it
            if distanceToEnd < lookaheadMargin {
                 bestSplitIndex = potentialChunk.index(after: lastSentenceEnd)
            }
        // If no suitable sentence end is found, try a comma
        } else if let lastComma = potentialChunk.lastIndex(where: { ",".contains($0) }) {
             let distanceToEnd = potentialChunk.distance(from: lastComma, to: potentialChunk.endIndex)
             // If the boundary is within the lookahead margin, split after it
             if distanceToEnd < lookaheadMargin {
                 bestSplitIndex = potentialChunk.index(after: lastComma)
             }
        }
        // If no suitable boundary is found within the margin, bestSplitIndex remains potentialChunk.endIndex

        let chunkLength = potentialChunk.distance(from: potentialChunk.startIndex, to: bestSplitIndex)

        // Calculate scaled minimum chunk length based on playback speed
        let baseMinChunkLength: Int = 60
        let scaledMinChunkLength = (self.ttsRate > 1.0) ? Int(Float(baseMinChunkLength) * self.ttsRate) : baseMinChunkLength

        // Check if the resulting chunk is too short, especially if it's not the complete text
        if chunkLength < scaledMinChunkLength && potentialChunk.count == remainingText.count && !isComplete {
            // If the potential chunk is the *entire* remaining text but still too short, don't send it yet unless LLM is finished.
            return ("", startIndex)
        }
        if chunkLength < baseMinChunkLength && !isComplete { // Use base for a hard minimum if not complete
             // Avoid sending very small initial chunks even with scaling, wait for more text.
             return ("", startIndex)
        }


        let finalChunk = String(potentialChunk[..<bestSplitIndex])
        return (finalChunk, startIndex + finalChunk.count)
    }


    @MainActor
    private func playAudioData(_ data: Data) {
        guard !data.isEmpty else {
             logger.warning("Attempted to play empty audio data.")
             self.manageTTSPlayback()
             return
        }
        do {
             let audioSession = AVAudioSession.sharedInstance()
             // Ensure category allows playback BEFORE overriding
             try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])

             // --- Add Speaker Override ---
             do {
                 try audioSession.overrideOutputAudioPort(.speaker)
                 logger.info("🔊 Audio output route forced to Speaker.")
             } catch {
                 logger.error("🚨 Failed to override audio output to speaker: \(error.localizedDescription)")
             }
             // --- End Speaker Override ---

             try audioSession.setActive(true) // Activate session *after* setting category/override

            currentAudioPlayer = try AVAudioPlayer(data: data)
            currentAudioPlayer?.delegate = self
            currentAudioPlayer?.enableRate = true
            currentAudioPlayer?.isMeteringEnabled = true
            
            if let player = currentAudioPlayer {
                 player.rate = self.ttsRate
            }

            if currentAudioPlayer?.play() == true {
                isSpeaking = true
                logger.info("▶️ Playback started.") // Log playback start
                startTTSLevelTimer()
                manageTTSPlayback() // Trigger next fetch
            } else {
                logger.error("🚨 Failed to start audio playback.")
                currentAudioPlayer = nil
                 isSpeaking = false
                 manageTTSPlayback()
            }
        } catch {
            logger.error("🚨 Failed to initialize or play audio: \(error.localizedDescription)")
            currentAudioPlayer = nil
            isSpeaking = false
            manageTTSPlayback()
        }
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
    
    // --- Audio Player Delegate ---
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
             guard player === self.currentAudioPlayer else { return }

            logger.info("⏹️ Playback finished (Success: \(flag)).")
            self.invalidateTTSLevelTimer()
            self.currentAudioPlayer = nil

            if self.isSpeaking {
                self.isSpeaking = false
                if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
            }
            
            self.manageTTSPlayback()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
         Task { @MainActor [weak self] in
             guard let self = self else { return }
             self.logger.error("🚨 Audio player decode error: \(error?.localizedDescription ?? "Unknown error")")
             self.invalidateTTSLevelTimer()
              if player === self.currentAudioPlayer {
                  self.currentAudioPlayer = nil
                  self.isSpeaking = false
                  self.ttsOutputLevel = 0.0
                  self.manageTTSPlayback()
              }
         }
     }
    
    // --- Cleanup ---
    deinit {
    }
    func cleanupOnDisappear() {
        stopListeningCleanup()
        self.stopSpeaking()
    }
    
    // --- OpenAI TTS Fetch ---
    func fetchOpenAITTSAudio(apiKey: String, text: String) async throws -> Data {
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
            response_format: openAITTSFormat, instructions: Prompts.ttsInstructions
        )
        
        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LlmError.requestEncodingError(error) }
        
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: request) }
        catch { throw LlmError.networkError(error) }
        
        guard let httpResponse = response as? HTTPURLResponse else { throw LlmError.networkError(URLError(.badServerResponse)) }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorDetails = ""
            if let errorString = String(data: data, encoding: .utf8) { errorDetails = errorString }
            logger.error("🚨 OpenAI TTS Error: Status \(httpResponse.statusCode). Body: \(errorDetails)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorDetails)
        }
        
        guard !data.isEmpty else { throw LlmError.streamingError("Received empty audio data from OpenAI TTS API") }
        
        return data
    }

    // --- TTS Level Visualization Logic ---
    func startTTSLevelTimer() {
        invalidateTTSLevelTimer()
        ttsLevelTimer = Timer.scheduledTimer(withTimeInterval: ttsLevelUpdateRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTTSLevel() }
        }
    }
    func invalidateTTSLevelTimer() {
         if ttsLevelTimer != nil {
             ttsLevelTimer?.invalidate()
             ttsLevelTimer = nil
             if self.currentAudioPlayer == nil && self.ttsOutputLevel != 0.0 {
                  self.ttsOutputLevel = 0.0
             }
         }
     }
    @MainActor private func updateTTSLevel() {
        guard let player = self.currentAudioPlayer, player.isPlaying else {
            if self.ttsOutputLevel != 0.0 {
                 self.ttsOutputLevel = 0.0
            }
            invalidateTTSLevelTimer()
            return
        }
        player.updateMeters()
        let averagePower = player.averagePower(forChannel: 0)

        let minDBFS: Float = -50.0
        let maxDBFS: Float = 0.0
        var normalizedLevel: Float = 0.0

        if averagePower > minDBFS {
            let dbRange = maxDBFS - minDBFS
            if dbRange > 0 {
                let clampedPower = max(averagePower, minDBFS)
                normalizedLevel = (clampedPower - minDBFS) / dbRange
            }
        }

        let exponent: Float = 1.5
        let curvedLevel = pow(normalizedLevel, exponent)
        let finalLevel = max(0.0, min(curvedLevel, 1.0))

        let smoothingFactor: Float = 0.2
        let smoothedLevel = self.ttsOutputLevel * (1.0 - smoothingFactor) + finalLevel * smoothingFactor

        if abs(self.ttsOutputLevel - smoothedLevel) > 0.01 || (smoothedLevel == 0 && self.ttsOutputLevel != 0) {
            self.ttsOutputLevel = smoothedLevel
        }
    }

    @MainActor
    func stopSpeaking() {
         let wasSpeaking = self.isSpeaking
         
         // Cancel TTS Fetch Task
         if let task = self.ttsFetchTask {
             task.cancel()
             self.ttsFetchTask = nil
             self.isFetchingTTS = false // Ensure flag is reset
         }

         // Stop Audio Player
         if let player = self.currentAudioPlayer {
             player.stop()
             self.currentAudioPlayer = nil
         }

         // Cleanup Timer and Audio Data
         self.invalidateTTSLevelTimer() // This also sets level to 0 if player is nil
         self.nextAudioData = nil

         // Update State only if it was speaking
         if wasSpeaking {
             self.isSpeaking = false
             if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 } // Ensure level resets visually
             logger.notice("⏹️ TTS interrupted/stopped.")
         }

         // Check if processing should end *after* stopping speaking
         // This condition seems complex and might be handled elsewhere better.
         // Let's simplify: Processing ends when LLM is finished AND TTS is idle, or when cancelled.
         // This check might be redundant now.
         // if wasSpeaking && self.isLLMFinished && self.ttsFetchTask == nil && self.currentAudioPlayer == nil && self.nextAudioData == nil {
         //     if self.isProcessing {
         //         self.isProcessing = false
         //         logger.info("⚙️ Processing finished (triggered by stopSpeaking).") // Added log
         //     }
         // }
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
            viewModel.logger.info("ContentView appeared.")
            // Start listening immediately if not already active
            if !viewModel.isListening && !viewModel.isProcessing && !viewModel.isSpeaking {
                viewModel.startListening()
            }
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
