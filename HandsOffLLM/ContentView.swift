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
    @Environment(\.sizeCategory) private var sizeCategory
    // Compute row height based on Dynamic Type
    private var pickerRowHeight: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let scaledLine = UIFontMetrics.default.scaledValue(for: font.lineHeight)
        // add top+bottom padding (10pt each to match other buttons)
        return scaledLine + 20
    }
    @State private var showHistory = false   // track history
    @State private var isMenuOpen = false     // track side menu
    @State private var isEditingSlider: Bool = false // Add this line
    private let menuWidth: CGFloat = 300      // side menu width
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ContentView")
    
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        UISlider.appearance().setThumbImage(UIImage(), for: .normal)
        UISegmentedControl.appearance().backgroundColor = UIColor(Theme.overlayMask)
        //UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(Theme.menuAccent)
    }
    
    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            
            VStack {
                VoiceIndicatorView(
                    state: $viewModel.state
                )
                .onTapGesture {
                    viewModel.cycleState()
                }

                // --- Updated Slider Section ---
                VStack(alignment: .center) { // This VStack will hold the Text and Slider
                    Text(String(format: "%.1fx", viewModel.ttsRate))
                        .font(.system(.body, design: .monospaced, weight: .regular))
                        .monospacedDigit()
                        .foregroundColor(Theme.primaryText)
                        .padding(.bottom, 2) // A small space between the text and the slider
                        .opacity(isEditingSlider ? 1.0 : 0.0) // Text fades based on editing state

                    Slider(
                        value: Binding<Float>(
                            get: { viewModel.ttsRate },
                            set: { newValue in
                                let quant = (newValue * 10).rounded() / 10
                                if viewModel.ttsRate != quant {
                                    viewModel.ttsRate = quant
                                }
                            }
                        ),
                        in: 0.2...4.0,
                        step: 0.1,
                        onEditingChanged: { editing in
                            isEditingSlider = editing
                        }
                    )
                    .tint(Theme.accent)
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)
                .animation(.easeInOut(duration: 0.25), value: isEditingSlider)
            }

            if isMenuOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture { withAnimation { isMenuOpen = false } }

                HStack(spacing: 0) {
                    Spacer() // Pushes menu to the right

                    // The actual menu content VStack
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            viewModel.startNewChat()
                            withAnimation { isMenuOpen = false }
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle")
                                Text("New Chat")
                                Spacer()
                            }
                            .foregroundColor(Theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .background(Theme.menuAccent)
                            .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)

                        Button {
                            showHistory = true
                            withAnimation { isMenuOpen = false }
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("History")
                                Spacer()
                            }
                            .foregroundColor(Theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .background(Theme.menuAccent)
                            .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)

                        NavigationLink {
                            SettingsView()
                        } label: {
                            HStack {
                                Image(systemName: "gearshape")
                                Text("Settings")
                                Spacer()
                            }
                            .foregroundColor(Theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .background(Theme.menuAccent)
                            .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        
                        RoutePickerView()
                            .frame(maxWidth: .infinity)
                            .frame(height: pickerRowHeight)
                            .background(Theme.menuAccent)
                            .cornerRadius(8)
                            .overlay(
                                HStack {
                                    Image(systemName: "airplayaudio")
                                    Text("Pick Output")
                                    Spacer()
                                }
                                .foregroundColor(Theme.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .allowsHitTesting(false)
                            )
                            .padding(.horizontal, 12)

                        Picker("LLM", selection: $viewModel.selectedProvider) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                                    .foregroundColor(Theme.primaryText)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .cornerRadius(8)
                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                        
                        Spacer()
                    }
                    .padding(.top)
                    .frame(width: menuWidth)
                    .background(Theme.overlayMask.opacity(0.8).edgesIgnoringSafeArea(.all))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation{ isMenuOpen.toggle() }
                } label: {
                    Image(systemName:"line.horizontal.3").foregroundColor(Theme.primaryText)
                }
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
