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
        VStack {
            // Display Error Message (Optional)
            if let error = viewModel.lastError {
                 Text(error)
                     .foregroundColor(.red)
                     .padding()
            }

            Spacer() // Pushes content to center/bottom

             // Display Messages (Example - You might want a dedicated ChatHistoryView later)
             // This is just a simple placeholder to show messages are available
              ScrollView {
                  VStack(alignment: .leading) {
                      ForEach(viewModel.messages) { message in
                           HStack {
                               if message.role == "user" { Spacer() }
                               Text("\(message.role): \(message.content)")
                                   .padding(8)
                                   .background(message.role == "user" ? Color.blue.opacity(0.7) : Color.gray.opacity(0.7))
                                   .foregroundColor(.white)
                                   .cornerRadius(8)
                               if message.role != "user" { Spacer() }
                           }
                           .padding(.horizontal)
                           .padding(.vertical, 2)
                      }
                  }
              }
             .frame(maxHeight: 200) // Limit height for now

            Spacer() // Pushes indicator and controls to the bottom

            VoiceIndicatorView(
                isListening: $viewModel.isListening,
                 // Use the combined processing state for the indicator's "thinking" phase
                isProcessing: $viewModel.isProcessing,
                isSpeaking: $viewModel.isSpeaking,
                audioLevel: $viewModel.listeningAudioLevel,
                ttsLevel: $viewModel.ttsOutputLevel
            )
            .onTapGesture {
                // Use the ViewModel's state cycling logic
                viewModel.cycleState()
            }
            /*
             // LLM Provider Picker (Example - Move to Settings later)
             Picker("LLM", selection: $viewModel.selectedProvider) {
                 ForEach(LLMProvider.allCases) { provider in
                     Text(provider.rawValue).tag(provider)
                 }
             }
             .pickerStyle(SegmentedPickerStyle())
             .padding(.horizontal)
             .disabled(viewModel.isProcessing || viewModel.isListening || viewModel.isSpeaking) // Disable during activity
            */

            HStack {
                Text("Speed:")
                    .foregroundColor(.white)
                 // Slider still binds to the ViewModel's ttsRate
                Slider(value: $viewModel.ttsRate, in: 0.2...4.0, step: 0.1)
                    .disabled(viewModel.isSpeaking) // Optionally disable during speech
                Text(String(format: "%.1fx", viewModel.ttsRate))
                    .foregroundColor(.white)
                    .frame(width: 40, alignment: .leading)
            }
            .padding()

            // Removed Spacer to keep controls at the bottom
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.edgesIgnoringSafeArea(.all))
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
}

#Preview {
    ContentView()
}