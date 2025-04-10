//
//  ContentView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 08.04.25.
//

import SwiftUI
@preconcurrency import AVFoundation
import Speech
import OSLog
import UIKit


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
    let speed: Float
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
            // Update the TimePitch node's rate when the slider changes
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.ttsTimePitchNode.rate = self.ttsDisplayMultiplier // Target TimePitch node
                // logger.debug("TimePitch rate set to: \(self.ttsTimePitchNode.rate)")
            }
        }
    }
    @Published var listeningAudioLevel: Float = -50.0 // Audio level dBFS (-50 silence, 0 max)
    @Published var ttsOutputLevel: Float = 0.0      // Normalized TTS output level (0-1)
    @Published var selectedProvider: LLMProvider = .claude // LLM Provider
    
    // --- Internal State ---
    private var llmTask: Task<Void, Never>? = nil
    private var ttsFetchAndPlayTask: Task<Void, Never>? = nil // Renamed from ttsFetchTask
    private var isLLMFinished: Bool = false
    private var llmResponseBuffer: String = ""
    private var processedTextIndex: Int = 0
    private var currentSpokenText: String = ""
    private var isFetchingTTS: Bool = false // Will now mean fetching *and* playing stream
    private var hasUserStartedSpeakingThisTurn: Bool = false
    private var hasReceivedFirstLLMChunk: Bool = false
    
    // --- Audio Components ---
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let inputAudioEngine = AVAudioEngine() // Renamed for clarity
    // --- New TTS Audio Engine Components ---
    private let ttsAudioEngine = AVAudioEngine()
    private let ttsAudioPlayerNode = AVAudioPlayerNode()
    private let ttsTimePitchNode = AVAudioUnitTimePitch() // Add TimePitch
    private var ttsAudioFormat: AVAudioFormat? = nil
    private var isTTSEnginePrepared = false
    // Keep buffer MainActor isolated, remove explicit queue
    private var _pendingAudioBuffers: [AVAudioPCMBuffer] = []
    // Define the expected format for ENGINE PROCESSING (Float32)
    private let expectedTTSAudioFormat: AVAudioFormat? = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                                        sampleRate: 24000.0, // Standard for OpenAI TTS WAV
                                                                        channels: 1,        // Standard mono
                                                                        interleaved: false)
    private lazy var expectedFrameCountPerBuffer: AVAudioFrameCount = { // Make this lazy based on format
        guard let format = expectedTTSAudioFormat else { return 2048 } // Default fallback
        return AVAudioFrameCount(format.sampleRate * ttsAudioBufferDuration)
    }()
    private var audioStreamEnded = false
    private var scheduledBufferCount: Int = 0
    private var completedBufferCount: Int = 0
    // --- End New TTS Audio Engine Components ---
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
    private let ttsAudioBufferDuration: TimeInterval = 0.1 // Target buffer duration
    
    // --- API Keys & Prompt ---
    private var anthropicAPIKey: String?
    private var geminiAPIKey: String?
    private var openaiAPIKey: String?
    private var systemPrompt: String?
    private var lastMeasuredAudioLevel: Float = -50.0
    
    private let preBufferCountThreshold = 3 // Number of buffers to schedule before starting playback
    
    override init() {
        super.init()
        speechRecognizer.delegate = self
        setupTTSEngine() // Setup includes TimePitch now
        
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
        
        // --- Add Lifecycle Observers ---
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        logger.debug("Lifecycle observers added.")
        // --- End Lifecycle Observers ---
    }
    
    // Add setup for TTS Audio Engine
    private func setupTTSEngine() {
        // Attach nodes - This happens once during init
        ttsAudioEngine.attach(ttsAudioPlayerNode)
        ttsAudioEngine.attach(ttsTimePitchNode) // Attach TimePitch
        logger.debug("TTS Nodes attached in setupTTSEngine.")
        // Connections and start will happen in prepareTTSEngine
    }
    
    // Prepare engine function (call before playback)
    @MainActor // Ensure this runs on main thread for engine operations
    private func prepareTTSEngine() {
        guard !isTTSEnginePrepared else {
             logger.debug("TTS Engine already prepared.")
             // Ensure rate is updated even if already prepared
             ttsTimePitchNode.rate = self.ttsDisplayMultiplier // Target TimePitch
             return
        }
        guard let format = expectedTTSAudioFormat else {
            logger.error("🚨 Cannot prepare TTS engine: Expected audio format is nil.")
            isTTSEnginePrepared = false
            return
        }

        logger.debug("Preparing TTS Engine...")
        do {
            // Connect full chain with the expected format before starting
            // Player -> TimePitch -> Mixer
            ttsAudioEngine.connect(ttsAudioPlayerNode, to: ttsTimePitchNode, format: format)
            ttsAudioEngine.connect(ttsTimePitchNode, to: ttsAudioEngine.mainMixerNode, format: format)
            // logger.debug("Connected Player -> TimePitch -> Mixer with expected format: \(format)") // Updated Log

            // Set TimePitch rate (pitch defaults to 1.0)
            ttsTimePitchNode.rate = self.ttsDisplayMultiplier // Target TimePitch
            // logger.debug("Initial TimePitch rate set to: \(ttsTimePitchNode.rate)")

            // Install tap on PlayerNode (before TimePitch)
            ttsAudioPlayerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] (buffer, time) in
                 Task { @MainActor [weak self] in self?.updateTTSLevel(buffer: buffer) }
            }
            // logger.debug("Installed tap on PlayerNode.") // Keep log as is

            // Start the engine now that the graph is fully configured
            try ttsAudioEngine.start()
            isTTSEnginePrepared = true // Mark as prepared AFTER successful start
            logger.info("✅ TTS Audio Engine prepared and started successfully.")

        } catch {
            logger.error("🚨🚨🚨 CRITICAL: Failed to connect nodes or start TTS engine during preparation: \(error.localizedDescription)")
            // Clean up connections on failure
             ttsAudioEngine.disconnectNodeInput(ttsTimePitchNode) // Disconnect TimePitch input
             ttsAudioEngine.disconnectNodeInput(ttsAudioEngine.mainMixerNode) // Disconnect TimePitch output from mixer
            isTTSEnginePrepared = false
        }
    }
    
    // Function to stop and reset the TTS engine if needed
    private func stopAndResetTTSEngine() {
        // Check if engine has state (is running or was prepared) that needs cleanup
        if ttsAudioEngine.isRunning || isTTSEnginePrepared {
            // Explicitly remove the tap BEFORE stopping/resetting the engine.
            // This is crucial because reset() doesn't guarantee tap removal.
            ttsAudioPlayerNode.removeTap(onBus: 0)
            logger.debug("Removed tap on PlayerNode.")

            // Now stop the player and engine if running
            if ttsAudioEngine.isRunning {
                ttsAudioPlayerNode.stop()
                ttsAudioEngine.stop()
            }
            // Reset the engine to clear internal state and graph configuration.
            ttsAudioEngine.reset()
            logger.debug("TTS Audio Engine stopped and/or reset.")
        }
        isTTSEnginePrepared = false // Mark as unprepared after full stop/reset

        // Reset buffer/stream tracking state
        // ttsAudioFormat = nil // Keep this commented, expected format is constant
        _pendingAudioBuffers.removeAll()
        audioStreamEnded = false
        scheduledBufferCount = 0
        completedBufferCount = 0
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
        
        stopSpeaking() // This will now handle the new engine/stream
        
        if self.isProcessing {
            isProcessing = false
        }
        self.llmResponseBuffer = ""
        self.processedTextIndex = 0
        self.isLLMFinished = false
    }
    
    // --- Speech Recognition (Listening) ---
    func startListening() {
        guard !inputAudioEngine.isRunning else { return }
        
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
        
        let inputNode = inputAudioEngine.inputNode
        
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
        
        inputAudioEngine.prepare()
        do {
            try inputAudioEngine.start()
            startAudioLevelTimer()
        } catch {
            logger.error("🚨 Audio input engine start error: \(error.localizedDescription)")
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
    
    
    func stopAudioEngine() { // Renamed to stopInputAudioEngine for clarity
        guard inputAudioEngine.isRunning else { return }
        inputAudioEngine.stop()
        inputAudioEngine.inputNode.removeTap(onBus: 0)
        invalidateAudioLevelTimer()
        logger.debug("Input Audio Engine stopped.") // Added log
    }
    
    func stopListeningCleanup() {
        stopAudioEngine() // Calls renamed stopInputAudioEngine
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
            self.isFetchingTTS = false
            self.ttsFetchAndPlayTask?.cancel() // Cancel any ongoing TTS task
            self.ttsFetchAndPlayTask = nil
            self.hasReceivedFirstLLMChunk = false
            self.stopSpeaking() // Ensure any previous TTS is stopped before starting new LLM req
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
                    self.manageTTSPlayback() // Triggers TTS based on new text
                }
            }
            
        } catch is CancellationError {
            logger.notice("⏹️ LLM Task Cancelled.")
            llmError = CancellationError()
            await MainActor.run { [weak self] in self?.stopSpeaking() } // Stop TTS if LLM cancelled
        } catch {
            if !(error is CancellationError) {
                logger.error("🚨 LLM Error during stream: \(error.localizedDescription)")
                llmError = error
                await MainActor.run { [weak self] in self?.stopSpeaking() } // Stop TTS on LLM error
            }
        }
        
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            
            self.isLLMFinished = true
            self.manageTTSPlayback() // Trigger final TTS check
            
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
        // Only start a *new* TTS stream if one isn't already running for a previous chunk
        guard ttsFetchAndPlayTask == nil else {
            // logger.debug("manageTTSPlayback: TTS task already running.") // Optional debug log
            return
        }
        
        // Find the next chunk of text to synthesize
        let (chunk, nextIndex) = findNextTTSChunk(text: llmResponseBuffer, startIndex: processedTextIndex, isComplete: isLLMFinished)
        
        if !chunk.isEmpty {
            // We have text to speak, start the streaming process for this chunk
            logger.info("➡️ Synthesizing TTS for chunk (\(chunk.count) chars)...")
            self.processedTextIndex = nextIndex
            self.isFetchingTTS = true // Indicate we are now fetching *and* playing
            
            guard let apiKey = self.openaiAPIKey else {
                logger.error("🚨 OpenAI API Key missing, cannot fetch TTS.")
                self.isFetchingTTS = false // Reset flag
                // Consider adding an error message to chat
                return
            }
            
            // Start the combined fetch and play task
            self.ttsFetchAndPlayTask = Task { [weak self] in
                do {
                    // Start the streaming request and playback
                    try await self?.fetchAndPlayOpenAITTSStream(apiKey: apiKey, text: chunk, speed: self?.ttsRate ?? AVSpeechUtteranceDefaultSpeechRate)

                    // If the task completes without cancellation or error, it means streaming finished
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        // This log might be slightly inaccurate, it means the *task* finished,
                        // which includes waiting for playback.
                        logger.info("✅ TTS Task finished for chunk.")
                        self.isFetchingTTS = false
                        self.ttsFetchAndPlayTask = nil
                        // Crucially, call manageTTSPlayback again *after* the task finishes
                        // to check if there's *more* text waiting from the LLM.
                        self.manageTTSPlayback()
                    }
                } catch is CancellationError {
                    await MainActor.run { [weak self] in
                        self?.logger.notice("⏹️ TTS Fetch/Play task cancelled.")
                        // Don't reset isFetchingTTS here, stopSpeaking handles it
                        // self?.ttsFetchAndPlayTask = nil // stopSpeaking handles this
                        self?.stopSpeaking() // Ensure cleanup on cancellation
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.logger.error("🚨 TTS Fetch/Play failed: \(error.localizedDescription)")
                        // Don't reset isFetchingTTS here, stopSpeaking handles it
                        // self?.ttsFetchAndPlayTask = nil // stopSpeaking handles this
                        self?.stopSpeaking() // Ensure cleanup on error
                        // Optionally add error message to chat
                        // We might still try the next chunk if LLM isn't finished
                        // self?.manageTTSPlayback() // Or maybe not, depends on desired behavior on error
                    }
                }
            }
        } else if isLLMFinished && processedTextIndex == llmResponseBuffer.count {
            // No more text, and LLM is done, and no TTS task is running. We are finished processing.
            if isProcessing {
                isProcessing = false
                logger.info("⚙️ Processing finished (LLM & TTS Idle).")
            }
            // Check if engine is running and stop it cleanly using stopSpeaking
            if ttsAudioEngine.isRunning || isTTSEnginePrepared || isSpeaking { // Check isSpeaking too for safety
                 logger.info("⏹️ Stopping TTS engine and state as LLM and TTS are finished.")
                 stopSpeaking(wasCancelled: false) // Use stopSpeaking to update state correctly
            }
            // Check if we should auto-start listening *only if* not currently speaking
            // This check should now reliably pass after stopSpeaking(false) is called.
            if !isSpeaking {
                autoStartListeningAfterDelay()
            } else {
                // This case shouldn't happen if stopSpeaking worked, but log if it does.
                logger.warning("Expected isSpeaking to be false after final TTS cleanup, but it was true. Auto-start blocked.")
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
        
        let minInitialChunkLength = 100
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
            // Check engine state as well
            guard !self.isSpeaking && !self.isProcessing && !self.isListening && !self.ttsAudioEngine.isRunning else {
                logger.debug("Auto-start aborted: Invalid state (speaking: \(self.isSpeaking), processing: \(self.isProcessing), listening: \(self.isListening), ttsEngineRunning: \(self.ttsAudioEngine.isRunning)).")
                return
            }
            
            logger.info("🎙️ TTS finished or idle. Switching to user turn after delay...")
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            
            // Re-check state *after* delay, before starting
            guard !self.isSpeaking && !self.isProcessing && !self.isListening && !self.ttsAudioEngine.isRunning else {
                logger.warning("🎤 Aborted auto-start: State changed during brief delay.")
                return
            }
            
            self.startListening()
        }
    }
    
    // --- Cleanup ---
    deinit {
        // Add logging and remove observers
        logger.notice("ChatViewModel deinit called.")
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    func cleanupOnDisappear() {
        logger.info("ContentView disappeared. Cleaning up...")
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
    
    // --- Modified OpenAI TTS Fetch and NEW Play Logic ---
    
    // This function now handles the entire streaming and playback process
    func fetchAndPlayOpenAITTSStream(apiKey: String, text: String, speed: Float) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LlmError.streamingError("Cannot synthesize empty text")
        }
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw LlmError.invalidURL
        }
        // Ensure the expected format is valid before proceeding
        guard let format = self.expectedTTSAudioFormat else {
             logger.error("🚨 Cannot fetch TTS stream: Expected audio format is nil.")
             throw LlmError.streamingError("Internal audio format configuration error.")
        }


        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let clampedOpenAISpeed = max(0.25, min(1.0 + speed * 3.0, 4.0))
        let payload = OpenAITTSRequest(
            model: openAITTSModel, input: text, voice: openAITTSVoice,
            response_format: openAITTSFormat, // Expecting WAV (Int16)
            speed: clampedOpenAISpeed
        )
        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LlmError.requestEncodingError(error) }


        logger.debug("🚀 Starting TTS stream request...")

        // Reset streaming state for this new request
        await MainActor.run { [weak self] in
            // Don't reset ttsAudioFormat - it's fixed now
            self?.audioStreamEnded = false
            self?.scheduledBufferCount = 0
            self?.completedBufferCount = 0
            self?._pendingAudioBuffers.removeAll() // Clear any old buffers just in case
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
            // Prepare and START the engine beforehand.
            // Explicitly run on MainActor for AVAudioEngine safety, even though prepareTTSEngine is @MainActor.
            await MainActor.run { [weak self] in
                self?.prepareTTSEngine()
            }
            // Check if engine is ready after attempting preparation
            guard self.isTTSEnginePrepared else {
                 logger.error("🚨 Aborting TTS stream: Engine failed to prepare.")
                 throw LlmError.streamingError("Audio engine failed to prepare.")
             }

        } catch {
             // Catch errors from urlSession.bytes or the preparation check
            logger.error("🚨 TTS Network request or engine prep failed: \(error.localizedDescription)")
             // If it's not already an LlmError, wrap it
             if error is LlmError { throw error }
             else { throw LlmError.networkError(error) }
        }


        // ... (httpResponse checks) ...
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            var bodyIterator = bytes.makeAsyncIterator()
            let maxErrorBytes = 1024
             var readCount = 0 // Use count instead of string length for byte limit
            while readCount < maxErrorBytes, let byte = try? await bodyIterator.next() {
                errorBody += String(UnicodeScalar(byte))
                 readCount += 1
            }
            if readCount >= maxErrorBytes { errorBody += "..." }
            logger.error("🚨 OpenAI TTS Error: Status \(httpResponse.statusCode). Body: \(errorBody)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody)
        }


        // --- Byte Processing and Playback (FIXED) ---
        var audioDataBuffer = Data()
        let headerSize = 44 // Standard WAV header size to skip
        var bytesProcessed: Int = 0

        // Calculate based on SOURCE format (Int16 mono = 2 bytes/frame)
        let sourceBytesPerFrame = 2
        let framesPerBuffer = self.expectedFrameCountPerBuffer // Target Float32 frames per buffer
        let sourceBytesNeededForBuffer = Int(framesPerBuffer) * sourceBytesPerFrame // Bytes needed *from source*

        guard sourceBytesNeededForBuffer > 0 else {
            logger.error("🚨 Calculated source bytes needed for buffer is zero. Aborting.")
            throw LlmError.streamingError("Internal audio buffer calculation error.")
        }


        for try await byte in bytes {
            try Task.checkCancellation()

            bytesProcessed += 1
            // Skip header bytes
            guard bytesProcessed > headerSize else { continue }

            audioDataBuffer.append(byte)

            // Process Audio Data into Buffers
            // Check if we have enough *source* bytes for a full *destination* buffer
            while audioDataBuffer.count >= sourceBytesNeededForBuffer {
                try Task.checkCancellation()
                let frameCount = framesPerBuffer // Target frame count (Float32)
                // Take the required number of *source* bytes
                let dataChunk = audioDataBuffer.prefix(sourceBytesNeededForBuffer)
                // Remove the *source* bytes we just took
                audioDataBuffer.removeFirst(sourceBytesNeededForBuffer)

                // Create the PCM buffer (converts Int16 source -> Float32 dest)
                guard let pcmBuffer = createPCMBuffer(format: format, frameCount: frameCount, data: dataChunk) else {
                    logger.warning("Failed to create PCM buffer from \(dataChunk.count) bytes. Skipping chunk.")
                    continue // Skip this chunk
                }
                scheduleBuffer(pcmBuffer) // Schedule asynchronously
            }
        }

        // --- Stream Finished ---
        logger.debug("✅ TTS network stream finished.")
        await MainActor.run { [weak self] in self?.audioStreamEnded = true }

        // Process any remaining data in the buffer (runs on MainActor for state access)
        await MainActor.run { [weak self, audioDataBuffer] in
             guard let self = self else { return }
             // Calculate remaining frames based on remaining *source* bytes
             let remainingSourceBytes = audioDataBuffer.count
             logger.debug("Processing \(remainingSourceBytes) remaining source bytes post-stream...")
             let remainingFrames = AVAudioFrameCount(remainingSourceBytes / sourceBytesPerFrame)

            if remainingFrames > 0 {
                let finalDataChunk = audioDataBuffer // Use the whole remaining buffer
                 // Create buffer with the calculated remaining frames
                if let pcmBuffer = self.createPCMBuffer(format: format, frameCount: remainingFrames, data: finalDataChunk) {
                     self.scheduleBuffer(pcmBuffer)
                 } else {
                    logger.warning("Failed to create final PCM buffer from \(finalDataChunk.count) bytes.")
                 }
            }
             // audioDataBuffer goes out of scope here, no need to removeAll
        }


        // Ensure the player node starts (handled by trySchedulingPendingBuffers now)
        // The check inside trySchedulingPendingBuffers handles starting the player

        // Wait until the last buffer is completed or task is cancelled
        try await waitForPlaybackCompletion()
        logger.debug("Playback seems complete or task cancelled.")

        // Final cleanup is handled by the calling task's completion/error block
    }


    // Helper to create PCM buffer from data chunk (KEEP AS IS)
    private func createPCMBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount, data: Data) -> AVAudioPCMBuffer? {
        // --- Check if frameCount is valid ---
        guard frameCount > 0 else {
            logger.warning("Attempted to create PCM buffer with zero frameCount.")
            return nil
        }
        // --- Check if data is empty ---
         guard !data.isEmpty else {
             logger.warning("Attempted to create PCM buffer with empty data for frameCount \(frameCount).")
             return nil
         }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            logger.error("🚨 Failed to create AVAudioPCMBuffer with format \(format) and capacity \(frameCount)")
            return nil
        }
        pcmBuffer.frameLength = frameCount // Set the actual length

        let channelCount = Int(format.channelCount)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            logger.error("🚨 Bytes per frame is zero in createPCMBuffer for format \(format)")
            return nil
        }

        // --- Handle Target Format: Float32 Non-Interleaved ---
        if format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved {
             guard let destChannelPtrs = pcmBuffer.floatChannelData else {
                logger.error("🚨 Failed to get floatChannelData for destination buffer.")
                return nil
            }

             // Source is assumed Int16 (WAV default)
             let sourceBytesPerSample = 2
             let sourceSamplesInData = data.count / sourceBytesPerSample
             let sourceFramesInData = sourceSamplesInData / channelCount // Assumes source channel count matches target for now

             // Ensure we have enough source frames for the requested output frameCount
             guard sourceFramesInData >= Int(frameCount) else {
                  logger.error("🚨 Data size mismatch (Int16 source -> Float32 dest): Got \(sourceFramesInData) source frames, needed \(frameCount) output frames. Data bytes=\(data.count). Cannot create buffer.")
                  // *** ALWAYS return nil if data is insufficient ***
                  return nil
             }


            data.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) in
                // Check baseAddress is not nil *and* count matches expected size based on source samples
                guard let baseAddress = rawBufferPointer.baseAddress,
                      rawBufferPointer.count >= Int(frameCount) * channelCount * sourceBytesPerSample else {
                    logger.error("🚨 Invalid data pointer or insufficient data size (\(rawBufferPointer.count) bytes) for \(frameCount) frames in createPCMBuffer (Int16->Float32 path)")
                    // We should technically invalidate the buffer or return nil here.
                    // However, the outer check sourceFramesInData >= Int(frameCount) should prevent this.
                    // For safety, maybe zero out the buffer? Or just log. Let's log for now.
                    return // Exit the withUnsafeBytes block
                }

                let sourcePtr = baseAddress.assumingMemoryBound(to: Int16.self) // *** READ SOURCE AS Int16 ***
                let totalSourceSamplesAvailable = rawBufferPointer.count / MemoryLayout<Int16>.size // Recalculate for safety

                let scale = Float(Int16.max) // For converting Int16 -> Float32 [-1.0, 1.0]

                for channel in 0..<channelCount {
                    let destChannelPtr = destChannelPtrs[channel] // Target is Float32

                    if channelCount == 1 {
                        // Mono: Convert Int16 source samples to Float32 destination samples
                        var sourceIndex = 0
                        for frameIndex in 0..<Int(pcmBuffer.frameLength) { // Use buffer's frameLength
                            if sourceIndex < totalSourceSamplesAvailable { // Check against actual available samples
                                 let intSample = sourcePtr[sourceIndex]
                                 destChannelPtr[frameIndex] = Float(intSample) / scale // Convert and write
                            } else {
                                 logger.warning("Unexpected end of source data during Int16->Float32 conversion (Mono). Frame \(frameIndex)/\(pcmBuffer.frameLength). Source samples \(totalSourceSamplesAvailable).")
                                 destChannelPtr[frameIndex] = 0.0 // Zero out remaining
                            }
                            sourceIndex += 1
                        }
                    } else {
                        // Multi-channel: De-interleave Int16 source, convert to Float32 destination
                        var sourceIndex = channel
                        for frameIndex in 0..<Int(pcmBuffer.frameLength) { // Use buffer's frameLength
                            if sourceIndex < totalSourceSamplesAvailable { // Check against actual available samples
                                let intSample = sourcePtr[sourceIndex]
                                destChannelPtr[frameIndex] = Float(intSample) / scale // Convert and write
                            } else {
                                 logger.warning("Unexpected end of source data during Int16->Float32 de-interleaving. Channel \(channel), Frame \(frameIndex)/\(pcmBuffer.frameLength). Source samples \(totalSourceSamplesAvailable).")
                                 destChannelPtr[frameIndex] = 0.0 // Zero out remaining
                            }
                            sourceIndex += channelCount
                        }
                    }
                }
            }
        }
        // --- Handle Target Format: Int16 Non-Interleaved (Keep previous logic just in case) ---
        else if format.commonFormat == .pcmFormatInt16 && !format.isInterleaved {
             // ... (Existing Int16 copy logic remains here, ensure similar bounds checks) ...
             guard let channelPtrs = pcmBuffer.int16ChannelData else {
                logger.error("🚨 Failed to get int16ChannelData for buffer.")
                return nil
            }

            data.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) in
                // Check baseAddress is not nil *and* count matches expected size
                 guard let baseAddress = rawBufferPointer.baseAddress,
                       rawBufferPointer.count >= Int(frameCount) * channelCount * MemoryLayout<Int16>.size else {
                     logger.error("🚨 Invalid data pointer or insufficient data size (\(rawBufferPointer.count) bytes) for \(frameCount) frames in createPCMBuffer (Int16 path)")
                     return // Exit the withUnsafeBytes block
                 }

                let sourcePtr = baseAddress.assumingMemoryBound(to: Int16.self)
                let totalSourceSamplesAvailable = rawBufferPointer.count / MemoryLayout<Int16>.size

                for channel in 0..<channelCount {
                    let destChannelPtr = channelPtrs[channel]

                    if channelCount == 1 {
                        // Mono: Direct copy
                         let samplesToCopy = min(Int(frameCount), totalSourceSamplesAvailable)
                         if samplesToCopy < Int(frameCount) {
                            logger.warning("Insufficient source data for direct Int16 copy (Mono). Requested \(frameCount), got \(samplesToCopy).")
                         }
                         destChannelPtr.initialize(from: sourcePtr, count: samplesToCopy)
                         // Zero out remaining if necessary
                         if samplesToCopy < Int(frameCount) {
                             destChannelPtr.advanced(by: samplesToCopy).initialize(repeating: 0, count: Int(frameCount) - samplesToCopy)
                         }
                    } else {
                        // Multi-channel: De-interleave
                        var sourceIndex = channel
                        for frameIndex in 0..<Int(frameCount) {
                            if sourceIndex < totalSourceSamplesAvailable {
                                destChannelPtr[frameIndex] = sourcePtr[sourceIndex]
                            } else {
                                logger.warning("Unexpected end of source data during de-interleaving (Int16). Channel \(channel), Frame \(frameIndex)/\(frameCount).")
                                destChannelPtr[frameIndex] = 0 // Zero out remaining
                            }
                            sourceIndex += channelCount
                        }
                    }
                }
            }
        }
        // --- Unsupported Format ---
        else {
            logger.error("Unsupported buffer format for copying: \(format)")
            return nil
        }

        return pcmBuffer
    }
    
    // Helper to schedule buffer and manage state (KEEP AS IS)
    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        // Dispatch append and scheduling check to MainActor
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self._pendingAudioBuffers.append(buffer) // Append on MainActor
            self.trySchedulingPendingBuffers()       // Call scheduling check on MainActor
        }
    }
    
    // Try to schedule buffers from the pending queue (starts player after threshold)
    @MainActor
    private func trySchedulingPendingBuffers() {
        guard ttsAudioPlayerNode.engine != nil, isTTSEnginePrepared else {
             if !_pendingAudioBuffers.isEmpty {
                 logger.warning("trySchedulingPendingBuffers: Engine not ready, cannot schedule buffer \(self.scheduledBufferCount + 1). Pending: \(self._pendingAudioBuffers.count)")
             }
            return
        }

        // Schedule buffers as long as there are pending ones and the engine is ready
        while !_pendingAudioBuffers.isEmpty {
            let bufferToSchedule = _pendingAudioBuffers.removeFirst() // Access directly

            scheduledBufferCount += 1
             // logger.debug("Scheduling buffer \(scheduledBufferCount)... Pending: \(_pendingAudioBuffers.count)") // Verbose

            ttsAudioPlayerNode.scheduleBuffer(bufferToSchedule) { [weak self] in
                // This completion handler runs on a background thread
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.completedBufferCount += 1
                    // logger.debug("Buffer \(self.completedBufferCount)/\(self.scheduledBufferCount) completed.") // Verbose

                    // ** Now, this completion only potentially triggers scheduling more, **
                    // ** it doesn't check for overall completion. **
                    // Schedule the next one *if* available. This is slightly less robust
                    // than calling trySchedulingPendingBuffers directly, but avoids potential recursion issues
                    // if completions happen very fast. Let's stick with the recursive call for now.
                    self.trySchedulingPendingBuffers() // Check again on MainActor
                }
            }

             // Check if we should start the player *after* scheduling this buffer
            // Start player only if it's not already playing, the engine is running,
            // AND we've scheduled enough initial buffers.
            if !ttsAudioPlayerNode.isPlaying && ttsAudioEngine.isRunning && scheduledBufferCount >= self.preBufferCountThreshold {
                // Double-check engine state right before playing
                 guard ttsAudioEngine.isRunning else {
                     logger.warning("Engine stopped unexpectedly before playback could start after pre-buffering.")
                     return // Don't try to play if engine stopped
                 }
                 guard ttsAudioPlayerNode.engine != nil else {
                     logger.warning("Player node detached unexpectedly before playback could start after pre-buffering.")
                     return // Don't try to play if node detached
                 }

                logger.info("▶️ Starting TTS playback node after reaching pre-buffer threshold (\(self.preBufferCountThreshold)).")
                ttsAudioPlayerNode.play()
                if !self.isSpeaking { self.isSpeaking = true } // Update state only when playing starts
                self.startTTSLevelTimer() // Start level monitoring only when playing starts
            }
        }
    }

    // Wait for playback completion helper (KEEP AS IS)
    private func waitForPlaybackCompletion() async throws {
        // logger.debug("Waiting for playback completion...")
        while true {
            try Task.checkCancellation()
            let isDone = await MainActor.run { [weak self] in
                guard let self = self else { return true } // If self is nil, exit loop
                // Check if the engine is still prepared; if not, something went wrong, consider it done/failed.
                 guard self.isTTSEnginePrepared else {
                     logger.warning("waitForPlaybackCompletion: Engine became unprepared. Exiting wait loop.")
                     return true
                 }
                // Done if stream ended AND all scheduled buffers have completed
                // AND there are no more pending buffers to be scheduled.
                return self.audioStreamEnded
                    && self.completedBufferCount >= self.scheduledBufferCount
                    && self._pendingAudioBuffers.isEmpty // Add check for pending buffers
            }
            if isDone {
                // logger.debug("Playback completion condition met.")
                break
            }
            // Sleep briefly to avoid busy-waiting
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
         // Add a final short sleep AFTER the loop breaks, before returning.
         // This allows the very last buffer completion handler to potentially finish
         // its MainActor task block, ensuring completedBufferCount is fully up-to-date.
         try? await Task.sleep(nanoseconds: 10_000_000) // 10ms safety buffer
        logger.debug("Wait for playback finished.") // Log when returning
    }
    
    // --- TTS Level Visualization Logic ---
    func startTTSLevelTimer() {
        // Only start if using the tap mechanism now
        // The timer might not even be needed if the tap provides updates frequently enough,
        // but let's keep it for consistency for now. It will just trigger the update function.
        invalidateTTSLevelTimer()
        ttsLevelTimer = Timer.scheduledTimer(withTimeInterval: ttsLevelUpdateRate, repeats: true) { _ in
            // The actual update happens in the tap block, this timer might become redundant
            // Task { @MainActor [weak self] in self?.updateTTSLevel() } // Remove direct call
        }
        logger.debug("TTS Level Timer started (monitors tap updates).")
    }
    
    func invalidateTTSLevelTimer() {
        if ttsLevelTimer != nil {
            ttsLevelTimer?.invalidate()
            ttsLevelTimer = nil
            // Reset level if timer stops and node isn't playing
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !self.ttsAudioPlayerNode.isPlaying && self.ttsOutputLevel != 0.0 {
                    self.ttsOutputLevel = 0.0
                }
            }
            logger.debug("TTS Level Timer invalidated.")
        }
    }
    
    // Updated Level Calculation (called by tap)
    @MainActor private func updateTTSLevel(buffer: AVAudioPCMBuffer) {
        guard ttsAudioPlayerNode.isPlaying else {
            if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
            return
        }

        let frameLength = buffer.frameLength
        guard frameLength > 0 else { return }
        var rms: Float = 0.0
        var sumOfSquares: Float = 0.0 // Use Float for accumulator

        // Revert to only handling Float32 Non-Interleaved, as that's what createPCMBuffer now produces
        guard buffer.format.commonFormat == .pcmFormatFloat32 && buffer.format.isInterleaved == false else {
             logger.warning("Unsupported format received in level tap (expected Float32 non-interleaved): \(buffer.format)")
             return
        }

        guard let channelData = buffer.floatChannelData?[0] else { return }
        let channelDataValue = UnsafeBufferPointer(start: channelData, count: Int(frameLength))
        for sample in channelDataValue { sumOfSquares += sample * sample }


        // Calculate RMS
        if frameLength > 0 {
             rms = sqrt(sumOfSquares / Float(frameLength))
        } else {
             rms = 0.0
        }


        // Similar dB calculation and normalization as before
        let dbValue = (rms > 0) ? (20 * log10(rms)) : -160.0 // Use -160 for silence floor
        let minDBFS: Float = -50.0
        let maxDBFS: Float = 0.0

        var normalizedLevel: Float = 0.0
        if dbValue > minDBFS {
            let dbRange = maxDBFS - minDBFS
            if dbRange > 0 {
                let clampedDb = max(minDBFS, min(dbValue, maxDBFS))
                normalizedLevel = (clampedDb - minDBFS) / dbRange
            }
        }

        // Apply curve and smoothing
        let exponent: Float = 1.5
        let curvedLevel = pow(normalizedLevel, exponent)
        let finalLevel = max(0.0, min(curvedLevel, 1.0))

        let smoothingFactor: Float = 0.2
        let smoothedLevel = self.ttsOutputLevel * (1.0 - smoothingFactor) + finalLevel * smoothingFactor

        if abs(self.ttsOutputLevel - smoothedLevel) > 0.01 || (smoothedLevel == 0 && self.ttsOutputLevel != 0) {
            self.ttsOutputLevel = smoothedLevel
        }
    }
    
    // --- Updated Stop Speaking ---
    @MainActor
    func stopSpeaking(wasCancelled: Bool = true) {
        let wasSpeakingPreviously = self.isSpeaking
        // Only log interruption if a task is actually being cancelled
        if wasCancelled, let task = self.ttsFetchAndPlayTask, !task.isCancelled {
            logger.notice("⏹️ TTS streaming/playback interrupted by explicit stop.")
            task.cancel() // Cancel the task
            self.ttsFetchAndPlayTask = nil // Clear the reference
            self.isFetchingTTS = false // Update flag
        } else if !wasCancelled {
             // Log normal finish if needed, but this function is mainly for stops/errors now
             // logger.info("⏹️ TTS playback finished, cleaning up.") // Optional: can remove if too noisy
        } else {
             // Task was already nil or cancelled
             // logger.debug("stopSpeaking called but no active/cancellable task found.")
        }
        
        // If we were speaking or the engine was prepared, reset it.
        if wasSpeakingPreviously || isTTSEnginePrepared {
            // 2. Stop AND RESET the audio node and engine for thorough cleanup
            stopAndResetTTSEngine() // Use the full reset function
        } else {
            // logger.debug("stopSpeaking called but engine already stopped/reset.")
        }


        // 4. Invalidate level timer and reset level (safe to call even if timer inactive)
        self.invalidateTTSLevelTimer()
        if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }

        // 5. Update speaking state (ensure it's false after stopping)
        if self.isSpeaking {
            self.isSpeaking = false
        }

        // 6. Handle processing state IF the stop was due to cancellation/error
        //    AND the LLM stream has also finished. Natural completion handles this elsewhere.
        //    This logic might be redundant now, as the task catch block calls stopSpeaking,
        //    and the manageTTSPlayback handles the final state transition. Let's remove it here.
        /*
        if wasCancelled && wasSpeakingPreviously && self.isLLMFinished && self.ttsFetchAndPlayTask == nil {
            if self.isProcessing {
                self.isProcessing = false
                logger.info("⚙️ Processing finished (TTS stopped due to cancel/error).")
            }
        }
        */
    }
    
    // --- Lifecycle Handlers ---
    @objc private func handleDidEnterBackground() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.logger.notice("App entered background. Cleaning up audio...")
            // Perform the same cleanup as when the view disappears
            self.stopListeningCleanup()
            self.stopSpeaking() // This now fully stops the TTS engine
            // Also cancel any active LLM task if backgrounded
            if self.llmTask != nil {
                self.logger.notice("Cancelling LLM task due to backgrounding.")
                self.llmTask?.cancel()
                self.llmTask = nil
                // Reset processing state if LLM was cancelled
                if self.isProcessing { self.isProcessing = false }
            }
        }
    }
    
    @objc private func handleWillEnterForeground() {
        Task { @MainActor [weak self] in
            self?.logger.notice("App will enter foreground.")
            // Re-prepare engines or re-acquire resources if needed.
            // Currently, engines are prepared on demand (prepareTTSEngine, inputAudioEngine.prepare),
            // so explicit re-preparation might not be required unless specific state was lost.
            // We could ensure the audio session is active again if needed, but setCategory is called in startListening.
        }
    }
    // --- End Lifecycle Handlers ---
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
