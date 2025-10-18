import Foundation
import AVFoundation
import OSLog
import Combine
import UIKit
import FluidAudio

@MainActor
class AudioService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AudioService")
    
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false
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
    
    let transcriptionSubject = PassthroughSubject<String, Never>()
    let errorSubject = PassthroughSubject<Error, Never>()
    let ttsChunkSavedSubject = PassthroughSubject<(messageID: UUID, path: String), Never>()
    let ttsPlaybackCompleteSubject = PassthroughSubject<Void, Never>()
    
    private var textBuffer: String = ""
    private var llmDone: Bool = false
    private var audioQueue: [Data] = []
    private var ttsFetchTask: Task<Void, Never>? = nil
    @Published private(set) var isFetchingTTS: Bool = false
    
    private let audioEngine = AVAudioEngine()
    private var currentAudioPlayer: AVAudioPlayer?
    
    private var silenceTimer: DispatchSourceTimer?
    
    private let settingsService: SettingsService
    private let historyService: HistoryService
    private var mistralTranscriptionService: MistralTranscriptionService?
    
    private var currentTTSConversationID: UUID?
    private var currentTTSMessageID: UUID?
    private var currentTTSChunkIndex: Int = 0
    
    private let baseMinChunkLength: Int = 60
    private let ttsChunkGrowthFactor: Double = 2.25
    private var prevTTSChunkSize: Int? = nil

    private var ttsSessionId: UUID = UUID()
    
    private var replayQueue: [String] = []
    
    private var vadManager: VadManager?
    private var vadStreamState: VadStreamState?
    private var capturedAudioSamples: [Float] = []
    private var isProcessingTranscription: Bool = false
    private var vadSampleBuffer: [Float] = []
    static private let vadChunkSize = 4096  // Matches Silero's expected input

    // For VAD-based trimming
    private var speechStartIndex: Int? = nil
    private var speechEndIndex: Int? = nil

    private lazy var vadSegmentationConfig: VadSegmentationConfig = {
        var config = VadSegmentationConfig.default  // Start with library defaults
        config.minSilenceDuration = settingsService.vadSilenceThreshold  // Override: user set hysteresis end, default is 1.5s
        config.maxSpeechDuration = .infinity  // Override: Unlimited talks
        return config
    }()
    
    func setTTSContext(conversationID: UUID, messageID: UUID) {
        if currentTTSConversationID != conversationID || currentTTSMessageID != messageID {
            currentTTSConversationID = conversationID
            currentTTSMessageID = messageID
            currentTTSChunkIndex = 0
        }
    }
    
    func replayAudioFiles(_ paths: [String]) {
        logger.info("Replaying saved audio files: \(paths)")
        replayQueue = paths
        playNextReplay()
    }
    
    private func playNextReplay() {
        guard !replayQueue.isEmpty else { return }
        let nextPath = replayQueue.removeFirst()
        logger.info("Playing replay file: \(nextPath)")
        playAudioFile(relativePath: nextPath)
    }
    
    func stopReplay() {
        logger.notice("Stopping replay, clearing replay queue.")
        replayQueue.removeAll()
        stopSpeaking()
    }
    
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default)
    }()
    
    private var routeChangeObserver: Any?
    private var isReconfiguringRoute: Bool = false
    
    init(settingsService: SettingsService, historyService: HistoryService) {
        self.settingsService = settingsService
        self.historyService = historyService
        super.init()
        
        if let mistralKey = settingsService.mistralAPIKey, !mistralKey.isEmpty, mistralKey != "YOUR_MISTRAL_API_KEY" {
            self.mistralTranscriptionService = MistralTranscriptionService(apiKey: mistralKey)
        }
        
        Task {
            await initializeVAD()
        }
        
        applyAudioSessionSettings()
    }

    private func initializeVAD() async {
        do {
            vadManager = try await VadManager(config: .default)  // Use library default (threshold 0.85)
            vadStreamState = await vadManager?.makeStreamState()
            logger.info("VAD initialized successfully with default config")
        } catch {
            logger.error("Failed to initialize VAD: \(error.localizedDescription)")
            errorSubject.send(AudioError.vadInitializationError(error.localizedDescription))
        }
    }

    func applyAudioSessionSettings() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [
                                        .allowBluetooth,
                                        .allowBluetoothA2DP,
                                        .allowAirPlay
                                    ])
            try session.setActive(true)
            let btTypes: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
            let hasBT = session.currentRoute.outputs.contains { btTypes.contains($0.portType) }
            if !hasBT {
                try session.overrideOutputAudioPort(.speaker)
            }
        } catch {
            logger.error("Audio session configuration error: \(error.localizedDescription)")
            errorSubject.send(AudioError.audioSessionError(error.localizedDescription))
        }
        
        if routeChangeObserver == nil {
            setupRouteChangeObserver()
        }
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        configureAudioEngineTap()
    }
    
    enum AudioError: Error, LocalizedError {
        case permissionDenied(type: String)
        case audioEngineError(String)
        case audioSessionError(String)
        case ttsFetchFailed(Error)
        case audioPlaybackError(Error)
        case transcriptionError(String)
        case vadInitializationError(String)
        
        var errorDescription: String? {
            switch self {
            case .permissionDenied(let type): return "\(type) permission was denied."
            case .audioEngineError(let desc): return "Audio engine error: \(desc)"
            case .audioSessionError(let desc): return "Audio session error: \(desc)"
            case .ttsFetchFailed(let error): return "TTS audio fetch failed: \(error.localizedDescription)"
            case .audioPlaybackError(let error): return "Audio playback failed: \(error.localizedDescription)"
            case .transcriptionError(let desc): return "Transcription error: \(desc)"
            case .vadInitializationError(let desc): return "VAD initialization error: \(desc)"
            }
        }
    }
    
    func startListening() {
        guard !isListening && !isSpeaking else { return }
        
        isListening = true
        isSpeaking = false
        capturedAudioSamples = []
        vadSampleBuffer = []
        speechStartIndex = nil
        speechEndIndex = nil
        isProcessingTranscription = false
        
        Task {
            vadStreamState = await vadManager?.makeStreamState()
        }
        
        logger.notice("🎤 Listening started with VAD events…")
    }
    
    func stopListeningCleanup() {
        let wasListening = isListening
        capturedAudioSamples.removeAll()
        vadSampleBuffer.removeAll()
        vadStreamState = nil
        speechStartIndex = nil
        speechEndIndex = nil
        
        isListening = false
        isProcessingTranscription = false
        
        if wasListening {
            logger.notice("🎙️ Listening stopped (Cleanup).")
        }
    }
    
    private func stopListeningAndSendTranscription() async {
        guard !isProcessingTranscription && isListening && !capturedAudioSamples.isEmpty else { return }
        isProcessingTranscription = true
        
        do {
            // Trim to speech bounds using VAD events (if available)
            var trimmedSamples = capturedAudioSamples
            if let startIdx = speechStartIndex, let endIdx = speechEndIndex, startIdx < capturedAudioSamples.count, endIdx > startIdx {
                let actualEnd = min(capturedAudioSamples.count, endIdx)
                trimmedSamples = Array(capturedAudioSamples[max(0, startIdx)..<actualEnd])
                logger.info("Trimmed to VAD bounds: \(trimmedSamples.count) samples")
            } else {
                logger.info("No VAD events - sending full buffer: \(self.capturedAudioSamples.count) samples")
            }
            
            if trimmedSamples.isEmpty {
                logger.info("🎤 Trimmed audio empty - continuing to listen.")
                isProcessingTranscription = false
                return
            }
            
            let audioData = try convertSamplesToAudioData(samples: trimmedSamples)
            logger.info("🎤 Converted \(trimmedSamples.count) samples to \(audioData.count) bytes")
            
            guard let transcriptionService = mistralTranscriptionService else {
                logger.error("Mistral transcription service not available - continuing to listen.")
                errorSubject.send(AudioError.transcriptionError("Mistral API key not available"))
                isProcessingTranscription = false
                return
            }
            
            let transcription = try await transcriptionService.transcribeAudio(audioData: audioData)
            
            let trimmedText = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                logger.info("🎤 Sending transcription to ViewModel: '\(trimmedText)'")
                transcriptionSubject.send(trimmedText)
            } else {
                logger.info("🎤 Transcription empty - continuing to listen.")
                isProcessingTranscription = false
                return
            }
        } catch {
            logger.error("🚨 Transcription error: \(error.localizedDescription) - continuing to listen.")
            errorSubject.send(AudioError.transcriptionError(error.localizedDescription))
            isProcessingTranscription = false
            return
        }
        
        // Only cleanup on successful non-empty send (go to idle)
        isProcessingTranscription = false
        stopListeningCleanup()
    }
    
    private func convertSamplesToAudioData(samples: [Float]) throws -> Data {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        
        var int16Samples = [Int16]()
        int16Samples.reserveCapacity(samples.count)
        for sample in samples {
            let clampedSample = max(-1.0, min(1.0, sample))
            int16Samples.append(Int16(clampedSample * Float(Int16.max)))
        }
        
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize
        
        var wavData = Data(capacity: Int(fileSize + 8))
        
        wavData.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: fileSize.littleEndian) { wavData.append(contentsOf: $0) }
        wavData.append(contentsOf: "WAVE".utf8)
        
        wavData.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: channels.littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { wavData.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { wavData.append(contentsOf: $0) }
        
        wavData.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataSize.littleEndian) { wavData.append(contentsOf: $0) }
        
        int16Samples.withUnsafeBytes { wavData.append(contentsOf: $0) }
        
        return wavData
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
    
    func processTTSChunk(textChunk: String, isLastChunk: Bool) {
        logger.debug("Received text chunk (\(textChunk.count) chars). IsLast: \(isLastChunk)")
        textBuffer.append(textChunk)
        if isLastChunk { llmDone = true }
        scheduleNext()
    }
    
    func stopSpeaking() {
        let wasSpeaking = self.isSpeaking
        cancelTTSFetch()
        
        if let player = self.currentAudioPlayer {
            if player.isPlaying {
                player.stop()
            }
            self.currentAudioPlayer = nil
            logger.info("Audio player stopped.")
        }
        
        self.audioQueue.removeAll()
        self.textBuffer = ""
        self.llmDone = false
        self.prevTTSChunkSize = nil
        
        self.currentTTSChunkIndex = 0
        
        if wasSpeaking {
            self.isSpeaking = false
            logger.notice("⏹️ TTS interrupted/stopped by request.")
        }
    }
    
    private func scheduleNext() {
        if !audioQueue.isEmpty && currentAudioPlayer?.isPlaying != true {
            let data = audioQueue.removeFirst()
            playAudioData(data)
        }

        guard !isFetchingTTS else { return }

        let idx = findNextTTSChunk()
        if idx > 0 {
            logger.debug("Fetching next TTS chunk: \(idx) chars")
            let chunk = String(textBuffer.prefix(idx))
            textBuffer.removeFirst(idx)
            fetchAudio(for: chunk)
            return
        }

        if llmDone && audioQueue.isEmpty && currentAudioPlayer?.isPlaying != true {
            ttsPlaybackCompleteSubject.send()
            llmDone = false
            prevTTSChunkSize = nil
        }
    }

    private func fetchAudio(for text: String) {
        guard let apiKey = settingsService.openaiAPIKey,
              !apiKey.isEmpty,
              apiKey != "YOUR_OPENAI_API_KEY"
        else {
            logger.error("OpenAI API key missing")
            return
        }

        let session = ttsSessionId
        isFetchingTTS = true

        ttsFetchTask = Task { [weak self] in
            guard let self = self else { return }
            guard self.ttsSessionId == session else { return }

            defer {
                Task { @MainActor in
                    self.isFetchingTTS = false
                    guard self.ttsSessionId == session else { return }
                    self.scheduleNext()
                }
            }

            do {
                if let data = try await fetchOpenAITTSAudio(
                    apiKey: apiKey,
                    text: text,
                    instruction: self.settingsService.activeTTSInstruction
                ) {
                    if self.ttsSessionId == session {
                        logger.info("Enqueued TTS chunk for playback \(self.currentTTSChunkIndex).")
                        self.audioQueue.append(data)
                    }
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
        var splitIdx = potentialChunk.count

        let lookaheadMargin = min(100, potentialChunk.count)
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
        logger.info("AudioService deinit.")
    }
    
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
        if let reason = reason {
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override:
                break
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
            try? await Task.sleep(nanoseconds: 100_000_000) 
            
            await MainActor.run {
                 logger.info("🎤 Reconfiguring audio engine tap after delay.")
                 audioEngine.inputNode.removeTap(onBus: 0) 
                 configureAudioEngineTap()
            }
        }
    }

    private func logRouteDetails(route: AVAudioSessionRouteDescription, reason: AVAudioSession.RouteChangeReason?) {
        let reasonDesc = reason?.description ?? "Initial State or Unknown"
        logger.debug("🔊 Route changed. Reason: \(reasonDesc)")
        
        if let output = route.outputs.first(where: { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver && $0.portType != .headphones }),
           let input = route.inputs.first(where: { $0.portType == output.portType || ($0.portType == .bluetoothHFP && output.portType == .bluetoothA2DP) }) {
            logger.info("🔊 External output '\(output.portName)' provides input '\(input.portName)'.")
        }
    }

    private func configureAudioEngineTap() {
        let input = audioEngine.inputNode
        let hardwareInputFormat = input.inputFormat(forBus: 0)

        guard hardwareInputFormat.sampleRate > 0 else {
            logger.error("🚨 Invalid hardware input format (sample rate 0).")
            errorSubject.send(AudioError.audioEngineError("Invalid input format (sample rate 0)"))
            if audioEngine.isRunning { audioEngine.stop() }
            return
        }

        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        
        guard let converter = AVAudioConverter(from: hardwareInputFormat, to: desiredFormat) else {
            logger.error("🚨 Failed to create audio converter")
            errorSubject.send(AudioError.audioEngineError("Failed to create audio converter"))
            return
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: hardwareInputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                if self.isListening {
                    self.lastMeasuredAudioLevel = self.calculatePowerLevel(buffer: buffer)
                    
                    let convertedBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / hardwareInputFormat.sampleRate))!
                    
                    var error: NSError?
                    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    
                    converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
                    
                    if let error = error {
                        self.logger.error("Audio conversion error: \(error.localizedDescription)")
                        return
                    }
                    
                    await self.processAudioBuffer(convertedBuffer)
                }
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
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        
        capturedAudioSamples.append(contentsOf: samples)
        vadSampleBuffer.append(contentsOf: samples)
        
        guard let vadManager = vadManager, var state = vadStreamState else { return }
        
        while vadSampleBuffer.count >= Self.vadChunkSize {
            let vadChunk = Array(vadSampleBuffer.prefix(Self.vadChunkSize))
            vadSampleBuffer.removeFirst(Self.vadChunkSize)
            
            do {
                let result = try await vadManager.processStreamingChunk(
                    vadChunk,
                    state: state,
                    config: vadSegmentationConfig,  // Reuse our custom config
                    returnSeconds: false,  // Use samples for precision
                    timeResolution: 2
                )
                
                vadStreamState = result.state
                
                switch result.event?.kind {
                case .speechStart:
                    logger.info("🎤 Speech start detected at sample \(result.event?.sampleIndex ?? 0).")
                    speechStartIndex = result.event?.sampleIndex
                    // Continue listening
                    
                case .speechEnd:
                    logger.info("🛑 Speech end detected at sample \(result.event?.sampleIndex ?? 0).")
                    speechEndIndex = result.event?.sampleIndex
                    await stopListeningAndSendTranscription()
                    
                case .none:
                    // Continue listening (speech ongoing)
                    break
                    
                @unknown default:
                    break
                }
            } catch {
                logger.error("VAD processing error: \(error.localizedDescription)")
            }
        }
    }
    
    func teardown() {
        ttsSessionId = UUID()
        if isListening {
            stopListeningCleanup()  // Handles cancel-like reset
        }
        stopSpeaking()
    }

    func cancelTTSFetch() {
        guard isFetchingTTS else { return }
        ttsFetchTask?.cancel()
        ttsFetchTask = nil
        isFetchingTTS = false
        logger.info("TTS fetch task cancelled.")
    }
}

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
