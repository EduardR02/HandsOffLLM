import Foundation

#if DEBUG
@MainActor
struct PreviewEnvironment {
    let settings: SettingsService
    let history: HistoryService
    let audio: AudioService
    let chat: ChatService
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
        let viewModel = ChatViewModel(audioService: audioService,
                                      chatService: chatService,
                                      settingsService: resolvedSettings,
                                      historyService: resolvedHistory)

        return PreviewEnvironment(settings: resolvedSettings,
                                  history: resolvedHistory,
                                  audio: audioService,
                                  chat: chatService,
                                  viewModel: viewModel)
    }
}
#endif
