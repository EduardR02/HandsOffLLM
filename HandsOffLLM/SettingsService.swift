// SettingsService.swift
import Foundation
import OSLog
import Combine // Import Combine for ObservableObject

@MainActor // Ensure updates happen on the main thread
class SettingsService: ObservableObject { // Make ObservableObject
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SettingsService")
    
    // --- Published Settings Data ---
    @Published var settings: SettingsData = SettingsData()
    
    // Ephemeral session-only overrides (not persisted)
    @Published var sessionSystemPromptOverride: String? = nil
    @Published var sessionTTSInstructionOverride: String? = nil
    
    // --- Available Options (Hardcoded Placeholders) ---
    let availableModels: [ModelInfo] = [
        // Claude
        ModelInfo(id: "claude-3-7-sonnet-latest", name: "Claude 3.7 Sonnet", description: "Smartest, most capable", provider: .claude),
        ModelInfo(id: "claude-3-5-sonnet-latest", name: "Claude 3.5 New Sonnet", description: "Smartest, most emotinally intelligent", provider: .claude),
        ModelInfo(id: "claude-3-5-haiku-latest", name: "Claude 3.5 Haiku", description: "Fast, good for simple responses", provider: .claude),
        // Gemini
        ModelInfo(id: "gemini-2.5-flash-preview-04-17", name: "Gemini 2.5 Flash", description: "Fast, very capable", provider: .gemini),
        ModelInfo(id: "gemini-2.5-pro-exp-03-25", name: "Gemini 2.5 Pro", description: "Highly intelligent, thinks before responding", provider: .gemini),
        ModelInfo(id: "gemini-2.0-flash", name: "Gemini 2 Flash", description: "Very fast, everyday tasks", provider: .gemini),
        // OpenAI models
        ModelInfo(id: "gpt-4.1", name: "GPT-4.1", description: "Smart and versatile", provider: .openai),
        ModelInfo(id: "gpt-4.1-mini", name: "GPT-4.1 Mini", description: "Fast, everyday tasks", provider: .openai),
        ModelInfo(id: "o4-mini", name: "o4 mini", description: "Thinks before responding, most capable", provider: .openai),
        ModelInfo(id: "chatgpt-4o-latest", name: "ChatGPT 4o", description: "Default model in ChatGPT", provider: .openai),
    ]
    
