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
    case error         // New error case
    // Consider adding an explicit .error state if needed for UI feedback
}

@MainActor
class ChatViewModel: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")
    
    // --- UI State ---
    @Published var state: ViewModelState = .idle // Single source of truth for UI state
    @Published var listeningAudioLevel: Float = -50.0
    @Published var ttsOutputLevel: Float = 0.0
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
    private let historyService: HistoryService
    
    private var cancellables = Set<AnyCancellable>()
    private var isProcessingLLM: Bool = false // Internal tracking
    private var isSpeaking: Bool = false     // Internal tracking
    private var isListening: Bool = false    // Internal tracking
    
    init(audioService: AudioService, chatService: ChatService, settingsService: SettingsService, historyService: HistoryService) {
        self.audioService = audioService
        self.chatService = chatService
        self.settingsService = settingsService
        self.historyService = historyService
        logger.info("ChatViewModel initialized.")
        
        // --- Subscribe to Service Publishers ---
        
        // Audio Service States
        audioService.$isListening
            .sink { [weak self] listening in self?.handleIsListeningUpdate(listening) }
            .store(in: &cancellables)
        
        audioService.$isSpeaking
            .sink { [weak self] speaking in self?.handleIsSpeakingUpdate(speaking) }
            .store(in: &cancellables)
        
        audioService.$listeningAudioLevel
            .assign(to: &$listeningAudioLevel)
        
        audioService.$ttsOutputLevel
            .assign(to: &$ttsOutputLevel)
        
        // Audio Service Events
        audioService.transcriptionSubject
            .sink { [weak self] transcription in
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
            .sink { [weak self] error in
                guard let self = self else { return }
                
                // Normal error handling path (if not user cancelling)
                self.logger.error("ViewModel received AudioService error: \(error.localizedDescription)")
                self.handleError(error) // Update lastError
                // Only reset if it wasn't handled as part of user cancellation
                self.resetToIdleState(attemptRestart: true)
            }
            .store(in: &cancellables)
        
        
        // Chat Service States
        chatService.$isProcessingLLM
            .sink { [weak self] processing in self?.handleIsProcessingLLMUpdate(processing) }
            .store(in: &cancellables)
        
        // Chat Service Events
        // Subscribe to LLM text chunks to drive TTS processing and saving
        chatService.llmChunkSubject
            .sink { [weak self] chunk in
                guard let self = self else { return }
                // Update TTS context for saving this message's audio
                if let convID = self.chatService.currentConversation?.id,
                   let msgID = self.chatService.currentConversation?.messages.last?.id {
                    self.audioService.setTTSContext(conversationID: convID, messageID: msgID)
                }
                // Process the text chunk for TTS
                self.audioService.processTTSChunk(textChunk: chunk, isLastChunk: false)
            }
            .store(in: &cancellables)
        
        chatService.llmCompleteSubject
            .sink { [weak self] in
                self?.logger.info("ViewModel received LLM completion signal.")
                self?.audioService.processTTSChunk(textChunk: "", isLastChunk: true)
            }
            .store(in: &cancellables)
        
        chatService.llmErrorSubject
            .sink { [weak self] error in
                self?.logger.error("ViewModel received ChatService error: \(error.localizedDescription)")
                self?.handleError(error)
                self?.audioService.processTTSChunk(textChunk: "", isLastChunk: true)
                self?.resetToIdleState(attemptRestart: true)
            }
            .store(in: &cancellables)
        
        // --- NEW: Subscribe to saved audio chunk paths ---
        audioService.ttsChunkSavedSubject
            .sink { [weak self] messageID, path in
                // Update the ChatService's currentConversation object
                self?.chatService.updateAudioPathInCurrentConversation(messageID: messageID, path: path)
            }
            .store(in: &cancellables)
        // --- END NEW ---
        
        // --- Initial State Transition: idle -> listening ---
        // Start listening shortly after initialization
        Task { @MainActor in
            if self.state == .idle {
                self.startListening()
            }
        }

        // New: apply default playback speed if set, then tell audioService
        if let defaultSpeed = settingsService.settings.selectedDefaultPlaybackSpeed {
            self.ttsRate = defaultSpeed
        }
        audioService.ttsRate = self.ttsRate

        // New: apply default API provider selection (fallback to saved model‑provider if unset)
        self.selectedProvider = settingsService.settings.selectedDefaultProvider
            ?? (settingsService.settings.selectedModelIdPerProvider.keys.first ?? .claude)
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
            // AudioService stopped listening (e.g., silence timeout).
            logger.info("Internal isListening became false. State remains \(String(describing: self.state)) (awaiting transcription or user action).")
            // If UI still expects listening, auto-restart
            if state == .listening {
                logger.info("Auto-restarting listening since state is .listening.")
                // Delay slightly to avoid immediate re-stop
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    self.startListening()
                }
            }
        }
        // else: No change needed (e.g., listening=true when already listening, listening=false when already not listening)
    }
    
    private func handleIsSpeakingUpdate(_ speaking: Bool) {
        let wasSpeaking = self.isSpeaking
        self.isSpeaking = speaking
        logger.debug("Internal isSpeaking updated: \(speaking)")
        
        // --- State Transition: processingLLM -> speakingTTS ---
        if speaking && !wasSpeaking && state == .processingLLM {
            updateState(.speakingTTS)
        }
        // --- State Transition: speakingTTS -> listening ---
        else if !speaking && wasSpeaking && state == .speakingTTS {
            logger.info("Speaking finished, scheduling automatic listening restart.")
            Task { @MainActor in
                // brief pause to let the TTS session tear down smoothly
                try? await Task.sleep(for: .milliseconds(50))
                self.startListening()
            }
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
    
    // --- NEW: Pause main activities ---
    func pauseMainActivities() {
        logger.info("⏸️ Pausing main activities (listening, processing, speaking) due to navigation.")
        // Stop listening first
        if audioService.isListening {
            audioService.resetListening() // This stops audio engine and tasks
        }
        // Cancel any ongoing LLM request (handles partial saves internally)
        if isProcessingLLM { // Check internal flag first
            chatService.cancelProcessing()
        }
        // Stop any ongoing TTS playback
        if audioService.isSpeaking {
            audioService.stopSpeaking() // Stops player and cancels fetch
        }
        // Explicitly set state to idle, as service updates might be async
        updateState(.idle)
        // Reset internal tracking flags as well for consistency
        self.isListening = false
        self.isProcessingLLM = false
        self.isSpeaking = false
        // Reset audio levels visually
        self.listeningAudioLevel = -50.0
        self.ttsOutputLevel = 0.0
    }
    // --- END NEW ---
    
    // MARK: - User Actions
    func cycleState() {
        switch state {
        case .listening:
            updateState(.idle)
            audioService.resetListening()
            
        case .speakingTTS, .processingLLM:
            cancelProcessingAndSpeaking()
            updateState(.listening)
            startListening()
            
        case .idle, .error:
            // on idle or after an error, just kick off listening
            lastError = nil
            startListening()
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
        guard !audioService.isListening else {
            logger.info("StartListening called but AudioService is already listening.")
            // Ensure UI state matches if audio service is already listening somehow
            if state == .idle { updateState(.listening) }
            return
        }
        
        lastError = nil
        logger.info("Requesting AudioService to start listening (Current state: \(String(describing: self.state))).")
        // Ensure chat context is ready before listening (might already be set)
        if chatService.activeConversationId == nil {
            logger.info("No active conversation context, resetting before listening.")
            chatService.resetConversationContext()
        }
        audioService.startListening()
        // State transition to .listening is handled by handleIsListeningUpdate
    }
    
    // Resets to a clean idle state
    func resetToIdleState(attemptRestart: Bool = false) {
        logger.info("Resetting to Idle State. Attempt restart: \(attemptRestart)")
        cancelProcessingAndSpeaking()
        if audioService.isListening { audioService.resetListening() }
        // Also reset the chat context to a new, fresh one
        chatService.resetConversationContext()
        
        updateState(.idle)
        self.isListening = false
        self.isSpeaking = false
        self.isProcessingLLM = false
        self.listeningAudioLevel = -50.0
        self.ttsOutputLevel = 0.0
        
        if attemptRestart {
            Task { @MainActor in
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
        updateState(.error) // Drive UI into "error" mode
    }
    
    // Method to trigger startup listening (if needed externally)
    func beginListeningOnStartup() {
        if state == .idle {
            logger.info("Triggering initial listening sequence.")
            startListening()
        }
    }
    
    // MARK: - History Interaction
    
    // Called from ChatDetailView's "Continue from here" button
    func loadConversationHistory(_ conversation: Conversation, upTo messageIndex: Int) {
        logger.info("Loading conversation \(conversation.id) up to index \(messageIndex)")
        cancelProcessingAndSpeaking() // Stop current LLM/TTS activity
        
        // --- CHANGE START ---
        // Always reset the audio service fully when loading history,
        // as we intend to start listening immediately after in ChatDetailView.
        // This ensures consistent cleanup regardless of the previous listening state.
        logger.info("Performing full AudioService reset before loading history.")
        audioService.resetListening() // Call reset unconditionally
        
        
        guard messageIndex >= 0 && messageIndex < conversation.messages.count else {
            logger.error("Invalid message index \(messageIndex) for conversation.")
            return
        }
        
        // Get messages up to the specified index (inclusive)
        let messagesToLoad = Array(conversation.messages.prefix(through: messageIndex))
        
        var audioPathsToLoad: [UUID: [String]]? = nil
        // Ensure we actually have the full parent conversation data from history service
        // Note: 'conversation' passed in might be stale if history changed; fetch fresh.
        if let fullParentConversation = historyService.conversations.first(where: { $0.id == conversation.id }) {
            if let parentAudioPaths = fullParentConversation.ttsAudioPaths {
                audioPathsToLoad = [:]
                for message in messagesToLoad {
                    // If the parent had audio for this message, copy the paths
                    if let paths = parentAudioPaths[message.id] {
                        audioPathsToLoad?[message.id] = paths
                    }
                }
                logger.info("Copied \(audioPathsToLoad?.count ?? 0) audio path entries from parent conversation.")
            }
        } else {
            logger.warning("Could not find full parent conversation \(conversation.id) in HistoryService to copy audio paths.")
        }
        
        // Start a *new* conversation context in ChatService, linking to the parent
        chatService.resetConversationContext(
            messagesToLoad: messagesToLoad,
            existingConversationId: nil, // Force new ID
            parentId: conversation.id, // Link to original
            initialAudioPaths: audioPathsToLoad // ← Pass the copied paths
        )
        
        // Reset UI state to idle initially...
        updateState(.idle)
    }
    
    // --- Helper for starting new chat ---
    func startNewChat() {
        logger.info("Starting new chat session.")
        resetToIdleState(attemptRestart: false) // Resets context and goes to Idle
        // User can then tap to start listening
    }
}
