// ChatViewModel.swift
import Foundation
import Combine
import OSLog
import SwiftUI // Import SwiftUI for @Published

@MainActor
class ChatViewModel: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")

    // --- UI State ---
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var isProcessing: Bool = false // Combined state: Processing LLM OR Speaking
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
    private let settingsService: SettingsService // Might be needed for future settings access

    private var cancellables = Set<AnyCancellable>()

    init(audioService: AudioService, chatService: ChatService, settingsService: SettingsService) {
        self.audioService = audioService
        self.chatService = chatService
        self.settingsService = settingsService
        logger.info("ChatViewModel initialized.")

        // --- Subscribe to Service Publishers ---

        // Audio Service States
        audioService.$isListening
            .receive(on: DispatchQueue.main)
            .sink { [weak self] listening in
                self?.isListening = listening
                self?.updateProcessingState()
            }
            .store(in: &cancellables)

        audioService.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speaking in
                guard let self = self else { return }
                self.isSpeaking = speaking
                self.updateProcessingState()

                // --- Restore automatic listening transition ---
                // When speaking stops AND LLM processing is also finished,
                // AND we are not already listening, automatically start listening again.
                if !speaking && !self.chatService.isProcessingLLM && !self.isListening {
                    self.logger.info("Speaking finished, automatically starting listening.")
                    // do not add a delay
                    Task {
                        // Re-check state in case something changed during the delay
                        if !self.isSpeaking && !self.chatService.isProcessingLLM && !self.isListening {
                           self.startListening()
                        }
                    }
                }
                // --- End restored transition ---
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
            .sink { [weak self] transcription in
                 guard let self = self else { return }
                 self.logger.info("ViewModel received transcription: '\(transcription)'")
                 // Immediately start processing with ChatService
                 self.chatService.processTranscription(transcription, provider: self.selectedProvider)
            }
            .store(in: &cancellables)

        audioService.errorSubject
             .receive(on: DispatchQueue.main)
             .sink { [weak self] error in
                 self?.logger.error("ViewModel received AudioService error: \(error.localizedDescription)")
                 self?.handleError(error)
                 // Decide if state needs reset on audio error
                 self?.resetToIdleState() // Go back to idle on audio errors
             }
             .store(in: &cancellables)


        // Chat Service States
        chatService.$isProcessingLLM
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processing in
                 self?.updateProcessingState() // Update combined processing state
            }
            .store(in: &cancellables)

        chatService.$messages
            .receive(on: DispatchQueue.main)
             // Use assign directly if ChatService is the source of truth
             .assign(to: &$messages)
