// ContentView.swift
import SwiftUI
import OSLog
import UIKit

struct ContentView: View {
    // Receive ViewModel from the App level
    @ObservedObject var viewModel: ChatViewModel
    // Access environment objects if needed, e.g., for navigation data
    @EnvironmentObject var historyService: HistoryService
    @EnvironmentObject var audioService: AudioService
    @State private var showHistory = false   // track history
    @State private var isMenuOpen = false     // track side menu
    private let menuWidth: CGFloat = 300      // side menu width
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ContentView")
    
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        // Hide slider thumb
        UISlider.appearance().setThumbImage(UIImage(), for: .normal)
        UISlider.appearance().minimumTrackTintColor = .white
        UISlider.appearance().maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
    }
    
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
                    state: $viewModel.state
                )
                .onTapGesture {
                    viewModel.cycleState()
                }
                
                Spacer() // Pushes indicator towards center
            }
            
            // main screen has no LLM picker
            
            // Side menu overlay
            if isMenuOpen {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { isMenuOpen = false } }
                HStack(spacing: 0) {
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        // New Chat with full-width background
                        Button {
                            viewModel.startNewChat()
                            withAnimation { isMenuOpen = false }
                        } label: {
                            HStack { Image(systemName: "plus.circle"); Text("New Chat") }
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .background(Color(.secondarySystemBackground).opacity(0.5))
                        .cornerRadius(8)
                        
                        // History with full-width background
                        Button {
                            showHistory = true
                            withAnimation { isMenuOpen = false }
                        } label: {
                            HStack { Image(systemName: "clock.arrow.circlepath"); Text("History") }
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .background(Color(.secondarySystemBackground).opacity(0.5))
                        .cornerRadius(8)
                        
                        // Settings with full-width background
                        NavigationLink {
                            SettingsView()
                        } label: {
                            HStack { Image(systemName: "gearshape"); Text("Settings") }
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .background(Color(.secondarySystemBackground).opacity(0.5))
                        .cornerRadius(8)
                        
                        // Output picker row
                        HStack(spacing: 4) {
                            RoutePickerView().fixedSize()
                            Text("Pick Output")
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 12))
                        .background(Color(.secondarySystemBackground).opacity(0.5))
                        .cornerRadius(8)
                        // Minimal TTS speed control
                        HStack {
                            Slider(
                                value: Binding<Float>(
                                    get: { viewModel.ttsRate },
                                    set: { newValue in
                                        let quant = (newValue * 10).rounded() / 10
                                        if viewModel.ttsRate != quant {
                                            viewModel.ttsRate = quant
                                        }
                                    }
                                ), in: 0.2...4.0, step: 0.1
                            )
                            .tint(.white)
                            Text(String(format: "%.1fx", viewModel.ttsRate))
                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .leading)
                                .foregroundColor(.white)
                        }
                        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemBackground).opacity(0.5))
                        .cornerRadius(8)
                        Picker("LLM", selection: $viewModel.selectedProvider) { ForEach(LLMProvider.allCases){ provider in Text(provider.rawValue).tag(provider) }}
                            .pickerStyle(SegmentedPickerStyle()).padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        Spacer()
                    }
                    .frame(width: menuWidth)
                    .background(Color(.systemBackground))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar{
            ToolbarItem(placement:.navigationBarTrailing){
                Button{withAnimation{isMenuOpen.toggle()}}label:{Image(systemName:"line.horizontal.3").foregroundColor(.white)}
            }
        }
        .gesture(
            DragGesture()
                .onEnded { v in
                    withAnimation {
                        if isMenuOpen {
                            if v.translation.width > 50 {
                                isMenuOpen = false
                            }
                        } else {
                            if v.translation.width < -50 {
                                isMenuOpen = true
                            }
                        }
                    }
                }
        )
        .onChange(of:isMenuOpen){ wasOpen, isOpen in
            if isOpen{ viewModel.stopListening() } // only stop listening, do not stop tts. this is so that the playback speed can be adjusted while playing
            else{ audioService.startListening() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showHistory) {
            HistoryView(rootIsActive: $showHistory)
        }
        .onAppear {
            logger.info("ContentView appeared, start listening.")
            isMenuOpen = false
            audioService.startListening()
        }
        .onDisappear {
            logger.info("ContentView disappeared, cleanup.")
            viewModel.cancelProcessingAndSpeaking()
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
        let audio = AudioService(settingsService: settings, historyService: history)
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
    let audio = AudioService(settingsService: settings, historyService: history)
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
