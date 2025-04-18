// SettingsService.swift
import Foundation
import OSLog
import Combine // Import Combine for ObservableObject

@MainActor // Ensure updates happen on the main thread
class SettingsService: ObservableObject { // Make ObservableObject
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SettingsService")

    // --- Published Settings Data ---
    @Published var settings: SettingsData = SettingsData()

    // --- Available Options (Hardcoded Placeholders) ---
    let availableModels: [ModelInfo] = [
        // Claude
        ModelInfo(id: "claude-3-7-sonnet-latest", name: "Claude 3.7 Sonnet", description: "Smartest, most capable", provider: .claude),
        ModelInfo(id: "claude-3-5-sonnet-latest", name: "Claude 3.5 Sonnet", description: "Smartest, most emotinally intelligent", provider: .claude),
        ModelInfo(id: "claude-3-5-haiku-latest", name: "Claude 3.5 Haiku", description: "Fast, good for simple responses", provider: .claude),
        // Gemini
        ModelInfo(id: "gemini-2.5-flash-preview-04-17", name: "Gemini 2.5 Flash", description: "Fast, very capable", provider: .gemini),
        ModelInfo(id: "gemini-2.5-pro-exp-03-25", name: "Gemini 2.5 Pro", description: "Highly intelligent, thinks before responding", provider: .gemini),
        ModelInfo(id: "gemini-2.0-flash", name: "Gemini 2 Flash", description: "Very fast, everyday tasks", provider: .gemini),
        // Add OpenAI models if needed
    ]

    let availableSystemPrompts: [PromptPreset] = [
        PromptPreset(id: "default-helpful", name: "Helpful Assistant", description: "Standard helpful, concise", fullPrompt: "You are a helpful voice assistant. Keep your responses concise and conversational."),
        PromptPreset(id: "casual-friend", name: "Casual Friend", description: "Informal, friendly chat", fullPrompt: "You are a friendly, casual AI assistant. Talk like you're chatting with a friend."),
        PromptPreset(id: "expert-coder", name: "Coding Expert", description: "Focused on code assistance", fullPrompt: "You are an expert programmer AI. Provide clear, accurate code examples and explanations."),
        PromptPreset(id: "custom", name: "Custom", description: "Use prompt from Advanced section", fullPrompt: ""), // Placeholder for custom
    ]

    let availableTTSInstructions: [PromptPreset] = [
        PromptPreset(id: "default-clear", name: "Clear & Pleasant", description: "Standard clear voice", fullPrompt: "Speak in a clear and pleasant manner."),
        PromptPreset(id: "energetic", name: "Energetic", description: "More enthusiastic tone", fullPrompt: "Speak with an energetic and enthusiastic tone."),
        PromptPreset(id: "calm", name: "Calm & Relaxed", description: "Softer, calmer tone", fullPrompt: "Speak in a calm and relaxed tone."),
        PromptPreset(id: "custom", name: "Custom", description: "Use instruction from Advanced", fullPrompt: ""), // Placeholder for custom
    ]

