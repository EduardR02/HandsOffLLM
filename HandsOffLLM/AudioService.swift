// AudioService.swift
import Foundation
import AVFoundation
import Speech
import OSLog
import Combine
import UIKit // Needed for AVAudioSession.routeChangeNotification userInfo keys

@MainActor
class AudioService: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVAudioPlayerDelegate {
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AudioService")
    
    // --- Published State ---
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var listeningAudioLevel: Float = -50.0 // Audio level dBFS (-50 silence, 0 max)
    @Published var ttsOutputLevel: Float = 0.0      // Normalized TTS output level (0-1)
    @Published var ttsRate: Float = 2.0 {
        didSet { updatePlayerRate() }
    }
    
    // --- Output Device State (Now updated via Notifications) ---
    enum OutputDevice: String {
        case speaker
        case bluetooth // Represents any non-speaker output selected by user
    }
    @Published var outputDevice: OutputDevice = .speaker // Default, will update on init/route change
    
    // --- Combine Subjects for Communication ---
    let transcriptionSubject = PassthroughSubject<String, Never>() // Sends final transcription
    let errorSubject = PassthroughSubject<Error, Never>()         // Reports errors
    let ttsChunkSavedSubject = PassthroughSubject<(messageID: UUID, path: String), Never>()
    
    // --- Internal State ---
    private var lastMeasuredAudioLevel: Float = -50.0
    private var currentSpokenText: String = ""
    private var hasUserStartedSpeakingThisTurn: Bool = false
    private var ttsFetchTask: Task<Void, Never>? = nil
    private var isFetchingTTS: Bool = false
    private var nextAudioData: Data? = nil
    private var currentTextToSpeakBuffer: String = ""
    private var currentTextProcessedIndex: Int = 0
    private var isTextStreamComplete: Bool = false
    
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
    
    // --- Dependencies ---
    private let settingsService: SettingsService
    private let historyService: HistoryService
    
    // MARK: - TTS Save Context
    private var currentTTSConversationID: UUID?
    private var currentTTSMessageID: UUID?
    private var currentTTSChunkIndex: Int = 0
    
    func setTTSContext(conversationID: UUID, messageID: UUID) {
        if currentTTSConversationID != conversationID || currentTTSMessageID != messageID {
            currentTTSConversationID = conversationID
            currentTTSMessageID = messageID
            currentTTSChunkIndex = 0
        }
    }
    
    // --- new: replay support ---
    private var replayQueue: [String] = []
    
    /// Start replaying a saved audio file sequence for a message
    func replayAudioFiles(_ paths: [String]) {
        logger.info("Replaying saved audio files: \(paths)")
        replayQueue = paths
        playNextReplay()
    }
    
    /// Play the next file in the replay queue
    private func playNextReplay() {
        guard !replayQueue.isEmpty else { return }
        let nextPath = replayQueue.removeFirst()
        logger.info("Playing replay file: \(nextPath)")
        playAudioFile(relativePath: nextPath)
    }
    
