//
//  SettingsView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 18.04.25.
//

import SwiftUI
import OSLog // Add Logger if needed

struct SettingsView: View {
    // Use @StateObject if SettingsService is initialized here,
    // or @EnvironmentObject if passed from parent (preferred)
    @EnvironmentObject var settingsService: SettingsService
    @EnvironmentObject var viewModel: ChatViewModel // Add ViewModel
    @EnvironmentObject var historyService: HistoryService
    @State private var tempDefaultPlaybackSpeed: Float = 2.0
    @State private var tempVADSilenceThreshold: Double = 1.0
    @State private var audioAutoDeleteEnabled = true
    @State private var showingAudioPurgeConfirmation = false
    @AppStorage("darkerMode") private var darkerModeObserver: Bool = true
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SettingsView")

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            Form {
                // MARK: - User Profile
                Section {
                    NavigationLink {
                        ProfileFormView(isInitial: false)
                    } label: {
                        HStack {
                            Text("User Profile")
                                .foregroundColor(Theme.primaryText)
                            Spacer()
                            if !settingsService.settings.userProfileEnabled {
                                Text("Disabled")
                                    .foregroundColor(Theme.secondaryText)
                            } else if let name = settingsService.settings.userDisplayName, !name.isEmpty {
                                Text("Hello, \(name)")
                                    .foregroundColor(Theme.secondaryAccent)
                            } else {
                                Text("Set up…")
                                    .foregroundColor(Theme.secondaryText)
                            }
                        }
                    }
                    .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - App Defaults
                Section("App Defaults") {
                    Picker("LLM Provider", selection: Binding(
                        get: { settingsService.settings.selectedDefaultProvider ?? .claude },
                        set: { settingsService.updateDefaultProvider(provider: $0) }
                    )) {
                        ForEach(LLMProvider.userFacing) { provider in
                            Text(provider.rawValue).tag(provider)
                                .foregroundColor(Theme.primaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                    .id("llmProviderPicker-\(darkerModeObserver)")

                    HStack {
                        Text("Speed")
                            .foregroundColor(Theme.primaryText)

                        Slider(
                            value: $tempDefaultPlaybackSpeed,
                            in: 0.2...4.0,
                            step: 0.1,
                            onEditingChanged: { editing in
                                if !editing {
                                    let quant = (tempDefaultPlaybackSpeed * 10).rounded() / 10
                                    if settingsService.settings.selectedDefaultPlaybackSpeed != quant {
                                        settingsService.updateDefaultPlaybackSpeed(speed: quant)
                                    }
                                    tempDefaultPlaybackSpeed = quant
                                }
                            }
                        )
                        .tint(Theme.accent)

                        Text(String(format: "%.1fx", tempDefaultPlaybackSpeed))
                            .font(.system(.body, design: .monospaced, weight: .regular))
                            .monospacedDigit()
                            .foregroundColor(Theme.secondaryAccent)
                    }
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Model Selection
                Section("LLM Models") {
                    ForEach(LLMProvider.userFacing) { provider in
                        NavigationLink {
                            ModelSelectionView(provider: provider)
                        } label: {
                            HStack {
                                Text(provider.rawValue)
                                    .foregroundColor(Theme.primaryText)
                                Spacer()
                                if let selectedId = settingsService.settings.selectedModelIdPerProvider[provider],
                                   let selModel = settingsService.availableModels.first(where: { $0.id == selectedId }) {
                                    Text(selModel.name)
                                      .foregroundColor(Theme.secondaryAccent)
                                } else {
                                    Text("Select Model")
                                        .foregroundColor(Theme.secondaryText)
                                }
                            }
                        }
                        .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                    }
                }
                .listRowBackground(Theme.menuAccent)

                Section("Reasoning") {
                    Picker(selection: Binding(
                        get: { settingsService.openAIReasoningEffort },
                        set: { settingsService.updateOpenAIReasoningEffort($0) }
                    )) {
                        ForEach(OpenAIReasoningEffort.allCases, id: \.self) { effort in
                            Text(effort.displayName).tag(effort)
                                .foregroundColor(Theme.primaryText)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OpenAI Reasoning Effort")
                            Text("Choose how long GPT-5 thinks before replying.")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                    .id("reasoningEffortPicker-\(darkerModeObserver)")
                    
                    Toggle(isOn: Binding(
                        get: { settingsService.claudeReasoningEnabled },
                        set: { settingsService.updateClaudeReasoningEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude Reasoning")
                                .foregroundColor(Theme.primaryText)
                            Text("Let Claude think before replying.")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Prompt Presets
                Section("Customize Chat Experience") {
                    NavigationLink {
                        SystemPromptSelectionView()
                    } label: {
                        HStack {
                            Text("LLM System Prompt")
                                .foregroundColor(Theme.primaryText)
                            Spacer()
                            Text(
                                settingsService
                                    .availableSystemPrompts
                                    .first { $0.id == settingsService.settings.selectedSystemPromptPresetId }?
                                    .name
                                ?? "Select…"
                            )
                            .foregroundColor(Theme.secondaryAccent)
                        }
                    }
                    .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                    if settingsService.settings.advancedSystemPromptEnabled {
                        Text("using custom")
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryAccent)
                    }

                    NavigationLink {
                        TTSInstructionSelectionView()
                    } label: {
                        HStack {
                            Text("Speech Instructions")
                                .foregroundColor(Theme.primaryText)
                            Spacer()
                            Text(
                                settingsService
                                    .availableTTSInstructions
                                    .first { $0.id == settingsService.settings.selectedTTSInstructionPresetId }?
                                    .name
                                ?? "Select…"
                            )
                            .foregroundColor(Theme.secondaryAccent)
                        }
                    }
                    .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                    if settingsService.settings.advancedTTSInstructionEnabled {
                        Text("using custom")
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryAccent)
                    }

                    Picker(selection: Binding(
                        get: { settingsService.selectedTTSProvider },
                        set: { settingsService.updateSelectedTTSProvider($0) }
                    )) {
                        ForEach(TTSProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                                .foregroundColor(Theme.primaryText)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TTS Provider")
                                .foregroundColor(Theme.primaryText)
                            Text("Kokoro runs on-device, no API needed")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                    .id("ttsProviderPicker-\(darkerModeObserver)")

                    // Only show voice picker for OpenAI
                    if settingsService.selectedTTSProvider == .openai {
                        Picker("Voice", selection: Binding(
                            get: { settingsService.openAITTSVoice },
                            set: { settingsService.updateSelectedTTSVoice(voice: $0) }
                        )) {
                            ForEach(settingsService.availableTTSVoices, id: \.self) { voice in
                                Text(voice.capitalized).tag(voice)
                                    .foregroundColor(Theme.primaryText)
                            }
                        }
                        .tint(Theme.secondaryAccent)
                        .id("voicePicker-\(darkerModeObserver)")
                    }
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Voice Detection
                Section("Voice Detection") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Silence Duration")
                                .foregroundColor(Theme.primaryText)
                            Spacer()
                            Text(String(format: "%.1fs", tempVADSilenceThreshold))
                                .font(.system(.body, design: .monospaced, weight: .regular))
                                .monospacedDigit()
                                .foregroundColor(Theme.secondaryAccent)
                        }
                        
                        Slider(
                            value: $tempVADSilenceThreshold,
                            in: 0.5...5.0,
                            step: 0.1,
                            onEditingChanged: { editing in
                                if !editing {
                                    let quant = (tempVADSilenceThreshold * 10).rounded() / 10
                                    if settingsService.vadSilenceThreshold != quant {
                                        settingsService.updateVADSilenceThreshold(quant)
                                    }
                                    tempVADSilenceThreshold = quant
                                }
                            }
                        )
                        .tint(Theme.accent)
                        
                        Text("How long to wait after you finish speaking before answering")
                            .font(.caption)
                            .foregroundColor(Theme.secondaryText)
                    }
                }
                .listRowBackground(Theme.menuAccent)
                
                // MARK: - Experimental Features
                Section("Experimental Features") {
                    Toggle(isOn: Binding(
                        get: { settingsService.webSearchEnabled },
                        set: { settingsService.updateAdvancedSetting(keyPath: \.webSearchEnabled, value: $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Web Search (Experimental)")
                                .foregroundColor(Theme.primaryText)
                            Text("GPT-4.1 and Grok 4 models")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Energy Saver Mode
                Section("Energy Saver") {
                    Toggle(isOn: Binding(
                        get: { settingsService.energySaverEnabled },
                        set: { settingsService.updateEnergySaverEnabled($0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Energy Saver Mode")
                                 .foregroundColor(Theme.primaryText)
                            Text("Circle won't move - reduces energy usage by ~30%")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Appearance
                Section("Appearance") {
                    Toggle(isOn: Binding(
                        get: { settingsService.darkerMode },
                        set: { settingsService.updateDarkerMode($0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Darker Mode")
                                .foregroundColor(Theme.primaryText)
                            Text("Rose Pine theme with deeper background")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                }
                .listRowBackground(Theme.menuAccent)

                Section("Audio Storage") {
                    Toggle(isOn: Binding(
                        get: { audioAutoDeleteEnabled },
                        set: { newValue in
                            audioAutoDeleteEnabled = newValue
                            let retention = newValue ? 7 : 0
                            historyService.updateAudioRetentionDays(retention)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Delete recordings after 7 days")
                                .foregroundColor(Theme.primaryText)
                            Text(audioAutoDeleteEnabled
                                 ? "Keeps only the latest week of audio clips to free space. Chat transcripts stay intact."
                                 : "Keeps all audio clips on this device until you delete them. Chat transcripts stay intact.")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)

                    Button(role: .destructive) {
                        showingAudioPurgeConfirmation = true
                    } label: {
                        Label("Delete Saved Audio", systemImage: "trash")
                    }
                    .foregroundColor(.red)
                    .confirmationDialog(
                        "Delete all saved audio clips?",
                        isPresented: $showingAudioPurgeConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Audio", role: .destructive) {
                            Task { await historyService.purgeAllAudio() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Audio clips live entirely on this device. Removing them frees storage—your chat transcripts stay intact.")
                    }
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - User API Keys
                Section {
                    NavigationLink {
                        UserAPIKeysView()
                    } label: {
                        HStack {
                            Image(systemName: "key.fill")
                            Text("Use Your Own API Keys")
                            Spacer()
                            if settingsService.useOwnOpenAIKey || settingsService.useOwnAnthropicKey ||
                               settingsService.useOwnGeminiKey || settingsService.useOwnXAIKey {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                } header: {
                    Text("API Keys")
                } footer: {
                    Text("Bypass the proxy and use your own API keys. You'll need to provide keys for each provider you want to use.")
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Advanced Settings
                Section("Advanced Settings") {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Text("Advanced Settings")
                    }
                    .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Sign Out
                Section {
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await AuthService.shared.signOut()
                            } catch {
                                print("Sign out error: \(error.localizedDescription)")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right.square")
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                } footer: {
                    if let user = AuthService.shared.currentUser {
                        Text("Signed in as \(user.email ?? "Unknown")")
                            .font(.caption)
                    }
                }
                .listRowBackground(Theme.menuAccent)
            }
            .onAppear {
                tempDefaultPlaybackSpeed = settingsService.settings.selectedDefaultPlaybackSpeed ?? 2.0
                let retentionDays = historyService.audioRetentionDays
                audioAutoDeleteEnabled = retentionDays != 0
                if retentionDays != 0 && retentionDays != 7 {
                    historyService.updateAudioRetentionDays(7)
                }
                tempVADSilenceThreshold = settingsService.vadSilenceThreshold
            }
            .onChange(of: settingsService.settings.selectedDefaultPlaybackSpeed) { _, newValue in
                tempDefaultPlaybackSpeed = newValue ?? 2.0
            }
            .onChange(of: historyService.audioRetentionDays) { _, newValue in
                audioAutoDeleteEnabled = newValue != 0
            }
            .onChange(of: settingsService.vadSilenceThreshold) { _, newValue in
                tempVADSilenceThreshold = newValue
            }
            .scrollContentBackground(.hidden)
            .foregroundColor(Theme.primaryText)
        }
        .navigationTitle("Settings")
    }
}

// Subview to pick one model for a single provider
struct ModelSelectionView: View {
    @EnvironmentObject var settingsService: SettingsService
    @Environment(\.presentationMode) var presentationMode
    let provider: LLMProvider

    // filter down to only this provider's models
    var models: [ModelInfo] {
        settingsService.availableModels.filter { $0.provider == provider }
    }

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            List {
                ForEach(models) { model in
                    Button {
                        // update & dismiss
                        settingsService.updateSelectedModel(provider: provider, modelId: model.id)
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .foregroundColor(Theme.primaryText)
                                Text(model.description)
                                    .font(.caption)
                                    .foregroundColor(Theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            // show a checkmark next to the current selection
                            if settingsService.settings.selectedModelIdPerProvider[provider] == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .listRowBackground(Theme.menuAccent)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(provider.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Generic Preset Selection View
struct GenericPresetSelectionView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var searchText = ""

    let availablePresets: [PromptPreset]
    let selectedPresetId: String?
    let categories: [(title: String, ids: [String])]
    let navigationTitle: String
    let onSelectPreset: (String) -> Void

    // Filter presets based on search text
    private var filteredPresets: [PromptPreset] {
        if searchText.isEmpty {
            return availablePresets
        } else {
            return availablePresets.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    // Helper to get presets for a specific category, considering the search filter
    private func presets(for categoryIDs: [String]) -> [PromptPreset] {
        filteredPresets.filter { categoryIDs.contains($0.id) }
            // Keep the original order from the source list
            .sorted { p1, p2 in
                guard let index1 = availablePresets.firstIndex(where: { $0.id == p1.id }),
                      let index2 = availablePresets.firstIndex(where: { $0.id == p2.id }) else {
                    return false
                }
                return index1 < index2
            }
    }

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            List {
                // If searching, show a flat list
                if !searchText.isEmpty {
                    ForEach(filteredPresets) { preset in
                        presetRow(preset)
                            .listRowBackground(Theme.menuAccent)
                    }
                } else {
                    // Otherwise, show sections
                    ForEach(categories, id: \.title) { category in
                        let categoryPresets = presets(for: category.ids)
                        // Only show section if it contains presets (relevant for future filtering)
                        if !categoryPresets.isEmpty {
                            Section(header: Text(category.title).foregroundColor(Theme.secondaryText)) {
                                ForEach(categoryPresets) { preset in
                                    presetRow(preset)
                                }
                            }
                            .listRowBackground(Theme.menuAccent)
                        }
                    }
                    // Optionally, show uncategorized items if any exist (good for maintenance)
                    let allCategorizedIds = categories.flatMap { $0.ids }
                    let uncategorizedPresets = filteredPresets.filter { !allCategorizedIds.contains($0.id) }
                    if !uncategorizedPresets.isEmpty && searchText.isEmpty {
                         Section(header: Text("Other").foregroundColor(Theme.secondaryText)) {
                            ForEach(uncategorizedPresets) { preset in
                                presetRow(preset)
                            }
                        }
                        .listRowBackground(Theme.menuAccent)
                    }
                }
            }
            .searchable(text: $searchText)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
        }
    }

    // Extracted row view for reuse
    @ViewBuilder
    private func presetRow(_ preset: PromptPreset) -> some View {
        Button {
            onSelectPreset(preset.id)
            presentationMode.wrappedValue.dismiss()
        } label: {
            HStack {
                 VStack(alignment: .leading) {
                    Text(preset.name)
                        .foregroundColor(Theme.primaryText)
                    if !preset.description.isEmpty { // Show description if available
                         Text(preset.description)
                            .font(.caption)
                            .foregroundColor(Theme.secondaryText)
                    }
                 }
                Spacer()
                if selectedPresetId == preset.id {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Specific Implementation for TTS Instructions
struct TTSInstructionSelectionView: View {
    @EnvironmentObject var settingsService: SettingsService

    // Define categories and their preset IDs specifically for TTS
    private let categories: [(title: String, ids: [String])] = [
        ("General / Supportive", ["default-happy", "critical-friend", "existential-crisis-companion", "morning-hype", "late-night-mode"]),
        ("Informative / Storytelling", ["passionate-educator", "vintage-broadcaster", "temporal-archivist", "internet-historian", "spaceship-ai"]),
        ("Fun", ["jaded-detective", "film-trailer-voice", "cyberpunk-street-kid", "rick-sanchez", "cosmic-horror-narrator", "oblivion-npc", "passive-aggressive", "cowboy"])
    ]

    var body: some View {
        GenericPresetSelectionView(
            availablePresets: settingsService.availableTTSInstructions,
            selectedPresetId: settingsService.settings.selectedTTSInstructionPresetId,
            categories: categories,
            navigationTitle: "Speech Instructions",
            onSelectPreset: { selectedId in
                settingsService.updateSelectedTTSInstruction(presetId: selectedId)
            }
        )
    }
}

// MARK: - Specific Implementation for System Prompts
struct SystemPromptSelectionView: View {
    @EnvironmentObject var settingsService: SettingsService

    // Define categories and their preset IDs specifically for System Prompts
    private let categories: [(title: String, ids: [String])] = [
        ("Skill & Knowledge Builders", [
            "learn-anything",
            "social-skills-coach",
            "relationship-argument-simulator",
            "health-fitness-trainer",
            "financial-advisor",
            "brainstorm-anything"
        ]),
        ("Companions & Guides", [
            "task-guide",
            "travel-guide",
            "conversational-companion",
            "voice-game-master"
        ]),
        ("Fun & Entertainment", [
            "incoherent-drunk",
            "edgy-gamer",
            "conspiracy-theorist",
            "life-coach-maniac",
            "victorian-traveler",
            "tech-bro"
        ]),
        ("Personal", ["remove-later"])
    ]

    var body: some View {
        GenericPresetSelectionView(
            availablePresets: settingsService.availableSystemPrompts,
            selectedPresetId: settingsService.settings.selectedSystemPromptPresetId,
            categories: categories,
            navigationTitle: "System Prompt",
            onSelectPreset: { selectedId in
                settingsService.updateSelectedSystemPrompt(presetId: selectedId)
            }
        )
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject private var settingsService: SettingsService
    @AppStorage("darkerMode") private var darkerModeObserver: Bool = true
    @State private var tempAdvancedTemperature: Float = SettingsService.defaultAdvancedTemperature
    @State private var tempAdvancedSystemPrompt: String = ""
    @State private var tempAdvancedTTSInstruction: String = ""
    private var systemPromptEditorHeight: CGFloat = 250
    private var ttsInstructionEditorHeight: CGFloat = 150

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            Form {
                // Temperature Section
                Section {
                    Toggle("Override Temperature", isOn: Binding(
                        get: { settingsService.settings.advancedTemperatureEnabled },
                        set: { enabled in
                            settingsService.updateAdvancedSetting(
                                keyPath: \.advancedTemperatureEnabled,
                                value: enabled
                            )
                        }
                    ))
                    .foregroundColor(Theme.primaryText)
                    .tint(Theme.secondaryAccent)

                    if settingsService.settings.advancedTemperatureEnabled {
                        HStack {
                            Slider(
                                value: $tempAdvancedTemperature,
                                in: 0...2,
                                step: 0.1,
                                onEditingChanged: { editing in
                                    if !editing {
                                        settingsService.updateAdvancedSetting(
                                            keyPath: \.advancedTemperature,
                                            value: tempAdvancedTemperature
                                        )
                                    }
                                }
                            )
                            .tint(Theme.accent)

                            Text(String(format: "%.1f", tempAdvancedTemperature))
                                .font(.system(.body, design: .monospaced, weight: .regular))
                                .monospacedDigit()
                                .foregroundColor(Theme.secondaryAccent)
                        }
                        .onAppear {
                            tempAdvancedTemperature = settingsService.settings.advancedTemperature
                                ?? SettingsService.defaultAdvancedTemperature
                        }
                        .onChange(of: settingsService.settings.advancedTemperature) { _, newValue in
                            if let newValue = newValue {
                                tempAdvancedTemperature = newValue
                            }
                        }

                        Button("Reset Temperature") {
                            settingsService.updateAdvancedSetting(
                                keyPath: \.advancedTemperature,
                                value: SettingsService.defaultAdvancedTemperature
                            )
                        }
                        .foregroundColor(Theme.accent)
                    }
                }
                .listRowBackground(Theme.menuAccent)

                // Max Tokens Section
                Section {
                    Toggle("Override Max Tokens", isOn: Binding(
                        get: { settingsService.settings.advancedMaxTokensEnabled },
                        set: { enabled in
                            settingsService.updateAdvancedSetting(
                                keyPath: \.advancedMaxTokensEnabled,
                                value: enabled
                            )
                        }
                    ))
                    .foregroundColor(Theme.primaryText)
                    .tint(Theme.secondaryAccent)

                    if settingsService.settings.advancedMaxTokensEnabled {
                        HStack {
                            TextField("", value: Binding(
                                get: { settingsService.settings.advancedMaxTokens ?? SettingsService.defaultAdvancedMaxTokens },
                                set: { newValue in
                                    settingsService.updateAdvancedSetting(
                                        keyPath: \.advancedMaxTokens,
                                        value: newValue
                                    )
                                }
                            ), format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .foregroundColor(Theme.primaryText)
                            .background(Theme.overlayMask.opacity(0.5))
                            .cornerRadius(4)

                            Button("Reset Max Tokens") {
                                settingsService.updateAdvancedSetting(
                                    keyPath: \.advancedMaxTokens,
                                    value: SettingsService.defaultAdvancedMaxTokens
                                )
                            }
                            .foregroundColor(Theme.accent)
                        }
                    }
                }
                .listRowBackground(Theme.menuAccent)

                // System Prompt Override
                textOverrideSection(
                    toggleTitle: "Override System Prompt",
                    isEnabled: Binding(
                        get: { settingsService.settings.advancedSystemPromptEnabled },
                        set: { enabled in
                            settingsService.updateAdvancedSetting(
                                keyPath: \.advancedSystemPromptEnabled,
                                value: enabled
                            )
                            if enabled {
                                tempAdvancedSystemPrompt = settingsService.settings.advancedSystemPrompt
                                    ?? SettingsService.defaultAdvancedSystemPrompt
                            }
                        }
                    ),
                    tempText: $tempAdvancedSystemPrompt,
                    height: systemPromptEditorHeight,
                    defaultText: SettingsService.defaultAdvancedSystemPrompt,
                    saveText: { newPrompt in
                        settingsService.updateAdvancedSetting(
                            keyPath: \.advancedSystemPrompt,
                            value: newPrompt
                        )
                    }
                )

                // TTS Instruction Override
                textOverrideSection(
                    toggleTitle: "Override TTS Instruction",
                    isEnabled: Binding(
                        get: { settingsService.settings.advancedTTSInstructionEnabled },
                        set: { enabled in
                            settingsService.updateAdvancedSetting(
                                keyPath: \.advancedTTSInstructionEnabled,
                                value: enabled
                            )
                            if enabled {
                                tempAdvancedTTSInstruction = settingsService.settings.advancedTTSInstruction
                                    ?? SettingsService.defaultAdvancedTTSInstruction
                            }
                        }
                    ),
                    tempText: $tempAdvancedTTSInstruction,
                    height: ttsInstructionEditorHeight,
                    defaultText: SettingsService.defaultAdvancedTTSInstruction,
                    saveText: { newInstruction in
                        settingsService.updateAdvancedSetting(
                            keyPath: \.advancedTTSInstruction,
                            value: newInstruction
                        )
                    }
                )
            }
            .scrollContentBackground(.hidden)
            .onAppear {
                tempAdvancedSystemPrompt = settingsService.settings.advancedSystemPrompt
                    ?? SettingsService.defaultAdvancedSystemPrompt
                tempAdvancedTTSInstruction = settingsService.settings.advancedTTSInstruction
                    ?? SettingsService.defaultAdvancedTTSInstruction
            }
            .onDisappear {
                let ss = settingsService.settings
                if ss.advancedSystemPromptEnabled,
                   tempAdvancedSystemPrompt != ss.advancedSystemPrompt {
                    settingsService.updateAdvancedSetting(
                        keyPath: \.advancedSystemPrompt,
                        value: tempAdvancedSystemPrompt
                    )
                }
                if ss.advancedTTSInstructionEnabled,
                   tempAdvancedTTSInstruction != ss.advancedTTSInstruction {
                    settingsService.updateAdvancedSetting(
                        keyPath: \.advancedTTSInstruction,
                        value: tempAdvancedTTSInstruction
                    )
                }
            }
            .navigationTitle("Advanced Settings")
        }
    }

    // MARK: ––––– Reusable Text‐Override Section –––––
    @ViewBuilder
    private func textOverrideSection(
        toggleTitle: String,
        isEnabled: Binding<Bool>,
        tempText: Binding<String>,
        height: CGFloat,
        defaultText: String,
        saveText: @escaping (String) -> Void
    ) -> some View {
        Section {
            Toggle(toggleTitle, isOn: isEnabled)
                .foregroundColor(Theme.primaryText)
                .tint(Theme.secondaryAccent)

            if isEnabled.wrappedValue {
                TextEditor(text: tempText)
                    .frame(height: height)
                    .foregroundColor(Theme.primaryText)
                    .background(Theme.overlayMask.opacity(0.3))
                    .scrollContentBackground(.hidden)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderColor))

                Button("Reset \(toggleTitle.replacingOccurrences(of: "Override ", with: ""))") {
                    tempText.wrappedValue = defaultText
                    saveText(defaultText)
                }
                .foregroundColor(Theme.accent)
            }
        }
        .listRowBackground(Theme.menuAccent)
    }
}

#if DEBUG
#Preview {
    let env = PreviewEnvironment.make()

    NavigationStack {
        SettingsView()
    }
    .environmentObject(env.settings)
    .environmentObject(env.viewModel)
    .environmentObject(env.history)
    .environmentObject(env.audio)
    .environmentObject(env.chat)
    .environmentObject(env.auth)
    .preferredColorScheme(.dark)
}
#endif
