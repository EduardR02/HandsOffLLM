// ContentView.swift
import SwiftUI
import OSLog

struct ContentView: View {
    // Receive ViewModel from the App level
    @ObservedObject var viewModel: ChatViewModel
    // Access environment objects if needed, e.g., for navigation data
    @EnvironmentObject var historyService: HistoryService
    @State private var showHistory = false   // NEW: track the HistoryLink binding

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ContentView")

    // Removed initializer - ViewModel is passed in now

    var body: some View {
        // Use NavigationStack provided by the App
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            VStack {
                Spacer() // Push indicator down a bit

                // Display errors subtly if needed (don't do this)
                /*
                if let error = viewModel.lastError {
                     Text(error)
                         .font(.caption)
                         .foregroundColor(.red)
                         .padding(.bottom, 5)
                         .transition(.opacity) // Animate appearance
                 }
                */


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
                        .id(viewModel.ttsRate) // Ensure text updates with slider
                }
                .padding()
                .padding(.horizontal) // Add horizontal padding for slider/text

                Spacer() // Pushes indicator/slider towards center
            }

            // Picker at the bottom
            VStack {
                Spacer()
                Picker("LLM", selection: $viewModel.selectedProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.bottom)
                .disabled(viewModel.state == .processingLLM || viewModel.state == .speakingTTS)
                .opacity(viewModel.state == .processingLLM || viewModel.state == .speakingTTS ? 0.5 : 1.0) // Use opacity instead of hide
                .animation(.easeInOut(duration: 0.3), value: viewModel.state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // History Button: push via state & navigationDestination
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }

                // Settings Button
                NavigationLink {
                    // Destination: Settings View
                    SettingsView() // Needs access to SettingsService (via @EnvironmentObject)
                } label: {
                    Image(systemName: "gearshape.fill")
                }
            }
             ToolbarItem(placement: .navigationBarLeading) {
                  // Button to explicitly start a new chat session
                  Button {
                      viewModel.startNewChat()
                  } label: {
                      Image(systemName: "plus.circle")
                  }
                  .disabled(viewModel.state != .idle && viewModel.state != .listening) // Allow reset when idle or listening
             }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showHistory) {
            HistoryView(rootIsActive: $showHistory)
        }
        .onAppear {
             logger.info("ContentView appeared.")
             // Start listening automatically only if idle? Or require first tap?
             // Let's require first tap for now. cycleState handles Idle -> Listening
             // viewModel.beginListeningOnStartup() // Remove if first tap is preferred
        }
        .onDisappear {
            logger.info("ContentView disappeared.")
            // Consider stopping listening/speaking if view disappears unexpectedly?
            // viewModel.cancelProcessingAndSpeaking()
        }
    }
}

// --- Preview Update ---
// Need to provide mock services for the preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        // Create mock services for preview
        let settings = SettingsService()
        let history = HistoryService()
        let audio = AudioService(settingsService: settings)
        let chat = ChatService(settingsService: settings, historyService: history)
        let viewModel = ChatViewModel(audioService: audio, chatService: chat, settingsService: settings, historyService: history)

        NavigationStack { // Wrap in NavigationStack for preview
            ContentView(viewModel: viewModel)
        }
        .environmentObject(settings)
        .environmentObject(history)
        .environmentObject(audio)
        .preferredColorScheme(.dark)
    }
}

// Create simpler preview struct if the above is too complex
#Preview {
     let settings = SettingsService()
     let history = HistoryService()
     let audio = AudioService(settingsService: settings)
     let chat = ChatService(settingsService: settings, historyService: history)
     let viewModel = ChatViewModel(audioService: audio, chatService: chat, settingsService: settings, historyService: history)

    return NavigationStack {
         ContentView(viewModel: viewModel)
     }
     .environmentObject(settings)
     .environmentObject(history)
     .environmentObject(audio)
     .preferredColorScheme(.dark)
}