    /// Stop any ongoing replay and clear the queue
    func stopReplay() {
        logger.notice("Stopping replay, clearing replay queue.")
        replayQueue.removeAll()
        stopSpeaking()
    }
    
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default)
    }()
    
    // --- Notification Observer ---
    private var routeChangeObserver: Any?
    
    init(settingsService: SettingsService, historyService: HistoryService) {
        self.settingsService = settingsService
        self.historyService = historyService
        super.init()
        speechRecognizer.delegate = self
        requestPermissions()
        setupRouteChangeObserver()
        applyAudioSessionSettings() // Ensure this call remains
    }

    func applyAudioSessionSettings() {
        let session = AVAudioSession.sharedInstance()
        var sessionNeedsActivation = !session.isOtherAudioPlaying
        var categoryNeedsSetting = true

        // --- Define desired options including Bluetooth ---
        let desiredOptions: AVAudioSession.CategoryOptions = [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
        // ---

        // Check if category AND options are already correct
        if session.category == .playAndRecord && session.categoryOptions == desiredOptions {
            categoryNeedsSetting = false
            logger.debug("Routing: Category and Options already correct.")
        } else {
             logger.debug("Routing: Category or Options need setting (Current Cat: \(session.category.rawValue), Opts: \(session.categoryOptions.rawValue), Desired Opts: \(desiredOptions.rawValue)).")
        }

        do {
            // Set Category & Options only if needed
            if categoryNeedsSetting {
                // --- Use desired options here ---
                try session.setCategory(.playAndRecord, mode: .default, options: desiredOptions)
                logger.debug("Routing: Set category to .playAndRecord with options: \(desiredOptions.rawValue).")
                 // Setting the category might deactivate the session
                 sessionNeedsActivation = true
            }

            // Activate Session only if needed
            if sessionNeedsActivation {
                 try session.setActive(true, options: .notifyOthersOnDeactivation)
                 logger.debug("Routing: Audio session activated.")
            } else {
                 logger.debug("Routing: Audio session likely already active and category/options were correct.")
            }

            // Earpiece override check (remains the same logic)
            let currentOutputs = session.currentRoute.outputs
            let isUsingReceiver = currentOutputs.contains { $0.portType == .builtInReceiver }
            if isUsingReceiver {
                logger.info("Routing: Current route includes built-in receiver. Attempting override to speaker.")
                try session.overrideOutputAudioPort(.speaker)
            } else {
                logger.info("Routing: Current route is not receiver (\(currentOutputs.map { $0.portName })), no override needed.")
            }

            updateOutputDeviceState(for: session.currentRoute)

        } catch {
            logger.error("🚨 Failed to apply audio session settings or override: \(error.localizedDescription)")
            updateOutputDeviceState(for: session.currentRoute)
            errorSubject.send(AudioError.audioSessionError("Failed to set session category/active/override: \(error.localizedDescription)"))
        }
    }
    
    // MARK: - Permission Request
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if authStatus != .authorized {
                    self.logger.error("Speech recognition authorization denied.")
                    self.errorSubject.send(AudioError.permissionDenied(type: "Speech Recognition"))
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
                    self.errorSubject.send(AudioError.permissionDenied(type: "Microphone"))
                } else {
                    self.logger.info("Microphone permission granted.")
                }
            }
        }
    }
    
    enum AudioError: Error, LocalizedError {
        case permissionDenied(type: String)
        case recognizerUnavailable
        case recognitionRequestError
        case audioEngineError(String)
        case audioSessionError(String)
        case ttsFetchFailed(Error)
        case audioPlaybackError(Error)
        
        var errorDescription: String? {
            switch self {
            case .permissionDenied(let type): return "\(type) permission was denied."
            case .recognizerUnavailable: return "Speech recognizer is unavailable."
            case .recognitionRequestError: return "Could not create speech recognition request."
            case .audioEngineError(let desc): return "Audio engine error: \(desc)"
            case .audioSessionError(let desc): return "Audio session error: \(desc)"
            case .ttsFetchFailed(let error): return "TTS audio fetch failed: \(error.localizedDescription)"
            case .audioPlaybackError(let error): return "Audio playback failed: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Listening Control
    func startListening() {
        guard !isListening && !isSpeaking else {
            logger.warning("Attempted to start listening while already active (Listening: \(self.isListening), Speaking: \(self.isSpeaking)).")
            return
        }
        
        guard speechRecognizer.isAvailable else {
            logger.error("🚨 Speech recognizer is not available right now.")
            errorSubject.send(AudioError.recognizerUnavailable)
            isListening = false
            return
        }
        
        isListening = true
        isSpeaking = false
        currentSpokenText = ""
        hasUserStartedSpeakingThisTurn = false
        listeningAudioLevel = -50.0
        logger.notice("🎤 Listening started…")
        
        applyAudioSessionSettings()
        
        let inputNode = audioEngine.inputNode
        
        guard !audioEngine.isRunning else {
            logger.warning("Audio engine is already running after applying session settings. Cannot start listening again yet.")
            isListening = false
            listeningAudioLevel = -50.0
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            logger.critical("Unable to create SFSpeechAudioBufferRecognitionRequest object")
            errorSubject.send(AudioError.recognitionRequestError)
            isListening = false
            return
        }
        recognitionRequest.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.recognitionTask != nil else { return } // Task might have been cancelled
                
                var isFinal = false
                
                if let result = result {
                    self.currentSpokenText = result.bestTranscription.formattedString
                    isFinal = result.isFinal
                    
                    if !self.currentSpokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.hasUserStartedSpeakingThisTurn {
                        self.logger.info("🎤 User started speaking. Starting silence timer.")
                        self.hasUserStartedSpeakingThisTurn = true
                        self.startSilenceTimer()
                    } else if self.hasUserStartedSpeakingThisTurn {
                        // User is still speaking (or pausing), reset timer
                        self.resetSilenceTimer()
                    }
                    
                    if isFinal {
                        self.logger.info("✅ Final transcription received: '\(self.currentSpokenText)'")
                        self.invalidateSilenceTimer()
                        self.stopListeningAndSendTranscription(transcription: self.currentSpokenText)
                        // Don't return yet, wait for cleanup
                    }
                }
                
                if let error = error {
                    let nsError = error as NSError
                    // Ignore specific "No speech" errors, treat others as actual errors
                    if !(nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 1107 || nsError.code == 216)) { // Added 216
                        self.logger.warning("🚨 Recognition task error: \(error.localizedDescription)")
                        self.errorSubject.send(error) // Propagate error
                    } else {
                        // It's a no-speech or session end error, treat as silence or end.
                        self.logger.info("🎤 Recognition ended with no speech detected or session ended.")
                    }
                    self.invalidateSilenceTimer()
                    // Whether error or final result, stop listening
                    if !isFinal { // If it wasn't already marked final, clean up listening
                        self.stopListeningCleanup()
                    } else {
                        // If it was final, stopListeningAndSendTranscription already called stopListeningCleanup indirectly
                    }
                }
            }
        }
        
        do {
            let hardwareFormat = inputNode.outputFormat(forBus: 0)
            logger.debug("🎤 Input node hardware format: \(hardwareFormat)")
            
            let tapFormat = hardwareFormat
            
            logger.debug("🎤 Installing tap with format: \(tapFormat)")
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] (buffer, time) in
                guard let self = self else { return }
                if self.isListening && !self.isSpeaking {
                    self.recognitionRequest?.append(buffer)
                }
                self.lastMeasuredAudioLevel = self.calculatePowerLevel(buffer: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            startAudioLevelTimer()
            logger.info("🎤 Audio engine started successfully.")

        } catch {
            logger.error("🚨 Audio engine/tap setup error: \(error.localizedDescription)")
            errorSubject.send(AudioError.audioEngineError("Engine/Tap setup failed: \(error.localizedDescription)"))
            recognitionTask?.cancel()
            recognitionTask = nil
            //self.recognitionRequest = nil
            stopListeningCleanup()
        }
    }
    
    func stopListeningCleanup() {
        let wasListening = isListening // Check state before modification
        stopAudioEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel() // Use cancel instead of finish
        recognitionTask = nil
        recognitionRequest = nil
        invalidateSilenceTimer()
        
        if wasListening { // Only log and update state if we were actually listening
            isListening = false
            listeningAudioLevel = -50.0 // Reset level visually
            logger.notice("🎙️ Listening stopped (Cleanup).")
        }
    }
    
    func stopListeningAndSendTranscription(transcription: String?) {
        // 1. Get the final text
        let textToSend = transcription ?? self.currentSpokenText
        
        // 2. Perform cleanup (stops engine, cancels tasks, sets isListening = false)
        stopListeningCleanup()
        
        // 3. Send the transcription if it's not empty
        let trimmedText = textToSend.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            logger.info("🎤 Sending final transcription to ViewModel: '\(trimmedText)'")
            transcriptionSubject.send(trimmedText)
        } else {
            logger.info("🎤 No speech detected or transcription empty, not sending.")
            // Notify ViewModel or whoever is listening that listening stopped without result?
            // For now, the state change of isListening to false handles this.
        }
    }
    
    // Called by ViewModel on user tap during listening
    func resetListening() {
        logger.notice("🎙️ Listening reset requested by user.")
        stopListeningCleanup()
        currentSpokenText = ""
        // Ensure other states are consistent (stopListeningCleanup handles isListening)
        if isSpeaking { stopSpeaking() } // Also stop speaking if reset happens during overlap
        listeningAudioLevel = -50.0
    }
    
    // MARK: - Silence Detection
    private func resetSilenceTimer() {
        if let timer = silenceTimer, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: silenceThreshold)
        }
    }
    
    private func startSilenceTimer() {
        invalidateSilenceTimer()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: self.silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isListening else { return } // Only process if still listening
                self.logger.notice("⏳ Silence detected by timer. Processing...")
                self.stopListeningAndSendTranscription(transcription: self.currentSpokenText)
            }
        }
        logger.debug("Silence timer started.")
    }
    
    private func invalidateSilenceTimer() {
        if silenceTimer != nil {
            silenceTimer?.invalidate()
            silenceTimer = nil
            logger.debug("Silence timer invalidated.")
        }
    }
    
    // MARK: - Audio Engine Management
    private func stopAudioEngine() {
        // Always remove any existing tap so we never install twice
        audioEngine.inputNode.removeTap(onBus: 0)
        // Then stop the engine if it's actually running
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.reset() // Add reset after stopping
        }
        invalidateAudioLevelTimer() // Stop level updates when engine stops
        logger.info("Audio engine stopped.")
    }
    
    private func calculatePowerLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -50.0 }
        let channelDataValue = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
        var rms: Float = 0.0
        for sample in channelDataValue { rms += sample * sample }
        rms = sqrt(rms / Float(buffer.frameLength))
        let dbValue = (rms > 0) ? (20 * log10(rms)) : -160.0 // Use -160 for true silence
        let minDb: Float = -50.0
        let maxDb: Float = 0.0
        // Clamp the value to the range [-50, 0]
        return max(minDb, min(dbValue, maxDb))
    }
    
    // MARK: - Audio Level Timers
    private func startAudioLevelTimer() {
        invalidateAudioLevelTimer()
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: audioLevelUpdateRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isListening else {
                    self?.invalidateAudioLevelTimer(); return // Stop timer if not listening
                }
                // Update published property directly
                self.listeningAudioLevel = self.lastMeasuredAudioLevel
            }
        }
    }
    
    private func invalidateAudioLevelTimer() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }
    
    private func startTTSLevelTimer() {
        invalidateTTSLevelTimer()
        ttsLevelTimer = Timer.scheduledTimer(withTimeInterval: ttsLevelUpdateRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateTTSLevel() }
        }
    }
    
    private func invalidateTTSLevelTimer() {
        if ttsLevelTimer != nil {
            ttsLevelTimer?.invalidate()
            ttsLevelTimer = nil
            // Reset level only if player is truly stopped/nil
            if self.currentAudioPlayer == nil && self.ttsOutputLevel != 0.0 {
                self.ttsOutputLevel = 0.0
            }
        }
    }
    
    @MainActor private func updateTTSLevel() {
        guard let player = self.currentAudioPlayer, player.isPlaying else {
            if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
            invalidateTTSLevelTimer() // Stop timer if player stopped
            return
        }
        player.updateMeters()
        let averagePower = player.averagePower(forChannel: 0) // dBFS
        
        let minDBFS: Float = -50.0 // Visual silence threshold
        let maxDBFS: Float = 0.0   // Max level
        var normalizedLevel: Float = 0.0
        
        // Map dBFS range [-50, 0] to [0, 1] linearly
        if averagePower > minDBFS {
            let dbRange = maxDBFS - minDBFS // Should be 50
            if dbRange > 0 {
                // Clamp power to the range before normalization
                let clampedPower = max(minDBFS, min(averagePower, maxDBFS))
                normalizedLevel = (clampedPower - minDBFS) / dbRange
            }
        } // Else: normalizedLevel remains 0 if below -50 dBFS
        
        // Apply a curve for better visual perception (optional)
        let exponent: Float = 1.5 // Makes lower levels appear slightly higher
        let curvedLevel = pow(normalizedLevel, exponent)
        
        // Ensure the final level is strictly between 0 and 1
        let finalLevel = max(0.0, min(curvedLevel, 1.0))
        
        // Apply smoothing for smoother visual updates
        let smoothingFactor: Float = 0.2 // Adjust for more/less smoothing
        let smoothedLevel = self.ttsOutputLevel * (1.0 - smoothingFactor) + finalLevel * smoothingFactor
        
        // Update published property only if change is significant or resetting to zero
        if abs(self.ttsOutputLevel - smoothedLevel) > 0.01 || (smoothedLevel == 0 && self.ttsOutputLevel != 0) {
            self.ttsOutputLevel = smoothedLevel
        }
    }
    
    // MARK: - TTS Playback Control
    // Called by ViewModel to provide text chunks
    func processTTSChunk(textChunk: String, isLastChunk: Bool) {
        logger.debug("Received TTS chunk (\(textChunk.count) chars). IsLast: \(isLastChunk)")
        self.currentTextToSpeakBuffer.append(textChunk)
        self.isTextStreamComplete = isLastChunk
        manageTTSPlayback() // Trigger playback management
    }
    
    func stopSpeaking() {
        let wasSpeaking = self.isSpeaking
        
        // Cancel any ongoing TTS Fetch Task
        if let task = self.ttsFetchTask {
            task.cancel()
            self.ttsFetchTask = nil
            self.isFetchingTTS = false
            logger.info("TTS fetch task cancelled.")
        }
        
        // Stop Audio Player
        if let player = self.currentAudioPlayer {
            if player.isPlaying {
                player.stop()
            }
            self.currentAudioPlayer = nil
            logger.info("Audio player stopped.")
        }
        
        // Cleanup Timer and Audio Data Buffer
        self.invalidateTTSLevelTimer() // Also resets level if player is nil
        self.nextAudioData = nil
        
        // Reset Text Buffer State for TTS
        self.currentTextToSpeakBuffer = ""
        self.currentTextProcessedIndex = 0
        self.isTextStreamComplete = false // Reset completion flag
        
        // Update State only if it was actively speaking
        if wasSpeaking {
            self.isSpeaking = false
            // Ensure level resets visually immediately if it wasn't already done by timer invalidation
            if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
            logger.notice("⏹️ TTS interrupted/stopped by request.")
        }
    }
    
    // MARK: - TTS Playback Internal Logic
    @MainActor
    private func manageTTSPlayback() {
        guard !isFetchingTTS else {
            logger.debug("TTS Manage: Already fetching, skipping.")
            return
        }
        
        if currentAudioPlayer == nil, let dataToPlay = nextAudioData {
            logger.debug("TTS Manage: Found pre-fetched data, playing...")
            self.nextAudioData = nil // Consume the data
            playAudioData(dataToPlay)
            manageTTSPlayback()
            return
        }
        
        let unprocessedText = currentTextToSpeakBuffer.suffix(from: currentTextToSpeakBuffer.index(currentTextToSpeakBuffer.startIndex, offsetBy: currentTextProcessedIndex))
        let shouldFetchInitial = currentAudioPlayer == nil && !unprocessedText.isEmpty && nextAudioData == nil && (isTextStreamComplete || unprocessedText.count > 5)
        let shouldFetchNext = currentAudioPlayer != nil && !unprocessedText.isEmpty && nextAudioData == nil
        
        if shouldFetchInitial || shouldFetchNext {
            logger.debug("TTS Manage: Conditions met to fetch new audio.")
            let (chunk, nextIndex) = findNextTTSChunk(text: currentTextToSpeakBuffer, startIndex: currentTextProcessedIndex, isComplete: isTextStreamComplete)
            
            if chunk.isEmpty {
                logger.debug("TTS Manage: Found no suitable chunk to fetch yet.")
                if isTextStreamComplete && currentTextProcessedIndex == currentTextToSpeakBuffer.count && currentAudioPlayer == nil && nextAudioData == nil {
                    logger.info("🏁 TTS processing and playback complete.")
                    if isSpeaking { isSpeaking = false }
                    self.currentTextToSpeakBuffer = ""
                    self.currentTextProcessedIndex = 0
                    self.isTextStreamComplete = false
                }
                return // Nothing to fetch
            }
            
            logger.info("➡️ Sending chunk (\(chunk.count) chars) to TTS API...")
            self.currentTextProcessedIndex = nextIndex
            self.isFetchingTTS = true
            
            guard let apiKey = self.settingsService.openaiAPIKey, !apiKey.isEmpty, apiKey != "YOUR_OPENAI_API_KEY" else {
                logger.error("🚨 OpenAI API Key missing, cannot fetch TTS.")
                self.isFetchingTTS = false
                errorSubject.send(LlmError.apiKeyMissing(provider: "OpenAI TTS"))
                manageTTSPlayback()
                return
            }
            
            self.ttsFetchTask = Task { [weak self] in
                guard let self = self else { return }
                do {
                    let fetchedData = try await self.fetchOpenAITTSAudio(apiKey: apiKey, text: chunk, instruction: self.settingsService.activeTTSInstruction)
                    try Task.checkCancellation()
                    
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.isFetchingTTS = false
                        self.ttsFetchTask = nil
                        
                        guard let data = fetchedData, !data.isEmpty else {
                            logger.warning("TTS fetch returned no data for chunk.")
                            self.manageTTSPlayback()
                            return
                        }
                        logger.info("⬅️ Received TTS audio (\(data.count) bytes).")
                        // Save this chunk's audio to disk under the conversation
                        if let convID = self.currentTTSConversationID, let msgID = self.currentTTSMessageID {
                            do {
                                let relPath = try self.historyService.saveAudioData(
                                    conversationID: convID,
                                    messageID: msgID,
                                    data: data,
                                    ext: self.settingsService.openAITTSFormat,
                                    chunkIndex: self.currentTTSChunkIndex
                                )
                                self.logger.info("Saved TTS chunk #\(self.currentTTSChunkIndex) at \(relPath)")
                                // --- NEW: Report path saved ---
                                self.ttsChunkSavedSubject.send((messageID: msgID, path: relPath))
                                // --- END NEW ---
                            } catch {
                                self.logger.error("Failed to save TTS audio chunk: \(error.localizedDescription)")
                            }
                            self.currentTTSChunkIndex += 1
                        }
                        if self.currentAudioPlayer == nil {
                            logger.debug("TTS Manage: Player idle, playing fetched data immediately.")
                            self.playAudioData(data)
                        } else {
                            logger.debug("TTS Manage: Player active, storing fetched data.")
                            self.nextAudioData = data
                        }
                        self.manageTTSPlayback()
                    }
                } catch is CancellationError {
                    await MainActor.run { [weak self] in
                        self?.logger.notice("⏹️ TTS Fetch task cancelled.")
                        self?.isFetchingTTS = false
                        self?.ttsFetchTask = nil
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.logger.error("🚨 TTS Fetch failed: \(error.localizedDescription)")
                        self.isFetchingTTS = false
                        self.ttsFetchTask = nil
                        self.errorSubject.send(AudioError.ttsFetchFailed(error))
                        self.manageTTSPlayback()
                    }
                }
            }
            
        } else if isTextStreamComplete && currentTextProcessedIndex == currentTextToSpeakBuffer.count && currentAudioPlayer == nil && nextAudioData == nil {
            logger.info("🏁 TTS processing and playback seems complete (checked after fetch condition).")
            if isSpeaking { isSpeaking = false }
            self.currentTextToSpeakBuffer = ""
            self.currentTextProcessedIndex = 0
            self.isTextStreamComplete = false
        } else {
            logger.debug("TTS Manage: Conditions not met to fetch audio or play next chunk.")
        }
    }
    
    
    private func findNextTTSChunk(text: String, startIndex: Int, isComplete: Bool) -> (String, Int) {
        let remainingText = text.suffix(from: text.index(text.startIndex, offsetBy: startIndex))
        if remainingText.isEmpty { return ("", startIndex) }
        
        let maxChunkLength = settingsService.maxTTSChunkLength
        
        if remainingText.count <= maxChunkLength && isComplete {
            return (String(remainingText), startIndex + remainingText.count)
        }
        
        let potentialChunk = remainingText.prefix(maxChunkLength)
        var bestSplitIndex = potentialChunk.endIndex
        if !isComplete {
            let lookaheadMargin = 75
            if let searchRange = potentialChunk.index(potentialChunk.endIndex, offsetBy: -min(lookaheadMargin, potentialChunk.count), limitedBy: potentialChunk.startIndex) {
                if let lastSentenceEnd = potentialChunk.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?"), options: .backwards, range: searchRange..<potentialChunk.endIndex)?.upperBound {
                    bestSplitIndex = lastSentenceEnd
                } else if let lastComma = potentialChunk.rangeOfCharacter(from: CharacterSet(charactersIn: ","), options: .backwards, range: searchRange..<potentialChunk.endIndex)?.upperBound {
                    bestSplitIndex = lastComma
                } else if let lastSpace = potentialChunk.rangeOfCharacter(from: .whitespaces, options: .backwards, range: searchRange..<potentialChunk.endIndex)?.upperBound {
                    if potentialChunk.distance(from: potentialChunk.startIndex, to: lastSpace) > 1 {
                        bestSplitIndex = lastSpace
                    }
                }
            }
        }
        
        let chunkLength = potentialChunk.distance(from: potentialChunk.startIndex, to: bestSplitIndex)
        let baseMinChunkLength: Int = 60
        let scaledMinChunkLength = Int(Float(baseMinChunkLength) * max(1.0, self.ttsRate))
        
        if chunkLength < baseMinChunkLength && !isComplete { return ("", startIndex) }
        if chunkLength < scaledMinChunkLength && chunkLength >= baseMinChunkLength && !isComplete { return ("", startIndex) }
        if chunkLength == remainingText.count && chunkLength < scaledMinChunkLength && !isComplete { return ("", startIndex) }
        
        let finalChunk = String(potentialChunk[..<bestSplitIndex])
        return (finalChunk, startIndex + finalChunk.count)
    }
    
    
    @MainActor
    private func playAudioData(_ data: Data) {
        guard !data.isEmpty else {
            logger.warning("Attempted to play empty audio data.")
            manageTTSPlayback()
            return
        }

        do {
            currentAudioPlayer = try AVAudioPlayer(data: data)
            currentAudioPlayer?.delegate = self
            currentAudioPlayer?.enableRate = true
            currentAudioPlayer?.isMeteringEnabled = true
            currentAudioPlayer?.rate = self.ttsRate
            
            if currentAudioPlayer?.play() == true {
                isSpeaking = true
                logger.info("▶️ Playback started.")
                startTTSLevelTimer()
            } else {
                logger.error("🚨 Failed to start audio playback (play() returned false).")
                currentAudioPlayer = nil
                isSpeaking = false
                errorSubject.send(AudioError.audioPlaybackError(NSError(domain: "AudioService", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play() returned false"])))
                manageTTSPlayback()
            }
        } catch {
            logger.error("🚨 Failed to initialize or play audio: \(error.localizedDescription)")
            errorSubject.send(AudioError.audioPlaybackError(error))
            currentAudioPlayer = nil
            isSpeaking = false
            manageTTSPlayback()
        }
    }
    
    private func updatePlayerRate() {
        Task { @MainActor [weak self] in
            guard let self = self, let player = self.currentAudioPlayer, player.enableRate else { return }
            player.rate = self.ttsRate
            logger.info("Player rate updated to \(self.ttsRate)x")
        }
    }
    
    // MARK: - OpenAI TTS Fetch Implementation (Updated Signature)
    private func fetchOpenAITTSAudio(apiKey: String, text: String, instruction: String?) async throws -> Data? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("Attempted to synthesize empty text.")
            return nil
        }
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw LlmError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let payload = OpenAITTSRequest(
            model: settingsService.openAITTSModel,
            input: text,
            voice: settingsService.openAITTSVoice,
            response_format: settingsService.openAITTSFormat,
            instructions: instruction
        )
        
        do { request.httpBody = try JSONEncoder().encode(payload) }
        catch { throw LlmError.requestEncodingError(error) }
        
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: request) }
        catch { throw LlmError.networkError(error) }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorDetails = ""
            if let errorString = String(data: data, encoding: .utf8) { errorDetails = errorString }
            logger.error("🚨 OpenAI TTS Error: Status \(httpResponse.statusCode). Body: \(errorDetails)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorDetails)
        }
        
        guard !data.isEmpty else {
            logger.warning("Received empty audio data from OpenAI TTS API for non-empty text.")
            return nil
        }
        return data
    }
    
    
    // MARK: - SFSpeechRecognizerDelegate
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !available {
                self.logger.error("🚨 Speech recognizer became unavailable.")
                self.errorSubject.send(AudioError.recognizerUnavailable)
                // If listening, stop it.
                if self.isListening {
                    self.stopListeningCleanup()
                }
            } else {
                self.logger.info("✅ Speech recognizer is available.")
            }
        }
    }
    
    // MARK: - Public TTS Synthesis & Playback Helpers
    /// Synthesize full audio for given text (non‑streaming) and return raw Data
    func synthesizeFullAudio(text: String) async throws -> Data? {
        guard let apiKey = settingsService.openaiAPIKey, !apiKey.isEmpty else {
            throw LlmError.apiKeyMissing(provider: "OpenAI TTS")
        }
        return try await fetchOpenAITTSAudio(apiKey: apiKey, text: text, instruction: settingsService.activeTTSInstruction)
    }
    
    /// Play an audio file previously saved at the given relative path under Documents
    func playAudioFile(relativePath: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("Could not find Documents directory for audio playback.")
            return
        }
        let fileURL = docs.appendingPathComponent(relativePath)

        do {
            let data = try Data(contentsOf: fileURL)
            currentAudioPlayer?.stop()
            currentAudioPlayer = try AVAudioPlayer(data: data)
            currentAudioPlayer?.delegate = self
            currentAudioPlayer?.enableRate = true
            currentAudioPlayer?.rate = ttsRate
            currentAudioPlayer?.isMeteringEnabled = true
            if currentAudioPlayer?.play() == true {
                isSpeaking = true
                logger.info("▶️ Playback started for file: \(relativePath)")
                startTTSLevelTimer()
            } else {
                logger.error("Failed to play audio file at: \(relativePath)")
                isSpeaking = false
            }
        } catch {
            logger.error("Error loading or playing audio file \(relativePath): \(error.localizedDescription)")
            errorSubject.send(AudioError.audioPlaybackError(error))
        }
    }
    
    // MARK: - AVAudioPlayerDelegate
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard player === self.currentAudioPlayer else {
                self.logger.warning("Unknown/outdated player finished.")
                return
            }
            
            self.logger.info("⏹️ Playback finished (success: \(flag)).")
            self.invalidateTTSLevelTimer()
            self.currentAudioPlayer = nil
            
            if self.isSpeaking {
                self.isSpeaking = false
                if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
            }
            
            // ── NEW: if we're in a replay, continue the queue; otherwise fall back to TTS streaming
            if !self.replayQueue.isEmpty {
                self.playNextReplay()
            } else {
                self.manageTTSPlayback()
            }
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.logger.error("🚨 Audio player decode error: \(error?.localizedDescription ?? "Unknown error")")
            // Ensure the failed player is the one we know about
            guard player === self.currentAudioPlayer else {
                self.logger.warning("Decode error delegate called for an unknown or outdated player.")
                return
            }
            self.invalidateTTSLevelTimer()
            self.currentAudioPlayer = nil // Release the player
            self.errorSubject.send(AudioError.audioPlaybackError(error ?? NSError(domain: "AudioService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown decode error"])))
            
            if self.isSpeaking {
                self.isSpeaking = false
                if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
            }
            // Try to continue with the next piece of audio if possible
            self.manageTTSPlayback()
        }
    }
    
    // MARK: - Cleanup
    func cleanupOnDisappear() {
        logger.info("AudioService cleanup initiated.")
        stopListeningCleanup()
        stopSpeaking() // This also cancels TTS fetch
        // Invalidate any remaining timers just in case
        invalidateAudioLevelTimer()
        invalidateSilenceTimer()
        invalidateTTSLevelTimer()
    }
    
    deinit {
        // deinit done by owner
        logger.info("AudioService deinit.")
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // --- Route Change Handling ---
    private func setupRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(notification: notification)
                }
        }
        logger.info("🔊 Route change observer set up.")
    }

    private func handleRouteChange(notification: Notification) {
        guard let userInfo    = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason      = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        // Always update our published state
        logger.info("🔊 Route changed. Reason: \(String(describing: reason))")
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        updateOutputDeviceState(for: currentRoute)

        // ── Only restart the engine on real device connect/disconnect ──
        if isListening, reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
            logger.info("🔄 Device connect/disconnect—restarting microphone engine.")
            stopListeningCleanup()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.startListening()
            }
        }
        // ── skip restarts on categoryChange, override, etc. ──
    }

    // Updates the @Published outputDevice based on the route's outputs
    private func updateOutputDeviceState(for route: AVAudioSessionRouteDescription) {
        // Consider it "speaker" only if the primary output is Speaker or Headphones (built-in)
        // Treat any Bluetooth or other external audio as "bluetooth" for the icon state
        let isSpeakerOutput = route.outputs.contains { output in
            output.portType == .builtInSpeaker
        }
        // Note: .headphones refers to the *wired* headphone jack, treat as speaker for icon? Or separate? Let's group with speaker for simplicity.
        let isWiredHeadphones = route.outputs.contains { $0.portType == .headphones }

        if isSpeakerOutput || isWiredHeadphones {
            if self.outputDevice != .speaker {
                self.outputDevice = .speaker
                logger.info("🔊 Output device state updated to: Speaker (Built-in or Wired)")
            }
        } else {
            // If any non-speaker/wired output exists (like Bluetooth A2DP/HFP/LE, AirPlay, CarAudio etc.)
            if self.outputDevice != .bluetooth {
                self.outputDevice = .bluetooth
                logger.info("🔊 Output device state updated to: Bluetooth/External")
            }
        }
    }
}


// Helper for reason description
extension AVAudioSession.RouteChangeReason {
    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .newDeviceAvailable: return "New Device Available"
        case .oldDeviceUnavailable: return "Old Device Unavailable"
        case .categoryChange: return "Category Change"
        case .override: return "Override"
        case .wakeFromSleep: return "Wake From Sleep"
        case .noSuitableRouteForCategory: return "No Suitable Route For Category"
        case .routeConfigurationChange: return "Route Configuration Change"
        @unknown default: return "Unknown Future Reason"
        }
    }
}
