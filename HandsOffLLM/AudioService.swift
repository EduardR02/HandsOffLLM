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
    /// Computed: dBFS [-50, 0]. Returns mic level in listening, playback level in speaking, -50 otherwise.
    private var lastMeasuredAudioLevel: Float = -50
    @MainActor
    var rawAudioLevel: Float {
        if isListening {
            return lastMeasuredAudioLevel
        }
        if isSpeaking, let player = currentAudioPlayer {
            player.updateMeters()
            let db = player.averagePower(forChannel: 0)
            return max(-50, min(db, 0))
        }
        return -50
    }
    @Published var ttsRate: Float = 2.0 {
        didSet {
            if oldValue != ttsRate {
                updatePlayerRate()
            }
        }
    }
    
    // --- Combine Subjects for Communication ---
    let transcriptionSubject = PassthroughSubject<String, Never>()  // Sends final transcription
    let errorSubject = PassthroughSubject<Error, Never>()          // Reports errors
    let ttsChunkSavedSubject = PassthroughSubject<(messageID: UUID, path: String), Never>()
    let ttsPlaybackCompleteSubject = PassthroughSubject<Void, Never>() // NEW: fired when all TTS chunks have played
    
    // --- Internal State for simplified TTS queue/SM ---
    private var currentSpokenText: String = ""
    private var hasUserStartedSpeakingThisTurn: Bool = false

    private var textBuffer: String = ""
    private var llmDone: Bool = false
    private var audioQueue: [Data] = []
    private var ttsFetchTask: Task<Void, Never>? = nil
    @Published private(set) var isFetchingTTS: Bool = false
    
    // --- Audio Components ---
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var currentAudioPlayer: AVAudioPlayer?
    
    // --- Configuration & Timers ---
    private var silenceTimer: DispatchSourceTimer?
    private let silenceThreshold: TimeInterval = 1.5
    
    // --- Dependencies ---
    private let settingsService: SettingsService
    private let historyService: HistoryService
    
    // MARK: - TTS Save Context
    private var currentTTSConversationID: UUID?
    private var currentTTSMessageID: UUID?
    private var currentTTSChunkIndex: Int = 0
    
    // --- TTS Chunk Growth State ---
    private let baseMinChunkLength: Int = 60
    private let ttsChunkGrowthFactor: Double = 2.25
    private var prevTTSChunkSize: Int? = nil
    private var listeningSessionId: UUID?  // ignore stale callbacks
    
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
    private var isReconfiguringRoute: Bool = false
    
    init(settingsService: SettingsService, historyService: HistoryService) {
        self.settingsService = settingsService
        self.historyService = historyService
        super.init()
        speechRecognizer.delegate = self
        requestPermissions()
        applyAudioSessionSettings()
    }

    func applyAudioSessionSettings() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default, // Use default mode
                                    options: [
                                        // No longer forcing speaker or overriding port
                                        .allowBluetooth,
                                        .allowBluetoothA2DP,
                                        .allowAirPlay
                                    ])
            try session.setActive(true)
            // Default to speaker only if no Bluetooth device is connected
            let btTypes: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
            let hasBT = session.currentRoute.outputs.contains { btTypes.contains($0.portType) }
            if !hasBT {
                try session.overrideOutputAudioPort(.speaker)
            }
            // Initial route check can happen here or in handleRouteChange
        } catch {
            logger.error("Audio session configuration error: \(error.localizedDescription)")
            errorSubject.send(AudioError.audioSessionError(error.localizedDescription))
        }
        
        // Re-establish route observer if removed
        if routeChangeObserver == nil {
            setupRouteChangeObserver()
        }
        // Re-install audio engine tap and start engine
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        configureAudioEngineTap()
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
        guard !isListening && !isSpeaking else { return }
        guard speechRecognizer.isAvailable else {
            errorSubject.send(AudioError.recognizerUnavailable)
            return
        }

        // mark a new session
        let sessionId = UUID()
        listeningSessionId = sessionId

        // reset per‐session state…
        hasUserStartedSpeakingThisTurn = false
        invalidateSilenceTimer()
        isListening = true
        isSpeaking = false
        currentSpokenText = ""
        logger.notice("🎤 Listening started…")

        // Only create a new recognition request & task
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            errorSubject.send(AudioError.recognitionRequestError)
            isListening = false
            return
        }
        recognitionRequest.shouldReportPartialResults = true

        recognitionTask = speechRecognizer.recognitionTask(
            with: recognitionRequest
        ) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.listeningSessionId == sessionId else { return }
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

        logger.info("🎤 Listening using existing audio engine.")
    }
    
    func stopListeningCleanup() {
        let wasListening = isListening
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        listeningSessionId = nil  // clear session
        invalidateSilenceTimer()

        if wasListening {
            isListening = false
            logger.notice("🎙️ Listening stopped (Cleanup).")
        }
    }
    
    func stopListeningAndSendTranscription(transcription: String?) {
        // 1. Get the final text
        let textToSend = transcription ?? self.currentSpokenText
        // 3. Send the transcription if it's not empty
        let trimmedText = textToSend.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            logger.info("🎤 Sending final transcription to ViewModel: '\(trimmedText)'")
            transcriptionSubject.send(trimmedText)
            stopListeningCleanup()
        } else {
            logger.info("🎤 No speech detected or transcription empty, not sending.")
            // Notify ViewModel or whoever is listening that listening stopped without result?
            // For now, the state change of isListening to false handles this.
        }
    }
    
    // MARK: - Silence Detection
    private func resetSilenceTimer() {
        startSilenceTimer()
    }
    
    private func startSilenceTimer() {
        // cancel existing
        silenceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + silenceThreshold)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isListening else { return }
            self.logger.notice("⏳ Silence detected by timer. Processing...")
            self.stopListeningAndSendTranscription(transcription: self.currentSpokenText)
        }
        timer.resume()
        silenceTimer = timer
        logger.debug("Silence timer started.")
    }
    
    private func invalidateSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
        logger.debug("Silence timer invalidated.")
    }
    
    // MARK: - Audio Engine Management
    
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
    
    // MARK: - TTS Playback Control
    
    /// Called by ViewModel on each LLM chunk
    func processTTSChunk(textChunk: String, isLastChunk: Bool) {
        logger.debug("Received text chunk (\(textChunk.count) chars). IsLast: \(isLastChunk)")
        // Enqueue text
        textBuffer.append(textChunk)
        if isLastChunk { llmDone = true }
        scheduleNext()
    }
    
    func stopSpeaking() {
        let wasSpeaking = self.isSpeaking
        cancelTTSFetch()
        
        // Stop Audio Player
        if let player = self.currentAudioPlayer {
            if player.isPlaying {
                player.stop()
            }
            self.currentAudioPlayer = nil
            logger.info("Audio player stopped.")
        }
        
        // Cleanup Timer and Audio Data Buffer
        self.audioQueue.removeAll()
        self.textBuffer = ""
        self.llmDone = false
        self.prevTTSChunkSize = nil
        
        
        // Reset Text Buffer State for TTS
        self.currentTTSChunkIndex = 0
        
        // Update State only if it was actively speaking
        if wasSpeaking {
            self.isSpeaking = false
            logger.notice("⏹️ TTS interrupted/stopped by request.")
        }
    }
    
    // New: single scheduler driving both play + fetch
    private func scheduleNext() {
        // 1) Play queued audio and then fetch next chunk even if a fetch is in flight
        if !audioQueue.isEmpty && currentAudioPlayer?.isPlaying != true {
            // start playing immediately
            let data = audioQueue.removeFirst()
            playAudioData(data)
        }

        // 2) If still fetching, wait
        guard !isFetchingTTS else { return }

        // 3) Initial fetch when nothing is queued or playing
        let idx = findNextTTSChunk()
        if idx > 0 {
            logger.debug("Fetching next TTS chunk: \(idx) chars")
            let chunk = String(textBuffer.prefix(idx))
            textBuffer.removeFirst(idx)
            fetchAudio(for: chunk)
            return
        }

        // 3) All done
        if llmDone && audioQueue.isEmpty && currentAudioPlayer?.isPlaying != true {
            ttsPlaybackCompleteSubject.send()
            llmDone = false
            prevTTSChunkSize = nil
        }
    }

    /// Handles one chunk fetch + enqueue + disk save
    private func fetchAudio(for text: String) {
        guard let apiKey = settingsService.openaiAPIKey,
              !apiKey.isEmpty,
              apiKey != "YOUR_OPENAI_API_KEY"
        else {
            logger.error("OpenAI API key missing")
            return
        }

        isFetchingTTS = true
        ttsFetchTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                Task { @MainActor in
                    self.isFetchingTTS = false
                    self.scheduleNext()
                }
            }
            do {
                if let data = try await fetchOpenAITTSAudio(
                    apiKey: apiKey,
                    text: text,
                    instruction: self.settingsService.activeTTSInstruction
                ) {
                    // enqueue for playback
                    logger.info("Enqueued TTS chunk for playback \(self.currentTTSChunkIndex).")
                    self.audioQueue.append(data)
                    // Batch disk writes off the main actor to reduce UI I/O
                    let chunkIndex = self.currentTTSChunkIndex
                    self.currentTTSChunkIndex += 1
                    if let convID = self.currentTTSConversationID, let msgID = self.currentTTSMessageID {
                        let dataCopy = data
                        Task.detached(priority: .utility) { [weak self] in
                            guard let self = self else { return }
                            do {
                                let relPath = try await self.historyService.saveAudioData(
                                    conversationID: convID,
                                    messageID: msgID,
                                    data: dataCopy,
                                    ext: self.settingsService.openAITTSFormat,
                                    chunkIndex: chunkIndex
                                )
                                await MainActor.run {
                                    self.ttsChunkSavedSubject.send((messageID: msgID, path: relPath))
                                }
                            } catch {
                                self.logger.error("🗄️ Failed to save TTS chunk \(chunkIndex): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            } catch {
                logger.error("🚨 OpenAI TTS Error: \(error.localizedDescription)")
            }
        }
    }
    
    private func findNextTTSChunk() -> Int {
        let scaledMinChunkLength = Int(Float(baseMinChunkLength) * max(1.0, ttsRate))
        if textBuffer.isEmpty || (!llmDone && textBuffer.count < scaledMinChunkLength) {
            return 0
        }

        let maxSetting = settingsService.maxTTSChunkLength
        let maxChunkLength = prevTTSChunkSize.map { min(Int(Double($0) * ttsChunkGrowthFactor), maxSetting) } ?? maxSetting

        if textBuffer.count <= maxChunkLength && llmDone {
            prevTTSChunkSize = textBuffer.count
            return textBuffer.count
        }

        let potentialChunk = textBuffer.prefix(maxChunkLength)
        var splitIdx = potentialChunk.count // Default: use all possible

        if !llmDone {
            let lookaheadMargin = min(75, potentialChunk.count)
            let searchStart = potentialChunk.index(potentialChunk.endIndex, offsetBy: -lookaheadMargin)
            let searchRange = searchStart..<potentialChunk.endIndex

            if let lastSentenceEnd = potentialChunk.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?"), options: .backwards, range: searchRange)?.upperBound {
                splitIdx = potentialChunk.distance(from: potentialChunk.startIndex, to: lastSentenceEnd)
            } else if let lastComma = potentialChunk.rangeOfCharacter(from: CharacterSet(charactersIn: ","), options: .backwards, range: searchRange)?.upperBound {
                splitIdx = potentialChunk.distance(from: potentialChunk.startIndex, to: lastComma)
            } else if let lastSpace = potentialChunk.rangeOfCharacter(from: .whitespaces, options: .backwards, range: searchRange)?.upperBound {
                if potentialChunk.distance(from: potentialChunk.startIndex, to: lastSpace) > 1 {
                    splitIdx = potentialChunk.distance(from: potentialChunk.startIndex, to: lastSpace)
                }
            }
        }

        if splitIdx < scaledMinChunkLength && !llmDone {
            return 0
        }
        prevTTSChunkSize = splitIdx
        return splitIdx
    }
    

    
    private func configurePlayer(_ player: AVAudioPlayer) {
        player.delegate = self
        player.enableRate = true
        player.isMeteringEnabled = true
        player.rate = ttsRate
    }
    
    @MainActor private func playAudioData(_ data: Data) {
        guard !data.isEmpty else {
            logger.warning("Attempted to play empty audio data.")
            scheduleNext()
            return
        }

        do {
            let player = try AVAudioPlayer(data: data)
            configurePlayer(player)
            currentAudioPlayer = player

            if currentAudioPlayer?.play() == true {
                isSpeaking = true
                logger.info("▶️ Playback started.")
            } else {
                logger.error("🚨 Failed to start audio playback (play() returned false).")
                currentAudioPlayer = nil
                isSpeaking = false
                errorSubject.send(AudioError.audioPlaybackError(NSError(domain: "AudioService", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play() returned false"])))
                scheduleNext()
            }
        } catch {
            logger.error("🚨 Failed to initialize or play audio: \(error.localizedDescription)")
            errorSubject.send(AudioError.audioPlaybackError(error))
            currentAudioPlayer = nil
            isSpeaking = false
            scheduleNext()
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
                // If listening, teardown completely
                if self.isListening {
                    self.teardown()
                }
            } else {
                self.logger.info("✅ Speech recognizer is available.")
            }
        }
    }
    
    // MARK: - Public TTS Synthesis & Playback Helpers
    
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
            let player = try AVAudioPlayer(data: data)
            configurePlayer(player)
            currentAudioPlayer = player
            if currentAudioPlayer?.play() == true {
                isSpeaking = true
                logger.info("▶️ Playback started for file: \(relativePath)")
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
            guard let self = self, player === self.currentAudioPlayer else {
                self?.logger.warning("Unknown/outdated player finished.")
                return
            }
            self.logger.info("⏹️ Playback finished (success: \(flag)).")
            self.currentAudioPlayer = nil

            if !self.replayQueue.isEmpty {
                self.playNextReplay()
            } else {
                if self.audioQueue.isEmpty {
                    self.isSpeaking = false
                }
                self.scheduleNext()
            }
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.logger.error("🚨 Audio player decode error: \(error?.localizedDescription ?? "Unknown error")")
            guard player === self.currentAudioPlayer else {
                self.logger.warning("Decode error delegate called for an unknown or outdated player.")
                return
            }
            self.currentAudioPlayer = nil
            self.errorSubject.send(AudioError.audioPlaybackError(error ?? NSError(domain: "AudioService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown decode error"])))

            if self.isSpeaking {
                self.isSpeaking = false
            }
            self.scheduleNext()
        }
    }
    
    // MARK: - Full cleanup for app background/termination
    func cleanupForBackground() {
        logger.info("AudioService full cleanup for background.")
        teardown()
        audioEngine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }
    
    deinit {
        // deinit done by owner
        logger.info("AudioService deinit.")
    }
    
    // MARK: - Route Change Handling
    private func setupRouteChangeObserver() {
        let session = AVAudioSession.sharedInstance()
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                Task { await self?.handleRouteChange(reason: nil) }
                return
            }
            Task { await self?.handleRouteChange(reason: reason) }
        }
    }
    
    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        // Only handle initial (nil reason) or actual device plugs/unplugs
        if let reason = reason {
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override:
                break  // proceed
            default:
                logger.debug("Ignoring route change: \(reason.description)")
                return
            }
        }

        guard !isReconfiguringRoute else {
            logger.info("Route reconfiguration already in progress. Skipping.")
            return
        }
        isReconfiguringRoute = true

        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute
        
        logRouteDetails(route: currentRoute, reason: reason)
        
        Task {
            defer {
                Task { @MainActor in self.isReconfiguringRoute = false }
            }
            // Give the system a moment (e.g., 100ms) to settle the route change
            try? await Task.sleep(nanoseconds: 100_000_000) 
            
            // Now reconfigure the tap on the main thread
            await MainActor.run {
                 logger.info("🎤 Reconfiguring audio engine tap after delay.")
                 // Important: removeTap must happen before installTap
                 audioEngine.inputNode.removeTap(onBus: 0) 
                 configureAudioEngineTap() // Re-install tap for the new (or same) route
            }
        }
    }

    /// Helper function to log route details and check for external mic
    private func logRouteDetails(route: AVAudioSessionRouteDescription, reason: AVAudioSession.RouteChangeReason?) {
        let reasonDesc = reason?.description ?? "Initial State or Unknown"
        logger.debug("🔊 Route changed. Reason: \(reasonDesc)")
        
        // Check if an external output also provides input
        if let output = route.outputs.first(where: { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver && $0.portType != .headphones }), // Consider headphones built-in for this check
           let input = route.inputs.first(where: { $0.portType == output.portType || ($0.portType == .bluetoothHFP && output.portType == .bluetoothA2DP) }) {
            logger.info("🔊 External output '\(output.portName)' provides input '\(input.portName)'.")
        }
    }

    /// Re-installs tap, prepares and starts engine. Called on init and route change.
    private func configureAudioEngineTap() {
        let input = audioEngine.inputNode
        let hardwareInputFormat = input.inputFormat(forBus: 0)

        guard hardwareInputFormat.sampleRate > 0 else {
            logger.error("🚨 Invalid hardware input format (sample rate 0).")
            errorSubject.send(AudioError.audioEngineError("Invalid input format (sample rate 0)"))
            if audioEngine.isRunning { audioEngine.stop() }
            return
        }

        input.installTap(onBus: 0,
                         bufferSize: 1024,
                         format: hardwareInputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            if self.isListening, let req = self.recognitionRequest {
                req.append(buffer)
                self.lastMeasuredAudioLevel = self.calculatePowerLevel(buffer: buffer)
            }
        }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                logger.error("🚨 Audio engine startup error: \(error.localizedDescription)")
                errorSubject.send(AudioError.audioEngineError("Engine start failed: \(error.localizedDescription)"))
                input.removeTap(onBus: 0)
            }
        }
    }
    
    /// Completely tears down speech-to-text, TTS fetch & playback.
    func teardown() {
        // 1) stop listening
        if isListening { stopListeningCleanup() }
        // 2) cancel any TTS fetch
        cancelTTSFetch()
        // 3) stop playback
        if isSpeaking { stopSpeaking() }
    }

    func cancelTTSFetch() {
        guard isFetchingTTS else { return }
        ttsFetchTask?.cancel()
        ttsFetchTask = nil
        isFetchingTTS = false
        logger.info("TTS fetch task cancelled.")
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
