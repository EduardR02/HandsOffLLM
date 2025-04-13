// AudioService.swift
import Foundation
import AVFoundation
import Speech
import OSLog
import Combine

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

    // --- Combine Subjects for Communication ---
    let transcriptionSubject = PassthroughSubject<String, Never>() // Sends final transcription
    let errorSubject = PassthroughSubject<Error, Never>()         // Reports errors

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
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default)
    }()

    init(settingsService: SettingsService) {
        self.settingsService = settingsService
        super.init()
        speechRecognizer.delegate = self
        requestPermissions()
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
        guard !audioEngine.isRunning else {
            logger.warning("Audio engine is already running, cannot start listening again yet.")
            return
        }
        guard speechRecognizer.isAvailable else {
            logger.error("🚨 Speech recognizer is not available right now.")
            errorSubject.send(AudioError.recognizerUnavailable)
            isListening = false
            return
        }

        isListening = true
        isSpeaking = false // Ensure speaking is false when listening starts
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
            errorSubject.send(AudioError.audioSessionError(error.localizedDescription))
            isListening = false
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

        let inputNode = audioEngine.inputNode

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] (buffer, time) in
             guard let self = self else { return }
            // Only append buffer if listening and NOT speaking (to avoid feedback loops)
             if self.isListening && !self.isSpeaking {
                 self.recognitionRequest?.append(buffer)
             }
             // Update level regardless of speaking state for visualization
            self.lastMeasuredAudioLevel = self.calculatePowerLevel(buffer: buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            startAudioLevelTimer()
        } catch {
            logger.error("🚨 Audio engine start error: \(error.localizedDescription)")
            errorSubject.send(AudioError.audioEngineError(error.localizedDescription))
            recognitionTask?.cancel()
            recognitionTask = nil
            stopListeningCleanup() // Ensure cleanup if engine fails
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
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
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
         // Don't fetch if already fetching
         guard !isFetchingTTS else {
             logger.debug("TTS Manage: Already fetching, skipping.")
             return
         }

        // Priority 1: If we have pre-fetched audio and player is idle, play it.
        if currentAudioPlayer == nil, let dataToPlay = nextAudioData {
            logger.debug("TTS Manage: Found pre-fetched data, playing...")
            self.nextAudioData = nil // Consume the data
            playAudioData(dataToPlay)
            // After starting playback, immediately check if more text needs fetching
            // This recursive call handles the case where playback starts AND more text is available
            manageTTSPlayback()
            return
        }

        // Determine if we *need* to fetch more audio
        let unprocessedText = currentTextToSpeakBuffer.suffix(from: currentTextToSpeakBuffer.index(currentTextToSpeakBuffer.startIndex, offsetBy: currentTextProcessedIndex))

        // Conditions to fetch:
        // 1. Player is idle, there's unprocessed text, AND (stream is finished OR text is reasonably long)
        let shouldFetchInitial = currentAudioPlayer == nil && !unprocessedText.isEmpty && nextAudioData == nil && (isTextStreamComplete || unprocessedText.count > 5)
        // 2. Player is active, there's unprocessed text, AND we haven't already fetched the next chunk
        let shouldFetchNext = currentAudioPlayer != nil && !unprocessedText.isEmpty && nextAudioData == nil

        if shouldFetchInitial || shouldFetchNext {
             logger.debug("TTS Manage: Conditions met to fetch new audio.")
             let (chunk, nextIndex) = findNextTTSChunk(text: currentTextToSpeakBuffer, startIndex: currentTextProcessedIndex, isComplete: isTextStreamComplete)

             if chunk.isEmpty {
                 logger.debug("TTS Manage: Found no suitable chunk to fetch yet.")
                 // If the stream is finished, we have processed everything, and the player is idle, it means TTS is truly done.
                 if isTextStreamComplete && currentTextProcessedIndex == currentTextToSpeakBuffer.count && currentAudioPlayer == nil && nextAudioData == nil {
                     logger.info("🏁 TTS processing and playback complete.")
                     // State cleanup might happen here or be triggered by the ViewModel observing isSpeaking = false
                     if isSpeaking { isSpeaking = false } // Ensure state is updated
                     // Reset buffer state for next interaction
                     self.currentTextToSpeakBuffer = ""
                     self.currentTextProcessedIndex = 0
                     self.isTextStreamComplete = false
                 }
                 return // Nothing to fetch
             }

            logger.info("➡️ Sending chunk (\(chunk.count) chars) to TTS API...")
            self.currentTextProcessedIndex = nextIndex
            self.isFetchingTTS = true // Set flag BEFORE starting async task

            guard let apiKey = self.settingsService.openaiAPIKey, !apiKey.isEmpty, apiKey != "YOUR_OPENAI_API_KEY" else {
                 logger.error("🚨 OpenAI API Key missing, cannot fetch TTS.")
                 self.isFetchingTTS = false
                 errorSubject.send(LlmError.apiKeyMissing(provider: "OpenAI TTS"))
                 return
            }

            // --- Start Async Fetch Task ---
            self.ttsFetchTask = Task { [weak self] in
                guard let self = self else { return }
                do {
                    let fetchedData = try await self.fetchOpenAITTSAudio(apiKey: apiKey, text: chunk)
                    try Task.checkCancellation() // Check if cancelled before proceeding

                    // --- Task Success ---
                    await MainActor.run { [weak self] in
                         guard let self = self else { return }
                         self.isFetchingTTS = false // Reset flag on main thread
                         self.ttsFetchTask = nil

                         guard let data = fetchedData, !data.isEmpty else {
                             logger.warning("TTS fetch returned no data for chunk.")
                              self.manageTTSPlayback() // Try to manage again (maybe get next chunk)
                             return
                         }

                         logger.info("⬅️ Received TTS audio (\(data.count) bytes).")

                         // If player is idle, play immediately. Otherwise, store for later.
                         if self.currentAudioPlayer == nil {
                              logger.debug("TTS Manage: Player idle, playing fetched data immediately.")
                              self.playAudioData(data)
                         } else {
                              logger.debug("TTS Manage: Player active, storing fetched data.")
                              self.nextAudioData = data
                         }
                         // After handling data, check again if more fetching is needed
                         self.manageTTSPlayback()
                    }
                } catch is CancellationError {
                     // --- Task Cancelled ---
                     await MainActor.run { [weak self] in
                          self?.logger.notice("⏹️ TTS Fetch task cancelled.")
                          self?.isFetchingTTS = false // Reset flag on cancellation
                          self?.ttsFetchTask = nil
                          // Don't automatically call manageTTSPlayback() on cancellation,
                          // let the cancellation flow handle state.
                     }
                 } catch {
                     // --- Task Error ---
                     await MainActor.run { [weak self] in
                          guard let self = self else { return }
                          self.logger.error("🚨 TTS Fetch failed: \(error.localizedDescription)")
                          self.isFetchingTTS = false // Reset flag on error
                          self.ttsFetchTask = nil
                          self.errorSubject.send(AudioError.ttsFetchFailed(error))
                          // Maybe try fetching again? Or signal failure?
                          // For now, just log and signal error. Further calls to manageTTSPlayback might retry.
                          self.manageTTSPlayback() // See if remaining text can be processed
                     }
                 }
             } // --- End of Async Fetch Task ---

        } else if isTextStreamComplete && currentTextProcessedIndex == currentTextToSpeakBuffer.count && currentAudioPlayer == nil && nextAudioData == nil {
            // This condition checks if everything is done *after* potentially trying to fetch
            logger.info("🏁 TTS processing and playback seems complete (checked after fetch condition).")
             if isSpeaking { isSpeaking = false } // Ensure state is updated
             // Reset buffer state
             self.currentTextToSpeakBuffer = ""
             self.currentTextProcessedIndex = 0
             self.isTextStreamComplete = false
        } else {
             logger.debug("TTS Manage: Conditions not met to fetch audio or play next chunk.")
        }
    }


    // Find the next chunk of text suitable for TTS synthesis
    private func findNextTTSChunk(text: String, startIndex: Int, isComplete: Bool) -> (String, Int) {
        let remainingText = text.suffix(from: text.index(text.startIndex, offsetBy: startIndex))
        if remainingText.isEmpty {
            logger.debug("TTS Chunk: No remaining text.")
            return ("", startIndex)
        }

        let maxChunkLength = settingsService.maxTTSChunkLength

        // If the entire remaining text is short enough, send it all, especially if complete.
        if remainingText.count <= maxChunkLength && isComplete {
             logger.debug("TTS Chunk: Sending all remaining text (\(remainingText.count) chars) as it's complete.")
             return (String(remainingText), startIndex + remainingText.count)
        }

        // Take up to maxChunkLength characters
        let potentialChunk = remainingText.prefix(maxChunkLength)
        var bestSplitIndex = potentialChunk.endIndex // Default to sending the whole potential chunk

        // If the stream is not complete, try to find a natural break near the end.
        if !isComplete {
            let lookaheadMargin = 75 // How far back from the end to look for a boundary

            // Find the last suitable boundary within the margin
            if let searchRange = potentialChunk.index(potentialChunk.endIndex, offsetBy: -min(lookaheadMargin, potentialChunk.count), limitedBy: potentialChunk.startIndex) {
                // Prioritize sentence endings
                if let lastSentenceEnd = potentialChunk.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?"), options: .backwards, range: searchRange..<potentialChunk.endIndex)?.upperBound {
                     bestSplitIndex = lastSentenceEnd
                     logger.debug("TTS Chunk: Found sentence boundary.")
                // Then try commas
                } else if let lastComma = potentialChunk.rangeOfCharacter(from: CharacterSet(charactersIn: ","), options: .backwards, range: searchRange..<potentialChunk.endIndex)?.upperBound {
                     bestSplitIndex = lastComma
                     logger.debug("TTS Chunk: Found comma boundary.")
                // Then try spaces (less ideal, but better than mid-word)
                } else if let lastSpace = potentialChunk.rangeOfCharacter(from: .whitespaces, options: .backwards, range: searchRange..<potentialChunk.endIndex)?.upperBound {
                    // Only use space if it's not immediately at the start (avoids splitting just spaces)
                    if potentialChunk.distance(from: potentialChunk.startIndex, to: lastSpace) > 1 {
                         bestSplitIndex = lastSpace
                         logger.debug("TTS Chunk: Found space boundary.")
                    } else {
                        logger.debug("TTS Chunk: Found only leading space boundary, ignoring.")
                    }
                } else {
                     logger.debug("TTS Chunk: No suitable boundary found in lookahead margin.")
                     // bestSplitIndex remains potentialChunk.endIndex
                }
            }
        } else {
             logger.debug("TTS Chunk: Stream is complete, using full potential chunk or remainder.")
             // If complete, we don't need to find a boundary, just take the max length allowed.
             bestSplitIndex = potentialChunk.endIndex
        }


        let chunkLength = potentialChunk.distance(from: potentialChunk.startIndex, to: bestSplitIndex)

        // Calculate scaled minimum chunk length based on playback speed
        let baseMinChunkLength: Int = 60 // Minimum characters to send generally
        let scaledMinChunkLength = Int(Float(baseMinChunkLength) * max(1.0, self.ttsRate)) // Scale up for faster speech

        // Avoid sending very short chunks unless it's the *absolute* end of the text
        if chunkLength < baseMinChunkLength && !isComplete {
            logger.debug("TTS Chunk: Chunk too short (\(chunkLength) < \(baseMinChunkLength)) and stream not complete. Waiting.")
            return ("", startIndex) // Wait for more text
        }
        // Apply scaled minimum if > base, but still avoid tiny chunks if not complete
         if chunkLength < scaledMinChunkLength && chunkLength >= baseMinChunkLength && !isComplete {
            logger.debug("TTS Chunk: Chunk shorter than scaled minimum (\(chunkLength) < \(scaledMinChunkLength)) and stream not complete. Waiting.")
            return ("", startIndex) // Wait for more text
         }

        // Check if the *entire remaining text* is too short and stream isn't complete yet
        if chunkLength == remainingText.count && chunkLength < scaledMinChunkLength && !isComplete {
             logger.debug("TTS Chunk: Entire remaining text is shorter than scaled minimum (\(chunkLength) < \(scaledMinChunkLength)) and stream not complete. Waiting.")
             return ("", startIndex)
        }

        let finalChunk = String(potentialChunk[..<bestSplitIndex])
        logger.debug("TTS Chunk: Determined final chunk length: \(finalChunk.count)")
        return (finalChunk, startIndex + finalChunk.count)
    }


    @MainActor
    private func playAudioData(_ data: Data) {
        guard !data.isEmpty else {
             logger.warning("Attempted to play empty audio data.")
             // If playing empty data failed, potentially try fetching/playing next?
             manageTTSPlayback()
             return
        }
        do {
             let audioSession = AVAudioSession.sharedInstance()
             try audioSession.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])

             // --- Speaker Override ---
             do {
                 try audioSession.overrideOutputAudioPort(.speaker)
                 logger.info("🔊 Audio output route forced to Speaker.")
             } catch {
                 logger.error("🚨 Failed to override audio output to speaker: \(error.localizedDescription)")
                 // Don't fail playback if override fails, just log it.
             }
             // --- End Speaker Override ---

             try audioSession.setActive(true) // Activate session *after* setting category/override

            currentAudioPlayer = try AVAudioPlayer(data: data)
            currentAudioPlayer?.delegate = self // Set delegate non-isolated context OK
            currentAudioPlayer?.enableRate = true
            currentAudioPlayer?.isMeteringEnabled = true // Enable metering for level visualization

            if let player = currentAudioPlayer {
                 player.rate = self.ttsRate // Set rate before playing
            }

            if currentAudioPlayer?.play() == true {
                isSpeaking = true // Set speaking state TRUE
                logger.info("▶️ Playback started.")
                startTTSLevelTimer() // Start visualizing levels
                // Don't call manageTTSPlayback here, let the fetch completion/player finish trigger it.
            } else {
                logger.error("🚨 Failed to start audio playback (play() returned false).")
                currentAudioPlayer = nil
                isSpeaking = false // Ensure speaking is false if play fails
                errorSubject.send(AudioError.audioPlaybackError(NSError(domain: "AudioService", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play() returned false"])))
                 manageTTSPlayback() // Try to recover or play next
            }
        } catch {
            logger.error("🚨 Failed to initialize or play audio: \(error.localizedDescription)")
             errorSubject.send(AudioError.audioPlaybackError(error))
            currentAudioPlayer = nil
            isSpeaking = false // Ensure speaking is false on error
            manageTTSPlayback() // Try to recover or play next
        }
    }

    private func updatePlayerRate() {
        Task { @MainActor [weak self] in
            guard let self = self, let player = self.currentAudioPlayer, player.enableRate else { return }
            player.rate = self.ttsRate
            logger.info("Player rate updated to \(self.ttsRate)x")
        }
    }

    // MARK: - OpenAI TTS Fetch Implementation
    private func fetchOpenAITTSAudio(apiKey: String, text: String) async throws -> Data? {
         guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
             logger.warning("Attempted to synthesize empty text.")
             return nil // Return nil for empty text, not an error
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
             instructions: settingsService.ttsInstructions
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
             // Technically successful response, but empty data is problematic.
             logger.warning("Received empty audio data from OpenAI TTS API for non-empty text.")
             return nil // Treat as non-error but no data
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

    // MARK: - AVAudioPlayerDelegate
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
             // Ensure the finished player is the one we know about
             guard player === self.currentAudioPlayer else {
                 self.logger.warning("Delegate called for an unknown or outdated player.")
                 return
             }

            self.logger.info("⏹️ Playback finished (Success: \(flag)).")
            self.invalidateTTSLevelTimer() // Stop level updates
            self.currentAudioPlayer = nil // Release the player

            // Only change isSpeaking state if it was true
            if self.isSpeaking {
                self.isSpeaking = false
                // Level should be reset by invalidateTTSLevelTimer if player is nil
                 if self.ttsOutputLevel != 0.0 { self.ttsOutputLevel = 0.0 }
            }

            // After finishing, check if there's more to play or fetch
            self.manageTTSPlayback()
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
    }
}