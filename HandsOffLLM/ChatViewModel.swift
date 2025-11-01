// ChatViewModel.swift
import Foundation
import Combine
import OSLog
import SwiftUI

enum ViewModelState: Equatable {
    case idle
    case listening
    case processingLLM
    case fetchingTTS
    case speakingTTS
    case error
}

@MainActor
class ChatViewModel: ObservableObject {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ChatViewModel")
    
    @Published var state: ViewModelState = .idle
    @Published var selectedProvider: LLMProvider = .claude
    @Published var ttsRate: Float = 2.0 {
        didSet {
            if oldValue != ttsRate {
                audioService.ttsRate = ttsRate
            }
        }
    }
    @Published var lastError: String? = nil
    
    private let audioService: AudioService
    private let chatService: ChatService
    private let settingsService: SettingsService
    private let historyService: HistoryService
    
    private var cancellables = Set<AnyCancellable>()
    
    init(audioService: AudioService,
         chatService: ChatService,
         settingsService: SettingsService,
         historyService: HistoryService) {
        self.audioService = audioService
        self.chatService = chatService
        self.settingsService = settingsService
        self.historyService = historyService
        logger.info("ChatViewModel initialized.")
        
        audioService.transcriptionSubject
            .sink { [weak self] transcription in
                guard let self else { return }
                self.logger.info("Received transcription: '\(transcription)'")
                self.chatService.processTranscription(transcription, provider: self.selectedProvider)
            }
            .store(in: &cancellables)
        
        audioService.errorSubject
            .sink { [weak self] error in
                guard let self else { return }
                self.logger.error("AudioService error: \(error.localizedDescription)")
                self.handleError(error)
                let hadSpoken = self.cancelProcessingAndSpeaking()
                self.startListening(useCooldown: hadSpoken)
            }
            .store(in: &cancellables)
        
        chatService.llmChunkSubject
            .sink { [weak self] chunk in
                guard let self else { return }
                if let convID = self.chatService.currentConversation?.id,
                   let msgID = self.chatService.currentConversation?.messages.last?.id {
                    self.audioService.setTTSContext(conversationID: convID, messageID: msgID)
                }
                self.audioService.processTTSChunk(textChunk: chunk, isLastChunk: false)
            }
            .store(in: &cancellables)
        
        chatService.llmCompleteSubject
            .sink { [weak self] in
                guard let self else { return }
                self.logger.info("LLM complete - enqueue final TTS chunk")
                self.audioService.processTTSChunk(textChunk: "", isLastChunk: true)
            }
            .store(in: &cancellables)
        
        chatService.llmErrorSubject
            .sink { [weak self] error in
                guard let self else { return }
                self.logger.error("LLM error: \(error.localizedDescription)")
                self.handleError(error)
                let hadSpoken = self.cancelProcessingAndSpeaking()
                self.startListening(useCooldown: hadSpoken)
            }
            .store(in: &cancellables)
        
        audioService.ttsChunkSavedSubject
            .sink { [weak self] messageID, path in
                self?.chatService.updateAudioPathInCurrentConversation(messageID: messageID, path: path)
            }
            .store(in: &cancellables)
        
        audioService.ttsPlaybackCompleteSubject
            .sink { [weak self] in self?.startListening(useCooldown: true) }
            .store(in: &cancellables)
        
        bindLoopState()
        
        Task { @MainActor in
            if self.state == .idle,
               settingsService.settings.hasCompletedInitialSetup {
                self.startListening()
            }
        }
        
        if let defaultSpeed = settingsService.settings.selectedDefaultPlaybackSpeed {
            self.ttsRate = defaultSpeed
        }
        audioService.ttsRate = self.ttsRate
        
        self.selectedProvider = settingsService.settings.selectedDefaultProvider
            ?? (settingsService.settings.selectedModelIdPerProvider.keys.first ?? .claude)
    }
    
    private func bindLoopState() {
        Publishers.CombineLatest4(
            audioService.$isListening.removeDuplicates(),
            audioService.$isTranscribing.removeDuplicates(),
            audioService.$isSpeaking.removeDuplicates(),
            audioService.$isFetchingTTS.removeDuplicates()
        )
        .combineLatest(
            chatService.$isProcessingLLM.removeDuplicates(),
            $lastError.removeDuplicates()
        )
        .map { flags, isProcessing, lastError -> ViewModelState in
            let (isListening, isTranscribing, isSpeaking, isFetchingTTS) = flags
            if lastError != nil {
                return .error
            }
            if isSpeaking {
                return .speakingTTS
            }
            if isFetchingTTS {
                return .fetchingTTS
            }
            if isProcessing || isTranscribing {
                return .processingLLM
            }
            if isListening {
                return .listening
            }
            return .idle
        }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] newState in
            self?.state = newState
        }
        .store(in: &cancellables)
    }
    
    func cycleState() {
        if audioService.isListening {
            audioService.teardown()
        } else {
            let hadSpoken = cancelProcessingAndSpeaking()
            startListening(useCooldown: hadSpoken)
        }
    }
    
    @discardableResult
    func cancelProcessingAndSpeaking() -> Bool {
        logger.notice("⏹️ Cancel requested, tearing down processing and audio.")
        lastError = nil
        let wasSpeaking = audioService.isSpeaking
        chatService.cancelProcessing()
        audioService.teardown()
        return wasSpeaking
    }
    
    func startListening(useCooldown: Bool = false) {
        lastError = nil
        audioService.startListening(useCooldown: useCooldown)
    }
    
    func stopListening() {
        audioService.stopListeningCleanup()
    }
    
    private func handleError(_ error: Error) {
        lastError = error.localizedDescription
    }
    
    func beginListeningOnStartup() {
        if state == .idle {
            logger.info("Triggering initial listening sequence.")
            startListening()
        }
    }
    
    func loadConversationHistory(_ conversation: Conversation, upTo messageIndex: Int) {
        logger.info("Loading conversation \(conversation.id) up to index \(messageIndex)")
        cancelProcessingAndSpeaking()

        Task { @MainActor in
            let messagesToLoad = Array(conversation.messages.prefix(through: messageIndex))
            let isLastMessage = messageIndex == conversation.messages.count - 1
            var audioPathsToLoad: [UUID: [String]]? = nil
            var parentTitle: String? = nil

            if let fullParentConversation = await historyService.loadConversationDetail(id: conversation.id) {
                parentTitle = fullParentConversation.title

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

            if isLastMessage {
                // Continue the existing conversation instead of forking
                logger.info("Continuing existing conversation (last message)")
                chatService.resetConversationContext(
                    messagesToLoad: messagesToLoad,
                    existingConversationId: conversation.id,
                    parentId: nil,
                    initialAudioPaths: audioPathsToLoad,
                    initialTitle: parentTitle
                )
            } else {
                // Fork to a new conversation
                logger.info("Forking new conversation from parent")
                chatService.resetConversationContext(
                    messagesToLoad: messagesToLoad,
                    existingConversationId: nil,
                    parentId: conversation.id,
                    initialAudioPaths: audioPathsToLoad,
                    initialTitle: parentTitle
                )
            }
        }
    }
    
    func startNewChat() {
        logger.info("Starting new chat session.")
        let hadSpoken = cancelProcessingAndSpeaking()
        chatService.resetConversationContext()
        startListening(useCooldown: hadSpoken)
    }
}
