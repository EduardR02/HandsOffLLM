// ContentView.swift
import SwiftUI
import OSLog // Keep OSLog if VoiceIndicatorView or other parts need it, or pass logger

struct ContentView: View {
    // Remove the static service properties
    // private static let settingsService = SettingsService()
    // private static let audioService = AudioService(settingsService: settingsService)
    // private static let chatService = ChatService(settingsService: settingsService)

    // Initialize ViewModel and its dependencies within the @StateObject initializer
    @StateObject private var viewModel: ChatViewModel

    // Logger can be kept here if needed
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ContentView")

    // Custom initializer (if needed for previews or dependency injection later)
    // We'll initialize directly in the @StateObject for now
    init() {
        // Create services first
        let settings = SettingsService()
        let audio = AudioService(settingsService: settings)
        let chat = ChatService(settingsService: settings)

        // Initialize the StateObject with the services
        // Note: _viewModel refers to the StateObject wrapper itself
        _viewModel = StateObject(wrappedValue: ChatViewModel(
            audioService: audio,
            chatService: chat,
            settingsService: settings
        ))
        logger.info("ContentView and ViewModel initialized.") // Log initialization
    }

    var body: some View {
        ZStack { // Use ZStack for layering
            // Background Color
            Color.black.edgesIgnoringSafeArea(.all)

            // Main content (Indicator and Slider) centered vertically
            VStack {
                // Don't display errors, keep interface clean
                Spacer()

                VoiceIndicatorView(
                    state: $viewModel.state,
                    audioLevel: $viewModel.listeningAudioLevel,
                    ttsLevel: $viewModel.ttsOutputLevel
                )
                .onTapGesture {
                    viewModel.cycleState()
                }

                // Slider Section (Reverted to original HStack)
                HStack {
                    Text("Speed:")
                        .foregroundColor(.white)
                    Slider(value: $viewModel.ttsRate, in: 0.2...4.0, step: 0.1)
                    Text(String(format: "%.1fx", viewModel.ttsRate))
                        .foregroundColor(.white)
                        .frame(width: 40, alignment: .leading)
                }
                .padding() // Keep padding around the slider HStack

                Spacer() // Pushes content up from the bottom
            }

            // Picker positioned at the bottom
            VStack { // Use a VStack to push the picker to the bottom edge
                Spacer() // Pushes picker down
                Picker("LLM", selection: $viewModel.selectedProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.bottom) // Add padding below the picker
                .disabled(viewModel.state == .processingLLM || viewModel.state == .speakingTTS)
                .opacity(viewModel.state == .processingLLM || viewModel.state == .speakingTTS ? 0.0 : 1.0)
                .animation(.easeInOut(duration: 0.3), value: viewModel.state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // logger.info("ContentView appeared. Current state: \(viewModel.state)") // Logging moved to init
            // ViewModel init now handles startup listening
        }
        .onDisappear {
             logger.info("ContentView disappeared.")
        }
    }
}

#Preview {
    ContentView()
}