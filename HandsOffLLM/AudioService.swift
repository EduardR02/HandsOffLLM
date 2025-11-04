import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import OSLog
import Combine
import FluidAudio
import Accelerate

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

fileprivate func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
    guard let channelData = buffer.floatChannelData?[0] else { return nil }
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else { return [] }
    let channelDataValue = UnsafeBufferPointer(start: channelData, count: frameLength)
    return Array(channelDataValue)
}

private struct CaptureBuffers {
    var capturedSamples: [Float] = []
    var vadSamples: [Float] = []
    var speechStartIndex: Int? = nil
    var speechEndIndex: Int? = nil
    var captureStartTime: Date? = nil

    mutating func reset(includeSpeechMarks: Bool = true) {
        capturedSamples.removeAll()
        vadSamples.removeAll()
        if includeSpeechMarks {
            speechStartIndex = nil
            speechEndIndex = nil
        }
        captureStartTime = nil
    }
}

private struct TTSState {
    var textBuffer: String = ""
    var llmFinished: Bool = false
    var audioQueue: [Data] = []
    var nextChunkIndex: Int = 0
    var previousChunkSize: Int? = nil

    mutating func resetSession() {
        textBuffer.removeAll(keepingCapacity: true)
        llmFinished = false
        audioQueue.removeAll(keepingCapacity: true)
        nextChunkIndex = 0
        previousChunkSize = nil
    }
}