//            .sink { [weak self] newMessages in
//                self?.messages = newMessages // Update local messages copy
//            }
//            .store(in: &cancellables)

        // Chat Service Events
        chatService.llmChunkSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chunk in
                 // Send chunk to AudioService for TTS
                 self?.audioService.processTTSChunk(textChunk: chunk, isLastChunk: false)
            }
            .store(in: &cancellables)

        chatService.llmCompleteSubject
             .receive(on: DispatchQueue.main)
             .sink { [weak self] in
                 self?.logger.info("ViewModel received LLM completion signal.")
                 // Signal to AudioService that the text stream is complete
                 self?.audioService.processTTSChunk(textChunk: "", isLastChunk: true)
                 // State update (isProcessing) happens via isProcessingLLM and isSpeaking publishers
             }
             .store(in: &cancellables)

        chatService.llmErrorSubject
             .receive(on: DispatchQueue.main)
             .sink { [weak self] error in
                 self?.logger.error("ViewModel received ChatService error: \(error.localizedDescription)")
                 self?.handleError(error)
                  // Signal to AudioService that the text stream is complete (with error)
                  self?.audioService.processTTSChunk(textChunk: "", isLastChunk: true)
                  // Go back to idle state on LLM errors? Or rely on isProcessing flag?
                 self?.resetToIdleState() // Go back to idle on LLM errors
             }
             .store(in: &cancellables)

        // Forward initial TTS Rate to Audio Service
        audioService.ttsRate = self.ttsRate
    }

    private func updateProcessingState() {
        // Considered processing if LLM is working OR TTS is speaking
        let newProcessingState = chatService.isProcessingLLM || audioService.isSpeaking
        if isProcessing != newProcessingState {
            isProcessing = newProcessingState
            logger.info("Processing state updated: \(self.isProcessing) (LLM: \(self.chatService.isProcessingLLM), Speaking: \(self.audioService.isSpeaking))")
        }
    }

    // MARK: - User Actions
    func cycleState() {
        logger.debug("cycleState called. Current state: Listening=\(self.isListening), Processing=\(self.isProcessing), Speaking=\(self.isSpeaking)")
        if isListening {
            // User tapped while listening: Reset listening, go to idle (grey)
             logger.info("Cycle: Listening -> Idle")
            audioService.resetListening() // Ask audio service to stop/reset
        } else if isProcessing || isSpeaking { // isProcessing covers both LLM and Speaking now
            // User tapped while processing/speaking: Cancel and immediately start listening
             logger.info("Cycle: Processing/Speaking -> Cancel -> Listening")
            cancelProcessingAndSpeaking()
             // Start listening immediately AFTER cancellation completes
             Task { // Ensure cancellation logic runs first
                  await Task.yield() // Allow state updates from cancellation to propagate
                  if !self.isListening && !self.isProcessing && !self.isSpeaking { // Double check state after cancellation
                      self.startListening()
                  } else {
                      logger.warning("State did not allow immediate listening after cancellation.")
                  }
             }
        } else {
            // User tapped while idle (grey): Start listening
            logger.info("Cycle: Idle -> Listening")
            startListening()
        }
    }

    // Now primarily asks services to stop their activities
    func cancelProcessingAndSpeaking() {
        logger.notice("⏹️ Cancel requested by user during processing/speaking.")
        chatService.cancelProcessing() // Ask chat service to cancel LLM fetch
        audioService.stopSpeaking()   // Ask audio service to stop TTS fetch/playback
        // State updates (isProcessingLLM, isSpeaking, isProcessing) will flow via publishers
    }

    // Starts listening via the AudioService
    func startListening() {
        // Guard against starting if not in a valid idle state OR if already listening
        // This guard needs to be slightly relaxed to allow the automatic transition
        guard !isListening else { // Only prevent if *already* listening
             // If already listening (e.g., manual trigger racing with auto-trigger), just log and do nothing.
             logger.info("StartListening called but already listening.")
             return
        }
         guard !isProcessing && !isSpeaking else { // Still prevent starting if processing/speaking
             logger.warning("Attempted to start listening while processing or speaking. State: L=\(self.isListening), P=\(self.isProcessing), S=\(self.isSpeaking)")
             return
         }
        // Clear any previous error message when starting fresh
        lastError = nil
        logger.info("Requesting AudioService to start listening.")
        audioService.startListening() // isListening state will be updated via publisher
    }

    // Resets to a clean idle state
    func resetToIdleState() {
         logger.info("Resetting to Idle State.")
         // Ensure all activities are stopped
         if chatService.isProcessingLLM { chatService.cancelProcessing() }
         if audioService.isSpeaking { audioService.stopSpeaking() }
         if audioService.isListening { audioService.resetListening() }
         // States should update via publishers, but ensure flags are false
         Task {
             await Task.yield() // Allow time for state updates
             self.isListening = false
             self.isSpeaking = false
             self.isProcessing = false
             self.listeningAudioLevel = -50.0
             self.ttsOutputLevel = 0.0
         }
     }

    // MARK: - Error Handling
    private func handleError(_ error: Error) {
        // Display a user-friendly message (optional)
        lastError = error.localizedDescription

        // Potentially add more specific error handling based on error type
        if let llmError = error as? LlmError {
            switch llmError {
            case .apiKeyMissing(let provider):
                lastError = "\(provider) API Key is missing or invalid."
            default:
                lastError = "An error occurred: \(llmError.localizedDescription)"
            }
        } else if let audioError = error as? AudioService.AudioError {
             lastError = "Audio error: \(audioError.localizedDescription)"
        } else {
             lastError = "An unexpected error occurred."
        }
    }

    // MARK: - Lifecycle
    func cleanupOnDisappear() {
        logger.info("ViewModel cleanupOnDisappear called.")
        // Ask services to clean up their resources
        audioService.cleanupOnDisappear()
        chatService.cancelProcessing() // Ensure LLM task is cancelled if view disappears
        cancellables.forEach { $0.cancel() } // Cancel Combine subscriptions
    }

    deinit {
        // cleanup done by owner
        logger.info("ChatViewModel deinit.")
    }
}
