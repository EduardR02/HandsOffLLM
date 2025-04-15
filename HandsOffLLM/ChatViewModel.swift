// ChatViewModel.swift
import Foundation
import Combine
import OSLog
import SwiftUI // Import SwiftUI for @Published

// Define the explicit states for the ViewModel OUTSIDE the class
enum ViewModelState: Equatable {
    case idle          // Not listening, not processing, not speaking (Grey circle)
    case listening     // Actively listening for user input (Blue circle)
    case processingLLM // Waiting for LLM response (Purple blur)
    case speakingTTS   // Playing back TTS audio (Green circle)
    // Consider adding an explicit .error state if needed for UI feedback
}

@MainActor
class ChatViewModel: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")

    // --- UI State ---
    @Published var state: ViewModelState = .idle // Single source of truth for UI state
    @Published var listeningAudioLevel: Float = -50.0
    @Published var ttsOutputLevel: Float = 0.0
    @Published var messages: [ChatMessage] = [] // Mirror ChatService messages
    @Published var selectedProvider: LLMProvider = .claude // Default provider
    @Published var ttsRate: Float = 2.0 { // Keep slider binding here for now
        didSet {
            audioService.ttsRate = ttsRate // Forward rate change to AudioService
        }
    }
    @Published var lastError: String? = nil // For displaying errors (optional)

    // --- Services ---
    private let audioService: AudioService
    private let chatService: ChatService
    private let settingsService: SettingsService

    private var cancellables = Set<AnyCancellable>()
    private var isProcessingLLM: Bool = false // Internal tracking
    private var isSpeaking: Bool = false     // Internal tracking
    private var isListening: Bool = false    // Internal tracking

    // Flag to indicate user-initiated cancellation
    private var isUserCancelling: Bool = false
    private var userCancelResetTask: Task<Void, Never>? = nil

    init(audioService: AudioService, chatService: ChatService, settingsService: SettingsService) {
        self.audioService = audioService
        self.chatService = chatService
        self.settingsService = settingsService
        logger.info("ChatViewModel initialized.")

        // --- Subscribe to Service Publishers ---

        // Audio Service States
        audioService.$isListening
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                 if case .failure(let error) = completion {
                     self?.logger.error("AudioService isListening publisher completed with error: \(error.localizedDescription)")
                 }
            }) { [weak self] listening in
                self?.handleIsListeningUpdate(listening)
            }
            .store(in: &cancellables)

        audioService.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                 if case .failure(let error) = completion {
                     self?.logger.error("AudioService isSpeaking publisher completed with error: \(error.localizedDescription)")
                 }
            }) { [weak self] speaking in
                self?.handleIsSpeakingUpdate(speaking)
            }
            .store(in: &cancellables)

        audioService.$listeningAudioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$listeningAudioLevel)

        audioService.$ttsOutputLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$ttsOutputLevel)

        // Audio Service Events
        audioService.transcriptionSubject
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                if case .failure(let error) = completion {
                     self?.logger.error("AudioService transcriptionSubject completed with error: \(error.localizedDescription)")
                 }
            }) { [weak self] transcription in
                 self?.logger.info("ViewModel received transcription: '\(transcription)'")
                 if let self = self {
                     if self.state == .listening {
                         self.updateState(.processingLLM)
                         self.chatService.processTranscription(transcription, provider: self.selectedProvider)
                     } else {
                        self.logger.warning("Received transcription but not in listening state (\(String(describing: self.state))). Ignoring.")
                     }
                 }
            }
            .store(in: &cancellables)

        audioService.errorSubject
             .receive(on: DispatchQueue.main)
             .sink(receiveCompletion: { [weak self] completion in
                 if case .failure(let error) = completion {
                     self?.logger.error("AudioService errorSubject completed with error: \(error.localizedDescription)")
                 }
             }) { [weak self] error in
                 guard let self = self else { return }

                 // Check if this error occurred during a user cancellation sequence
                 if self.isUserCancelling {
                     // Check if it's specifically a cancellation error (optional but good practice)
                     let isCancellationError = (error as? URLError)?.code == .cancelled || error.localizedDescription.lowercased().contains("cancel")

                     if isCancellationError {
                         self.logger.info("Ignoring expected AudioService cancellation error during user action.")
                         // Reset the flag immediately since the expected error arrived
                         self.isUserCancelling = false
                         self.userCancelResetTask?.cancel() // Cancel the fallback reset task
                         self.userCancelResetTask = nil
                         // DO NOT reset state here
                         return // Stop further processing of this error
                     } else {
                         self.logger.warning("Received non-cancellation error during user cancellation window: \(error.localizedDescription)")
                         // Proceed with normal error handling if it wasn't the expected cancellation error
                     }
                 }

                 // Normal error handling path (if not user cancelling)
                 self.logger.error("ViewModel received AudioService error: \(error.localizedDescription)")
                 self.handleError(error) // Update lastError
                 // Only reset if it wasn't handled as part of user cancellation
                 self.resetToIdleState(attemptRestart: true)
             }
             .store(in: &cancellables)


        // Chat Service States
        chatService.$isProcessingLLM
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                 if case .failure(let error) = completion {
                     self?.logger.error("ChatService isProcessingLLM publisher completed with error: \(error.localizedDescription)")
                 }
            }) { [weak self] processing in
                self?.handleIsProcessingLLMUpdate(processing)
            }
            .store(in: &cancellables)

        chatService.$messages
            .receive(on: DispatchQueue.main)
             .assign(to: &$messages) // Use assign directly

        // Chat Service Events
        chatService.llmChunkSubject
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] completion in
                 if case .failure(let error) = completion {
                    self?.logger.error("ChatService llmChunkSubject completed with error: \(error.localizedDescription)")
                 }
            }) { [weak self] chunk in
                 self?.audioService.processTTSChunk(textChunk: chunk, isLastChunk: false)
            }
            .store(in: &cancellables)

        chatService.llmCompleteSubject
             .receive(on: DispatchQueue.main)
             .sink(receiveCompletion: { [weak self] completion in
                 if case .failure(let error) = completion {
                     self?.logger.error("ChatService llmCompleteSubject completed with error: \(error.localizedDescription)")
                 }
             }) { [weak self] in
                 self?.logger.info("ViewModel received LLM completion signal.")
                 self?.audioService.processTTSChunk(textChunk: "", isLastChunk: true)
             }
             .store(in: &cancellables)

        chatService.llmErrorSubject
             .receive(on: DispatchQueue.main)
             .sink(receiveCompletion: { [weak self] completion in
                 if case .failure(let error) = completion {
                     self?.logger.error("ChatService llmErrorSubject completed with error: \(error.localizedDescription)")
                 }
             }) { [weak self] error in
                 self?.logger.error("ViewModel received ChatService error: \(error.localizedDescription)")
                 self?.handleError(error)
                  self?.audioService.processTTSChunk(textChunk: "", isLastChunk: true)
                  self?.resetToIdleState(attemptRestart: true)
             }
             .store(in: &cancellables)

        // Forward initial TTS Rate to Audio Service
        audioService.ttsRate = self.ttsRate

        // --- Initial State Transition: idle -> listening ---
        // Start listening shortly after initialization
        Task { @MainActor in
             try? await Task.sleep(for: .milliseconds(100)) // Small delay allow UI to settle
             if self.state == .idle {
                 self.startListening()
             }
        }
    }

    // MARK: - State Update Helpers

    private func updateState(_ newState: ViewModelState) {
        guard state != newState else { return }
        let oldState = state
        state = newState
        logger.info("State Transition: \(String(describing: oldState)) -> \(String(describing: newState))")
    }

    private func handleIsListeningUpdate(_ listening: Bool) {
        let wasListening = self.isListening // Track previous internal state for logging/edge cases
        self.isListening = listening
        logger.debug("Internal isListening updated: \(listening)")

        // If listening STARTS successfully, update state to .listening
        // This can happen from .idle (user tap/initial start) or after .speakingTTS completes
        if listening && !wasListening && (state == .idle || state == .speakingTTS) {
            updateState(.listening)
        }
        // If listening STOPS...
        else if !listening && wasListening {
            // *** REMOVED THE TRANSITION TO IDLE HERE ***
            // When listening stops normally after speech detection, AudioService sets isListening=false
            // *before* sending the transcription. We MUST wait for the transcription subject
            // to trigger the transition to .processingLLM.
            // Transitioning to .idle here would cause the transcription to be ignored.
            // If listening stops for other reasons (e.g., VAD timeout *without* transcription, error),
            // the state might remain .listening visually until the user taps, an error occurs, or a new cycle starts.
            // This is less disruptive than breaking the main flow.
            logger.info("Internal isListening became false. State remains \(String(describing: self.state)) (awaiting transcription or user action).")
        }
        // else: No change needed (e.g., listening=true when already listening, listening=false when already not listening)
    }

    private func handleIsSpeakingUpdate(_ speaking: Bool) {
         let wasSpeaking = self.isSpeaking
         self.isSpeaking = speaking
         logger.debug("Internal isSpeaking updated: \(speaking)")

         // --- State Transition: processingLLM -> speakingTTS ---
         // This is the correct place for this transition.
         if speaking && !wasSpeaking && state == .processingLLM {
             updateState(.speakingTTS)
         }
         // --- State Transition: speakingTTS -> listening ---
         else if !speaking && wasSpeaking && state == .speakingTTS {
             // TTS finished, automatically start listening again
             logger.info("Speaking finished, attempting to automatically start listening.")
             // Reset internal flags before starting? isProcessingLLM should already be false if LLM completed normally.
             // self.isProcessingLLM = false // Probably not needed here
             startListening() // Directly attempt to start listening
         }
         // --- Handle case where TTS finishes WITHOUT ever starting ---
         // This might happen if the LLM response was empty or TTS failed immediately.
         else if !speaking && wasSpeaking == false && state == .processingLLM {
             // If speaking becomes false (or never became true) and we are still in processingLLM,
             // and the LLM itself is also done, it means TTS finished/failed without playback.
             // We should transition back to listening.
             if !self.isProcessingLLM {
                 logger.warning("TTS completed/failed without starting playback while in processingLLM state. Transitioning to listening.")
                 // Don't reset completely, just try to go back to listening.
                 startListening()
             } else {
                 // This case is less likely - isSpeaking becomes false while still processing LLM? Maybe an early TTS error.
                 logger.warning("isSpeaking became false while still processing LLM and in processingLLM state. Waiting for LLM completion.")
             }
         }
         else if !speaking && wasSpeaking && state == .listening {
             // This can happen if user cancels TTS (cycleState: speakingTTS -> cancel -> listening)
             logger.info("Speaking stopped while transitioning to listening state (\(String(describing: self.state))) (expected after cancel).")
         }
     }

    private func handleIsProcessingLLMUpdate(_ processing: Bool) {
        self.isProcessingLLM = processing
        logger.debug("Internal isProcessingLLM updated: \(processing)")

        // State transition (listening -> processingLLM) is handled by transcriptionSubject
        // State transition (processingLLM -> speakingTTS) is handled by handleIsSpeakingUpdate

        // *** REMOVE THE PREMATURE RESET ***
        // We should NOT reset just because LLM finished before TTS started playing.
        // The state should remain .processingLLM, waiting for isSpeaking to become true.
        /*
        if !processing && state == .processingLLM && !self.isSpeaking {
            // OLD LOGIC (REMOVED):
            // logger.warning("LLM processing finished but TTS never started. State: \(String(describing: self.state)). Resetting.")
            // resetToIdleState(attemptRestart: true)
        }
        */
        // If LLM finishes processing, we just update the internal flag.
        // The state machine waits for isSpeaking changes or errors.
    }

    // MARK: - User Actions
    func cycleState() {
        logger.debug("cycleState called. Current state: \(String(describing: self.state))")

        // Cancel any pending flag reset task from a previous cycle
        userCancelResetTask?.cancel()
        userCancelResetTask = nil

        switch state {
        case .listening:
            logger.info("Cycle: Listening -> Idle")
            updateState(.idle)
            audioService.resetListening()

        case .speakingTTS:
            logger.info("Cycle: Speaking -> Cancel -> Listening")
            // --- Indicate User Cancellation ---
            isUserCancelling = true
            // Schedule a task to reset the flag after a delay, in case the error doesn't arrive
            userCancelResetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if self.isUserCancelling { // Check if flag wasn't reset by error handler
                    logger.info("Resetting isUserCancelling flag after timeout.")
                    self.isUserCancelling = false
                }
            }
            // --- End Indication ---
            audioService.stopSpeaking() // -> This might trigger the "cancelled" error
            chatService.cancelProcessing() // Less likely to cause issues here
            updateState(.listening) // Immediate UI update
            startListening() // Start listening engine

        case .idle:
            logger.info("Cycle: Idle -> Listening")
            startListening()

        case .processingLLM:
            logger.info("Cycle: Processing LLM -> Cancel -> Listening")
            // --- Indicate User Cancellation ---
            isUserCancelling = true
            // Schedule flag reset task
            userCancelResetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if self.isUserCancelling {
                    logger.info("Resetting isUserCancelling flag after timeout.")
                    self.isUserCancelling = false
                }
            }
            // --- End Indication ---
            chatService.cancelProcessing() // -> Might trigger error? Less likely via subject
            audioService.stopSpeaking()   // -> Might trigger "cancelled" error if TTS started buffering
            updateState(.listening) // Immediate UI update
            startListening() // Start listening engine
        }
    }

    // Cancels ongoing operations - now mostly handled within cycleState or resetToIdleState
    func cancelProcessingAndSpeaking() {
        logger.notice("⏹️ Cancel requested (likely internal or reset).")
        chatService.cancelProcessing()
        audioService.stopSpeaking()
    }

    // Starts listening via the AudioService
    func startListening() {
        guard state == .idle || state == .speakingTTS || state == .listening else {
            logger.warning("StartListening called in unexpected state: \(String(describing: self.state)). Preventing.")
            return
        }
         guard !self.isListening else {
             logger.info("StartListening called but AudioService is already listening.")
             return
         }
        lastError = nil
        logger.info("Requesting AudioService to start listening (Current state: \(String(describing: self.state))).")
        audioService.startListening()
    }

    // Resets to a clean idle state
    func resetToIdleState(attemptRestart: Bool = false) {
         logger.info("Resetting to Idle State. Attempt restart: \(attemptRestart)")
         cancelProcessingAndSpeaking()
         if audioService.isListening { audioService.resetListening() }

         updateState(.idle)
         self.isListening = false
         self.isSpeaking = false
         self.isProcessingLLM = false
         self.listeningAudioLevel = -50.0
         self.ttsOutputLevel = 0.0

         if attemptRestart {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                logger.info("Attempting automatic restart after reset.")
                self.startListening()
            }
        }
     }

    // MARK: - Error Handling
    private func handleError(_ error: Error) {
        lastError = error.localizedDescription

        if let llmError = error as? LlmError {
            switch llmError {
            case .apiKeyMissing(let provider):
                lastError = "\(provider) API Key is missing or invalid."
            default:
                lastError = "An LLM error occurred: \(llmError.localizedDescription)"
            }
        } else if let audioError = error as? AudioService.AudioError {
             lastError = "An audio error occurred: \(audioError.localizedDescription)"
        } else {
            lastError = "An unexpected error occurred: \(error.localizedDescription)"
        }
    }

    // Method to trigger startup listening (if needed externally)
    func beginListeningOnStartup() {
        if state == .idle {
            logger.info("Triggering initial listening sequence.")
            startListening()
        }
    }
}
