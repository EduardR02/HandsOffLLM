import Foundation
import Combine

enum VoicePhase: Equatable {
    case idle
    case listening
    case transcribing
    case waitingForLLM
    case fetchingTTS
    case speaking
    case error(String?)
}

enum VoiceLoopEvent {
    case resetToIdle
    case listeningStarted
    case listeningStopped
    case transcriptionBegan
    case transcriptionDelivered
    case transcriptionFailed(String)
    case llmStarted
    case llmCompleted(success: Bool)
    case ttsFetchStarted
    case ttsSpeakingStarted
    case ttsCompleted
    case ttsWaiting
    case encounteredError(String)
}

@MainActor
final class VoiceLoopCoordinator: ObservableObject {
    @Published private(set) var phase: VoicePhase = .idle
    
    private var cancellables = Set<AnyCancellable>()
    
    func bind(audioService: AudioService, chatService: ChatService) {
        audioService.voiceEventSubject
            .merge(with: chatService.voiceEventSubject.eraseToAnyPublisher())
            .sink { [weak self] event in
                self?.handle(event: event)
            }
            .store(in: &cancellables)
    }
    
    private func handle(event: VoiceLoopEvent) {
        switch event {
        case .resetToIdle:
            phase = .idle
        case .listeningStarted:
            phase = .listening
        case .listeningStopped:
            phase = .idle
        case .transcriptionBegan:
            phase = .transcribing
        case .transcriptionDelivered:
            if phase == .transcribing {
                phase = .waitingForLLM
            }
        case .transcriptionFailed(let message):
            phase = .error(message)
        case .llmStarted:
            phase = .waitingForLLM
        case .llmCompleted(let success):
            if !success {
                phase = .error(nil)
            }
        case .ttsFetchStarted:
            if phase != .speaking {
                phase = .fetchingTTS
            }
        case .ttsSpeakingStarted:
            phase = .speaking
        case .ttsCompleted:
            phase = .listening
        case .ttsWaiting:
            phase = .fetchingTTS
        case .encounteredError(let message):
            phase = .error(message)
        }
    }
}