    // --- Persistence ---
    private let persistenceFileName = "settings.json"
    private var persistenceURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(persistenceFileName)
    }

    // --- API Keys (Read-only access for now) ---
    var anthropicAPIKey: String? { APIKeys.anthropic }
    var geminiAPIKey: String? { APIKeys.gemini }
    var openaiAPIKey: String? { APIKeys.openai }

    // --- Hardcoded OpenAI TTS details (Could be moved to SettingsData if needed) ---
    let openAITTSModel = "gpt-4o-mini-tts"
    let openAITTSVoice = "nova" // Or alloy, echo, fable, onyx, shimmer
    let openAITTSFormat = "opus" // Other options: opus, aac, flac, pcm, mp3
    let maxTTSChunkLength = 4000 // Keep hardcoded for now

    init() {
        loadSettings()
        validateKeysAndPrompts() // Keep validation
        logger.info("SettingsService initialized.")

        // Set default model selections if none are saved
        setDefaultModelsIfNeeded()
        // Set default prompt selections if none are saved
        setDefaultPromptsIfNeeded()
    }

     // --- Default Selections ---
     private func setDefaultModelsIfNeeded() {
         var changed = false
         for provider in LLMProvider.allCases {
             if settings.selectedModelIdPerProvider[provider] == nil {
                 // Find the first available model for this provider
                 if let defaultModel = availableModels.first(where: { $0.provider == provider }) {
                     settings.selectedModelIdPerProvider[provider] = defaultModel.id
                     logger.info("Setting default model for \(provider.rawValue): \(defaultModel.name)")
                     changed = true
                 }
             }
         }
         if changed {
             saveSettings()
         }
     }

    private func setDefaultPromptsIfNeeded() {
        var changed = false
        if settings.selectedSystemPromptPresetId == nil, let defaultPrompt = availableSystemPrompts.first(where: { $0.id != "custom" }) {
             settings.selectedSystemPromptPresetId = defaultPrompt.id
             logger.info("Setting default system prompt: \(defaultPrompt.name)")
             changed = true
        }
        if settings.selectedTTSInstructionPresetId == nil, let defaultTTS = availableTTSInstructions.first(where: { $0.id != "custom" }) {
             settings.selectedTTSInstructionPresetId = defaultTTS.id
             logger.info("Setting default TTS instruction: \(defaultTTS.name)")
             changed = true
        }
        if changed {
             saveSettings()
        }
    }


    // MARK: - Active Setting Accessors

    // Get the currently active model ID for a given provider
    func activeModelId(for provider: LLMProvider) -> String? {
        return settings.selectedModelIdPerProvider[provider]
    }

    // Get the currently active system prompt
    var activeSystemPrompt: String? {
        // Prioritize advanced override
        if let advanced = settings.advancedSystemPrompt, !advanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return advanced
        }
        // Fallback to selected preset
        guard let selectedId = settings.selectedSystemPromptPresetId,
              let preset = availableSystemPrompts.first(where: { $0.id == selectedId }),
              preset.id != "custom" // Don't use the "custom" placeholder prompt itself
        else {
            // Fallback to the very first non-custom prompt if selection is invalid or missing
            return availableSystemPrompts.first(where: { $0.id != "custom" })?.fullPrompt
        }
        return preset.fullPrompt
    }

    // Get the currently active TTS instruction
    var activeTTSInstruction: String? {
        // Prioritize advanced override
        if let advanced = settings.advancedTTSInstruction, !advanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return advanced
        }
        // Fallback to selected preset
        guard let selectedId = settings.selectedTTSInstructionPresetId,
              let preset = availableTTSInstructions.first(where: { $0.id == selectedId }),
              preset.id != "custom"
        else {
             // Fallback to the very first non-custom instruction if selection is invalid or missing
             return availableTTSInstructions.first(where: { $0.id != "custom" })?.fullPrompt
        }
        return preset.fullPrompt
    }

    // Get the currently active temperature
    var activeTemperature: Float {
        // Prioritize advanced override
        return settings.advancedTemperature ?? 1.0 // Default temperature
    }

    // Get the currently active max tokens
    var activeMaxTokens: Int {
        // Prioritize advanced override
        return settings.advancedMaxTokens ?? 4096 // Default max tokens (adjust as needed)
    }

    // MARK: - Persistence
    func loadSettings() {
        guard let url = persistenceURL else {
            logger.error("Could not get persistence URL for loading settings.")
            settings = SettingsData() // Use defaults
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
             logger.info("No settings file found. Using default settings.")
             settings = SettingsData() // Use defaults
             return
        }

        do {
            let data = try Data(contentsOf: url)
            settings = try JSONDecoder().decode(SettingsData.self, from: data)
            logger.info("Settings loaded successfully.")
        } catch {
            logger.error("Failed to load or decode settings: \(error.localizedDescription). Using defaults.")
            settings = SettingsData() // Use defaults on error
        }
    }

    func saveSettings() {
        guard let url = persistenceURL else {
            logger.error("Could not get persistence URL for saving settings.")
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(settings)
            try data.write(to: url, options: [.atomicWrite])
            logger.info("Settings saved successfully.")
        } catch {
            logger.error("Failed to encode or save settings: \(error.localizedDescription)")
        }
    }


    private func validateKeysAndPrompts() {
        if anthropicAPIKey == nil || anthropicAPIKey!.isEmpty || anthropicAPIKey == "YOUR_ANTHROPIC_API_KEY" {
             logger.warning("Anthropic API Key is not set in APIKeys.swift.")
         }
         if geminiAPIKey == nil || geminiAPIKey!.isEmpty || geminiAPIKey == "YOUR_GEMINI_API_KEY" {
             logger.warning("Gemini API Key is not set in APIKeys.swift.")
         }
         if openaiAPIKey == nil || openaiAPIKey!.isEmpty || openaiAPIKey == "YOUR_OPENAI_API_KEY" {
             logger.warning("OpenAI API Key (for TTS) is not set in APIKeys.swift.")
         }

        // Validation for active prompt can be simplified or removed if defaults handle it
        if activeSystemPrompt == nil || activeSystemPrompt!.isEmpty {
             logger.warning("Active system prompt is currently empty.")
        }
        if activeTTSInstruction == nil || activeTTSInstruction!.isEmpty {
            logger.warning("Active TTS instruction is currently empty.")
        }
    }

    // --- Methods to update settings ---
    // These will be called by the SettingsView
    func updateSelectedModel(provider: LLMProvider, modelId: String?) {
         settings.selectedModelIdPerProvider[provider] = modelId
         saveSettings()
         // Could potentially trigger other actions if needed
    }

    func updateSelectedSystemPrompt(presetId: String?) {
         settings.selectedSystemPromptPresetId = presetId
         saveSettings()
    }

     func updateSelectedTTSInstruction(presetId: String?) {
         settings.selectedTTSInstructionPresetId = presetId
         saveSettings()
     }

    func updateAdvancedSetting<T>(keyPath: WritableKeyPath<SettingsData, T?>, value: T?) {
         settings[keyPath: keyPath] = value
         saveSettings()
    }
     func updateAdvancedSetting<T>(keyPath: WritableKeyPath<SettingsData, T>, value: T) {
          settings[keyPath: keyPath] = value
          saveSettings()
     }
}