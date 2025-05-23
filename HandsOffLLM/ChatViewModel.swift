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
    case fetchingTTS   // Waiting on TTS fetch
    case speakingTTS   // Playing back TTS audio (Green circle)
    case error         // New error case
}

@MainActor
class ChatViewModel: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")
    
    // --- UI State ---
    @Published var state: ViewModelState = .idle // Single source of truth for UI state
    @Published var selectedProvider: LLMProvider = .claude // Default provider
    @Published var ttsRate: Float = 2.0 { // Keep slider binding here for now
        didSet {
            if oldValue != ttsRate {
                audioService.ttsRate = ttsRate // Forward rate change to AudioService
            }
        }
    }
    @Published var lastError: String? = nil // For displaying errors (optional)
    
    // --- Services ---
    private let audioService: AudioService
    private let chatService: ChatService
    private let settingsService: SettingsService
    private let historyService: HistoryService
    
    private var cancellables = Set<AnyCancellable>()
    
    init(audioService: AudioService, chatService: ChatService, settingsService: SettingsService, historyService: HistoryService) {
        self.audioService = audioService
        self.chatService = chatService
        self.settingsService = settingsService
        self.historyService = historyService
        logger.info("ChatViewModel initialized.")
        
        // Audio Service Events
        // Transcription → only forwards to ChatService (state flip happens in CombineLatest)
        audioService.transcriptionSubject
            .sink { [weak self] transcription in
                guard let self = self, self.state == .listening else { return }
                self.logger.info("Received transcription: '\(transcription)'")
                self.chatService.processTranscription(transcription, provider: self.selectedProvider)
            }
            .store(in: &cancellables)
        
        audioService.errorSubject
            .sink { [weak self] error in
                guard let self = self else { return }
                self.logger.error("AudioService error: \(error.localizedDescription)")
                self.handleError(error)
                self.cancelProcessingAndSpeaking()
                self.audioService.startListening()
            }
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
                guard let self = self else { return }
                self.logger.info("LLM complete - enqueue final TTS chunk")
                self.audioService.processTTSChunk(textChunk: "", isLastChunk: true)
            }
            .store(in: &cancellables)
        
        chatService.llmErrorSubject
            .sink { [weak self] error in
                guard let self = self else { return }
                self.logger.error("LLM error: \(error.localizedDescription)")
                self.handleError(error)
                self.cancelProcessingAndSpeaking()
                self.audioService.startListening()
            }
            .store(in: &cancellables)
        
        // --- NEW: Subscribe to saved audio chunk paths ---
        audioService.ttsChunkSavedSubject
            .sink { [weak self] messageID, path in
                // Update the ChatService's currentConversation object
                self?.chatService.updateAudioPathInCurrentConversation(messageID: messageID, path: path)
            }
            .store(in: &cancellables)
        
        // --- NEW: when audio service reports all TTS chunks finished, restart listening ---
        audioService.ttsPlaybackCompleteSubject
            .sink { [weak self] in self?.audioService.startListening() }
            .store(in: &cancellables)
        
        // --- Initial State Transition: idle -> listening ---
        // Start listening shortly after initialization
        Task { @MainActor in
            if self.state == .idle,
               settingsService.settings.hasCompletedInitialSetup {  // guard to not listen on first app startup when setup screen is showing
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

        Publishers
            .CombineLatest4(
                audioService.$isListening,
                chatService.$isProcessingLLM,
                audioService.$isFetchingTTS,
                audioService.$isSpeaking
            )
            .receive(on: RunLoop.main)
            .map { listening, processing, fetching, speaking in
                if speaking       { return .speakingTTS }
                else if processing{ return .processingLLM }
                else if fetching  { return .fetchingTTS }
                else if listening { return .listening }
                else              { return .idle }
            }
            .assign(to: &$state)
    }

    // MARK: - User Actions
    func cycleState() {
        if audioService.isListening {
            // User tap during listening: teardown to idle
            audioService.teardown()
        } else {
            // Cancel current and restart listening
            cancelProcessingAndSpeaking()
            audioService.startListening()
        }
    }
    
    // Cancels LLM processing and tears down all audio (listening, TTS, playback)
    func cancelProcessingAndSpeaking() {
        logger.notice("⏹️ Cancel requested, tearing down processing and audio.")
        chatService.cancelProcessing()
        audioService.teardown()
    }

    func startListening() {
        audioService.startListening()
    }

    func stopListening() {
        audioService.stopListeningCleanup()
    }
    
    // MARK: - Error Handling
    private func handleError(_ error: Error) {
        lastError = error.localizedDescription
        state = .error
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
        // Teardown any in-flight processing or audio
        cancelProcessingAndSpeaking()
        
        // Perform history lookup and reset in background
        Task { @MainActor in
            let messagesToLoad = Array(conversation.messages.prefix(through: messageIndex))
            var audioPathsToLoad: [UUID: [String]]? = nil
            
            // Fetch full parent conversation
            if let fullParentConversation = await historyService.loadConversationDetail(id: conversation.id) {
                if let parentAudioPaths = fullParentConversation.ttsAudioPaths {
                    audioPathsToLoad = [:]
                    for msg in messagesToLoad {
                        if let paths = parentAudioPaths[msg.id] {
                            audioPathsToLoad?[msg.id] = paths
                        }
                    }
                    logger.info("Copied \(audioPathsToLoad?.count ?? 0) audio path entries from parent conversation.")
                }
            } else {
                logger.warning("Could not load full parent conversation \(conversation.id)")
            }
            
            chatService.resetConversationContext(
                messagesToLoad: messagesToLoad,
                existingConversationId: nil,
                parentId: conversation.id,
                initialAudioPaths: audioPathsToLoad
            )
        }
    }
    
    // --- Helper for starting new chat ---
    func startNewChat() {
        logger.info("Starting new chat session.")
        cancelProcessingAndSpeaking()
        chatService.resetConversationContext()
        audioService.startListening()
    }
}