    let availableSystemPrompts: [PromptPreset] = [
        PromptPreset(id: "learn-anything", name: "Learn Anything", description: "Focused on learning", fullPrompt: Prompts.learnAnythingSystemPrompt),
        PromptPreset(id: "relationship-argument-simulator", name: "Relationship Argument Simulator", description: "Simulate difficult arguments for practice", fullPrompt: Prompts.relationshipArgumentSimulator),
        PromptPreset(id: "social-skills-coach", name: "Social Skills Coach", description: "Actionable social skills guidance", fullPrompt: Prompts.socialSkillsCoach),
        PromptPreset(id: "conversational-companion", name: "Conversational Companion", description: "Thoughtful, authentic conversation partner", fullPrompt: Prompts.conversationalCompanion),
        PromptPreset(id: "task-guide", name: "Task Guide", description: "Step-by-step hands-free instructions", fullPrompt: Prompts.taskGuide),
        PromptPreset(id: "voice-game-master", name: "Voice Game Master", description: "Games and adventures via voice", fullPrompt: Prompts.voiceGameMaster),
        PromptPreset(id: "brainstorm-anything", name: "Brainstorm Anything", description: "Brainstorming partner", fullPrompt: Prompts.brainstormAnything),
        // new expert prompts
        PromptPreset(id: "financial-advisor", name: "Financial Advisor", description: "Insightful financial guidance", fullPrompt: Prompts.financialAdvisorSystemPrompt),
        PromptPreset(id: "health-fitness-trainer", name: "Health & Fitness Trainer", description: "Exercise and nutrition guidance", fullPrompt: Prompts.healthAndFitnessTrainerSystemPrompt),
        PromptPreset(id: "travel-guide", name: "Travel Guide", description: "Practical travel insights", fullPrompt: Prompts.travelGuideSystemPrompt),
        // fun prompts
        PromptPreset(id: "incoherent-drunk", name: "Incoherent Drunk", description: "Your wasted, oversharing 'friend'", fullPrompt: Prompts.incoherentDrunk),
        PromptPreset(id: "edgy-gamer", name: "Edgy Gamer", description: "Toxic, hypercompetitive gamer stereotype", fullPrompt: Prompts.edgyGamer),
        PromptPreset(id: "conspiracy-theorist", name: "Conspiracy Theorist", description: "Paranoid, sees connections everywhere", fullPrompt: Prompts.conspiracyTheorist),
        PromptPreset(id: "life-coach-maniac", name: "Life Coach Maniac", description: "Overly intense self-help guru", fullPrompt: Prompts.overlyEnthusiasticLifeCoach),
        PromptPreset(id: "victorian-traveler", name: "Victorian Time Traveler", description: "Proper, confused 1885 traveler", fullPrompt: Prompts.victorianTimeTraveler),
        PromptPreset(id: "tech-bro", name: "Tech Bro", description: "Stereotypical SV founder delusion", fullPrompt: Prompts.siliconValleyTechBro),
        // custom
        PromptPreset(id: "remove-later", name: "Remove Later", description: "remove later", fullPrompt: Prompts.chatPrompt)
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
        PromptPreset(id: "cowboy", name: "Cowboy", description: "", fullPrompt: Prompts.cowboy)
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
    
    // --- Advanced Defaults ---
    static let defaultAdvancedTemperature: Float = 1.0
    static let defaultAdvancedMaxTokens: Int   = 8000
    static let defaultAdvancedSystemPrompt: String = Prompts.learnAnythingSystemPrompt
    static let defaultAdvancedTTSInstruction: String = Prompts.defaultHappy

    // --- Default Preset IDs ---
    static let defaultSystemPromptId = "conversational-companion"
    static let defaultTTSInstructionPromptId = "default-happy"

    // MARK: - Active Setting Accessors
    
    // Get the currently active model ID for a given provider
    func activeModelId(for provider: LLMProvider) -> String? {
        return settings.selectedModelIdPerProvider[provider]
    }
    
    // Get the currently active system prompt
    var activeSystemPrompt: String? {
        // Session override takes priority
        if let session = sessionSystemPromptOverride,
           !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session
        }
        // Prioritize advanced override if enabled
        if settings.advancedSystemPromptEnabled,
           let advanced = settings.advancedSystemPrompt,
           !advanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return advanced
        }
        // Fallback to selected preset
        if let selectedId = settings.selectedSystemPromptPresetId,
           let preset = availableSystemPrompts.first(where: { $0.id == selectedId }) {
            return preset.fullPrompt
        }
        // Fallback to explicit default
        return availableSystemPrompts
            .first(where: { $0.id == Self.defaultSystemPromptId })?
            .fullPrompt
    }
    
    // Get the currently active TTS instruction
    var activeTTSInstruction: String? {
        // Session override takes priority
        if let session = sessionTTSInstructionOverride,
           !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session
        }
        // Prioritize advanced override if enabled
        if settings.advancedTTSInstructionEnabled,
           let advanced = settings.advancedTTSInstruction,
           !advanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return advanced
        }
        // Fallback to selected preset
        if let selectedId = settings.selectedTTSInstructionPresetId,
           let preset = availableTTSInstructions.first(where: { $0.id == selectedId }) {
            return preset.fullPrompt
        }
        // Fallback to explicit default
        return availableTTSInstructions
            .first(where: { $0.id == Self.defaultTTSInstructionPromptId })?
            .fullPrompt
    }
    
    // Get the currently active temperature
    var activeTemperature: Float {
        // Only use the stored temperature if the override is enabled
        if settings.advancedTemperatureEnabled,
           let t = settings.advancedTemperature {
            return t
        }
        return Self.defaultAdvancedTemperature
    }
    
    // Get the currently active max tokens
    var activeMaxTokens: Int {
        // Only use the stored maxTokens if the override is enabled
        if settings.advancedMaxTokensEnabled,
           let m = settings.advancedMaxTokens {
            return m
        }
        return Self.defaultAdvancedMaxTokens
    }
    
    // Web search toggle
    var webSearchEnabled: Bool {
        settings.webSearchEnabled ?? false
    }
    
    // Energy Saver Mode
    var energySaverEnabled: Bool {
        settings.energySaverEnabled ?? false
    }
    
    // Max/min caps from API definitions
    static let maxTempOpenAI: Float = 2.0
    static let maxTokensOpenAI: Int = 16384
    static let maxTempAnthropic: Float = 1.0
    static let maxTokensAnthropic: Int = 8192
    static let maxTempGemini: Float = 2.0
    static let maxTokensGemini: Int = 8192
    
    // MARK: - Personalization getters
    var speechRecognitionLocale: Locale {
        Locale(identifier: settings.speechRecognitionLanguage ?? "en-US")
    }

    var userProfilePrompt: String {
        var lines: [String] = []
        if let name = settings.userDisplayName, !name.isEmpty {
            lines.append("The user prefers to be addressed as \"\(name)\".")
        }
        if let localeId = settings.speechRecognitionLanguage,
           let languageName = Locale.current.localizedString(forIdentifier: localeId) {
            lines.append("Speech recognition language: \(languageName) (\(localeId)).")
        }
        if let desc = settings.userProfileDescription, !desc.isEmpty {
            lines.append("Additional information: \(desc)")
        }
        return lines.joined(separator: " ")
    }

    var activeSystemPromptWithUserProfile: String? {
        let base = activeSystemPrompt ?? ""
        guard settings.userProfileEnabled else {
            // When disabled, just return the base system prompt without profile info
            return base
        }
        let profile = userProfilePrompt
        guard !profile.isEmpty else { return base }
        let instruction = """
        Below are some details about the user you are assisting. Use this information to adapt your responses to their preferences and context, but do not reference these details explicitly in your replies.

        \(profile)
        """
        return "\(base)\n\n\(instruction)"
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

    func updateEnergySaverEnabled(_ enabled: Bool) {
        updateAdvancedSetting(keyPath: \.energySaverEnabled, value: enabled)
    }

    /// Apply a temporary session-only override of system prompt and TTS instruction
    func setSessionOverride(systemPrompt: String?, ttsInstruction: String?) {
        sessionSystemPromptOverride = systemPrompt
        sessionTTSInstructionOverride = ttsInstruction
    }

    /// Clear any temporary session-only overrides
    func clearSessionOverride() {
        sessionSystemPromptOverride = nil
        sessionTTSInstructionOverride = nil
    }

    /// Atomically update all profile fields and persist once.
    /// If `completedInitialSetup` is true, we flip that flag, but never clear it.
    func updateUserProfile(
        language: String,
        displayName: String,
        description: String,
        enabled: Bool,
        completedInitialSetup: Bool
    ) {
        settings.speechRecognitionLanguage = language
        settings.userDisplayName = displayName
        settings.userProfileDescription = description
        settings.userProfileEnabled = enabled
        if completedInitialSetup {
            settings.hasCompletedInitialSetup = true
        }
        saveSettings()
    }

    init() {
        loadSettings()
        // Force initial setup screen to show for debugging
        // settings.hasCompletedInitialSetup = false
        validateKeysAndPrompts()
        logger.info("SettingsService initialized.")
        
        setDefaultModelsIfNeeded()
        setDefaultPromptsIfNeeded()
        setDefaultUISettingsIfNeeded()
        setDefaultUserProfileSettingsIfNeeded()
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
        if settings.selectedSystemPromptPresetId == nil {
            settings.selectedSystemPromptPresetId = Self.defaultSystemPromptId
            logger.info("Setting default system prompt preset: \(Self.defaultSystemPromptId)")
            changed = true
        }
        if settings.selectedTTSInstructionPresetId == nil {
            settings.selectedTTSInstructionPresetId = Self.defaultTTSInstructionPromptId
            logger.info("Setting default TTS instruction preset: \(Self.defaultTTSInstructionPromptId)")
            changed = true
        }
        if changed {
            saveSettings()
        }
    }
    
    private func setDefaultUISettingsIfNeeded() {
        var changed = false
        if settings.selectedDefaultProvider == nil {
            // Explicitly set Claude as the default if no provider is selected
            let defaultProvider: LLMProvider = .claude
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

    private func setDefaultUserProfileSettingsIfNeeded() {
        var changed = false
        if settings.speechRecognitionLanguage == nil {
            settings.speechRecognitionLanguage = "en-US"; changed = true
        }
        if changed { saveSettings() }
    }
}
