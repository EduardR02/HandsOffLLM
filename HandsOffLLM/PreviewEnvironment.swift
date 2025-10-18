import Foundation

#if DEBUG
@MainActor
struct PreviewEnvironment {
    let settings: SettingsService
    let history: HistoryService
    let audio: AudioService
    let chat: ChatService
    let coordinator: VoiceLoopCoordinator
    let viewModel: ChatViewModel

    static func make(
        settings: SettingsService? = nil,
        history: HistoryService? = nil,
        configureHistory: ((HistoryService) -> Void)? = nil
    ) -> PreviewEnvironment {
        let resolvedSettings = settings ?? SettingsService()
        let resolvedHistory = history ?? HistoryService()
        configureHistory?(resolvedHistory)

        let audioService = AudioService(settingsService: resolvedSettings, historyService: resolvedHistory)
        let chatService = ChatService(settingsService: resolvedSettings, historyService: resolvedHistory)
        let coordinator = VoiceLoopCoordinator()
        coordinator.bind(audioService: audioService, chatService: chatService)
        let viewModel = ChatViewModel(audioService: audioService,
                                      chatService: chatService,
                                      settingsService: resolvedSettings,
                                      historyService: resolvedHistory,
                                      loopCoordinator: coordinator)

        return PreviewEnvironment(settings: resolvedSettings,
                                  history: resolvedHistory,
                                  audio: audioService,
                                  chat: chatService,
                                  coordinator: coordinator,
                                  viewModel: viewModel)
    }
}
#endif
