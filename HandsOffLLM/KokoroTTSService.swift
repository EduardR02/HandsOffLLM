// KokoroTTSService.swift
import Foundation
import OSLog
import FluidAudio

/// Wrapper service for Kokoro TTS using FluidAudio
@MainActor
class KokoroTTSService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "KokoroTTS")
    private var ttsManager: KokoroTTSManager?

    init() {
        // Initialize TTS manager
        ttsManager = KokoroTTSManager()
    }

    /// Prepares the Kokoro pipeline so the first utterance plays without warm-up lag.
    /// - Parameters:
    ///   - voice: Optional Kokoro voice identifier to prime embeddings for.
    ///   - speakerId: Optional speaker variant (defaults to zero).
    func prepare(voice: String? = nil, speakerId: Int = 0) async throws {
        guard let manager = ttsManager else {
            logger.error("❌ Kokoro TTS manager not initialized during prepare()")
            throw LlmError.ttsError("TTS manager not initialized")
        }

        do {
            try await manager.prepare(voice: voice, speakerId: speakerId)
            let label = voice ?? "default"
            logger.notice("🔥 Kokoro TTS warmed (voice: \(label, privacy: .public))")
        } catch {
            logger.error("❌ Kokoro TTS warm-up failed: \(error.localizedDescription)")
            throw LlmError.ttsError("Kokoro warm-up failed: \(error.localizedDescription)")
        }
    }

    /// Synthesize text to audio using Kokoro TTS
    /// - Parameters:
    ///   - text: Text to synthesize.
    ///   - voice: Optional Kokoro voice identifier. Defaults to the manager's active voice.
    ///   - speed: Playback speed multiplier applied at synthesis time (1.0 = normal pitch).
    /// - Returns: Audio data in WAV format, or nil if synthesis failed
    func synthesize(text: String, voice: String? = nil, speed: Float = 1.0) async throws -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.warning("Attempted to synthesize empty text")
            return nil
        }

        let voiceLabel = voice ?? "default"
        logger.info("🎙️ Synthesizing \(trimmed.count) characters with Kokoro TTS voice \(voiceLabel, privacy: .public) at \(speed)x speed")

        guard let manager = ttsManager else {
            logger.error("❌ Kokoro TTS manager not initialized")
            throw LlmError.ttsError("TTS manager not initialized")
        }

        let variantPreference: ModelNames.TTS.Variant = .fifteenSecond
        logger.debug("Using Kokoro variant 15s for chunk.")

        do {
            let audioData = try await manager.synthesize(
                text: trimmed,
                voice: voice,
                speed: speed,
                variant: variantPreference
            )
            logger.info("✅ Kokoro TTS synthesis complete: \(audioData.count) bytes")
            return audioData
        } catch {
            logger.error("❌ Kokoro TTS synthesis failed: \(error.localizedDescription)")
            throw LlmError.ttsError("Kokoro synthesis failed: \(error.localizedDescription)")
        }
    }
}
