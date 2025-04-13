// ContentView.swift
import SwiftUI
import OSLog // Keep OSLog if VoiceIndicatorView or other parts need it, or pass logger

struct ContentView: View {
    // Instantiate Services and ViewModel
    // Ideally, these would be injected from a higher level (e.g., App struct)
    // for better testability and lifecycle management.
    private static let settingsService = SettingsService()
    private static let audioService = AudioService(settingsService: settingsService)
    private static let chatService = ChatService(settingsService: settingsService)
    
    @StateObject private var viewModel = ChatViewModel(
        audioService: audioService,
        chatService: chatService,
        settingsService: settingsService
    )

    // Logger can be kept here if needed, or passed down from ViewModel/Services
     let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ContentView")

    var body: some View {
        ZStack { // Use ZStack for layering
            // Background Color
            Color.black.edgesIgnoringSafeArea(.all)

            // Main content (Indicator and Slider) centered vertically
            VStack {
                // Optional Error Display (remains at top)
                if let error = viewModel.lastError {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                    Spacer() // Pushes content down
                } else {
                    Spacer() // Pushes content down
                }

                VoiceIndicatorView(
                    isListening: $viewModel.isListening,
                    isProcessing: $viewModel.isProcessing,
                    isSpeaking: $viewModel.isSpeaking,
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
                .disabled(viewModel.isProcessing || viewModel.isSpeaking) // Corrected disabled logic: Only disable during processing/speaking
                .opacity(pickerOpacity) // Control opacity
                .animation(.easeInOut(duration: 0.3), value: pickerOpacity) // Animate opacity changes
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            logger.info("ContentView appeared.")
            // Start listening immediately if idle on appear
            // Check the ViewModel's state, not services directly
            if !viewModel.isListening && !viewModel.isProcessing && !viewModel.isSpeaking {
                 logger.info("Starting initial listening on appear.")
                 viewModel.startListening()
            }
        }
        .onDisappear {
            logger.info("ContentView disappeared.")
            // Trigger ViewModel cleanup
            viewModel.cleanupOnDisappear()
        }
    }

    // Computed property for picker opacity
    private var pickerOpacity: Double {
        // Visible (1.0) when idle or listening. Invisible (0.0) when processing LLM or speaking.
        if viewModel.isProcessing || viewModel.isSpeaking {
            return 0.0
        } else {
            return 1.0
        }
    }
}

#Preview {
    ContentView()
}