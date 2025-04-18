//
//  SettingsView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 18.04.25.
//

import SwiftUI

struct SettingsView: View {
    // Use @StateObject if SettingsService is initialized here,
    // or @EnvironmentObject if passed from parent (preferred)
    @EnvironmentObject var settingsService: SettingsService
    @State private var showingAdvanced = false // State for DisclosureGroup

    var body: some View {
        Form {
            // MARK: - Model Selection
            Section("LLM Models") {
                ForEach(LLMProvider.allCases) { provider in
                     let available = settingsService.availableModels.filter { $0.provider == provider }
                     // Use non-optional binding for Picker selection
                     Picker(provider.rawValue, selection: Binding(
                         get: { settingsService.settings.selectedModelIdPerProvider[provider] ?? "" },
                         set: { settingsService.updateSelectedModel(provider: provider, modelId: $0) }
                     )) {
                         ForEach(available) { model in
                             VStack(alignment: .leading) {
                                 Text(model.name).tag(model.id)
                                 Text(model.description).font(.caption).foregroundColor(.gray)
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
                 Picker("Preset", selection: Binding(
                     get: { settingsService.settings.selectedTTSInstructionPresetId ?? "" },
                     set: { settingsService.updateSelectedTTSInstruction(presetId: $0) }
                 )) {
                     ForEach(settingsService.availableTTSInstructions) { preset in
                         VStack(alignment: .leading) {
                             Text(preset.name).tag(preset.id)
                             Text(preset.description).font(.caption).foregroundColor(.gray)
                         }
                     }
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

                     // Max Tokens Stepper
                     Stepper("Max Tokens: \(settingsService.settings.advancedMaxTokens ?? settingsService.activeMaxTokens)",
                             value: Binding(
                                 get: { settingsService.settings.advancedMaxTokens ?? settingsService.activeMaxTokens },
                                 set: { settingsService.updateAdvancedSetting(keyPath: \.advancedMaxTokens, value: $0) }
                             ),
                             in: 512...16384, // Example range
                             step: 256)


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
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
             // Explicitly save settings when view disappears, just in case
             settingsService.saveSettings()
        }
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

