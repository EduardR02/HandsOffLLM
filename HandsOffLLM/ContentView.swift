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
    @Published var ttsRate: Float = AVSpeechUtteranceDefaultSpeechRate {
        didSet {
            chunkedAudioPlayer.rate = ttsDisplayMultiplier
        }
    }
    @Published var listeningAudioLevel: Float = -50.0 // Audio level dBFS (-50 silence, 0 max)
    @Published var ttsOutputLevel: Float = 0.0      // Restored TTS output level (0-1)
    @Published var selectedProvider: LLMProvider = .claude // LLM Provider

    // --- Internal State ---
    private var llmTask: Task<Void, Never>? = nil
    private var isLLMFinished: Bool = false
    private var llmResponseBuffer: String = ""
    private var processedTextIndex: Int = 0
    private var currentSpokenText: String = ""
    private var hasUserStartedSpeakingThisTurn: Bool = false
    private var hasReceivedFirstLLMChunk: Bool = false
    private var currentTTSStreamTask: Task<Void, Never>? = nil
    private var internalPlayerState: AudioPlayerState? = nil // Added internal state tracking

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
                startListening()
            } else if isListening {
                stopListeningAndProcess()
            } else if isProcessing || isSpeaking {
                cancelProcessingAndSpeaking()
            }
        }
    }
    
    func cancelProcessingAndSpeaking() {
        logger.notice("⏹️ Cancel requested by user.")
        
        if let task = llmTask {
            task.cancel()
            llmTask = nil
        }
        
        stopSpeaking()
        
        if self.isProcessing {
            isProcessing = false
        }
        self.llmResponseBuffer = ""
        self.processedTextIndex = 0
        self.isLLMFinished = false
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
            self.llmResponseBuffer = ""
            self.processedTextIndex = 0
            self.isLLMFinished = false
            self.currentTTSStreamTask?.cancel()
            self.currentTTSStreamTask = nil
            self.hasReceivedFirstLLMChunk = false
            self.stopSpeaking()
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
                    self.llmResponseBuffer.append(chunk)

                    if !self.hasReceivedFirstLLMChunk {
                        self.logger.info("🤖 Received first LLM chunk (\(providerString)).")
                        self.hasReceivedFirstLLMChunk = true
                        self.fetchAndPlayNextTTSChunk()
                    }
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
            
            self.fetchAndPlayNextTTSChunk()
            
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

            if (self.internalPlayerState == .initial || self.internalPlayerState == .completed) {
                 self.checkCompletionAndContinue()
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
    
    // --- New TTS Playback Logic using ChunkedAudioPlayer ---

    @MainActor
    private func fetchAndPlayNextTTSChunk() {
        let isIdleOrCompleted = internalPlayerState == .initial || internalPlayerState == .completed
        guard isIdleOrCompleted else {
             logger.debug("Skipping fetchAndPlayNextTTSChunk: Player not idle/completed (State: \(String(describing: self.internalPlayerState))).")
             return
        }
        guard currentTTSStreamTask == nil || currentTTSStreamTask!.isCancelled else {
            logger.debug("Skipping fetchAndPlayNextTTSChunk: TTS fetch task already active.")
            return
        }

        let (chunk, nextIndex) = findNextTTSChunk(text: llmResponseBuffer, startIndex: processedTextIndex, isComplete: isLLMFinished)

        if chunk.isEmpty {
            logger.debug("fetchAndPlayNextTTSChunk: No chunk found.")
            if isLLMFinished {
                checkCompletionAndContinue()
            }
            return
        }

        logger.info("➡️ Preparing TTS stream for chunk (\(chunk.count) chars)...")
        self.processedTextIndex = nextIndex

        guard let apiKey = self.openaiAPIKey else {
             logger.error("🚨 OpenAI API Key missing, cannot fetch TTS.")
             return
        }

        currentTTSStreamTask = Task { [weak self] in
            guard let self = self else { return }
            var fetchedStream: AsyncThrowingStream<Data, Error>?
            var fetchError: Error?

            do {
                fetchedStream = try await self.streamOpenAITTSAudio(apiKey: apiKey, text: chunk, speed: self.ttsRate)
                try Task.checkCancellation()
            } catch is CancellationError {
                self.logger.notice("⏹️ TTS Fetch task cancelled.")
                fetchError = CancellationError()
            } catch {
                self.logger.error("🚨 Failed to get TTS stream: \(error.localizedDescription)")
                fetchError = error
            }

            await MainActor.run { [weak self] in
                 guard let self = self else { return }
                 self.currentTTSStreamTask = nil

                 if let stream = fetchedStream, fetchError == nil {
                     logger.info("▶️ Starting ChunkedAudioPlayer...")
                     self.chunkedAudioPlayer.rate = self.ttsDisplayMultiplier
                     self.chunkedAudioPlayer.volume = 1.0
                     if self.internalPlayerState == .initial || self.internalPlayerState == .completed {
                          self.chunkedAudioPlayer.start(stream, type: kAudioFileWAVEType)
                     } else {
                          self.logger.warning("Player state changed before playback could start. Expected initial/completed, got \(String(describing: self.internalPlayerState))")
                          if self.internalPlayerState == .initial || self.internalPlayerState == .completed {
                                self.checkCompletionAndContinue()
                          }
                     }
                 } else {
                      self.logger.error("TTS Fetch failed or was cancelled. Error: \(fetchError?.localizedDescription ?? "Unknown")")
                      if self.isProcessing { self.isProcessing = false }
                      if self.isLLMFinished {
                           self.checkCompletionAndContinue()
                      }
                 }
             }
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

        if let lastSentenceEnd = potentialChunk.lastIndex(where: { ".!?".contains($0) }) {
            let distanceToEnd = potentialChunk.distance(from: lastSentenceEnd, to: potentialChunk.endIndex)
            if distanceToEnd < 150 || potentialChunk.count < 200 {
                 bestSplitIndex = potentialChunk.index(after: lastSentenceEnd)
            }
        } else if let lastComma = potentialChunk.lastIndex(where: { ",".contains($0) }) {
             let distanceToEnd = potentialChunk.distance(from: lastComma, to: potentialChunk.endIndex)
             if distanceToEnd < 150 || potentialChunk.count < 200 {
                 bestSplitIndex = potentialChunk.index(after: lastComma)
             }
        }

        let chunkLength = potentialChunk.distance(from: potentialChunk.startIndex, to: bestSplitIndex)

        let minInitialChunkLength = 80
        let minSubsequentChunkLength = 100

        if startIndex == 0 && chunkLength < minInitialChunkLength && !isComplete {
            return ("", startIndex)
        }
        if startIndex > 0 && chunkLength < minSubsequentChunkLength && potentialChunk.count == remainingText.count && !isComplete {
            return ("", startIndex)
        }

        let finalChunk = String(potentialChunk[..<bestSplitIndex])
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
            guard !self.isSpeaking && !self.isProcessing && !self.isListening else { return }
            
            logger.info("🎙️ TTS finished. Switching to user turn...")
            try? await Task.sleep(nanoseconds: 200_000_000)

            if !self.isListening && !self.isProcessing && !self.isSpeaking {
                self.startListening()
            } else {
                 logger.warning("🎤 Aborted auto-start: State changed during brief delay.")
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
    
    // --- TTS Speed Calculation ---
    var ttsDisplayMultiplier: Float {
        let rate = self.ttsRate
        let minDisplay: Float = 1.0
        let maxDisplay: Float = 4.0
        return minDisplay + rate * (maxDisplay - minDisplay)
    }
    
    // --- OpenAI TTS Streaming Fetch ---
    func streamOpenAITTSAudio(apiKey: String, text: String, speed: Float) async throws -> AsyncThrowingStream<Data, Error> {
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
            model: openAITTSModel,
            input: text,
            voice: openAITTSVoice,
            response_format: openAITTSFormat,
            stream: true,
            instructions: Prompts.ttsInstructions
        )

        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LlmError.requestEncodingError(error) }

        return AsyncThrowingStream<Data, Error> { continuation in
            let streamer = TTSStreamer(request: request, continuation: continuation, logger: logger)
            continuation.onTermination = { @Sendable _ in
                 streamer.cancel()
                 Task { @MainActor [weak self] in
                    self?.logger.debug("TTS Stream terminated.")
                 }
            }
            streamer.start()
        }
    }

    @MainActor
    func stopSpeaking() {
         let wasSpeaking = self.isSpeaking

         if let task = self.currentTTSStreamTask {
             task.cancel()
             self.currentTTSStreamTask = nil
         }

         chunkedAudioPlayer.stop()

         if wasSpeaking {
             logger.notice("⏹️ TTS interrupted.")
         }
    }

    private func setupAudioPlayerSubscriptions() {
         chunkedAudioPlayer.$currentState
             .receive(on: DispatchQueue.main)
             .sink { [weak self] state in
                 guard let self = self else { return }
                 self.logger.debug("AudioPlayer State: \(String(describing: state))")
                 self.internalPlayerState = state

                 switch state {
                 case .initial, .completed:
                     if self.isSpeaking { self.isSpeaking = false }
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
                     if state == .completed { self.logger.info("▶️ AudioPlayer Completed.") }
                     self.checkCompletionAndContinue()

                 case .playing:
                     if !self.isSpeaking { self.isSpeaking = true }
                     if self.ttsOutputLevel == 0.0 { self.ttsOutputLevel = 0.7 }

                 case .paused:
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }

                 case .failed:
                     self.logger.error("🚨 AudioPlayer Failed: ")
                     if self.isSpeaking { self.isSpeaking = false }
                     if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
                     if self.isProcessing { self.isProcessing = false }
                 }
             }
             .store(in: &cancellables)

         chunkedAudioPlayer.$currentError
             .receive(on: DispatchQueue.main)
             .compactMap { $0 }
             .sink { [weak self] error in
                 let errorMessage = "🚨 AudioPlayer Error Detail: \(error.localizedDescription)"
                 self?.logger.error("\(errorMessage)")
             }
             .store(in: &cancellables)
    }

    private func checkCompletionAndContinue() {
         if self.isLLMFinished && self.processedTextIndex == self.llmResponseBuffer.count {
             if self.isProcessing { self.isProcessing = false }
             self.logger.info("⚙️ Processing finished (TTS Chain Complete).")
             self.autoStartListeningAfterDelay()
         }
         else if !self.llmResponseBuffer.isEmpty && self.processedTextIndex < self.llmResponseBuffer.count {
             self.logger.debug("Player Idle/Completed, checking for more TTS work.")
             self.fetchAndPlayNextTTSChunk()
         }
         else if self.isLLMFinished {
             if self.isProcessing { self.isProcessing = false }
             self.autoStartListeningAfterDelay()
         }
    }
}

private class TTSStreamer: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let logger: Logger
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var accumulatedData = Data()

    init(request: URLRequest, continuation: AsyncThrowingStream<Data, Error>.Continuation, logger: Logger) {
        self.request = request
        self.continuation = continuation
        self.logger = logger
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session?.dataTask(with: request).resume()
        Task { @MainActor [logger] in logger.debug("TTS URLSessionDataTask started.") }
    }

    func cancel() {
        session?.invalidateAndCancel()
        Task { @MainActor [logger] in logger.debug("TTS URLSession explicitly cancelled.") }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            Task { @MainActor [logger] in logger.error("🚨 TTS Error: Did not receive HTTPURLResponse.") }
            completionHandler(.cancel)
            continuation.finish(throwing: ChatViewModel.LlmError.networkError(URLError(.badServerResponse)))
            return
        }
        
        self.response = httpResponse
        Task { @MainActor [logger, httpResponse] in logger.debug("TTS Received response headers. Status: \(httpResponse.statusCode)") }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
         if let httpResponse = self.response, (200...299).contains(httpResponse.statusCode) {
             continuation.yield(data)
         } else {
             accumulatedData.append(data)
         }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
         if let error = error {
             Task { @MainActor [logger, error] in logger.error("🚨 TTS Network Error: \(error.localizedDescription)") }
             continuation.finish(throwing: ChatViewModel.LlmError.networkError(error))
         } else if let httpResponse = self.response, !(200...299).contains(httpResponse.statusCode) {
             let errorBody = String(data: accumulatedData, encoding: .utf8) ?? "Could not decode error body"
             Task { @MainActor [logger, httpResponse, errorBody] in logger.error("🚨 TTS API Error: Status \(httpResponse.statusCode). Body: \(errorBody)") }
             continuation.finish(throwing: ChatViewModel.LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody))
         } else {
             Task { @MainActor [logger] in logger.debug("TTS Stream finished successfully.") }
             continuation.finish()
         }
        self.session?.finishTasksAndInvalidate()
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
                Slider(value: $viewModel.ttsRate, in: 0.0...1.0, step: 0.05)
                Text(String(format: "%.1fx", viewModel.ttsDisplayMultiplier))
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
