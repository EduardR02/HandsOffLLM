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
    private static let mistralModel = "voxtral-mini-2602"

    private var ttsSessionId: UUID = UUID()

    private var replayQueue: [String] = []
    private var lastChunkProvider: TTSProvider?

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
        config.maxSpeechDuration = 3600.0  // Override: 1 hour max speech duration (FluidAudio doesn't handle .infinity properly)
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


    private let urlSession: URLSession
    
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
    
    private let proxyService: ProxyService

    init(
        settingsService: SettingsService,
        historyService: HistoryService,
        authService: AuthService,
        urlSession: URLSession? = nil
    ) {
        self.settingsService = settingsService
        self.historyService = historyService
        self.proxyService = ProxyService(authService: authService, settingsService: settingsService)
        self.urlSession = urlSession ?? Self.makeDefaultURLSession()
        super.init()
        Task {
            await initializeVAD()
        }

        applyAudioSessionSettings()
    }

    private static func makeDefaultURLSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120  // 2 minutes
        config.timeoutIntervalForResource = 300 // 5 minutes
        return URLSession(configuration: config)
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

    private func transcribeViaProxy(audioData: Data, filename: String, contentType: String, model: String) async throws -> String {
        let request = try await proxyService.makeProxiedTranscriptionRequest(
            audioData: audioData,
            model: model,
            filename: filename,
            contentType: contentType
        )
        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            logger.error("Mistral proxy transcription failed: \(http.statusCode) \(body)")
            throw LlmError.invalidResponse(statusCode: http.statusCode, body: body)
        }

        let responsePayload = try JSONDecoder().decode(MistralTranscriptionResponse.self, from: data)
        return responsePayload.text
    }
    
    private func mistralService(for key: String) -> MistralTranscriptionService {
        if let existing = mistralTranscriptionService, existing.apiKey == key {
            return existing
        }
        let service = MistralTranscriptionService(apiKey: key)
        mistralTranscriptionService = service
        return service
    }
    
    private func convertSamplesToAACData(samples: [Float]) throws -> Data {
        let sampleRate: Double = 16_000
        let frameCount = AVAudioFrameCount(samples.count)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioError.transcriptionError("Failed to prepare audio buffer.")
        }

        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                channel.update(from: ptr.baseAddress!, count: Int(frameCount))
            }
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mistral-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue  // Let encoder choose optimal bit rate
        ]

        do {
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: settings)
            try audioFile.write(from: buffer)
        } catch {
            throw AudioError.transcriptionError("Failed to encode AAC audio: \(error.localizedDescription)")
        }

        do {
            return try Data(contentsOf: tempURL)
        } catch {
            throw AudioError.transcriptionError("Failed to read encoded AAC audio: \(error.localizedDescription)")
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
            
            let aacData = try convertSamplesToAACData(samples: trimmedSamples)
            logger.info("🎤 Converted \(trimmedSamples.count) samples to \(aacData.count) bytes of AAC")

            let transcription: String
            if settingsService.useOwnMistralKey {
                guard let key = settingsService.mistralAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !key.isEmpty else {
                    logger.error("Mistral key override enabled but no key provided.")
                    let audioError = AudioError.transcriptionError("Add your Mistral API key before enabling direct transcription.")
                    errorSubject.send(audioError)
                    captureBuffers.reset()
                    Task { @MainActor in
                        vadStreamState = await vadManager?.makeStreamState()
                    }
                    isTranscribing = false
                    return
                }
                let service = mistralService(for: key)
                transcription = try await service.transcribeAudio(
                    data: aacData,
                    filename: "audio.m4a",
                    contentType: "audio/aac",
                    model: Self.mistralModel
                )
            } else {
                mistralTranscriptionService = nil
                transcription = try await transcribeViaProxy(
                    audioData: aacData,
                    filename: "audio.m4a",
                    contentType: "audio/aac",
                    model: Self.mistralModel
                )
            }
            
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

    private func makeDesiredInputFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw AudioError.audioEngineError("Failed to create desired input format")
        }
        return format
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
        let desiredFormat: AVAudioFormat
        do {
            desiredFormat = try makeDesiredInputFormat(sampleRate: desiredSampleRate)
        } catch let audioError as AudioError {
            logger.error("🚨 Failed to create desired input format.")
            errorSubject.send(audioError)
            if audioEngine.isRunning { audioEngine.stop() }
            return
        } catch {
            logger.error("🚨 Unexpected error creating desired input format: \(error.localizedDescription)")
            let audioError = AudioError.audioEngineError("Failed to create desired input format")
            errorSubject.send(audioError)
            if audioEngine.isRunning { audioEngine.stop() }
            return
        }
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
        Task { @MainActor [weak self] in
            self?.scheduleNext()
        }
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

        // Stop listening/VAD before playing audio (prevents mic from picking up playback)
        if isListening {
            stopListeningCleanup()
        }

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

        let provider = settingsService.selectedTTSProvider
        if lastChunkProvider != provider {
            ttsState.previousChunkSize = nil
            lastChunkProvider = provider
        }

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
    private func isReplicateSuccessStatus(_ status: String) -> Bool {
        switch status {
        case "succeeded", "successful", "completed":
            return true
        default:
            return false
        }
    }

    private func isReplicateFailureStatus(_ status: String) -> Bool {
        switch status {
        case "failed", "canceled", "cancelled":
            return true
        default:
            return false
        }
    }

    func fetchAudio(for text: String) {
        // Check which TTS provider is selected
        let ttsProvider = settingsService.selectedTTSProvider

        // For OpenAI, verify API key availability
        if ttsProvider == .openai {
            let useProxy = proxyService.shouldUseProxy(for: .openai)
            let trimmedKey = settingsService.openaiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)

            if !useProxy {
                guard let userKey = trimmedKey, !userKey.isEmpty else {
                    logger.error("OpenAI API key missing while user override enabled.")
                    let audioError = AudioError.transcriptionError("Add your OpenAI API key before enabling direct TTS.")
                    errorSubject.send(audioError)
                    return
                }
            }
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
                let data: Data?

                // Route to appropriate TTS provider
                switch self.settingsService.selectedTTSProvider {
                case .kokoro:
                    // Use Kokoro via Replicate API
                    let voice = self.settingsService.kokoroTTSVoice
                    data = try await self.fetchReplicateTTSAudio(
                        text: text,
                        voice: voice,
                        speed: 1.0
                    )

                case .openai:
                    // Use OpenAI TTS (existing implementation)
                    let useProxy = self.proxyService.shouldUseProxy(for: .openai)
                    let trimmedKey = self.settingsService.openaiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
                    data = try await self.fetchOpenAITTSAudio(
                        text: text,
                        instruction: self.settingsService.activeTTSInstruction,
                        useProxy: useProxy,
                        apiKey: trimmedKey
                    )
                }

                if let data {
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
                        let fileExtension = self.settingsService.selectedTTSProvider == .kokoro ? "wav" : self.settingsService.openAITTSFormat
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            do {
                                let relPath = try await self.historyService.saveAudioData(
                                    conversationID: convID,
                                    messageID: msgID,
                                    data: dataCopy,
                                    ext: fileExtension,
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
                let provider = self.settingsService.selectedTTSProvider.displayName
                if error is CancellationError {
                    self.logger.notice("\(provider) TTS fetch cancelled for session \(session).")
                } else if let urlError = error as? URLError, urlError.code == .cancelled {
                    self.logger.notice("\(provider) TTS fetch cancelled (URLError.cancelled) for session \(session).")
                } else if (error as NSError).domain == NSURLErrorDomain,
                          (error as NSError).code == NSURLErrorCancelled {
                    self.logger.notice("\(provider) TTS fetch cancelled (NSError cancelled) for session \(session).")
                } else if let llmError = error as? LlmError,
                          case let .networkError(inner) = llmError,
                          (inner is CancellationError) ||
                          (inner as NSError).domain == NSURLErrorDomain && (inner as NSError).code == NSURLErrorCancelled ||
                          (inner as? URLError)?.code == .cancelled {
                    self.logger.notice("\(provider) TTS fetch cancelled (LlmError.networkError cancelled) for session \(session).")
                } else {
                    self.logger.error("🚨 \(provider) TTS Error: \(error.localizedDescription)")
                    self.errorSubject.send(AudioError.ttsFetchFailed(error))
                }
            }
        }
    }
    
    private func nextChunkLength(baseMin: Int, maxCap: Int, growth: Double) -> Int {
        let scaledMin = Int(Float(baseMin) * max(1.0, ttsRate))
        guard !ttsState.textBuffer.isEmpty else { return 0 }
        if !ttsState.llmFinished && ttsState.textBuffer.count < scaledMin {
            return 0
        }

        let effectiveCap = max(1, maxCap)
        let dynamicCap = ttsState.previousChunkSize.map { min(Int(Double($0) * growth), effectiveCap) } ?? effectiveCap

        if ttsState.textBuffer.count <= dynamicCap && ttsState.llmFinished {
            ttsState.previousChunkSize = ttsState.textBuffer.count
            return ttsState.textBuffer.count
        }

        let potentialChunk = ttsState.textBuffer.prefix(dynamicCap)
        var splitIdx = potentialChunk.count

        let lookaheadMargin = min(100, potentialChunk.count)
        let searchStart = potentialChunk.index(potentialChunk.endIndex, offsetBy: -lookaheadMargin)
        let searchRange = searchStart..<potentialChunk.endIndex

        if let lastSentenceEnd = potentialChunk.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?"), options: .backwards, range: searchRange)?.upperBound {
            splitIdx = potentialChunk.distance(from: potentialChunk.startIndex, to: lastSentenceEnd)
        } else if let lastComma = potentialChunk.rangeOfCharacter(from: CharacterSet(charactersIn: ","), options: .backwards, range: searchRange)?.upperBound {
            splitIdx = potentialChunk.distance(from: potentialChunk.startIndex, to: lastComma)
        } else if let lastSpace = potentialChunk.rangeOfCharacter(from: .whitespaces, options: .backwards, range: searchRange)?.upperBound {
            let distance = potentialChunk.distance(from: potentialChunk.startIndex, to: lastSpace)
            if distance > 1 {
                splitIdx = distance
            }
        }

        if splitIdx < scaledMin && !ttsState.llmFinished {
            return 0
        }
        ttsState.previousChunkSize = splitIdx
        return splitIdx
    }

    func findNextTTSChunk() -> Int {
        let maxSetting = settingsService.maxTTSChunkLength
        return nextChunkLength(baseMin: baseMinChunkLength, maxCap: maxSetting, growth: ttsChunkGrowthFactor)
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

        // Stop listening/VAD before playing TTS (prevents mic from picking up TTS audio)
        if isListening {
            stopListeningCleanup()
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
    
    func fetchOpenAITTSAudio(
        text: String,
        instruction: String?,
        useProxy: Bool,
        apiKey: String?
    ) async throws -> Data? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("Attempted to synthesize empty text.")
            return nil
        }

        let payload = OpenAITTSRequest(
            model: settingsService.openAITTSModel,
            input: text,
            voice: settingsService.openAITTSVoice,
            response_format: settingsService.openAITTSFormat,
            instructions: instruction
        )

        let payloadData = try JSONEncoder().encode(payload)

        let request: URLRequest
        if useProxy {
            // Route through proxy
            request = try await proxyService.makeProxiedRequest(
                provider: .openai,
                endpoint: "https://api.openai.com/v1/audio/speech",
                method: "POST",
                headers: ["Content-Type": "application/json"],
                bodyData: payloadData
            )
        } else {
            // Direct call
            guard let apiKey, !apiKey.isEmpty else {
                throw LlmError.apiKeyMissing(provider: "OpenAI")
            }
            guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
                throw LlmError.invalidURL
            }

            var directRequest = URLRequest(url: url)
            directRequest.httpMethod = "POST"
            directRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
            directRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            directRequest.httpBody = payloadData
            request = directRequest
        }
        
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

    func fetchReplicateTTSAudio(
        text: String,
        voice: String,
        speed: Double
    ) async throws -> Data? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("Attempted to synthesize empty text.")
            return nil
        }

        let input = ReplicateTTSInput(
            text: text,
            voice: voice,
            speed: speed
        )

        let payload = ReplicateTTSRequest(
            version: "f559560eb822dc509045f3921a1921234918b91739db4bf3daab2169b71c7a13",
            input: input
        )

        let payloadData = try JSONEncoder().encode(payload)

        // Check if we should use proxy or direct API
        let useProxy = proxyService.shouldUseProxy(for: .replicate)
        let trimmedKey = settingsService.replicateAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replicateHeaders = [
            "Content-Type": "application/json",
            "Prefer": "wait"
        ]
        let request: URLRequest

        if useProxy {
            // Route through proxy - Prefer: wait blocks until completion when possible
            request = try await proxyService.makeProxiedRequest(
                provider: .replicate,
                endpoint: "https://api.replicate.com/v1/predictions",
                method: "POST",
                headers: replicateHeaders,
                bodyData: payloadData
            )
        } else {
            // Direct API call with user's key
            guard let apiKey = trimmedKey, !apiKey.isEmpty else {
                throw LlmError.apiKeyMissing(provider: "Replicate")
            }
            guard let url = URL(string: "https://api.replicate.com/v1/predictions") else {
                throw LlmError.invalidURL
            }
            var directRequest = URLRequest(url: url)
            directRequest.httpMethod = "POST"
            directRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            replicateHeaders.forEach { directRequest.addValue($0.value, forHTTPHeaderField: $0.key) }
            directRequest.httpBody = payloadData
            request = directRequest
        }

        let maxAttempts = 3
        var attempt = 1
        let decoder = JSONDecoder()

        while true {
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await urlSession.data(for: request) }
            catch { throw LlmError.networkError(error) }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LlmError.networkError(URLError(.badServerResponse))
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 429, attempt < maxAttempts {
                    let retryAfterSeconds = (try? decoder.decode(ReplicateRateLimitResponse.self, from: data).retry_after) ?? 1
                    let sanitizedRetryAfter = max(0, retryAfterSeconds)

                    if Task.isCancelled {
                        throw CancellationError()
                    }

                    logger.warning("Replicate TTS rate limited. Retrying in \(sanitizedRetryAfter)s (attempt \(attempt)/\(maxAttempts)).")

                    let maxSleepSeconds = Double(UInt64.max) / 1_000_000_000
                    let clampedSleepSeconds = min(sanitizedRetryAfter, maxSleepSeconds)
                    let sleepNanoseconds = UInt64(clampedSleepSeconds * 1_000_000_000)
                    if sleepNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: sleepNanoseconds)
                    }

                    attempt += 1
                    continue
                }

                var errorDetails = ""
                if let errorString = String(data: data, encoding: .utf8) { errorDetails = errorString }
                logger.error("🚨 Replicate TTS Error: Status \(httpResponse.statusCode). Body: \(errorDetails)")
                throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorDetails)
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if !contentType.contains("application/json") {
                let body = String(data: data, encoding: .utf8)
                throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: body)
            }

            // Parse response - with Prefer: wait, this often completes immediately
            let prediction = try decodeReplicatePrediction(from: data)

            // Check if already completed (thanks to Prefer: wait header)
            let audioURL: String?
            let status = prediction.status.lowercased()
            if isReplicateSuccessStatus(status), let output = prediction.outputURL {
                audioURL = output
                logger.info("Replicate TTS completed immediately (no polling needed)")
            } else if isReplicateFailureStatus(status) {
                throw LlmError.ttsError("Replicate prediction \(status): \(prediction.error ?? "Unknown error")")
            } else {
                // Still processing, fall back to polling
                logger.info("Replicate TTS still processing, falling back to polling")
                audioURL = try await pollReplicatePrediction(
                    id: prediction.id,
                    useProxy: useProxy,
                    apiKey: useProxy ? nil : trimmedKey
                )
            }

            guard let audioURL = audioURL else {
                logger.warning("Replicate prediction completed but no output URL received.")
                return nil
            }

            // Download the audio file
            guard let url = URL(string: audioURL) else {
                throw LlmError.invalidURL
            }

            let (audioData, audioResponse) = try await urlSession.data(from: url)
            guard let httpAudioResponse = audioResponse as? HTTPURLResponse,
                  (200...299).contains(httpAudioResponse.statusCode) else {
                throw LlmError.invalidResponse(statusCode: (audioResponse as? HTTPURLResponse)?.statusCode ?? -1, body: nil)
            }

            guard !audioData.isEmpty else {
                logger.warning("Received empty audio data from Replicate TTS API.")
                return nil
            }

            return audioData
        }
    }

    private struct ReplicateRateLimitResponse: Decodable {
        let retry_after: TimeInterval
    }

    private func pollReplicatePrediction(
        id: String,
        useProxy: Bool,
        apiKey: String?,
        maxAttempts: Int = 30
    ) async throws -> String? {
        // Only called if Prefer: wait timed out, so job is already running
        for attempt in 1...maxAttempts {
            // Don't wait on first attempt (job already started), then wait 500ms between polls
            if attempt > 1 {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }

            let request: URLRequest
            if useProxy {
                request = try await proxyService.makeProxiedRequest(
                    provider: .replicate,
                    endpoint: "https://api.replicate.com/v1/predictions/\(id)",
                    method: "GET",
                    headers: ["Content-Type": "application/json"],
                    bodyData: nil
                )
            } else {
                guard let apiKey, !apiKey.isEmpty else {
                    throw LlmError.apiKeyMissing(provider: "Replicate")
                }
                guard let url = URL(string: "https://api.replicate.com/v1/predictions/\(id)") else {
                    throw LlmError.invalidURL
                }
                var directRequest = URLRequest(url: url)
                directRequest.httpMethod = "GET"
                directRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
                directRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request = directRequest
            }

            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw LlmError.invalidResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: nil)
            }

            let prediction = try decodeReplicatePrediction(from: data)
            let status = prediction.status.lowercased()

            if isReplicateSuccessStatus(status), let output = prediction.outputURL {
                return output
            } else if isReplicateSuccessStatus(status) {
                throw LlmError.ttsError("Replicate prediction succeeded but returned no output URL")
            } else if isReplicateFailureStatus(status) {
                throw LlmError.ttsError("Replicate prediction \(status): \(prediction.error ?? "Unknown error")")
            }

            logger.debug("Replicate prediction \(id) status: \(prediction.status). Attempt \(attempt)/\(maxAttempts)")
        }

        throw LlmError.ttsError("Replicate prediction timed out after \(maxAttempts) attempts")
    }

    private func decodeReplicatePrediction(from data: Data) throws -> ReplicateTTSResponse {
        do {
            return try JSONDecoder().decode(ReplicateTTSResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            logger.error("Failed to decode Replicate prediction: \(body)")
            throw LlmError.responseDecodingError(error)
        }
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
