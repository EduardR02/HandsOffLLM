//
//  HandsOffLLMApp.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 08.04.25.
//

import SwiftUI
import OSLog
import UIKit

@main
struct HandsOffLLMApp: App {
    // Declare StateObjects without initial values here
    @StateObject var settingsService: SettingsService
    @StateObject var historyService: HistoryService
    @StateObject var audioService: AudioService
    @StateObject var chatService: ChatService
    @StateObject var viewModel: ChatViewModel
    @Environment(\.scenePhase) private var scenePhase
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "App")
    
    init() {
        // Create the actual service instances first
        let localSettingsService = SettingsService()
        let localHistoryService = HistoryService()
        let localAudioService = AudioService(settingsService: localSettingsService, historyService: localHistoryService)
        let localChatService = ChatService(settingsService: localSettingsService, historyService: localHistoryService)
        let localViewModel = ChatViewModel(
            audioService: localAudioService,
            chatService: localChatService,
            settingsService: localSettingsService,
            historyService: localHistoryService
        )

        // Initialize the StateObject wrapped properties
        _settingsService = StateObject(wrappedValue: localSettingsService)
        _historyService = StateObject(wrappedValue: localHistoryService)
        _audioService = StateObject(wrappedValue: localAudioService)
        _chatService = StateObject(wrappedValue: localChatService)
        _viewModel = StateObject(wrappedValue: localViewModel)
        
        // --- Theme Navigation Bar ---
        let appearance = UINavigationBarAppearance()
        
        appearance.configureWithTransparentBackground()
        
        appearance.shadowImage = UIImage()
        appearance.shadowColor = .clear

        appearance.titleTextAttributes = [.foregroundColor: UIColor(Theme.primaryText)]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.primaryText)]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        
        UIBarButtonItem.appearance().tintColor = UIColor(Theme.accent)
        
        logger.info("App Services Initialized.")
    }
    
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView(viewModel: viewModel)
            }
            .environmentObject(settingsService)
            .environmentObject(historyService)
            .environmentObject(audioService)
            .environmentObject(chatService)
            .environmentObject(viewModel)
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                logger.info("App moved to background: full audio cleanup.")
                audioService.cleanupForBackground()
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                logger.info("App became active: reconfiguring audio.")
                audioService.applyAudioSessionSettings()
                audioService.startListening()
            default:
                break
            }
        }
    }
}
