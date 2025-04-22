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
    @State private var isTopLevelActive = true // Add this state
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SettingsView")
    
    var body: some View {
        NavigationView { // Or Form, depending on your structure
            Form {
                // MARK: - Model Selection
                Section("LLM Models") {
                    ForEach(LLMProvider.allCases) { provider in
                        NavigationLink {
                            ModelSelectionView(provider: provider, isParentTopLevelActive: $isTopLevelActive)
                        } label: {
                            HStack {
                                Text(provider.rawValue)
                                Spacer()
                                // show the name of the currently selected model in secondary text
                                if let selectedId = settingsService.settings.selectedModelIdPerProvider[provider],
                                   let selModel = settingsService.availableModels.first(where: { $0.id == selectedId }) {
                                    Text(selModel.name)
                                      .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                
                // MARK: - Prompt Presets
                Section("System Prompt") {
                    Picker("Preset", selection: Binding(
                        get: { settingsService.settings.selectedSystemPromptPresetId ?? "" },
                        set: { settingsService.updateSelectedSystemPrompt(presetId: $0) }
                    )) {
                        ForEach(settingsService.availableSystemPrompts) { preset in
                            VStack(alignment: .leading) {
                                Text(preset.name).tag(preset.id)
                                Text(preset.description).font(.caption).foregroundColor(.gray)
                            }
                        }
                    }
                }
                
                Section("TTS Instructions") {
                    NavigationLink {
                        TTSInstructionSelectionView(isParentTopLevelActive: $isTopLevelActive)
                    } label: {
                        HStack {
                            Text("Preset")
                            Spacer()
                            Text(
                                settingsService
                                    .availableTTSInstructions
                                    .first { $0.id == settingsService.settings.selectedTTSInstructionPresetId }?
                                    .name
                                ?? "Select…"
                            )
                            .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("TTS Voice") {
                    Picker("Voice", selection: Binding(
                        get: { settingsService.openAITTSVoice },
                        set: { settingsService.updateSelectedTTSVoice(voice: $0) }
                    )) {
                        ForEach(settingsService.availableTTSVoices, id: \.self) { voice in
                            Text(voice.capitalized).tag(voice)
                        }
                    }
                }
                
                // MARK: - App Defaults
                Section("App Defaults") {
                    Picker("Default Provider", selection: Binding(
                        get: { settingsService.settings.selectedDefaultProvider ?? .claude },
                        set: { settingsService.updateDefaultProvider(provider: $0) }
                    )) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }

                    HStack {
                        Text("Default Playback Speed:")
                        Slider(value: Binding(
                            get: { settingsService.settings.selectedDefaultPlaybackSpeed ?? 2.0 },
                            set: { settingsService.updateDefaultPlaybackSpeed(speed: $0) }
                        ), in: 0.2...4.0, step: 0.1)
                        Text(String(format: "%.1fx", settingsService.settings.selectedDefaultPlaybackSpeed ?? 2.0))
                            .frame(width: 40)
                    }
                }
                
                // MARK: - Advanced Settings
                DisclosureGroup("Advanced Settings", isExpanded: $showingAdvanced) {
                    VStack(alignment: .leading) {
                        Text("Overrides preset selections above.")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.bottom)
                        
                        // Temperature Slider
                        HStack {
                            Text("Temperature:")
                            Slider(value: Binding(
                                get: { settingsService.settings.advancedTemperature ?? settingsService.activeTemperature }, // Show current or default
                                set: { settingsService.updateAdvancedSetting(keyPath: \.advancedTemperature, value: $0) }
                            ), in: 0.0...2.0, step: 0.1)
                            Text(String(format: "%.1f", settingsService.settings.advancedTemperature ?? settingsService.activeTemperature))
                                .frame(width: 40)
                        }
                        
                        // Max Tokens Input (replacing stepper)
                        HStack {
                            Text("Max Tokens:")
                            TextField("", value: Binding(
                                get: { settingsService.settings.advancedMaxTokens ?? settingsService.activeMaxTokens },
                                set: { settingsService.updateAdvancedSetting(keyPath: \.advancedMaxTokens, value: $0) }
                            ), format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        }
                        
                        // Custom System Prompt TextEditor
                        VStack(alignment: .leading) {
                            Text("Custom System Prompt:")
                            TextEditor(text: Binding(
                                get: { settingsService.settings.advancedSystemPrompt ?? "" },
                                set: { settingsService.updateAdvancedSetting(keyPath: \.advancedSystemPrompt, value: $0.isEmpty ? nil : $0) } // Store nil if empty
                            ))
                            .frame(height: 150)
                            .border(Color.gray.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .padding(.top)
                        
                        // Custom TTS Instruction TextEditor
                        VStack(alignment: .leading) {
                            Text("Custom TTS Instruction:")
                            TextEditor(text: Binding(
                                get: { settingsService.settings.advancedTTSInstruction ?? "" },
                                set: { settingsService.updateAdvancedSetting(keyPath: \.advancedTTSInstruction, value: $0.isEmpty ? nil : $0) } // Store nil if empty
                            ))
                            .frame(height: 80)
                            .border(Color.gray.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .padding(.top)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                logger.info("SettingsView appeared, pausing main activities.")
                viewModel.pauseMainActivities()
                isTopLevelActive = true // Reset flag when SettingsView appears/reappears
            }
            .onDisappear {
                // Only resume listening if SettingsView is disappearing while it *thought*
                // it was the top-level view (meaning we're not just navigating deeper).
                if isTopLevelActive {
                    logger.info("SettingsView disappeared (presumed exit), resuming listening.")
                    viewModel.startListening()
                } else {
                     logger.info("SettingsView disappeared (navigating deeper), NOT resuming.")
                }
            }
        }
        .navigationViewStyle(.stack) // Use stack style if needed
    }
}

// Subview to pick one model for a single provider
struct ModelSelectionView: View {
    @EnvironmentObject var settingsService: SettingsService
    @Environment(\.presentationMode) var presentationMode
    let provider: LLMProvider
    @Binding var isParentTopLevelActive: Bool

    // filter down to only this provider's models
    var models: [ModelInfo] {
        settingsService.availableModels.filter { $0.provider == provider }
    }

    var body: some View {
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
                            Text(model.description)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        // show a checkmark next to the current selection
                        if settingsService.settings.selectedModelIdPerProvider[provider] == model.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain) // keep the row tappable without default button styling
            }
        }
        .navigationTitle(provider.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Tell the parent it's no longer the top active view
            isParentTopLevelActive = false
        }
    }
}

struct TTSInstructionSelectionView: View {
    @EnvironmentObject var settingsService: SettingsService
    @Environment(\.presentationMode) var presentationMode
    @State private var searchText = ""
    @Binding var isParentTopLevelActive: Bool

    // Define categories and their preset IDs
    private let categories: [(title: String, ids: [String])] = [
        ("General / Supportive", ["default-happy", "critical-friend", "existential-crisis-companion", "morning-hype", "late-night-mode"]),
        ("Informative / Storytelling", ["passionate-educator", "vintage-broadcaster", "temporal-archivist", "internet-historian", "spaceship-ai"]),
        ("Fun", ["jaded-detective", "film-trailer-voice", "cyberpunk-street-kid", "rick-sanchez", "cosmic-horror-narrator", "oblivion-npc", "passive-aggressive"]),
        ("Advanced", ["custom"]) // Keep custom separate
    ]

    // Filter presets based on search text
    private var filteredPresets: [PromptPreset] {
        if searchText.isEmpty {
            return settingsService.availableTTSInstructions
        } else {
            return settingsService.availableTTSInstructions.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    // Helper to get presets for a specific category, considering the search filter
    private func presets(for categoryIDs: [String]) -> [PromptPreset] {
        filteredPresets.filter { categoryIDs.contains($0.id) }
            // Keep the original order from SettingsService
            .sorted { p1, p2 in
                guard let index1 = settingsService.availableTTSInstructions.firstIndex(where: { $0.id == p1.id }),
                      let index2 = settingsService.availableTTSInstructions.firstIndex(where: { $0.id == p2.id }) else {
                    return false
                }
                return index1 < index2
            }
    }

    var body: some View {
        List {
            // If searching, show a flat list
            if !searchText.isEmpty {
                ForEach(filteredPresets) { preset in
                    presetRow(preset)
                }
            } else {
                // Otherwise, show sections
                ForEach(categories, id: \.title) { category in
                    let categoryPresets = presets(for: category.ids)
                    // Only show section if it contains presets (relevant for future filtering)
                    if !categoryPresets.isEmpty {
                        Section(header: Text(category.title)) {
                            ForEach(categoryPresets) { preset in
                                presetRow(preset)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle("TTS Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Tell the parent it's no longer the top active view
            isParentTopLevelActive = false
        }
    }

    // Extracted row view for reuse
    @ViewBuilder
    private func presetRow(_ preset: PromptPreset) -> some View {
        Button {
            settingsService.updateSelectedTTSInstruction(presetId: preset.id)
            presentationMode.wrappedValue.dismiss()
        } label: {
            HStack {
                Text(preset.name)
                Spacer()
                if settingsService.settings.selectedTTSInstructionPresetId == preset.id {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
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

