// ContentView.swift
import SwiftUI
import OSLog
import UIKit

// Quick-select prompt model
struct QuickPromptOption: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let systemPromptId: String?
    let ttsInstructionId: String?
}

// All quick‐select options (excluding "remove‐later")
fileprivate let quickPromptOptions: [QuickPromptOption] = [
    QuickPromptOption(id: "current",                         title: "My Preset",         icon: "circle.grid.2x2",               systemPromptId: nil,                            ttsInstructionId: nil),
    QuickPromptOption(id: "learn-anything",                  title: "Learn Anything",    icon: "brain",                         systemPromptId: "learn-anything",               ttsInstructionId: "passionate-educator"),
    QuickPromptOption(id: "brainstorm-anything",             title: "Brainstorm",        icon: "bubbles.and.sparkles",          systemPromptId: "brainstorm-anything",          ttsInstructionId: "internet-historian"),
    QuickPromptOption(id: "relationship-argument-simulator", title: "Argument Practice", icon: "figure.stand.line.dotted.figure.stand", systemPromptId: "relationship-argument-simulator", ttsInstructionId: "passive-aggressive"),
    QuickPromptOption(id: "conversational-companion",        title: "Casual Chat",       icon: "hand.raised.fingers.spread",    systemPromptId: "conversational-companion",     ttsInstructionId: "default-happy"),
    QuickPromptOption(id: "travel-guide",                    title: "Travel Guide",      icon: "airplane",                      systemPromptId: "travel-guide",                 ttsInstructionId: "temporal-archivist"),
    QuickPromptOption(id: "social-skills-coach",             title: "Social Coach",      icon: "figure.socialdance",            systemPromptId: "social-skills-coach",          ttsInstructionId: "critical-friend"),  
    QuickPromptOption(id: "task-guide",                      title: "How-To Guide",      icon: "wrench.and.screwdriver",        systemPromptId: "task-guide",                   ttsInstructionId: "morning-hype"),
    QuickPromptOption(id: "voice-game-master",               title: "Play Game",         icon: "dice",                          systemPromptId: "voice-game-master",            ttsInstructionId: "film-trailer-voice"),
    QuickPromptOption(id: "financial-advisor",               title: "Money Advice",      icon: "dollarsign",                    systemPromptId: "financial-advisor",            ttsInstructionId: "spaceship-ai"),
    QuickPromptOption(id: "health-fitness-trainer",          title: "Fitness Coach",     icon: "figure.core.training",          systemPromptId: "health-fitness-trainer",       ttsInstructionId: "spaceship-ai"),
    QuickPromptOption(id: "incoherent-drunk",                title: "3AM Drunk",         icon: "wineglass",                     systemPromptId: "incoherent-drunk",             ttsInstructionId: "rick-sanchez"),
    QuickPromptOption(id: "edgy-gamer",                      title: "Edgy Gamer",        icon: "dot.scope",                     systemPromptId: "edgy-gamer",                   ttsInstructionId: "cyberpunk-street-kid"),
    QuickPromptOption(id: "conspiracy-theorist",             title: "Conspiracy",        icon: "antenna.radiowaves.left.and.right", systemPromptId: "conspiracy-theorist",      ttsInstructionId: "cosmic-horror-narrator"),
    QuickPromptOption(id: "life-coach-maniac",               title: "Crazy Coach",       icon: "figure.mind.and.body",          systemPromptId: "life-coach-maniac",            ttsInstructionId: "morning-hype"),
    QuickPromptOption(id: "victorian-traveler",              title: "Time Traveler",     icon: "infinity",                      systemPromptId: "victorian-traveler",           ttsInstructionId: "vintage-broadcaster"),
    QuickPromptOption(id: "tech-bro",                        title: "Tech Bro",          icon: "cpu",                           systemPromptId: "tech-bro",                     ttsInstructionId: "internet-historian")
]

