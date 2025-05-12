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
    @State private var showingAdvanced = false // State for DisclosureGroup
    @State private var tempDefaultPlaybackSpeed: Float = 2.0
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SettingsView")
    
    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            Form {
                // MARK: - App Defaults
                Section("App Defaults") {
                    Picker("LLM Provider", selection: Binding(
                        get: { settingsService.settings.selectedDefaultProvider ?? .claude },
                        set: { settingsService.updateDefaultProvider(provider: $0) }
                    )) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                                .foregroundColor(Theme.primaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)

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
                    .onAppear {
                        tempDefaultPlaybackSpeed = settingsService.settings.selectedDefaultPlaybackSpeed ?? 2.0
                    }
                    .onChange(of: settingsService.settings.selectedDefaultPlaybackSpeed) { oldValue, newValue in
                        tempDefaultPlaybackSpeed = newValue ?? 2.0
                    }
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Model Selection
                Section("LLM Models") {
                    ForEach(LLMProvider.allCases) { provider in
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
                            Text("Only GPT-4.1 models")
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
                            Text("Static circle mode, reduces energy usage by ~35%")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .tint(Theme.secondaryAccent)
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
        ("Helpful Assistants", ["learn-anything", "conversational-companion", "task-guide", "social-skills-coach", "brainstorm-anything"]),
        ("Simulators & Games", ["relationship-argument-simulator", "voice-game-master"]),
        ("Fun", ["incoherent-drunk", "edgy-gamer", "conspiracy-theorist", "life-coach-maniac", "victorian-traveler", "tech-bro"]),
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

#Preview {
    // Mock service for preview
    let settings = SettingsService()
    // You might want to pre-populate settingsService.settings for a better preview
    
    return NavigationStack { // Add NavigationStack for preview context
        SettingsView()
    }
    .environmentObject(settings)
    .preferredColorScheme(.dark)
}
