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
                profileSection
                appDefaultsSection
                modelSelectionSection
                reasoningSection
                customizeChatSection
                voiceDetectionSection
                featuresSection
                audioStorageSection
                apiKeysSection
                advancedSection
                signOutSection
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

    // MARK: - Section Views

    private var profileSection: some View {
        Section {
            NavigationLink {
                ProfileFormView(isInitial: false)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    Text("User Profile")
                        .foregroundColor(Theme.primaryText)
                    Spacer()
                    if !settingsService.settings.userProfileEnabled {
                        Text("Disabled")
                            .foregroundColor(Theme.secondaryText.opacity(0.6))
                            .font(.subheadline)
                    } else if let name = settingsService.settings.userDisplayName, !name.isEmpty {
                        Text(name)
                            .foregroundColor(Theme.secondaryAccent)
                            .font(.subheadline)
                    }
                }
            }
            .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)
        }
    }

    private var appDefaultsSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundColor(Theme.secondaryAccent)
                    .frame(width: 32)
                Picker("Provider", selection: Binding(
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
            }
            .listRowBackground(Theme.menuAccent)

            HStack(spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.title2)
                    .foregroundColor(Theme.secondaryAccent)
                    .frame(width: 32)

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
            .listRowBackground(Theme.menuAccent)
        } header: {
            Text("Defaults")
        }
    }

    private var modelSelectionSection: some View {
        Section {
            ForEach(LLMProvider.userFacing) { provider in
                NavigationLink {
                    ModelSelectionView(provider: provider)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cpu")
                            .font(.title2)
                            .foregroundColor(Theme.secondaryAccent)
                            .frame(width: 32)
                        Text(provider.rawValue)
                            .foregroundColor(Theme.primaryText)
                        Spacer()
                        if let selectedId = settingsService.settings.selectedModelIdPerProvider[provider],
                           let selModel = settingsService.availableModels.first(where: { $0.id == selectedId }) {
                            Text(selModel.name)
                              .foregroundColor(Theme.secondaryAccent)
                              .font(.subheadline)
                        }
                    }
                }
                .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                .listRowBackground(Theme.menuAccent)
            }
        } header: {
            Text("Models")
        }
    }

    private var reasoningSection: some View {
        Section {
            NavigationLink {
                ReasoningSettingsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "brain")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    Text("Reasoning")
                        .foregroundColor(Theme.primaryText)
                    Spacer()
                    if settingsService.reasoningEnabled {
                        Text("On")
                            .foregroundColor(Theme.secondaryAccent)
                            .font(.subheadline)
                    }
                }
            }
            .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)
        }
    }

    private var customizeChatSection: some View {
        Section {
            NavigationLink {
                SystemPromptSelectionView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    Text("System Prompt")
                        .foregroundColor(Theme.primaryText)
                    Spacer()
                    if settingsService.settings.advancedSystemPromptEnabled {
                        Text("Custom")
                            .foregroundColor(Theme.accent)
                            .font(.caption)
                    } else {
                        Text(
                            settingsService
                                .availableSystemPrompts
                                .first { $0.id == settingsService.settings.selectedSystemPromptPresetId }?
                                .name
                            ?? "None"
                        )
                        .foregroundColor(Theme.secondaryAccent)
                        .font(.subheadline)
                    }
                }
            }
            .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)

            // TTS instructions only supported by OpenAI, not Kokoro
            if settingsService.selectedTTSProvider != .kokoro {
                NavigationLink {
                    TTSInstructionSelectionView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.circle")
                            .font(.title2)
                            .foregroundColor(Theme.secondaryAccent)
                            .frame(width: 32)
                        Text("Speech Style")
                            .foregroundColor(Theme.primaryText)
                        Spacer()
                        if settingsService.settings.advancedTTSInstructionEnabled {
                            Text("Custom")
                                .foregroundColor(Theme.accent)
                                .font(.caption)
                        } else {
                            Text(
                                settingsService
                                    .availableTTSInstructions
                                    .first { $0.id == settingsService.settings.selectedTTSInstructionPresetId }?
                                    .name
                                ?? "None"
                            )
                            .foregroundColor(Theme.secondaryAccent)
                            .font(.subheadline)
                        }
                    }
                }
                .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
                .listRowBackground(Theme.menuAccent)
            }

            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2")
                    .font(.title2)
                    .foregroundColor(Theme.secondaryAccent)
                    .frame(width: 32)
                Picker("TTS", selection: Binding(
                    get: { settingsService.selectedTTSProvider },
                    set: { settingsService.updateSelectedTTSProvider($0) }
                )) {
                    ForEach(TTSProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                            .foregroundColor(Theme.primaryText)
                    }
                }
                .tint(Theme.secondaryAccent)
                .id("ttsProviderPicker-\(darkerModeObserver)")
            }
            .listRowBackground(Theme.menuAccent)

            // Show voice picker for both providers
            if settingsService.selectedTTSProvider == .openai {
                HStack(spacing: 12) {
                    Image(systemName: "person.wave.2")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
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
                .listRowBackground(Theme.menuAccent)
            } else if settingsService.selectedTTSProvider == .kokoro {
                HStack(spacing: 12) {
                    Image(systemName: "person.wave.2")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    Picker("Voice", selection: Binding(
                        get: { settingsService.kokoroTTSVoice },
                        set: { settingsService.updateSelectedKokoroVoice(voice: $0) }
                    )) {
                        ForEach(settingsService.availableKokoroVoices) { voice in
                            Text(voice.displayName).tag(voice.id)
                                .foregroundColor(Theme.primaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
                    .id("kokoroVoicePicker-\(darkerModeObserver)")
                }
                .listRowBackground(Theme.menuAccent)
            }
        } header: {
            Text("Chat Experience")
        }
    }

    private var voiceDetectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
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
                .padding(.leading, 44)
            }
            .listRowBackground(Theme.menuAccent)
        } header: {
            Text("Voice Input")
        }
    }

    private var featuresSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settingsService.webSearchEnabled },
                set: { settingsService.updateAdvancedSetting(keyPath: \.webSearchEnabled, value: $0) }
            )) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Web Search")
                            .foregroundColor(Theme.primaryText)
                        Text("GPT · Grok")
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryText.opacity(0.7))
                    }
                }
            }
            .tint(Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)

            Toggle(isOn: Binding(
                get: { settingsService.energySaverEnabled },
                set: { settingsService.updateEnergySaverEnabled($0) }
            )) {
                HStack(spacing: 12) {
                    Image(systemName: "leaf")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Energy Saver")
                            .foregroundColor(Theme.primaryText)
                        Text("Reduce battery usage")
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryText.opacity(0.7))
                    }
                }
            }
            .tint(Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)

            Toggle(isOn: Binding(
                get: { settingsService.darkerMode },
                set: { settingsService.updateDarkerMode($0) }
            )) {
                HStack(spacing: 12) {
                    Image(systemName: "moon.fill")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Darker Mode")
                            .foregroundColor(Theme.primaryText)
                        Text("Deeper background")
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryText.opacity(0.7))
                    }
                }
            }
            .tint(Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)
        } header: {
            Text("Preferences")
        }
    }

    private var audioStorageSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { audioAutoDeleteEnabled },
                set: { newValue in
                    audioAutoDeleteEnabled = newValue
                    let retention = newValue ? 7 : 0
                    historyService.updateAudioRetentionDays(retention)
                }
            )) {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Delete Audio")
                            .foregroundColor(Theme.primaryText)
                        Text(audioAutoDeleteEnabled ? "After 7 days" : "Never")
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryText.opacity(0.7))
                    }
                }
            }
            .tint(Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)

            Button(role: .destructive) {
                showingAudioPurgeConfirmation = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .frame(width: 32)
                    Text("Delete All Audio")
                }
            }
            .foregroundColor(Theme.accent)
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
                Text("Audio clips are stored on this device. Transcripts stay intact.")
            }
            .listRowBackground(Theme.menuAccent)
        } header: {
            Text("Storage")
        }
    }

    private var apiKeysSection: some View {
        Section {
            NavigationLink {
                UserAPIKeysView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    Text("API Keys")
                        .foregroundColor(Theme.primaryText)
                    Spacer()
                    if settingsService.useOwnOpenAIKey || settingsService.useOwnAnthropicKey ||
                       settingsService.useOwnGeminiKey || settingsService.useOwnXAIKey ||
                       settingsService.useOwnReplicateKey {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.secondaryAccent)
                    }
                }
            }
            .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)
        }
    }

    private var advancedSection: some View {
        Section {
            NavigationLink {
                AdvancedSettingsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.2")
                        .font(.title2)
                        .foregroundColor(Theme.secondaryAccent)
                        .frame(width: 32)
                    Text("Advanced")
                        .foregroundColor(Theme.primaryText)
                }
            }
            .foregroundStyle(Theme.primaryText, Theme.secondaryAccent)
            .listRowBackground(Theme.menuAccent)
        }
    }

    private var signOutSection: some View {
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
                HStack(spacing: 12) {
                    Image(systemName: "arrow.right.square")
                        .font(.title2)
                        .frame(width: 32)
                    Text("Sign Out")
                    Spacer()
                }
            }
            .listRowBackground(Theme.menuAccent)
        }
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
