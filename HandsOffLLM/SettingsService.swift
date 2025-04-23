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
        // General/Positive/Supportive
        PromptPreset(id: "default-happy", name: "Default Happy", description: "", fullPrompt: Prompts.defaultHappy),
        PromptPreset(id: "critical-friend", name: "Critical Friend", description: "", fullPrompt: Prompts.criticalFriend),
        PromptPreset(id: "existential-crisis-companion", name: "Existential Crisis Companion", description: "", fullPrompt: Prompts.existentialCrisisCompanion),
        PromptPreset(id: "morning-hype", name: "Morning Hype", description: "", fullPrompt: Prompts.morningHype),
        PromptPreset(id: "late-night-mode", name: "Late Night Mode", description: "", fullPrompt: Prompts.lateNightMode),

        // Professional/Informative/Storytelling
        PromptPreset(id: "passionate-educator", name: "Passionate Educator", description: "", fullPrompt: Prompts.passionateEducator),
        PromptPreset(id: "vintage-broadcaster", name: "Vintage Broadcaster", description: "", fullPrompt: Prompts.vintageBroadcaster),
        PromptPreset(id: "temporal-archivist", name: "Temporal Archivist", description: "", fullPrompt: Prompts.temporalArchivist),
        PromptPreset(id: "internet-historian", name: "Internet Historian", description: "", fullPrompt: Prompts.internetHistorian),
        PromptPreset(id: "spaceship-ai", name: "Spaceship AI", description: "", fullPrompt: Prompts.spaceshipAI),

        // Fictional/Roleplay/Entertainment
        PromptPreset(id: "jaded-detective", name: "Jaded Detective", description: "", fullPrompt: Prompts.jadedDetective),
        PromptPreset(id: "film-trailer-voice", name: "Film Trailer Voice", description: "", fullPrompt: Prompts.filmTrailerVoice),
        PromptPreset(id: "cyberpunk-street-kid", name: "Cyberpunk Street Kid", description: "", fullPrompt: Prompts.cyberpunkStreetKid),
        PromptPreset(id: "rick-sanchez", name: "Rick Sanchez", description: "", fullPrompt: Prompts.rickSanchez),
        PromptPreset(id: "cosmic-horror-narrator", name: "Cosmic Horror Narrator", description: "", fullPrompt: Prompts.cosmicHorrorNarrator),
        PromptPreset(id: "oblivion-npc", name: "Oblivion NPC", description: "", fullPrompt: Prompts.oblivionNPC),
        PromptPreset(id: "passive-aggressive", name: "Passive Aggressive", description: "", fullPrompt: Prompts.passiveAggressive),
        PromptPreset(id: "cowboy", name: "Cowboy", description: "", fullPrompt: Prompts.cowboy),

        // Custom Placeholder
        PromptPreset(id: "custom", name: "Custom", description: "Uses text from Advanced", fullPrompt: Prompts.spaceshipAI)
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
    
    let defaultTTSVoice = "nova"    // Default OpenAI TTS voice
    let availableTTSVoices = [
        "alloy", "ash", "ballad", "coral", "echo",
        "fable", "nova", "onyx", "sage", "shimmer", "verse"
    ]   // All supported voices

    var openAITTSVoice: String {    // Dynamic: picks saved setting or falls back to default
        settings.selectedTTSVoice ?? defaultTTSVoice
    }

    let openAITTSFormat = "aac"     // Other options: opus, flac, pcm, mp3
    let maxTTSChunkLength = 1000    // 1000 chars ≈ 1 minute of audio
    
    init() {
        loadSettings()
        validateKeysAndPrompts()
        logger.info("SettingsService initialized.")
        
        setDefaultModelsIfNeeded()
        setDefaultPromptsIfNeeded()
        setDefaultUISettingsIfNeeded()
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
    
    private func setDefaultUISettingsIfNeeded() {
        var changed = false
        if settings.selectedDefaultProvider == nil, let defaultProvider = LLMProvider.allCases.first {
            settings.selectedDefaultProvider = defaultProvider
            logger.info("Setting default API provider: \(defaultProvider.rawValue)")
            changed = true
        }
        if settings.selectedDefaultPlaybackSpeed == nil {
            let defaultSpeed: Float = 2.0
            settings.selectedDefaultPlaybackSpeed = defaultSpeed
            logger.info("Setting default playback speed: \(defaultSpeed)x")
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
    
    func updateSelectedTTSVoice(voice: String) {
        settings.selectedTTSVoice = voice
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
    
    // New: allow changing the default API provider
    func updateDefaultProvider(provider: LLMProvider) {
        settings.selectedDefaultProvider = provider
        saveSettings()
    }
    // New: allow changing the default playback speed
    func updateDefaultPlaybackSpeed(speed: Float) {
        settings.selectedDefaultPlaybackSpeed = speed
        saveSettings()
    }
}