@MainActor
class AudioService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    nonisolated let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AudioService")
    
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var isProcessingLLM: Bool = false  // Set by ChatViewModel for voice interrupt
    @Published private(set) var currentListeningSessionId: UUID?
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
    
    let transcriptionSubject = PassthroughSubject<(text: String, sessionId: UUID), Never>()
    let errorSubject = PassthroughSubject<Error, Never>()
    let ttsChunkSavedSubject = PassthroughSubject<(messageID: UUID, path: String), Never>()
    let ttsPlaybackCompleteSubject = PassthroughSubject<Void, Never>()
    let voiceInterruptSubject = PassthroughSubject<Void, Never>()

    private var listeningSessionId: UUID = UUID()

    private var ttsState = TTSState()
    private var ttsFetchTask: Task<Void, Never>? = nil
    @Published private(set) var isFetchingTTS: Bool = false

    private let audioEngine = AVAudioEngine()
    private var currentAudioPlayer: AVAudioPlayer?
    
    private let settingsService: SettingsService
    private let historyService: HistoryService
    private var mistralTranscriptionService: MistralTranscriptionService?

    private var currentTTSConversationID: UUID?
    private var currentTTSMessageID: UUID?

    private let baseMinChunkLength: Int = 60
    private let ttsChunkGrowthFactor: Double = 2.25

    private var ttsSessionId: UUID = UUID()

    private var replayQueue: [String] = []

    private var vadManager: VadManager?
    private var vadStreamState: VadStreamState?
    private var captureBuffers = CaptureBuffers()
    private var isProcessingTranscription: Bool = false
    static private let vadChunkSize = 4096  // Matches Silero's expected input
    private let maxCaptureDurationSeconds: Double = 60
    private let defaultListeningCooldown: TimeInterval = 0.15
    private var listeningCooldownEndTime: Date?

    // For VAD-based trimming
    private lazy var vadSegmentationConfig: VadSegmentationConfig = {
        var config = VadSegmentationConfig.default  // Start with library defaults
        config.minSilenceDuration = settingsService.vadSilenceThreshold  // Override: user set hysteresis end, default is 1.5s
        config.maxSpeechDuration = .infinity  // Override: Unlimited talks
        return config
    }()

    
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
    private let externalPreferredOutputs: Set<AVAudioSession.Port> = [
        .bluetoothHFP,
        .bluetoothA2DP,
        .bluetoothLE,
        .carAudio,
        .headphones,
        .headsetMic,
        .lineOut,
        .airPlay
    ]
    
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
            let audioError = AudioError.vadInitializationError(error.localizedDescription)
            errorSubject.send(audioError)
        }
    }

    func applyAudioSessionSettings() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [
                                        .allowBluetoothHFP,
                                        .allowBluetoothA2DP,
                                        .allowAirPlay,
                                        .defaultToSpeaker
                                    ])
            try session.setPreferredSampleRate(16_000)
            try session.setPreferredInputNumberOfChannels(1)
            try session.setActive(true)
            enforcePreferredOutputRoute(using: session)
        } catch {
            logger.error("Audio session configuration error: \(error.localizedDescription)")
            let audioError = AudioError.audioSessionError(error.localizedDescription)
            errorSubject.send(audioError)
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
    
    func startListening(useCooldown: Bool = true) {
        guard !isListening && !isSpeaking else { return }
        if useCooldown {
            logger.info("🎤 Listening started with cooldown.")
        }
        listeningSessionId = UUID()
        currentListeningSessionId = listeningSessionId
        isListening = true
        isSpeaking = false
        isTranscribing = false
        captureBuffers.reset()
        isProcessingTranscription = false
        listeningCooldownEndTime = useCooldown ? Date().addingTimeInterval(defaultListeningCooldown) : nil
        if listeningCooldownEndTime == nil {
            captureBuffers.captureStartTime = Date()
        }

        Task {
            vadStreamState = await vadManager?.makeStreamState()
        }

        logger.notice("🎤 Listening started with VAD events… (session: \(self.listeningSessionId))")
    }
    
    func stopListeningCleanup(resetTranscribing: Bool = true) {
        let wasListening = isListening
        captureBuffers.reset(includeSpeechMarks: resetTranscribing)
        vadStreamState = nil
        isListening = false
        if resetTranscribing {
            isTranscribing = false
        }
        isProcessingTranscription = false
        listeningCooldownEndTime = nil

        if wasListening {
            logger.notice("🎙️ Listening stopped (Cleanup).")
        }
    }
    
    private func stopListeningAndSendTranscription() async {
        guard !isProcessingTranscription && isListening && !captureBuffers.capturedSamples.isEmpty else { return }
        isProcessingTranscription = true
        isTranscribing = true
        let sessionId = listeningSessionId  // Capture session ID
        defer { isProcessingTranscription = false }

        do {
            // Trim to speech bounds using VAD events (if available)
            var trimmedSamples = captureBuffers.capturedSamples
            if let startIdx = captureBuffers.speechStartIndex, let endIdx = captureBuffers.speechEndIndex, startIdx < captureBuffers.capturedSamples.count, endIdx > startIdx {
                let actualEnd = min(captureBuffers.capturedSamples.count, endIdx)
                trimmedSamples = Array(captureBuffers.capturedSamples[max(0, startIdx)..<actualEnd])
                logger.info("Trimmed to VAD bounds: \(trimmedSamples.count) samples")
            } else {
                logger.info("No VAD events - sending full buffer: \(self.captureBuffers.capturedSamples.count) samples")
            }
            
            if trimmedSamples.isEmpty {
                logger.info("🎤 Trimmed audio empty - continuing to listen.")
                captureBuffers.reset()
                Task { @MainActor in
                    vadStreamState = await vadManager?.makeStreamState()
                }
                isTranscribing = false
                return
            }
            
            let audioData = try convertSamplesToAudioData(samples: trimmedSamples)
            logger.info("🎤 Converted \(trimmedSamples.count) samples to \(audioData.count) bytes")
            
            guard let transcriptionService = mistralTranscriptionService else {
                logger.error("Mistral transcription service not available - continuing to listen.")
                let audioError = AudioError.transcriptionError("Mistral API key not available")
                errorSubject.send(audioError)
                captureBuffers.reset()
                Task { @MainActor in
                    vadStreamState = await vadManager?.makeStreamState()
                }
                isTranscribing = false
                return
            }
            
            let transcription = try await transcriptionService.transcribeAudio(audioData: audioData)
            
            let trimmedText = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                logger.info("🎤 Sending transcription to ViewModel: '\(trimmedText)' (session: \(sessionId))")
                transcriptionSubject.send((text: trimmedText, sessionId: sessionId))
            } else {
                logger.info("🎤 Transcription empty - continuing to listen.")
                captureBuffers.reset()
                Task { @MainActor in
                    vadStreamState = await vadManager?.makeStreamState()
                }
                isTranscribing = false
                return
            }
        } catch {
            logger.error("🚨 Transcription error: \(error.localizedDescription) - continuing to listen.")
            let audioError = AudioError.transcriptionError(error.localizedDescription)
            errorSubject.send(audioError)
            captureBuffers.reset()
            Task { @MainActor in
                vadStreamState = await vadManager?.makeStreamState()
            }
            isTranscribing = false
            return
        }
        
        // Only cleanup on successful non-empty send (go to idle)
        stopListeningCleanup(resetTranscribing: false)
        captureBuffers.reset()
        isTranscribing = false
    }
    
    private func enforcePreferredOutputRoute(using session: AVAudioSession = AVAudioSession.sharedInstance()) {
        let outputs = session.currentRoute.outputs
        let hasPreferredExternal = outputs.contains { externalPreferredOutputs.contains($0.portType) }
        guard !hasPreferredExternal else { return }
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            logger.warning("Failed to override output to speaker: \(error.localizedDescription)")
        }
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
    
    private func calculatePowerLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -50.0 }
        var rms: Float = 0.0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let dbValue = (rms > 0) ? (20 * log10(rms)) : -160.0
        let minDb: Float = -50.0
        let maxDb: Float = 0.0
        return max(minDb, min(dbValue, maxDb))
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
                 enforcePreferredOutputRoute()
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
            let audioError = AudioError.audioEngineError("Invalid input format (sample rate 0)")
            errorSubject.send(audioError)
            if audioEngine.isRunning { audioEngine.stop() }
            return
        }

        let desiredSampleRate: Double = 16_000
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: desiredSampleRate,
                                          channels: 1,
                                          interleaved: false)!
        let needsConversion = hardwareInputFormat.sampleRate != desiredSampleRate ||
                              hardwareInputFormat.channelCount != 1 ||
                              hardwareInputFormat.commonFormat != .pcmFormatFloat32

        let converter: AVAudioConverter?
        if needsConversion {
            guard let created = AVAudioConverter(from: hardwareInputFormat, to: desiredFormat) else {
                logger.error("🚨 Failed to create audio converter")
                let audioError = AudioError.audioEngineError("Failed to create audio converter")
                errorSubject.send(audioError)
                return
            }
            converter = created
        } else {
            converter = nil
        }

        let weakSelf = WeakBox(self)
        let onSamples: @Sendable ([Float]) -> Void = { [weakSelf] samples in
            Task { @MainActor [samples] in
                guard let service = weakSelf.value else { return }
                // Process audio when listening OR when detecting interrupt during LLM processing
                let shouldProcess = service.isListening ||
                                   (service.isProcessingLLM && !service.isSpeaking && !service.isTranscribing)
                guard shouldProcess else { return }

                if service.isListening {
                    service.lastMeasuredAudioLevel = service.calculatePowerLevel(samples: samples)
                }
                await service.processAudioSamples(samples)
            }
        }

        let tapBlock = Self.makeTapHandler(
            converter: converter,
            desiredFormat: desiredFormat,
            desiredSampleRate: desiredSampleRate,
            hardwareSampleRate: hardwareInputFormat.sampleRate,
            logger: logger,
            onSamples: onSamples
        )

        input.installTap(onBus: 0, bufferSize: 2048, format: hardwareInputFormat, block: tapBlock)

        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                logger.error("🚨 Audio engine startup error: \(error.localizedDescription)")
                let audioError = AudioError.audioEngineError("Engine start failed: \(error.localizedDescription)")
                errorSubject.send(audioError)
                input.removeTap(onBus: 0)
            }
        }
    }
    
    nonisolated private static func makeTapHandler(
        converter: AVAudioConverter?,
        desiredFormat: AVAudioFormat,
        desiredSampleRate: Double,
        hardwareSampleRate: Double,
        logger: Logger,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            let samples: [Float]
            if let converter {
                let targetFrames = AVAudioFrameCount(Double(buffer.frameLength) * desiredSampleRate / hardwareSampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: targetFrames) else {
                    logger.error("Failed to allocate converted audio buffer.")
                    return
                }

                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

                if let error {
                    logger.error("Audio conversion error: \(error.localizedDescription)")
                    return
                }

                guard let convertedSamples = extractSamples(from: convertedBuffer) else {
                    logger.error("Failed to read converted audio samples.")
                    return
                }
                samples = convertedSamples
            } else {
                guard let rawSamples = extractSamples(from: buffer) else { return }
                samples = rawSamples
            }

            guard !samples.isEmpty else { return }
            onSamples(samples)
        }
    }
    
    private func processAudioSamples(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }

        // Process audio when actively listening OR during LLM processing (for interrupt detection)
        let shouldProcess = isListening || (isProcessingLLM && !isSpeaking)
        guard shouldProcess else { return }

        // If we're not in active listening mode, we need to initialize for interrupt detection
        if !isListening && isProcessingLLM {
            if vadStreamState == nil {
                vadStreamState = await vadManager?.makeStreamState()
            }
        }

        if let cooldownEnd = listeningCooldownEndTime {
            if Date() < cooldownEnd {
                return
            } else {
                listeningCooldownEndTime = nil
                captureBuffers.reset(includeSpeechMarks: false)
            }
        }

        captureBuffers.capturedSamples.append(contentsOf: samples)
        captureBuffers.vadSamples.append(contentsOf: samples)

        if captureBuffers.captureStartTime == nil { captureBuffers.captureStartTime = Date() }

        if captureBuffers.speechStartIndex == nil,
           let start = captureBuffers.captureStartTime,
           Date().timeIntervalSince(start) >= maxCaptureDurationSeconds,
           !isProcessingTranscription {
            logger.notice("⌛ No speech end detected for \(Int(self.maxCaptureDurationSeconds))s. Returning to idle.")
            stopListeningCleanup()
            return
        }

        guard let vadManager = vadManager, let state = vadStreamState else { return }

        while captureBuffers.vadSamples.count >= Self.vadChunkSize {
            let vadChunk = Array(captureBuffers.vadSamples.prefix(Self.vadChunkSize))
            captureBuffers.vadSamples.removeFirst(Self.vadChunkSize)

            do {
                let result = try await vadManager.processStreamingChunk(
                    vadChunk,
                    state: state,
                    config: vadSegmentationConfig,
                    returnSeconds: false,
                    timeResolution: 2
                )

                vadStreamState = result.state

                switch result.event?.kind {
                case .speechStart:
                    logger.info("🎤 Speech start detected at sample \(result.event?.sampleIndex ?? 0).")
                    captureBuffers.speechStartIndex = result.event?.sampleIndex

                    if !isListening && isProcessingLLM {
                        // Voice interrupt: user spoke during LLM processing
                        // Switch to listening mode (UI update) but DON'T reset buffers
                        logger.info("🔴 Voice interrupt - switching to listening mode")
                        isListening = true
                        voiceInterruptSubject.send()  // Cancel LLM only
                    }

                case .speechEnd:
                    if isListening {
                        logger.info("🛑 Speech end detected at sample \(result.event?.sampleIndex ?? 0).")
                        captureBuffers.speechEndIndex = result.event?.sampleIndex
                        await stopListeningAndSendTranscription()
                    }
                    // Ignore speech end during interrupt mode (we're not in listening state)

                case .none:
                    // Continue processing (speech ongoing or no speech)
                    break

                @unknown default:
                    break
                }
            } catch {
                logger.error("VAD processing error: \(error.localizedDescription)")
            }
        }
    }
    
}