// Horizontal quick-prompt bar
private struct QuickPromptBar: View {
    @Binding var selectedId: String
    @EnvironmentObject var settingsService: SettingsService

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickPromptOptions) { option in
                    Button {
                        // Update selection & apply session override
                        selectedId = option.id
                        if let sysId = option.systemPromptId,
                           let sysText = settingsService.availableSystemPrompts.first(where: { $0.id == sysId })?.fullPrompt,
                           let ttsId = option.ttsInstructionId,
                           let ttsText = settingsService.availableTTSInstructions.first(where: { $0.id == ttsId })?.fullPrompt
                        {
                            settingsService.setSessionOverride(systemPrompt: sysText, ttsInstruction: ttsText)
                        } else {
                            settingsService.clearSessionOverride()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: option.icon)
                                .font(.system(size: 20))
                                .frame(width: 24, height: 24)
                            Text(option.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(height: 16)
                        }
                        .frame(height: 60)
                        .padding(.horizontal, 8)
                        .background(Theme.menuAccent)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedId == option.id ? Theme.accent : Color.clear, lineWidth: 2)
                        )
                        .foregroundColor(selectedId == option.id ? Theme.accent : Theme.primaryText)
                        .animation(.easeInOut(duration: 0.2), value: selectedId)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
        }
        .frame(height: 68)
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("darkerMode") private var darkerModeObserver: Bool = true
    // Compute row height based on Dynamic Type
    private var pickerRowHeight: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let scaledLine = UIFontMetrics.default.scaledValue(for: font.lineHeight)
        // add top+bottom padding (10pt each to match other buttons)
        return scaledLine + 20
    }
    @State private var showHistory = false
    @State private var showUsage = false
    @State private var isMenuOpen = false
    @State private var isEditingSlider: Bool = false
    @State private var showInitialSliderValueHelpText: Bool = false
    private let menuWidth: CGFloat = 300
    @State private var selectedQuickPromptId: String = "current"
    
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ContentView")
    
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        UISlider.appearance().setThumbImage(UIImage(), for: .normal)
        UISegmentedControl.appearance().backgroundColor = UIColor(Theme.overlayMask)
        //UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(Theme.menuAccent)
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.edgesIgnoringSafeArea(.all)

            // 1) Quick‐select bar as an overlay at the very top
            QuickPromptBar(selectedId: $selectedQuickPromptId)
                .padding(.top, 16)
                .opacity(viewModel.state == .idle || viewModel.state == .listening ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: viewModel.state)
                .zIndex(1)

            // 2) Main content VStack that truly centers circle + slider
            VStack {
                Spacer()

                VoiceIndicatorView(state: $viewModel.state)
                    .onTapGesture {
                        viewModel.cycleState()
                    }

                // --- Updated Slider Section ---
                VStack(alignment: .center) {
                    Text(String(format: "%.1fx", viewModel.ttsRate))
                        .font(.system(.body, design: .monospaced, weight: .regular))
                        .monospacedDigit()
                        .foregroundColor(Theme.primaryText)
                        .padding(.bottom, 2)
                        .opacity(isEditingSlider || showInitialSliderValueHelpText ? 1 : 0)

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

                Spacer()
            }

            // 3) Slide-in menu, now with zIndex(2)
            if isMenuOpen {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture { withAnimation { isMenuOpen = false } }

                    HStack(spacing: 0) {
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                viewModel.startNewChat()
                                withAnimation { isMenuOpen = false }
                            } label: {
                                MenuRowContent(imageName: "plus.circle", text: "New Chat")
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)

                            Button {
                                showHistory = true
                            } label: {
                                MenuRowContent(imageName: "clock.arrow.circlepath", text: "History")
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)

                            Button {
                                showUsage = true
                            } label: {
                                MenuRowContent(imageName: "chart.bar.fill", text: "Usage")
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)

                            NavigationLink {
                                SettingsView()
                            } label: {
                                MenuRowContent(imageName: "gearshape", text: "Customize")
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
                                ForEach(LLMProvider.userFacing) { provider in
                                    Text(provider.rawValue).tag(provider)
                                        .foregroundColor(Theme.primaryText)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .onChange(of: darkerModeObserver) {
                                updateSegmentedControlColors()
                            }
                            .onAppear {
                                updateSegmentedControlColors()
                            }
                            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                            
                            Spacer()
                        }
                        .padding(.top)
                        .frame(width: menuWidth)
                        .background(Theme.overlayMask.opacity(0.8).edgesIgnoringSafeArea(.all))
                    }
                }
                .zIndex(2)  // <- MENU ABOVE THE BAR
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
            else{ viewModel.startListening() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showHistory) {
            HistoryView(rootIsActive: $showHistory)
        }
        .navigationDestination(isPresented: $showUsage) {
            UsageDashboardView()
        }
        .onAppear {
            logger.info("ContentView appeared, start listening.")
            viewModel.isViewVisible = true
            isMenuOpen = false
            viewModel.startListening()

            // slider text fade out so user doesn't confuse speed slider with "loading"
            showInitialSliderValueHelpText = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeInOut(duration: 0.25)) { // Explicitly animate only the fade-out
                    showInitialSliderValueHelpText = false
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                logger.info("ContentView foregrounded, restart listening.")
                viewModel.startListening()
            }
        }
        .onDisappear {
            logger.info("ContentView disappeared, cleanup.")
            viewModel.isViewVisible = false
            viewModel.cancelProcessingAndSpeaking()
        }
    }

    private func updateSegmentedControlColors() {
        let appearance = UISegmentedControl.appearance()
        appearance.backgroundColor = UIColor(Theme.menuAccent)
        appearance.selectedSegmentTintColor = UIColor(Theme.accent)
        appearance.setDividerImage(UIImage(), forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
    }
}


private struct MenuRowContent: View {
    let imageName: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: imageName)
            Text(text)
            Spacer()
        }
        .foregroundColor(Theme.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .background(Theme.menuAccent)
        .cornerRadius(8)
    }
}

#if DEBUG
#Preview {
    let env = PreviewEnvironment.make()

    NavigationStack {
        ContentView(viewModel: env.viewModel)
    }
    .environmentObject(env.settings)
    .environmentObject(env.history)
    .environmentObject(env.audio)
    .environmentObject(env.chat)
    .environmentObject(env.auth)
    .preferredColorScheme(.dark)
}
#endif
