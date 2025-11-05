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
    @StateObject var authService = AuthService.shared
    @Environment(\.scenePhase) private var scenePhase
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "App")
    
    init() {
        // Create the actual service instances first
        let localSettingsService = SettingsService()
        let localHistoryService = HistoryService()
        let localAuthService = AuthService.shared

        let localAudioService = AudioService(
            settingsService: localSettingsService,
            historyService: localHistoryService,
            authService: localAuthService
        )

        let localChatService = ChatService(
            settingsService: localSettingsService,
            historyService: localHistoryService,
            authService: localAuthService
        )

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

        // Set global UI appearance
        UIBarButtonItem.appearance().tintColor = UIColor(Theme.accent)

        logger.info("App Services Initialized.")
    }
    
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if !authService.isAuthenticated {
                    // Auth gate - must sign in first
                    AuthView()
                } else if settingsService.settings.hasCompletedInitialSetup {
                    ContentView(viewModel: viewModel)
                } else {
                    ProfileFormView(isInitial: true)
                        .onAppear {
                            // Make sure we stop listening when setup view appears
                            audioService.stopListeningCleanup()
                        }
                }
            }
            .environmentObject(settingsService)
            .environmentObject(historyService)
            .environmentObject(audioService)
            .environmentObject(chatService)
            .environmentObject(viewModel)
            .environmentObject(authService)
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
                if settingsService.settings.hasCompletedInitialSetup {
                    audioService.startListening()   // restart listening if not in initial setup screen
                }
            default:
                break
            }
        }
    }
}