// MARK: - TTS pipeline
@MainActor
extension AudioService {
    func processTTSChunk(textChunk: String, isLastChunk: Bool) {
        logger.debug("Received text chunk (\(textChunk.count) chars). IsLast: \(isLastChunk)")
        ttsState.textBuffer.append(textChunk)
        if isLastChunk { ttsState.llmFinished = true }
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
        
        ttsState.resetSession()
        
        if wasSpeaking {
            self.isSpeaking = false
            logger.notice("⏹️ TTS interrupted/stopped by request.")
        }
    }
    
    func setTTSContext(conversationID: UUID, messageID: UUID) {
        if currentTTSConversationID != conversationID || currentTTSMessageID != messageID {
            currentTTSConversationID = conversationID
            currentTTSMessageID = messageID
            ttsState.nextChunkIndex = 0
        }
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
            enforcePreferredOutputRoute()
            if currentAudioPlayer?.play() == true {
                isSpeaking = true
                logger.info("▶️ Playback started for file: \(relativePath)")
            } else {
                logger.error("Failed to play audio file at: \(relativePath)")
                isSpeaking = false
                let audioError = AudioError.audioPlaybackError(NSError(domain: "AudioService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to play audio file."]))
                errorSubject.send(audioError)
            }
        } catch {
            logger.error("Error loading or playing audio file \(relativePath): \(error.localizedDescription)")
            let audioError = AudioError.audioPlaybackError(error)
            errorSubject.send(audioError)
        }
    }
    
    func cancelTTSFetch() {
        guard isFetchingTTS else { return }
        ttsFetchTask?.cancel()
        ttsFetchTask = nil
        isFetchingTTS = false
        logger.info("TTS fetch task cancelled.")
    }
    
    func teardown() {
        ttsSessionId = UUID()
        if isListening {
            stopListeningCleanup()  // Handles cancel-like reset
        }
        stopSpeaking()
    }
    
    func scheduleNext() {
        if !ttsState.audioQueue.isEmpty && currentAudioPlayer?.isPlaying != true {
            let data = ttsState.audioQueue.removeFirst()
            playAudioData(data)
        }

        guard !isFetchingTTS else { return }

        let idx = findNextTTSChunk()
        if idx > 0 {
            logger.debug("Fetching next TTS chunk: \(idx) chars")
            let chunk = String(ttsState.textBuffer.prefix(idx))
            ttsState.textBuffer.removeFirst(idx)
            fetchAudio(for: chunk)
            return
        }

        if ttsState.llmFinished && ttsState.audioQueue.isEmpty && currentAudioPlayer?.isPlaying != true {
            ttsPlaybackCompleteSubject.send()
            ttsState.llmFinished = false
            ttsState.previousChunkSize = nil
        }
        // No else branch: UI derives state from service flags.
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
                if self.ttsState.audioQueue.isEmpty {
                    self.isSpeaking = false
                }
                let hadPendingLLM = self.ttsState.llmFinished
                self.scheduleNext()
                if !hadPendingLLM && self.replayQueue.isEmpty && self.ttsState.audioQueue.isEmpty && self.currentAudioPlayer == nil {
                    self.logger.debug("Audio playback finished; no queued audio remaining.")
                }
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
            let audioError = AudioError.audioPlaybackError(error ?? NSError(domain: "AudioService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown decode error"]))
            self.errorSubject.send(audioError)

            if self.isSpeaking {
                self.isSpeaking = false
            }
            self.scheduleNext()
        }
    }
}

