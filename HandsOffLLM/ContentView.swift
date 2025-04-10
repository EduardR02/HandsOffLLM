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


// --- Data Structures (Identifiable Message, API Requests/Responses) ---
// (Keep these structs as they were: ChatMessage, ClaudeRequest, MessageParam,
// ClaudeStreamEvent, Delta, ClaudeResponseMessage, UsageData,
// OpenAITTSRequest, GeminiRequest, GeminiContent, GeminiPart,
// GeminiResponseChunk, GeminiCandidate)
// ... (Struct definitions omitted for brevity - unchanged from original) ...

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


// --- Main ViewModel ---
@MainActor
class ChatViewModel: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")
    
    enum LLMProvider { case gemini, claude }
    enum TTSState { case idle, fetching, buffering, playing } // Simplified state concept
    
    // --- Published Properties ---
    @Published var messages: [ChatMessage] = []
    @Published var isListening: Bool = false
    @Published var isProcessing: Bool = false // Thinking/Waiting for LLM response stream
    @Published var isSpeaking: Bool = false   // TTS audio playback is active via player node
    @Published var ttsRate: Float = AVSpeechUtteranceDefaultSpeechRate {
        didSet { Task { @MainActor [weak self] in self?.updateTimePitchRate() } }
    }
    @Published var listeningAudioLevel: Float = -50.0 // Mic Input dBFS
    @Published var ttsOutputLevel: Float = 0.0      // TTS Output Normalized (0-1)
    @Published var selectedProvider: LLMProvider = .claude
    
    // --- Internal State ---
    private var llmTask: Task<Void, Never>? = nil
    private var ttsFetchAndBufferTask: Task<Void, Error>? = nil // Handles fetching N *and* N+1 logic now
    private var isLLMFinished: Bool = false
    private var llmResponseBuffer: String = ""
    private var processedTextIndex: Int = 0 // Tracks end of the *last chunk sent* for TTS fetching
    private var hasUserStartedSpeakingThisTurn: Bool = false
    private var hasReceivedFirstLLMChunk: Bool = false
    private var lastMeasuredAudioLevel: Float = -50.0
    private var currentSpokenText: String = ""
    
    // --- Audio Components ---
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let inputAudioEngine = AVAudioEngine()
    // TTS Audio Engine Components
    private let ttsAudioEngine = AVAudioEngine()
    private let ttsAudioPlayerNode = AVAudioPlayerNode()
    private let ttsTimePitchNode = AVAudioUnitTimePitch()
    private var isTTSEnginePrepared = false
    private var _pendingAudioBuffers: [AVAudioPCMBuffer] = [] // Central queue for all TTS audio
    private var ttsAudioFormat: AVAudioFormat? = nil // Should be set once based on expected format
    private let expectedTTSAudioFormat: AVAudioFormat? = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                                        sampleRate: 24000.0,
                                                                        channels: 1,
                                                                        interleaved: false)
    private lazy var expectedFrameCountPerBuffer: AVAudioFrameCount = { // Based on target duration
        guard let format = expectedTTSAudioFormat else { return 2048 }
        return AVAudioFrameCount(format.sampleRate * ttsAudioBufferDuration)
    }()
    private var scheduledBufferCount: Int = 0
    private var completedBufferCount: Int = 0
    private var ttsLevelTimer: Timer?
    
    // --- Configuration & Timers ---
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 1.5
    private let audioLevelUpdateRate: TimeInterval = 0.1
    private var audioLevelTimer: Timer?
    private let ttsLevelUpdateRate: TimeInterval = 0.05
    private let claudeModel = "claude-3-7-sonnet-20250219" // Ensure this matches user file
    private let geminiModel = "gemini-2.0-flash"         // Ensure this matches user file
    private let openAITTSModel = "gpt-4o-mini-tts"       // Ensure this matches user file
    private let openAITTSVoice = "nova"
    private let openAITTSFormat = "wav" // Needs to match createPCMBuffer logic (Int16 source)
    private let maxTTSChunkLength = 4000 // Max characters per single TTS request
    private let ttsAudioBufferDuration: TimeInterval = 0.1 // Target duration for each AVAudioPCMBuffer
    private let preBufferCountThreshold = 2 // Buffers needed before starting player
    private let baseMinTTSChunkLength = 60.0 // Base min characters at 1.0x speed
    
    // --- API Keys & Prompt ---
    private var anthropicAPIKey: String?
    private var geminiAPIKey: String?
    private var openaiAPIKey: String?
    private var systemPrompt: String?

    // --- Session Management ---
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        // Add timeouts? config.timeoutIntervalForRequest = 30?
        return URLSession(configuration: config)
    }()

    // --- NEW State for Concurrent Fetch Strategy ---
    private var fetchContinuation: CheckedContinuation<Void, Error>? = nil // Signals fetch completion
    private var isFetchingNextChunk: Bool = false // Tracks if the N+1 fetch is active
    private var fetchTriggeredByPlaybackStart = false // Ensure trigger fires only once per chunk start

    // --- Initialization ---
    override init() {
        super.init()
        speechRecognizer.delegate = self
        setupTTSEngine()
        loadAPIKeysAndPrompt()
        requestPermissions()
        setupLifecycleObservers()
        // Set the expected format once
        self.ttsAudioFormat = self.expectedTTSAudioFormat
        logger.info("ChatViewModel initialized.")
    }

    private func loadAPIKeysAndPrompt() {
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
            logger.warning("System prompt is empty. Using default behavior.")
        } else if systemPrompt == "You are a helpful voice assistant. Keep your responses concise and conversational." {
            logger.warning("Using the default placeholder system prompt. Edit Prompts.swift to customize.")
        } else {
            logger.info("Custom system prompt loaded.")
        }
        }
        
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        logger.debug("Lifecycle observers added.")
    }
    
    // --- Audio Engine Setup ---
    private func setupTTSEngine() {
        ttsAudioEngine.attach(ttsAudioPlayerNode)
        ttsAudioEngine.attach(ttsTimePitchNode)
        logger.debug("TTS Nodes attached.")
        // Connections happen in prepareTTSEngine
    }

    @MainActor
    private func prepareTTSEngine() {
        guard !isTTSEnginePrepared else {
             logger.debug("TTS Engine already prepared.")
            updateTimePitchRate() // Ensure rate is correct
             return
        }
        guard let format = self.ttsAudioFormat else { // Use the stored format
            logger.error("🚨 Cannot prepare TTS engine: Expected audio format is nil.")
            isTTSEnginePrepared = false
            return
        }

        logger.debug("Preparing TTS Engine...")
        do {
            // Connect Player -> TimePitch -> Mixer
            ttsAudioEngine.connect(ttsAudioPlayerNode, to: ttsTimePitchNode, format: format)
            ttsAudioEngine.connect(ttsTimePitchNode, to: ttsAudioEngine.mainMixerNode, format: format)
            logger.debug("Connected Player -> TimePitch -> Mixer with format: \(format)")

            // Set TimePitch rate
            updateTimePitchRate()

            // Install tap on PlayerNode (before TimePitch) for level monitoring
            ttsAudioPlayerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] (buffer, _) in
                 Task { @MainActor [weak self] in self?.updateTTSLevel(buffer: buffer) }
            }
            logger.debug("Installed tap on PlayerNode.")

            // Start the engine
            try ttsAudioEngine.start()
            isTTSEnginePrepared = true
            logger.info("✅ TTS Audio Engine prepared and started.")

        } catch {
            logger.error("🚨🚨🚨 CRITICAL: Failed to connect nodes or start TTS engine: \(error.localizedDescription)")
            ttsAudioEngine.disconnectNodeInput(ttsTimePitchNode)
            ttsAudioEngine.disconnectNodeInput(ttsAudioEngine.mainMixerNode)
            isTTSEnginePrepared = false
        }
    }
    
    @MainActor
    private func updateTimePitchRate() {
        guard isTTSEnginePrepared || ttsAudioEngine.isRunning else { return } // Avoid updates if not ready
        let targetRate = self.ttsDisplayMultiplier // Use calculated display multiplier
        if abs(ttsTimePitchNode.rate - targetRate) > 0.01 {
            ttsTimePitchNode.rate = targetRate
            // logger.debug("TimePitch rate set to: \(targetRate)")
        }
    }

    @MainActor // Ensure called on main thread
    private func stopAndResetTTSEngine() {
        if ttsAudioEngine.isRunning || isTTSEnginePrepared {
            // Remove tap before stopping
             // Check if player node is attached before removing tap
             if ttsAudioPlayerNode.engine != nil {
            ttsAudioPlayerNode.removeTap(onBus: 0)
            logger.debug("Removed tap on PlayerNode.")
             } else {
                logger.warning("Attempted to remove tap, but player node was not attached to engine.")
             }

            // Stop player and engine
            if ttsAudioEngine.isRunning {
                ttsAudioPlayerNode.stop()
                ttsAudioEngine.stop()
                logger.debug("TTS Audio Player Node and Engine stopped.")
            }

            // Reset engine (clears graph and state)
            ttsAudioEngine.reset()
            logger.debug("TTS Audio Engine reset.")
        }
        isTTSEnginePrepared = false // Mark as unprepared

        // Reset buffer/stream tracking state
        _pendingAudioBuffers.removeAll()
        scheduledBufferCount = 0
        completedBufferCount = 0
        fetchContinuation?.resume(throwing: CancellationError()) // Cancel any pending fetch wait
        fetchContinuation = nil
        isFetchingNextChunk = false
        fetchTriggeredByPlaybackStart = false

        // Stop level timer and reset level
        invalidateTTSLevelTimer()
        if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
        if self.isSpeaking { self.isSpeaking = false } // Ensure speaking state is false

        logger.debug("TTS Engine and associated state fully reset.")
    }
    
    // --- Permission Request ---
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if authStatus != .authorized {
                    self.logger.error("Speech recognition authorization denied.")
                    // Handle error (e.g., show alert)
                }
            }
        }
        
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !granted {
                    self.logger.error("Microphone permission denied.")
                    // Handle error
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
                cancelOngoingTasks()
            }
        }
    }
    
    // Combined cancellation function
    func cancelOngoingTasks() {
        logger.notice("⏹️ Cancel requested by user.")
        
        // Cancel LLM Task
        if let task = llmTask {
            task.cancel()
            llmTask = nil
            if isProcessing { isProcessing = false } // Reset processing if LLM was cancelled
        }

        // Cancel TTS Fetch/Buffer Task(s)
        if let task = ttsFetchAndBufferTask {
            task.cancel()
            ttsFetchAndBufferTask = nil
        }
        fetchContinuation?.resume(throwing: CancellationError()) // Cancel wait
        fetchContinuation = nil
        isFetchingNextChunk = false

        // Stop and reset TTS audio engine and state
        stopAndResetTTSEngine() // This now handles player stop, reset, buffers, state vars

        // Reset LLM buffer state
        self.llmResponseBuffer = ""
        self.processedTextIndex = 0
        self.isLLMFinished = false
        self.hasReceivedFirstLLMChunk = false
    }
    
    // --- Speech Recognition (Listening) ---
    func startListening() {
        guard !inputAudioEngine.isRunning, SFSpeechRecognizer.authorizationStatus() == .authorized, AVAudioApplication.shared.recordPermission == .granted else {
            logger.warning("Cannot start listening - engine running or permissions denied.")
            // Maybe request permissions again here?
            return
        }

        // Ensure TTS is fully stopped before listening
        if isSpeaking || ttsAudioEngine.isRunning {
            logger.warning("TTS was active when starting listening. Stopping TTS first.")
            stopAndResetTTSEngine()
        }
        
        isListening = true
        isProcessing = false
        // isSpeaking should be false after potential stopAndResetTTSEngine
        currentSpokenText = ""
        hasUserStartedSpeakingThisTurn = false
        listeningAudioLevel = -50.0
        logger.notice("🎙️ Listening started...")
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Use playAndRecord to allow potential TTS overlap if needed later, but duck others.
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("🚨 Audio session setup error: \(error.localizedDescription)")
            isListening = false
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            logger.critical("Unable to create SFSpeechAudioBufferRecognitionRequest")
            isListening = false
            return
        }
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = inputAudioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard speechRecognizer.isAvailable else {
            logger.error("🚨 Speech recognizer is not available.")
            isListening = false
            return
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.recognitionTask != nil else { return } // Check if task is still valid
                
                var isFinal = false
                
                if let result = result {
                    let newTranscription = result.bestTranscription.formattedString
                    // Only update and reset timer if text changes meaningfully
                    if newTranscription != self.currentSpokenText {
                        self.currentSpokenText = newTranscription
                         if !self.currentSpokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                             if !self.hasUserStartedSpeakingThisTurn {
                        self.logger.info("🎤 User started speaking. Starting silence timer.")
                        self.hasUserStartedSpeakingThisTurn = true
                        self.startSilenceTimer()
                             } else {
                                 self.resetSilenceTimer() // Reset timer on new speech
                    }
                         }
                    }
                    isFinal = result.isFinal
                    
                    if isFinal {
                        self.logger.info("✅ Final transcription received: '\(self.currentSpokenText)'")
                        self.invalidateSilenceTimer()
                        self.stopListeningAndProcess(transcription: self.currentSpokenText)
                        return // Important: return after final processing
                    }
                }
                
                if let error = error {
                    let nsError = error as NSError
                    // Ignore "No speech" (1110) or session errors (1107) unless final
                    if !(nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 1107)) {
                        self.logger.warning("🚨 Recognition task error: \(error.localizedDescription)")
                    }
                    // Don't stop listening on intermittent errors unless final
                    if !isFinal {
                        self.invalidateSilenceTimer()
                        // Consider if stopListeningCleanup() is needed here on specific errors
                    } else {
                         // If final and error occurred, process whatever we have
                         self.logger.warning("Error occurred on final recognition result.")
                         self.invalidateSilenceTimer()
                         self.stopListeningAndProcess(transcription: self.currentSpokenText) // Process potentially partial text
                    }
                }
            }
        }

        // Install tap for recognition and level measurement
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
             // Only append if listening and recognition request exists
             if self.isListening, let request = self.recognitionRequest {
                 request.append(buffer)
             }
            // Measure level regardless of speaking state for visual feedback
            self.lastMeasuredAudioLevel = self.calculatePowerLevel(buffer: buffer)
        }
        
        inputAudioEngine.prepare()
        do {
            try inputAudioEngine.start()
            startAudioLevelTimer() // Start monitoring mic level
        } catch {
            logger.error("🚨 Audio input engine start error: \(error.localizedDescription)")
            stopListeningCleanup() // Cleanup if engine fails to start
        }
    }

    func stopListeningAndProcess(transcription: String? = nil) {
            Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard self.isListening else { return } // Only process if currently listening

            let textToProcess = (transcription ?? self.currentSpokenText).trimmingCharacters(in: .whitespacesAndNewlines)

            self.stopListeningCleanup() // Stop mic, timers, recognition task

            if !textToProcess.isEmpty {
                self.isProcessing = true // Indicate LLM communication starts
                logger.info("⚙️ Processing transcription: '\(textToProcess)'")
                let userMessage = ChatMessage(role: "user", content: textToProcess)
                self.messages.append(userMessage) // Add user message to history

                // --- Start the LLM Fetch Task ---
                self.llmTask = Task {
                    await self.fetchLLMResponseStreaming()
                }
            } else {
                logger.info("⚙️ No valid text detected to process. Returning to idle/listening.")
                // If no text, we might want to immediately start listening again or wait
                 self.startListening() // Or implement different idle behavior
            }
        }
    }


    // Combined cleanup for stopping listening components
    private func stopListeningCleanup() {
        guard isListening else { return } // Avoid redundant cleanup

        // Stop recognition task first
        recognitionTask?.cancel()
        recognitionTask?.finish() // Mark task as finished
        recognitionRequest?.endAudio() // Signal end of audio if request exists
        recognitionTask = nil
        recognitionRequest = nil

        // Stop audio engine and related components
        if inputAudioEngine.isRunning {
            inputAudioEngine.stop()
            inputAudioEngine.inputNode.removeTap(onBus: 0)
        }
        invalidateAudioLevelTimer()
        invalidateSilenceTimer()

        // Reset state variables
            isListening = false
            listeningAudioLevel = -50.0
        currentSpokenText = "" // Clear last transcription
        hasUserStartedSpeakingThisTurn = false

        // Deactivate audio session only if TTS isn't expected soon
        // Let setCategory in startListening/prepareTTSEngine handle activation
        // do {
        //     try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // } catch {
        //     logger.warning("Failed to deactivate audio session: \(error.localizedDescription)")
        // }

        logger.notice("🎙️ Listening stopped and cleaned up.")
    }


    // --- Silence Detection ---
    private func resetSilenceTimer() {
        silenceTimer?.fireDate = Date(timeIntervalSinceNow: silenceThreshold)
    }

    private func startSilenceTimer() {
        invalidateSilenceTimer()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isListening else { return }
                self.logger.notice("⏳ Silence detected. Processing...")
                self.stopListeningAndProcess() // Process current transcription
            }
        }
    }

    private func invalidateSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }


    // --- Mic Level Calculation & Timer ---
    private func calculatePowerLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -160.0 } // Return very low on error
        let channelDataValue = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
        let rms = sqrt(channelDataValue.reduce(0.0) { $0 + ($1 * $1) } / Float(buffer.frameLength))
        let db = 20 * log10(rms)
        return (db.isFinite && !db.isNaN) ? max(-50.0, min(db, 0.0)) : -50.0 // Clamp between -50 and 0 dBFS
    }

    private func startAudioLevelTimer() {
        invalidateAudioLevelTimer()
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: audioLevelUpdateRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                 if self.isListening { // Only update published value if listening
                     self.listeningAudioLevel = self.lastMeasuredAudioLevel
                 } else {
                     self.invalidateAudioLevelTimer() // Stop timer if not listening
                 }
            }
        }
    }

    private func invalidateAudioLevelTimer() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }

    
    // --- LLM Interaction ---
    // Renamed to reflect it handles the entire streaming process including TTS trigger
    func fetchLLMResponseStreaming() async {
        // Reset state for the new response stream
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            self.llmResponseBuffer = ""
            self.processedTextIndex = 0
            self.isLLMFinished = false
            self.hasReceivedFirstLLMChunk = false
            // Don't cancel TTS here - let existing TTS finish naturally if desired,
            // or rely on user cancellation. If overlap is bad, cancel here.
            // self.cancelOngoingTasks() // Uncomment for aggressive cancellation
        }
        
        var fullResponseAccumulator = ""
        var llmError: Error? = nil
        let providerString = String(describing: selectedProvider)
        
        do {
            try Task.checkCancellation()
            
            let stream: AsyncThrowingStream<String, Error>
            switch selectedProvider {
            case .gemini:
                guard let apiKey = self.geminiAPIKey else { throw LlmError.apiKeyMissing(provider: "Gemini") }
                stream = try await fetchGeminiStream(apiKey: apiKey)
            case .claude:
                guard let apiKey = self.anthropicAPIKey else { throw LlmError.apiKeyMissing(provider: "Claude") }
                stream = try await fetchClaudeStream(apiKey: apiKey)
            }
            
            // Process the stream
            for try await chunk in stream {
                try Task.checkCancellation()
                fullResponseAccumulator += chunk
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if !self.hasReceivedFirstLLMChunk {
                        logger.info("🤖 Received first LLM chunk (\(providerString)).")
                        self.hasReceivedFirstLLMChunk = true
                        // Start TTS flow immediately upon receiving the first chunk
                        self.manageTTSFlow()
                    }
                    self.llmResponseBuffer.append(chunk)
                    // Subsequent chunks might trigger TTS via manageTTSFlow if needed (e.g., if TTS becomes idle)
                    // Or more likely, the playback start trigger will handle subsequent chunks.
                    self.manageTTSFlow() // Call to check if initial TTS can start
                }
            }
            // LLM Stream finished successfully
            logger.info("🤖 LLM stream finished (\(providerString)). Total chars: \(fullResponseAccumulator.count)")
            
        } catch is CancellationError {
            logger.notice("⏹️ LLM Task Cancelled.")
            llmError = CancellationError()
            // Don't stop TTS here necessarily, let it finish speaking buffered audio.
        } catch let error as LlmError {
             logger.error("🚨 LLM Error (\(providerString)): \(error.localizedDescription)")
             llmError = error
        } catch {
            logger.error("🚨 Unknown LLM Error (\(providerString)): \(error.localizedDescription)")
                llmError = error
        }
        
        // --- Final State Update After LLM Stream Ends or Errors ---
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            
            self.isLLMFinished = true // Mark LLM as done
            self.isProcessing = false // No longer waiting for LLM specifically

            // Add final message to chat history
            if !fullResponseAccumulator.isEmpty {
                let messageRole = (llmError == nil) ? "assistant" : "assistant_error" // Simplified role
                let assistantMessage = ChatMessage(role: messageRole, content: fullResponseAccumulator)
                // Avoid duplicates if cancellation happened after full response
                if self.messages.last?.content != assistantMessage.content {
                    self.messages.append(assistantMessage)
                }
            } else if llmError != nil && !(llmError is CancellationError) {
                // Add generic error message if LLM failed and produced no output
                let errorMessage = ChatMessage(role: "assistant_error", content: "Sorry, I encountered an error.")
                 if self.messages.last?.role != "assistant_error" { // Avoid duplicate errors
                self.messages.append(errorMessage)
                 }
            }

            // Crucially, call manageTTSFlow again. This allows it to process the *final* chunk
            // if TTS is idle or when the current chunk finishes.
            self.manageTTSFlow()

            // Check if TTS needs explicit stopping if LLM errored badly
            if llmError != nil && !(llmError is CancellationError) {
                 logger.warning("LLM errored, ensuring TTS cleanup.")
                 // Consider stopping TTS forcefully on LLM error?
                 // self.cancelOngoingTasks() // Or let buffered audio finish? Current approach lets it finish.
            }

            // Log the final accumulated response for debugging
            if llmError == nil {
                 print("--- LLM FINAL RESPONSE (\(providerString)) ---")
                 print(fullResponseAccumulator)
                 print("--------------------------")
            }

            self.llmTask = nil // Clear the task reference
        }
    }

    // --- LLM API Specific Stream Fetchers ---
    private func fetchGeminiStream(apiKey: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(geminiModel):streamGenerateContent?key=\(apiKey)&alt=sse") else {
            throw LlmError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Construct conversation history (including system prompt if applicable)
        var conversationHistory: [GeminiContent] = []
        if let sysPrompt = self.systemPrompt, !sysPrompt.isEmpty {
            // Gemini prefers system instructions within the first user message turn
            let initialUserMessage = "\(sysPrompt)\n\nUser: \(messages.last?.content ?? "")" // Combine prompt and last user message
            let historyExcludingLast = messages.dropLast().map { GeminiContent(role: $0.role == "user" ? "user" : "model", parts: [GeminiPart(text: $0.content)]) }
            conversationHistory.append(contentsOf: historyExcludingLast)
            conversationHistory.append(GeminiContent(role: "user", parts: [GeminiPart(text: initialUserMessage)]))
        } else {
            // Standard history mapping
            conversationHistory = messages.map { GeminiContent(role: $0.role == "user" ? "user" : "model", parts: [GeminiPart(text: $0.content)]) }
        }

        let payload = GeminiRequest(contents: conversationHistory)
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }
        
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
             // Limit reading error body size
             let maxErrorBodyLength = 1024
             var count = 0
             for try await byte in bytes {
                 if count < maxErrorBodyLength { errorBody += String(UnicodeScalar(byte)) }
                 count += 1
             }
            logger.error("Gemini Error Response (\(httpResponse.statusCode)): \(errorBody)")
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
                                logger.warning("Gemini JSON decoding error for line: \(line). Error: \(error)")
                                // Decide whether to continue or fail the stream
                            }
                        }
                    }
                } catch { streamError = error }
                continuation.finish(throwing: streamError)
            }
        }
    }
    
    private func fetchClaudeStream(apiKey: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LlmError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version") // Keep version unless API requires update
        
        let history = messages.map { MessageParam(role: $0.role, content: $0.content) }
        let systemPromptToUse = (self.systemPrompt?.isEmpty ?? true) ? nil : self.systemPrompt

        let payload = ClaudeRequest(
            model: claudeModel,
            system: systemPromptToUse,
            messages: history,
            stream: true,
            max_tokens: 8000, // Adjust as needed
            temperature: 1.0 // Adjust for desired creativity/factuality
        )
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw LlmError.requestEncodingError(error)
        }
        
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
             let maxErrorBodyLength = 1024
             var count = 0
             for try await byte in bytes {
                 if count < maxErrorBodyLength { errorBody += String(UnicodeScalar(byte)) }
                 count += 1
             }
            logger.error("Claude Error Response (\(httpResponse.statusCode)): \(errorBody)")
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
                                if event.type == "content_block_delta" {
                                    if let text = event.delta?.text {
                                        continuation.yield(text)
                                    }
                                } else if event.type == "message_stop" {
                                     // Optional: Log token usage from message_stop event
                                     if let usage = event.message?.usage {
                                         logger.info("Claude usage: Input \(usage.input_tokens), Output \(usage.output_tokens)")
                                }
                                }
                            } catch {
                                logger.warning("Claude JSON decoding error for line: \(line). Error: \(error)")
                            }
                        }
                    }
                } catch { streamError = error }
                continuation.finish(throwing: streamError)
            }
        }
    }
    
    // --- LlmError Enum ---
    enum LlmError: Error, LocalizedError {
        case apiKeyMissing(provider: String)
        case invalidURL
        case requestEncodingError(Error)
        case networkError(Error)
        case invalidResponse(statusCode: Int, body: String?)
        case responseDecodingError(Error)
        case streamingError(String) // Generic streaming issue
        case ttsError(String)      // Specific TTS issue

        var errorDescription: String? {
            switch self {
            case .apiKeyMissing(let provider): return "\(provider) API Key is missing."
            case .invalidURL: return "Invalid API endpoint URL."
            case .requestEncodingError(let error): return "Failed to encode request: \(error.localizedDescription)"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .invalidResponse(let statusCode, let body): return "Invalid response: Status \(statusCode). Body: \(body ?? "N/A")"
            case .responseDecodingError(let error): return "Failed to decode response: \(error.localizedDescription)"
            case .streamingError(let message): return "Streaming error: \(message)"
            case .ttsError(let message): return "TTS error: \(message)"
            }
        }
    }


    // --- TTS Flow Management (NEW STRATEGY) ---

    // Central function to manage starting/continuing the TTS stream
    @MainActor
    private func manageTTSFlow() {
        // logger.debug("manageTTSFlow called. isSpeaking: \(isSpeaking), task active: \(ttsFetchAndBufferTask != nil), isFetchingNext: \(isFetchingNextChunk)")

        // Condition to start the *very first* chunk fetch
        if !isSpeaking && ttsFetchAndBufferTask == nil {
            let (chunk, nextIndex) = findNextTTSChunk()
            if !chunk.isEmpty {
                logger.info("▶️ Starting TTS fetch for initial chunk (len: \(chunk.count)).")
                processedTextIndex = nextIndex
                fetchTriggeredByPlaybackStart = false // Reset trigger flag for the new chunk
                // Start the main task that handles fetching N and triggering N+1
                ttsFetchAndBufferTask = Task {
                    await fetchAndBufferChunk_Managed(text: chunk, isInitialChunk: true)
                }
            }
        }
        // If already speaking or fetching, the flow is driven by playback start triggers
        // or the completion of the fetch task.
    }

    // Task function that fetches a chunk and manages the lookahead fetch trigger
    private func fetchAndBufferChunk_Managed(text: String, isInitialChunk: Bool) async {
        do {
            // logger.debug("Task started: fetchAndBufferChunk_Managed for text len \(text.count)")
            // The actual fetching and buffering logic
            try await fetchAndBufferOpenAITTSStream(apiKey: openaiAPIKey!, text: text, speed: ttsRate)

            // --- Fetch Completion Logic ---
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                 logger.debug("✅ Fetch/Buffer completed for chunk ending at index \(self.processedTextIndex)")

                // If this task was the main one (not the lookahead), clear it.
                // The lookahead logic is handled internally now.
                 if self.ttsFetchAndBufferTask != nil { // Check if it's the currently assigned task
                    // What happens now depends on whether the LLM is finished and buffers are empty
                    if self.isLLMFinished && self._pendingAudioBuffers.isEmpty && !self.ttsAudioPlayerNode.isPlaying {
                        logger.info("TTS fetch task finished, LLM done, buffer empty. Cleaning up.")
                        self.playbackDidFinish() // Transition to final state
                         self.ttsFetchAndBufferTask = nil // Clear task *after* cleanup check
                    } else {
                         // logger.debug("TTS fetch task finished, but more work pending (LLM active or buffers remain).")
                         // Task completion doesn't immediately mean stopping everything.
                         // Clear the task reference so a new one can potentially start if needed later.
                         self.ttsFetchAndBufferTask = nil
                         // Call manageTTSFlow again? Maybe not, let playback completion drive it.
                    }
                 }
            }

        } catch is CancellationError {
             await MainActor.run { [weak self] in
                self?.logger.notice("⏹️ TTS Fetch/Buffer task cancelled.")
                 // Task cancellation should lead to full stop/reset handled by cancelOngoingTasks
                 self?.stopAndResetTTSEngine()
            }
        } catch {
             await MainActor.run { [weak self] in
                self?.logger.error("🚨 TTS Fetch/Buffer task failed: \(error.localizedDescription)")
                 // Stop TTS on error
                 self?.stopAndResetTTSEngine()
                // Optionally add chat message about TTS failure
            }
        }
    }


    // Fetches and buffers audio, signaling playback start potential
    private func fetchAndBufferOpenAITTSStream(apiKey: String, text: String, speed: Float) async throws {
         guard let apiKey = self.openaiAPIKey, !apiKey.isEmpty, apiKey != "YOUR_OPENAI_API_KEY" else {
             throw LlmError.apiKeyMissing(provider: "OpenAI")
         }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LlmError.ttsError("Cannot synthesize empty text")
        }
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw LlmError.invalidURL
        }
        guard let format = self.ttsAudioFormat else { // Use the class property
             logger.error("🚨 Cannot fetch TTS stream: Expected audio format is nil.")
             throw LlmError.ttsError("Internal audio format configuration error.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Clamp speed for OpenAI API (0.25x to 4.0x)
        // Map our internal 0.0-1.0 slider range to OpenAI's range
        let minOpenAISpeed: Float = 0.25
        let maxOpenAISpeed: Float = 4.0
        let clampedInternalSpeed = max(0.0, min(speed, 1.0)) // Ensure 0-1 range
        // Linear mapping: speed 0.0 -> 0.25x, speed 1.0 -> 4.0x
        let mappedOpenAISpeed = minOpenAISpeed + (maxOpenAISpeed - minOpenAISpeed) * clampedInternalSpeed

        let payload = OpenAITTSRequest(
            model: openAITTSModel,
            input: text,
            voice: openAITTSVoice,
            response_format: openAITTSFormat, // Expecting WAV (Int16 source)
            speed: mappedOpenAISpeed
        )
        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LlmError.requestEncodingError(error) }

        logger.debug("🚀 Starting TTS stream request (Chunk len: \(text.count), Speed: \(mappedOpenAISpeed)x)...")

        // Prepare engine BEFORE making the request
        await MainActor.run { [weak self] in self?.prepareTTSEngine() }
            guard self.isTTSEnginePrepared else {
            throw LlmError.ttsError("Audio engine failed to prepare.")
        }

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            let maxErrorBytes = 1024; var count = 0
            for try await byte in bytes { if count < maxErrorBytes { errorBody += String(UnicodeScalar(byte)); count += 1 } else { break } }
            logger.error("🚨 OpenAI TTS Error: Status \(httpResponse.statusCode). Body: \(errorBody)...")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody)
        }

        // --- Byte Processing and Buffering ---
        var audioDataBuffer = Data()
        let headerSize = 44 // Standard WAV header size to skip
        var bytesProcessed = 0
        let sourceBytesPerFrame = 2 // Int16 mono source
        let framesPerBuffer = self.expectedFrameCountPerBuffer
        let sourceBytesNeededForBuffer = Int(framesPerBuffer) * sourceBytesPerFrame

        guard sourceBytesNeededForBuffer > 0 else {
            throw LlmError.ttsError("Internal audio buffer calculation error (bytes needed is zero).")
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            bytesProcessed += 1
            guard bytesProcessed > headerSize else { continue } // Skip header

            audioDataBuffer.append(byte)

            // Process full buffers
            while audioDataBuffer.count >= sourceBytesNeededForBuffer {
                try Task.checkCancellation()
                let dataChunk = audioDataBuffer.prefix(sourceBytesNeededForBuffer)
                audioDataBuffer.removeFirst(sourceBytesNeededForBuffer)

                guard let pcmBuffer = createPCMBuffer(format: format, frameCount: framesPerBuffer, data: dataChunk) else {
                    logger.warning("Failed to create PCM buffer from \(dataChunk.count) bytes. Skipping chunk.")
                    continue
                }
                // Schedule buffer asynchronously on MainActor
                scheduleBufferAsync(pcmBuffer)
            }
        }

        // --- Stream Finished ---
        logger.debug("✅ TTS network stream finished fetching chunk.")

        // Process remaining partial buffer
             let remainingSourceBytes = audioDataBuffer.count
        if remainingSourceBytes > 0 {
             let remainingFrames = AVAudioFrameCount(remainingSourceBytes / sourceBytesPerFrame)
             logger.debug("Processing \(remainingSourceBytes) remaining bytes (\(remainingFrames) frames)...")
            if remainingFrames > 0 {
                 if let pcmBuffer = createPCMBuffer(format: format, frameCount: remainingFrames, data: audioDataBuffer) {
                     scheduleBufferAsync(pcmBuffer)
                 } else {
                     logger.warning("Failed to create final partial PCM buffer.")
                 }
            }
        }

        // Fetching is complete. Buffering might still be happening via scheduleBufferAsync.
        // The calling task (fetchAndBufferChunk_Managed) handles completion logic now.
    }

    // Helper to schedule buffer and trigger scheduling check (Runs on MainActor)
    @MainActor
    private func scheduleBufferAsync(_ buffer: AVAudioPCMBuffer) {
        self._pendingAudioBuffers.append(buffer)
        self.trySchedulingPendingBuffers() // Check if player can take buffers now
    }

    // Try to schedule buffers from the queue and manage playback start trigger
    @MainActor
    private func trySchedulingPendingBuffers() {
        guard ttsAudioEngine.isRunning && isTTSEnginePrepared else {
            // logger.warning("Engine not ready, cannot schedule buffers.") // Too noisy
            return
        }

        // Schedule available buffers
        while !_pendingAudioBuffers.isEmpty {
            // Check if player node is still attached
            guard ttsAudioPlayerNode.engine != nil else {
                logger.warning("Player node detached, cannot schedule buffer.")
                _pendingAudioBuffers.removeAll() // Clear queue if node is gone
                stopAndResetTTSEngine() // Reset state if node detached unexpectedly
                return
            }

            let bufferToSchedule = _pendingAudioBuffers.removeFirst()
            scheduledBufferCount += 1
            // logger.debug("Scheduling buffer \(scheduledBufferCount)... Pending: \(_pendingAudioBuffers.count)")

            ttsAudioPlayerNode.scheduleBuffer(bufferToSchedule) { [weak self] in
                // Completion handler runs on background thread
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.completedBufferCount += 1
                    // logger.debug("Buffer \(self.completedBufferCount)/\(self.scheduledBufferCount) completed playing.")

                    // Check if playback naturally finished
                    self.checkPlaybackCompletion()
                }
            }
        } // End while loop

        // --- Playback Start Logic ---
        // Check if player should START playing (only if not already playing and threshold met)
        if !ttsAudioPlayerNode.isPlaying && scheduledBufferCount >= preBufferCountThreshold {
            // Double-check engine/node state right before playing
            guard ttsAudioEngine.isRunning && ttsAudioPlayerNode.engine != nil else {
                logger.warning("Engine stopped or node detached before playback could start.")
                return
            }

            logger.info("▶️ Starting TTS playback node (scheduled \(self.scheduledBufferCount) >= threshold \(self.preBufferCountThreshold)).")
            ttsAudioPlayerNode.play()
            if !self.isSpeaking { self.isSpeaking = true }
            self.startTTSLevelTimer() // Start level monitoring

            // --- *** THE CRITICAL TRIGGER *** ---
            // Trigger the fetch for the NEXT chunk precisely when playback starts
            if !fetchTriggeredByPlaybackStart {
                 logger.debug("Playback started, triggering lookahead fetch.")
                 self.triggerLookaheadFetch()
                 fetchTriggeredByPlaybackStart = true // Prevent re-triggering for this logical chunk
            }
        }
    }

    // Trigger the fetch for the next chunk (N+1)
    @MainActor
    private func triggerLookaheadFetch() {
        guard ttsFetchAndBufferTask == nil else {
             // This case should ideally not happen if logic is correct,
             // means we tried to trigger N+1 while N was still fetching/buffering.
             logger.warning("triggerLookaheadFetch called but a fetch task is already active.")
             return
        }

        let (nextChunk, nextIndex) = findNextTTSChunk() // Find chunk *after* the one last initiated
        if !nextChunk.isEmpty {
            logger.info("🔭 Triggering lookahead TTS fetch (Chunk len: \(nextChunk.count)).")
            processedTextIndex = nextIndex // Update index to mark this chunk as initiated
            fetchTriggeredByPlaybackStart = false // Reset trigger flag for the *next* chunk start

            // Start the fetch task for N+1. This task runs independently.
            ttsFetchAndBufferTask = Task {
                 await fetchAndBufferChunk_Managed(text: nextChunk, isInitialChunk: false)
                        }
                    } else {
            // logger.debug("Lookahead fetch triggered, but no further text chunk available yet.")
            // If LLM is finished, this is expected. If not, we wait for more text.
        }
    }


    // Check if playback has fully completed
    @MainActor
    private func checkPlaybackCompletion() {
        // Conditions for full completion:
        // 1. LLM stream has finished delivering text.
        // 2. All buffers ever scheduled have completed playback.
        // 3. There are no more buffers waiting in the pending queue.
        // 4. The player node is currently not playing (it stops automatically when buffer queue is empty).
        if isLLMFinished &&
           completedBufferCount >= scheduledBufferCount && // Ensure all scheduled are played
           _pendingAudioBuffers.isEmpty &&
           !ttsAudioPlayerNode.isPlaying &&
           isSpeaking // Check isSpeaking to prevent multiple calls
        {
            logger.info("🏁 Playback appears to have fully completed.")
            playbackDidFinish()
        }
    }

    // Cleanup after all TTS playback is confirmed finished
    @MainActor
    private func playbackDidFinish() {
        logger.debug("playbackDidFinish: Cleaning up TTS engine and state.")
        stopAndResetTTSEngine() // Full reset

        // Reset any related flags
        isSpeaking = false // Explicitly set state
        llmResponseBuffer = "" // Clear buffer after successful playback
        processedTextIndex = 0

        // Decide next action (e.g., return to listening)
        autoStartListeningAfterDelay()
    }


    // Finds the next chunk of text suitable for TTS
    private func findNextTTSChunk() -> (String, Int) {
        // Use the current full buffer and the index of the end of the last *initiated* chunk
        let text = llmResponseBuffer
        let startIndex = processedTextIndex
        let isComplete = isLLMFinished

        // logger.debug("findNextTTSChunk called. startIndex: \(startIndex), textLen: \(text.count), isComplete: \(isComplete)")

        // Calculate remaining text based on the last initiated fetch index
        guard startIndex < text.count else { return ("", startIndex) } // No new text
        let remainingText = String(text.suffix(from: text.index(text.startIndex, offsetBy: startIndex)))

        if remainingText.isEmpty { return ("", startIndex) }

        // --- DYNAMIC MIN CHUNK LENGTH CALCULATION ---
        let currentSpeedMultiplier = self.ttsDisplayMultiplier // Speed multiplier (0.25x to 4.0x)
        let dynamicMinChunkLength = currentSpeedMultiplier > 1.0 ? Int(baseMinTTSChunkLength * Double(currentSpeedMultiplier)) : Int(baseMinTTSChunkLength)
        // logger.debug("Dynamic min chunk length: \(dynamicMinChunkLength) chars for speed \(String(format: "%.2f", currentSpeedMultiplier))x")
        // --- END DYNAMIC CALCULATION ---

        let potentialChunkMaxLength = min(remainingText.count, maxTTSChunkLength)
        let potentialChunk = String(remainingText.prefix(potentialChunkMaxLength))

        // Find the best split point (sentence end > comma > max length)
        var bestSplitIndex = potentialChunk.endIndex // Default to end if no better split found
        var splitFound = false

        // Prefer sentence endings, search backwards
        if let lastSentenceEnd = potentialChunk.lastIndex(where: { ".!?".contains($0) }) {
            // Check if it's reasonably close to the end or if the chunk is short anyway
            let distanceToEnd = potentialChunk.distance(from: lastSentenceEnd, to: potentialChunk.endIndex)
            if distanceToEnd < 150 || potentialChunk.count < 250 { // Heuristics
                bestSplitIndex = potentialChunk.index(after: lastSentenceEnd)
                splitFound = true
                // logger.debug("Found sentence split at relative index \(potentialChunk.distance(from: potentialChunk.startIndex, to: bestSplitIndex))")
            }
        }

        // If no sentence split, try comma
        if !splitFound, let lastComma = potentialChunk.lastIndex(where: { ",".contains($0) }) {
            let distanceToEnd = potentialChunk.distance(from: lastComma, to: potentialChunk.endIndex)
            if distanceToEnd < 100 || potentialChunk.count < 150 { // Stricter heuristics for comma
                bestSplitIndex = potentialChunk.index(after: lastComma)
                splitFound = true
                 // logger.debug("Found comma split at relative index \(potentialChunk.distance(from: potentialChunk.startIndex, to: bestSplitIndex))")
            }
        }

        let finalChunk = String(potentialChunk[..<bestSplitIndex])
        let finalChunkLength = finalChunk.count

        // Minimum length check using the DYNAMIC minimum length
        // Avoid sending tiny fragments unless it's the very end or more text is available
        if finalChunkLength < dynamicMinChunkLength && !isComplete && potentialChunk.count == remainingText.count {
             // logger.debug("Chunk too short (\(finalChunkLength) < \(dynamicMinChunkLength)) and not final. Waiting.")
             return ("", startIndex) // Wait for more text if it's short and more might come
        }

        let nextOverallIndex = startIndex + finalChunkLength
        // logger.debug("Found chunk: len=\(finalChunkLength), nextIndex=\(nextOverallIndex)")
        return (finalChunk, nextOverallIndex)
    }


    // --- TTS Audio Buffer Creation ---
    private func createPCMBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount, data: Data) -> AVAudioPCMBuffer? {
        guard frameCount > 0, !data.isEmpty else {
             logger.warning("Attempted to create PCM buffer with zero frameCount (\(frameCount)) or empty data (\(data.count)).")
            return nil
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            logger.error("🚨 Failed to create AVAudioPCMBuffer (format: \(format), capacity: \(frameCount))")
            return nil
        }
        pcmBuffer.frameLength = frameCount // Set actual length

        // Assuming format is Float32, non-interleaved (as per expectedTTSAudioFormat)
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            logger.error("🚨 Unsupported buffer format for creation: \(format)")
            return nil
        }
        guard let destChannelPtrs = pcmBuffer.floatChannelData else {
            logger.error("🚨 Failed to get floatChannelData for buffer.")
            return nil
        }

        let channelCount = Int(format.channelCount)
        let sourceBytesPerSample = 2 // Assuming Int16 source from WAV
        let expectedSourceBytes = Int(frameCount) * channelCount * sourceBytesPerSample

        // --- Data Validation ---
        guard data.count >= expectedSourceBytes else {
             logger.error("🚨 Insufficient data for createPCMBuffer: Got \(data.count) bytes, needed \(expectedSourceBytes) for \(frameCount) frames.")
             // Set buffer to zero? Or just return nil? Returning nil is safer.
             return nil
        }
        // If extra data, log warning but proceed with needed amount
         if data.count > expectedSourceBytes {
             logger.warning("Extra data provided to createPCMBuffer: Got \(data.count), using \(expectedSourceBytes).")
         }

        let scale = Float(Int16.max) // For Int16 to Float32 conversion

        data.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else {
                logger.error("🚨 Failed to get base address of source data.")
                // Need to handle this - maybe zero out buffer? For now, log and return potentially corrupt buffer.
                return
            }
            let sourcePtr = baseAddress.assumingMemoryBound(to: Int16.self)

            for channel in 0..<channelCount {
                let destPtr = destChannelPtrs[channel]
                if channelCount == 1 { // Mono
                    for frame in 0..<Int(frameCount) {
                        let intSample = sourcePtr[frame]
                        destPtr[frame] = Float(intSample) / scale
                    }
                } else { // Stereo or multi-channel (de-interleave)
                    var sourceIndex = channel
                    for frame in 0..<Int(frameCount) {
                        let intSample = sourcePtr[sourceIndex]
                        destPtr[frame] = Float(intSample) / scale
                        sourceIndex += channelCount
                    }
                }
            }
        }
        return pcmBuffer
    }


    // --- TTS Level Visualization ---
    func startTTSLevelTimer() {
        guard ttsLevelTimer == nil else { return } // Avoid multiple timers
        // Timer is mainly needed if tap block doesn't fire frequently enough or stops
        ttsLevelTimer = Timer.scheduledTimer(withTimeInterval: ttsLevelUpdateRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // If player stops but tap didn't catch it, reset level here
                guard let self = self else { return }
                if !self.ttsAudioPlayerNode.isPlaying && self.ttsOutputLevel != 0.0 {
                    // logger.debug("TTS Level timer resetting level as player stopped.")
                    self.ttsOutputLevel = 0.0
                    self.invalidateTTSLevelTimer() // Stop timer once level is zeroed
                }
            }
        }
        // logger.debug("TTS Level Timer started.")
    }
    
    func invalidateTTSLevelTimer() {
        if ttsLevelTimer != nil {
            ttsLevelTimer?.invalidate()
            ttsLevelTimer = nil
            // logger.debug("TTS Level Timer invalidated.")
        }
    }

    @MainActor private func updateTTSLevel(buffer: AVAudioPCMBuffer) {
        guard ttsAudioPlayerNode.isPlaying else {
            if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
            return
        }
        guard buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved else { return } // Only process expected format
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let frameLength = buffer.frameLength
        guard frameLength > 0 else { return }

        let channelPtr = UnsafeBufferPointer(start: channelData, count: Int(frameLength))
        let sumOfSquares = channelPtr.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(sumOfSquares / Float(frameLength))

        // Convert RMS to dBFS, normalize 0-1, apply curve and smoothing
        let dbValue = (rms > 0) ? (20 * log10(rms)) : -160.0
        let minDBFS: Float = -50.0
        let maxDBFS: Float = 0.0
        var normalizedLevel: Float = 0.0
        if dbValue > minDBFS {
            normalizedLevel = (max(minDBFS, min(dbValue, maxDBFS)) - minDBFS) / (maxDBFS - minDBFS)
        }

        let exponent: Float = 1.5 // Curve for visual effect
        let curvedLevel = pow(normalizedLevel, exponent)
        let finalLevel = max(0.0, min(curvedLevel, 1.0)) // Clamp 0-1

        let smoothingFactor: Float = 0.2 // Temporal smoothing
        let smoothedLevel = self.ttsOutputLevel * (1.0 - smoothingFactor) + finalLevel * smoothingFactor

        // Update published value only if changed significantly or zeroing out
        if abs(self.ttsOutputLevel - smoothedLevel) > 0.01 || (smoothedLevel == 0 && self.ttsOutputLevel != 0) {
            self.ttsOutputLevel = smoothedLevel
        }
    }
    
    // --- TTS Speed Calculation ---
    var ttsDisplayMultiplier: Float {
        // Linear map from slider [0, 1] to speed [0.25, 4.0] for display
        let minDisplay: Float = 0.25
        let maxDisplay: Float = 4.0
        let rate = max(0.0, min(ttsRate, 1.0)) // Clamp slider value 0-1
        return minDisplay + (maxDisplay - minDisplay) * rate
    }


    // --- Speech Recognizer Delegate ---
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !available {
                self.logger.error("🚨 Speech recognizer became unavailable.")
                // If listening, stop and show error?
                if self.isListening {
                    self.stopListeningCleanup()
                    // Optionally show an error message to the user
                }
        } else {
                self.logger.info("Speech recognizer is available.")
            }
        }
    }

    // --- Auto-Restart Listening ---
    func autoStartListeningAfterDelay() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Check state: not speaking, not processing LLM, not already listening, engine stopped
            guard !self.isSpeaking && !self.isProcessing && !self.isListening && !self.ttsAudioEngine.isRunning else {
                 logger.debug("Auto-start listening aborted: Invalid state.")
                 return
            }

            logger.info("🎙️ TTS idle. Will switch to listening after delay...")
            do {
                try await Task.sleep(for: .milliseconds(50)) // 250ms delay

                // Re-check state *after* delay, before starting
                guard !self.isSpeaking && !self.isProcessing && !self.isListening && !self.ttsAudioEngine.isRunning else {
                    logger.warning("🎤 Auto-start aborted: State changed during delay.")
                    return
                }
                self.startListening()

            } catch {
                 logger.info("Auto-start listening delay cancelled.")
            }
        }
    }
    
    // --- Lifecycle Handlers ---
    @objc private func handleDidEnterBackground() {
        Task { @MainActor [weak self] in
            self?.logger.notice("App entered background. Cleaning up...")
            self?.cancelOngoingTasks() // Cancel LLM, TTS fetches
            self?.stopListeningCleanup() // Ensure mic is off
            // stopAndResetTTSEngine is called within cancelOngoingTasks
        }
    }
    
    @objc private func handleWillEnterForeground() {
        Task { @MainActor [weak self] in
            self?.logger.notice("App will enter foreground.")
            // Re-request permissions if needed, or prepare engines.
            // Currently, preparation happens on demand.
        }
    }

    // --- Cleanup on View Disappear ---
    func cleanupOnDisappear() {
        logger.info("View disappeared. Cleaning up...")
        cancelOngoingTasks()
        stopListeningCleanup()
    }

    deinit {
        logger.notice("ChatViewModel deinit.")
        // Stop timers, engines, cancel tasks if not already done
        // Wrap timer invalidations in Task to ensure main actor execution if needed
        Task { @MainActor [weak self] in
            self?.invalidateAudioLevelTimer()
            self?.invalidateSilenceTimer()
            self?.invalidateTTSLevelTimer()
        }
        if inputAudioEngine.isRunning { inputAudioEngine.stop() }
        if ttsAudioEngine.isRunning { ttsAudioEngine.stop() }
        llmTask?.cancel()
        ttsFetchAndBufferTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

// --- SwiftUI View ---
struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    
    var body: some View {
        VStack(spacing: 0) { // Reduce spacing
            // --- Top Section (Optional: Chat History Display) ---
            // ScrollView {
            //     VStack(alignment: .leading) {
            //         ForEach(viewModel.messages) { message in
            //             Text("\(message.role): \(message.content)")
            //                 .padding(.horizontal)
            //                 .foregroundColor(message.role == "user" ? .blue : .green)
            //         }
            //     }
            // }
            // Spacer() // Pushes indicator down

            // --- Center: Voice Indicator ---
            VoiceIndicatorView(
                isListening: $viewModel.isListening,
                isProcessing: $viewModel.isProcessing, // Use LLM processing state
                isSpeaking: $viewModel.isSpeaking, // Use TTS playback state
                audioLevel: $viewModel.listeningAudioLevel,
                ttsLevel: $viewModel.ttsOutputLevel
            )
            .frame(height: 250) // Give it ample space
            .onTapGesture {
                viewModel.cycleState() // Use the cycle state function
                }
            .padding(.vertical, 40) // Add padding around indicator
            
            // --- Bottom Section: Controls ---
            VStack {
            HStack {
                Text("Speed:")
                        .font(.caption)
                        .foregroundColor(.gray)
                Slider(value: $viewModel.ttsRate, in: 0.0...1.0, step: 0.05)
                        .tint(.white) // Color the slider track/thumb
                    Text(String(format: "%.2fx", viewModel.ttsDisplayMultiplier))
                        .font(.caption)
                    .foregroundColor(.white)
                        .frame(width: 45, alignment: .leading) // Ensure space for "4.00x"
                }
                .padding(.horizontal)
                .padding(.bottom, 20) // Add padding below slider

                // Optional: Add provider picker
                // Picker("LLM", selection: $viewModel.selectedProvider) {
                //     Text("Claude").tag(ChatViewModel.LLMProvider.claude)
                //     Text("Gemini").tag(ChatViewModel.LLMProvider.gemini)
                // }
                // .pickerStyle(.segmented)
                // .padding(.horizontal)
            }
            .frame(maxWidth: .infinity) // Ensure controls take width
             .padding(.bottom, 30) // Padding from bottom edge
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.edgesIgnoringSafeArea(.all))
        .onAppear {
            viewModel.logger.info("ContentView appeared.")
            // Request permissions on appear if not already granted?
        }
        .onDisappear {
            viewModel.logger.info("ContentView disappeared.")
            viewModel.cleanupOnDisappear()
        }
        // Handle potential errors with alerts?
        // .alert("Error", isPresented: $showErrorAlert) {
        //     Button("OK", role: .cancel) { }
        // } message: {
        //     Text(viewModel.lastError?.localizedDescription ?? "An unknown error occurred.")
        // }
    }
}


// --- Preview ---
#Preview {
    ContentView()
}
