// SettingsService.swift
import Foundation
import OSLog
import Combine // Import Combine for ObservableObject

@MainActor // Ensure updates happen on the main thread
class SettingsService: ObservableObject { // Make ObservableObject
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SettingsService")
    private let keychain = KeychainService.shared
    
    // --- Published Settings Data ---
    @Published var settings: SettingsData = SettingsData()

    // --- Sensitive API Keys (persisted via Keychain) ---
    @Published private(set) var openaiAPIKey: String?
    @Published private(set) var anthropicAPIKey: String?
    @Published private(set) var geminiAPIKey: String?
    @Published private(set) var xaiAPIKey: String?
    @Published private(set) var moonshotAPIKey: String?
    @Published private(set) var mistralAPIKey: String?
    @Published private(set) var replicateAPIKey: String?
    
    // Ephemeral session-only overrides (not persisted)
    @Published var sessionSystemPromptOverride: String? = nil
    @Published var sessionTTSInstructionOverride: String? = nil
    
    // --- Available Options (Hardcoded Placeholders) ---
    let availableModels: [ModelInfo] = [
        // Claude
        ModelInfo(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", description: "Incredibly smart, creative, and capable model", provider: .claude),
        ModelInfo(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4", description: "Highly capable, creative, and fast", provider: .claude),
        ModelInfo(id: "claude-opus-4-1-20250805", name: "Claude Opus 4.1", description: "Most powerful, smartest, most creative model", provider: .claude),
        // ModelInfo(id: "claude-3-7-sonnet-latest", name: "Claude 3.7 Sonnet", description: "Smartest, most capable", provider: .claude),
        // ModelInfo(id: "claude-3-5-sonnet-latest", name: "Claude 3.5 New Sonnet", description: "Smartest, most emotinally intelligent", provider: .claude),
        // ModelInfo(id: "claude-3-5-haiku-latest", name: "Claude 3.5 Haiku", description: "Fast, good for simple responses", provider: .claude),
        // Gemini
        ModelInfo(id: "gemini-2.5-flash-preview-09-2025", name: "Gemini 2.5 Flash", description: "Fast, very capable", provider: .gemini),
        ModelInfo(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", description: "Highly intelligent, thinks before responding", provider: .gemini),
        ModelInfo(id: "gemini-2.0-flash", name: "Gemini 2 Flash", description: "Very fast, everyday tasks", provider: .gemini),
        // OpenAI models
        ModelInfo(id: "gpt-5", name: "GPT-5", description: "Newest OpenAI flagship", provider: .openai),
        ModelInfo(id: "gpt-5-mini", name: "GPT-5 Mini", description: "Fast GPT-5 family model", provider: .openai),
        ModelInfo(id: "gpt-4.1", name: "GPT-4.1", description: "Smart and versatile", provider: .openai),
        ModelInfo(id: "gpt-4.1-mini", name: "GPT-4.1 Mini", description: "Fast, everyday tasks", provider: .openai),
        ModelInfo(id: "o4-mini", name: "o4 mini", description: "Thinks before responding, most capable", provider: .openai),
        ModelInfo(id: "chatgpt-4o-latest", name: "ChatGPT 4o", description: "Default model in ChatGPT", provider: .openai),
        // xAI
        ModelInfo(id: "grok-4", name: "Grok 4", description: "Frontier level intelligence", provider: .xai),
        ModelInfo(id: "grok-4-fast", name: "Grok 4 Fast", description: "Ultra-fast responses with strong intelligence", provider: .xai),
        ModelInfo(id: "grok-4-fast-non-reasoning", name: "Grok 4 Fast (No Reasoning)", description: "Instant responses", provider: .xai),
        // Moonshot AI
        ModelInfo(id: "kimi-k2-thinking", name: "Kimi K2 Thinking", description: "Advanced reasoning model", provider: .moonshot),
        ModelInfo(id: "kimi-k2-thinking-turbo", name: "Kimi K2 Thinking Turbo", description: "Fast reasoning model", provider: .moonshot),
        ModelInfo(id: "kimi-k2-turbo-preview", name: "Kimi K2 Turbo Preview", description: "Fast general purpose model (Recommended)", provider: .moonshot),
        ModelInfo(id: "kimi-k2-0905-preview", name: "Kimi K2 Preview (0905)", description: "Latest preview model", provider: .moonshot),
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
    
    // --- User API Keys Toggle ---
    var useOwnOpenAIKey: Bool {
        get { settings.useOwnOpenAIKey }
        set { settings.useOwnOpenAIKey = newValue; saveSettings() }
    }
    var useOwnAnthropicKey: Bool {
        get { settings.useOwnAnthropicKey }
        set { settings.useOwnAnthropicKey = newValue; saveSettings() }
    }
    var useOwnGeminiKey: Bool {
        get { settings.useOwnGeminiKey }
        set { settings.useOwnGeminiKey = newValue; saveSettings() }
    }
    var useOwnXAIKey: Bool {
        get { settings.useOwnXAIKey }
        set { settings.useOwnXAIKey = newValue; saveSettings() }
    }
    var useOwnMoonshotKey: Bool {
        get { settings.useOwnMoonshotKey }
        set { settings.useOwnMoonshotKey = newValue; saveSettings() }
    }
    var useOwnMistralKey: Bool {
        get { settings.useOwnMistralKey }
        set { settings.useOwnMistralKey = newValue; saveSettings() }
    }
    var useOwnReplicateKey: Bool {
        get { settings.useOwnReplicateKey }
        set { settings.useOwnReplicateKey = newValue; saveSettings() }
    }
    
    // --- Hardcoded TTS details ---
    let openAITTSModel = "gpt-4o-mini-tts"

    let defaultTTSVoice = "nova"    // Default OpenAI TTS voice
    let defaultKokoroVoice = "af_bella"  // Default Replicate Kokoro voice

    let availableTTSVoices = [
        "alloy", "ash", "ballad", "coral", "echo",
        "fable", "nova", "onyx", "sage", "shimmer", "verse"
    ]   // All supported OpenAI voices

    let availableKokoroVoices: [VoiceInfo] = [
        // Grade A voices (highest quality)
        VoiceInfo(id: "af_bella", displayName: "Bella · EN-US"),
        // Grade B voices (high quality)
        VoiceInfo(id: "af_nicole", displayName: "Nicole · EN-US"),
        VoiceInfo(id: "bf_emma", displayName: "Emma · EN-GB"),
        VoiceInfo(id: "ff_siwis", displayName: "Siwis · FR"),
        // Grade C+ voices (good quality)
        VoiceInfo(id: "af_aoede", displayName: "Aoede · EN-US"),
        VoiceInfo(id: "af_kore", displayName: "Kore · EN-US"),
        VoiceInfo(id: "af_sarah", displayName: "Sarah · EN-US"),
        VoiceInfo(id: "am_fenrir", displayName: "Fenrir · EN-US"),
        VoiceInfo(id: "am_michael", displayName: "Michael · EN-US"),
        VoiceInfo(id: "am_puck", displayName: "Puck · EN-US"),
        VoiceInfo(id: "bm_george", displayName: "George · EN-GB"),
        VoiceInfo(id: "bm_fable", displayName: "Fable · EN-GB"),
        VoiceInfo(id: "jf_alpha", displayName: "Alpha · JA"),
    ]

    var openAITTSVoice: String {    // Dynamic: picks saved setting or falls back to default
        settings.selectedTTSVoice ?? defaultTTSVoice
    }

    var kokoroTTSVoice: String {
        settings.selectedKokoroVoice ?? defaultKokoroVoice
    }

    let openAITTSFormat = "aac"     // Other options: opus, flac, pcm, mp3
    let maxTTSChunkLength = 2000    // 2000 chars ≈ 2 minutes of audio

    private enum KeychainKey {
        static let openai = "user.openai.api_key"
        static let anthropic = "user.anthropic.api_key"
        static let gemini = "user.gemini.api_key"
        static let xai = "user.xai.api_key"
        static let moonshot = "user.moonshot.api_key"
        static let mistral = "user.mistral.api_key"
        static let replicate = "user.replicate.api_key"
    }
    
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
    
    var openAIReasoningEffort: OpenAIReasoningEffort {
        settings.openAIReasoningEffort ?? .medium
    }

    var openAIReasoningEffortOpt: OpenAIReasoningEffort? {
        settings.openAIReasoningEffort
    }

    var claudeReasoningEnabled: Bool {
        settings.claudeReasoningEnabled ?? false
    }

    // Energy Saver Mode
    var energySaverEnabled: Bool {
        settings.energySaverEnabled ?? false
    }

    // Darker Mode
    var darkerMode: Bool {
        settings.darkerMode ?? true
    }

    var vadSilenceThreshold: Double {
        settings.vadSilenceThreshold ?? 1.5
    }

    var selectedTTSProvider: TTSProvider {
        settings.selectedTTSProvider ?? .openai
    }
    
    // Max/min caps from API definitions
    static let maxTempOpenAI: Float = 2.0
    static let maxTokensOpenAI: Int = 16384
    static let maxTempAnthropic: Float = 1.0
    static let maxTokensAnthropic: Int = 32000
    static let maxTempGemini: Float = 2.0
    static let maxTokensGemini: Int = 8192
    static let maxTempXAI: Float = 2.0
    static let maxTokensXAI: Int = 131072
    static let maxTempMoonshot: Float = 1.0
    static let maxTokensMoonshot: Int = 131072

    // MARK: - Personalization getters
    var userProfilePrompt: String {
        var lines: [String] = []
        if let name = settings.userDisplayName, !name.isEmpty {
            lines.append("The user prefers to be addressed as \"\(name)\".")
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
            // Sync darkerMode to UserDefaults for Theme.swift
            UserDefaults.standard.set(darkerMode, forKey: "darkerMode")
            logger.info("Settings loaded successfully.")
        } catch {
            logger.error("Failed to load or decode settings: \(error.localizedDescription). Using defaults.")
            settings = SettingsData() // Use defaults on error
            UserDefaults.standard.set(darkerMode, forKey: "darkerMode")
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
        if useOwnAnthropicKey && (anthropicAPIKey?.isEmpty ?? true) {
            logger.warning("Anthropic API key missing while user override is enabled.")
        }
        if useOwnGeminiKey && (geminiAPIKey?.isEmpty ?? true) {
            logger.warning("Gemini API key missing while user override is enabled.")
        }
        if useOwnOpenAIKey && (openaiAPIKey?.isEmpty ?? true) {
            logger.warning("OpenAI API key missing while user override is enabled.")
        }
        if useOwnXAIKey && (xaiAPIKey?.isEmpty ?? true) {
            logger.warning("xAI API key missing while user override is enabled.")
        }
        if useOwnMistralKey && (mistralAPIKey?.isEmpty ?? true) {
            logger.warning("Mistral API key missing while user override is enabled.")
        }
        
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

    func updateOpenAIReasoningEffort(_ effort: OpenAIReasoningEffort) {
        settings.openAIReasoningEffort = effort
        saveSettings()
    }
    
    func updateClaudeReasoningEnabled(_ enabled: Bool) {
        settings.claudeReasoningEnabled = enabled
        saveSettings()
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

    func updateSelectedKokoroVoice(voice: String) {
        settings.selectedKokoroVoice = voice
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

    func updateDarkerMode(_ enabled: Bool) {
        updateAdvancedSetting(keyPath: \.darkerMode, value: enabled)
        // Sync to UserDefaults so Theme.swift can read it
        UserDefaults.standard.set(enabled, forKey: "darkerMode")
    }

    func setOpenAIAPIKey(_ value: String?) {
        openaiAPIKey = storeKey(value, keychainKey: KeychainKey.openai)
    }

    func setAnthropicAPIKey(_ value: String?) {
        anthropicAPIKey = storeKey(value, keychainKey: KeychainKey.anthropic)
    }

    func setGeminiAPIKey(_ value: String?) {
        geminiAPIKey = storeKey(value, keychainKey: KeychainKey.gemini)
    }

    func setXAIAPIKey(_ value: String?) {
        xaiAPIKey = storeKey(value, keychainKey: KeychainKey.xai)
    }

    func setMoonshotAPIKey(_ value: String?) {
        moonshotAPIKey = storeKey(value, keychainKey: KeychainKey.moonshot)
    }

    func setMistralAPIKey(_ value: String?) {
        mistralAPIKey = storeKey(value, keychainKey: KeychainKey.mistral)
    }

    func setReplicateAPIKey(_ value: String?) {
        replicateAPIKey = storeKey(value, keychainKey: KeychainKey.replicate)
    }

    func updateVADSilenceThreshold(_ threshold: Double) {
        updateAdvancedSetting(keyPath: \.vadSilenceThreshold, value: threshold)
    }

    func updateSelectedTTSProvider(_ provider: TTSProvider) {
        settings.selectedTTSProvider = provider
        saveSettings()
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
        displayName: String,
        description: String,
        enabled: Bool,
        completedInitialSetup: Bool
    ) {
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
        loadAPIKeys()
        // Force initial setup screen to show for debugging
        // settings.hasCompletedInitialSetup = false
        validateKeysAndPrompts()
        logger.info("SettingsService initialized.")
        
        let modelsChanged = setDefaultModelsIfNeeded()
        let promptsChanged = setDefaultPromptsIfNeeded()
        let uiChanged = setDefaultUISettingsIfNeeded()
        if modelsChanged || promptsChanged || uiChanged {
            saveSettings()
        }
    }
    
    // --- Default Selections ---
    private func setDefaultModelsIfNeeded() -> Bool {
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
        return changed
    }
    
    private func setDefaultPromptsIfNeeded() -> Bool {
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
        return changed
    }
    
    private func setDefaultUISettingsIfNeeded() -> Bool {
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
        if settings.openAIReasoningEffort == nil {
            settings.openAIReasoningEffort = .medium
            logger.info("Setting default OpenAI reasoning effort: medium")
            changed = true
        }
        if settings.claudeReasoningEnabled == nil {
            settings.claudeReasoningEnabled = false
            changed = true
        }
        if settings.vadSilenceThreshold == nil {
            settings.vadSilenceThreshold = 1.5
            logger.info("Setting default VAD silence threshold: \(self.vadSilenceThreshold)")
            changed = true
        }
        if settings.selectedTTSProvider == nil {
            settings.selectedTTSProvider = .openai
            logger.info("Setting default TTS provider: OpenAI")
            changed = true
        }
        if settings.selectedKokoroVoice == nil {
            settings.selectedKokoroVoice = defaultKokoroVoice
            logger.info("Setting default Kokoro voice: \(self.defaultKokoroVoice)")
            changed = true
        }
        return changed
    }

    private func loadAPIKeys() {
        do { openaiAPIKey = try keychain.string(for: KeychainKey.openai) } catch {
            logger.error("Failed to load OpenAI API key from keychain: \(error.localizedDescription)")
            openaiAPIKey = nil
        }
        do { anthropicAPIKey = try keychain.string(for: KeychainKey.anthropic) } catch {
            logger.error("Failed to load Anthropic API key from keychain: \(error.localizedDescription)")
            anthropicAPIKey = nil
        }
        do { geminiAPIKey = try keychain.string(for: KeychainKey.gemini) } catch {
            logger.error("Failed to load Gemini API key from keychain: \(error.localizedDescription)")
            geminiAPIKey = nil
        }
        do { xaiAPIKey = try keychain.string(for: KeychainKey.xai) } catch {
            logger.error("Failed to load xAI API key from keychain: \(error.localizedDescription)")
            xaiAPIKey = nil
        }
        do { moonshotAPIKey = try keychain.string(for: KeychainKey.moonshot) } catch {
            logger.error("Failed to load Moonshot API key from keychain: \(error.localizedDescription)")
            moonshotAPIKey = nil
        }
        do { mistralAPIKey = try keychain.string(for: KeychainKey.mistral) } catch {
            logger.error("Failed to load Mistral API key from keychain: \(error.localizedDescription)")
            mistralAPIKey = nil
        }
        do { replicateAPIKey = try keychain.string(for: KeychainKey.replicate) } catch {
            logger.error("Failed to load Replicate API key from keychain: \(error.localizedDescription)")
            replicateAPIKey = nil
        }
    }

    @discardableResult
    private func storeKey(_ rawValue: String?, keychainKey: String) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try keychain.set(trimmed, for: keychainKey)
        } catch {
            logger.error("Failed to store keychain item (\(keychainKey)): \(error.localizedDescription)")
        }
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        } else {
            return nil
        }
    }
}