// MARK: - TTS helpers
@MainActor
extension AudioService {
    func fetchAudio(for text: String) {
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

            let chunkIndex = self.ttsState.nextChunkIndex
            let capturedConversationID = self.currentTTSConversationID
            let capturedMessageID = self.currentTTSMessageID

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
                    let isCurrentSession = (self.ttsSessionId == session)

                    if isCurrentSession {
                        self.logger.info("Enqueued TTS chunk \(chunkIndex) for playback.")
                        self.ttsState.audioQueue.append(data)
                        if self.ttsState.nextChunkIndex <= chunkIndex {
                            self.ttsState.nextChunkIndex = chunkIndex + 1
                        } else {
                            self.ttsState.nextChunkIndex = max(self.ttsState.nextChunkIndex, chunkIndex + 1)
                        }
                    } else {
                        self.logger.debug("Discarding playback queue update for stale TTS session \(session).")
                    }

                    if let convID = capturedConversationID, let msgID = capturedMessageID {
                        let dataCopy = data
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            do {
                                let relPath = try await self.historyService.saveAudioData(
                                    conversationID: convID,
                                    messageID: msgID,
                                    data: dataCopy,
                                    ext: self.settingsService.openAITTSFormat,
                                    chunkIndex: chunkIndex
                                )
                                self.ttsChunkSavedSubject.send((messageID: msgID, path: relPath))
                            } catch {
                                self.logger.error("🗄️ Failed to save TTS chunk \(chunkIndex): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            } catch {
                if error is CancellationError {
                    self.logger.notice("OpenAI TTS fetch cancelled for session \(session).")
                } else if let urlError = error as? URLError, urlError.code == .cancelled {
                    self.logger.notice("OpenAI TTS fetch cancelled (URLError.cancelled) for session \(session).")
                } else if (error as NSError).domain == NSURLErrorDomain,
                          (error as NSError).code == NSURLErrorCancelled {
                    self.logger.notice("OpenAI TTS fetch cancelled (NSError cancelled) for session \(session).")
                } else if let llmError = error as? LlmError,
                          case let .networkError(inner) = llmError,
                          (inner is CancellationError) ||
                          (inner as NSError).domain == NSURLErrorDomain && (inner as NSError).code == NSURLErrorCancelled ||
                          (inner as? URLError)?.code == .cancelled {
                    self.logger.notice("OpenAI TTS fetch cancelled (LlmError.networkError cancelled) for session \(session).")
                } else {
                    self.logger.error("🚨 OpenAI TTS Error: \(error.localizedDescription)")
                    self.errorSubject.send(AudioError.ttsFetchFailed(error))
                }
            }
        }
    }
    
    func findNextTTSChunk() -> Int {
        let scaledMinChunkLength = Int(Float(baseMinChunkLength) * max(1.0, ttsRate))
        if ttsState.textBuffer.isEmpty || (!ttsState.llmFinished && ttsState.textBuffer.count < scaledMinChunkLength) {
            return 0
        }

        let maxSetting = settingsService.maxTTSChunkLength
        let maxChunkLength = ttsState.previousChunkSize.map { min(Int(Double($0) * ttsChunkGrowthFactor), maxSetting) } ?? maxSetting

        if ttsState.textBuffer.count <= maxChunkLength && ttsState.llmFinished {
            ttsState.previousChunkSize = ttsState.textBuffer.count
            return ttsState.textBuffer.count
        }

        let potentialChunk = ttsState.textBuffer.prefix(maxChunkLength)
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

        if splitIdx < scaledMinChunkLength && !ttsState.llmFinished {
            return 0
        }
        ttsState.previousChunkSize = splitIdx
        return splitIdx
    }
    
    func configurePlayer(_ player: AVAudioPlayer) {
        player.delegate = self
        player.enableRate = true
        player.isMeteringEnabled = true
        player.rate = ttsRate
    }
    
    func playAudioData(_ data: Data) {
        guard !data.isEmpty else {
            logger.warning("Attempted to play empty audio data.")
            scheduleNext()
            return
        }

        do {
            let player = try AVAudioPlayer(data: data)
            configurePlayer(player)
            currentAudioPlayer = player
            enforcePreferredOutputRoute()

            if currentAudioPlayer?.play() == true {
                isSpeaking = true
                logger.info("▶️ Playback started.")
            } else {
                logger.error("🚨 Failed to start audio playback (play() returned false).")
                currentAudioPlayer = nil
                isSpeaking = false
                let audioError = AudioError.audioPlaybackError(NSError(domain: "AudioService", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play() returned false"]))
                errorSubject.send(audioError)
                scheduleNext()
            }
        } catch {
            logger.error("🚨 Failed to initialize or play audio: \(error.localizedDescription)")
            let audioError = AudioError.audioPlaybackError(error)
            errorSubject.send(audioError)
            currentAudioPlayer = nil
            isSpeaking = false
            scheduleNext()
        }
    }
    
    func updatePlayerRate() {
        Task { @MainActor [weak self] in
            guard let self = self, let player = self.currentAudioPlayer, player.enableRate else { return }
            player.rate = self.ttsRate
            logger.info("Player rate updated to \(self.ttsRate)x")
        }
    }
    
    func fetchOpenAITTSAudio(apiKey: String, text: String, instruction: String?) async throws -> Data? {
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
