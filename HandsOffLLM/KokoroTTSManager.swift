import Foundation
@preconcurrency import FluidAudio
import OSLog

/// Serializes Kokoro TTS access so we only download and warm the models once.
actor KokoroTTSManager {
    private let logger: Logger
    private let ttsManager: TtSManager
    private let bootstrapVoice: String
    private var activeVoice: String
    private var initializationTask: Task<Void, Error>?

    init(defaultVoice: String = TtsConstants.recommendedVoice) {
        self.bootstrapVoice = defaultVoice
        self.activeVoice = defaultVoice
        let subsystem = Bundle.main.bundleIdentifier ?? "HandsOffLLM"
        self.logger = Logger(subsystem: subsystem, category: "KokoroTTSManager")
        self.ttsManager = TtSManager(defaultVoice: defaultVoice, defaultSpeakerId: 0)
    }

    /// Generate speech audio for the given text.
    /// - Parameters:
    ///   - text: Text to synthesize.
    ///   - voice: Optional Kokoro voice identifier (fallbacks to `defaultVoice`).
    ///   - speed: Playback speed multiplier (1.0 = normal).
    func synthesize(
        text: String,
        voice: String? = nil,
        speed: Float = 1.0,
        variant: ModelNames.TTS.Variant? = nil
    ) async throws -> Data {
        try await ensureInitialized()
        let resolvedVoice = (voice?.isEmpty == false) ? voice! : activeVoice

        do {
            let audio = try await ttsManager.synthesize(
                text: text,
                voice: resolvedVoice,
                voiceSpeed: speed,
                variantPreference: variant
            )
            activeVoice = resolvedVoice
            return audio
        } catch {
            logger.error("Kokoro synthesis failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Switches the active voice. Reuses the same model load but ensures embeddings exist.
    func updateVoice(_ voice: String, speakerId: Int = 0) async throws {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != activeVoice else { return }

        try await ensureInitialized()

        do {
            try await ttsManager.setDefaultVoice(trimmed, speakerId: speakerId)
            activeVoice = trimmed
            logger.info("Set Kokoro voice to \(trimmed, privacy: .public)")
        } catch {
            logger.error("Failed to switch Kokoro voice to \(trimmed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Ensures models are ready and optionally primes a voice before playback begins.
    func prepare(voice: String? = nil, speakerId: Int = 0) async throws {
        try await ensureInitialized()

        if let voice, !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, voice != activeVoice {
            try await updateVoice(voice, speakerId: speakerId)
        }
    }

    /// Ensures the underlying TTS manager has downloaded and loaded its models.
    private func ensureInitialized() async throws {
        if let task = initializationTask {
            return try await task.value
        }

        let task = Task {
            do {
                logger.notice("Preparing Kokoro TTS models…")
                let models = try await TtsModels.download(variants: [.fifteenSecond])
                let voicesToPreload = Set([self.bootstrapVoice, self.activeVoice])
                try await ttsManager.initialize(models: models, preloadVoices: voicesToPreload)
                try await ttsManager.setDefaultVoice(self.activeVoice)
                logger.notice("Kokoro TTS ready.")
            } catch {
                logger.error("Kokoro initialization failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        initializationTask = task

        do {
            try await task.value
        } catch {
            initializationTask = nil
            throw error
        }
    }
}
