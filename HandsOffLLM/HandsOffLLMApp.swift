//
//  HandsOffLLMApp.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 08.04.25.
//

import SwiftUI
import OSLog

@main
struct HandsOffLLMApp: App {
    // Initialize services once
    @StateObject private var settingsService = SettingsService()
    @StateObject private var historyService = HistoryService()
    // AudioService needs SettingsService
    @StateObject private var audioService: AudioService
    // ChatService needs SettingsService and HistoryService
    @StateObject private var chatService: ChatService
    // ViewModel needs all services
    @StateObject private var chatViewModel: ChatViewModel

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "App")

    init() {
        let settings = SettingsService()
        let history = HistoryService()
        let audio = AudioService(settingsService: settings, historyService: history)
        let chat = ChatService(settingsService: settings, historyService: history)
        let viewModel = ChatViewModel(audioService: audio,
                                     chatService: chat,
                                     settingsService: settings,
                                     historyService: history)

        _settingsService = StateObject(wrappedValue: settings)
        _historyService = StateObject(wrappedValue: history)
        _audioService = StateObject(wrappedValue: audio)
        _chatService = StateObject(wrappedValue: chat)
        _chatViewModel = StateObject(wrappedValue: viewModel)

        logger.info("App Services Initialized.")
    }

    var body: some Scene {
        WindowGroup {
            // Use NavigationStack for navigation features
            NavigationStack {
                ContentView(viewModel: chatViewModel) // Pass the viewModel
            }
            // Make services available to the environment if needed lower down
            .environmentObject(settingsService)
            .environmentObject(historyService)
            .environmentObject(audioService) // Make audio service available for potential replay in detail view
            .environmentObject(chatViewModel)
            .preferredColorScheme(.dark) // Keep dark mode
        }
    }
}
