import Testing
import Foundation
@testable import HandsOffLLM

struct SettingsServiceTests {

    @Test @MainActor func settingsHierarchyDefaults() async {
        let settings = SettingsService()
        #expect(settings.activeSystemPrompt?.isEmpty == false)
        #expect(settings.activeTemperature == 1.0)
        #expect(settings.activeMaxTokens == 8000)
        #expect(settings.reasoningEnabled == true)
        #expect(settings.reasoningEffort == .high)
        #expect(settings.webSearchEnabled == false)

        for provider in LLMProvider.userFacing {
            let selected = settings.activeModelId(for: provider)
            let hasSelectedModel = settings.availableModels.contains(where: { $0.provider == provider && $0.id == selected })
            #expect(hasSelectedModel)
        }
    }

    @Test @MainActor func sessionOverrideTakesPrecedence() async {
        let settings = SettingsService()
        settings.updateSelectedSystemPrompt(presetId: "learn-anything")

        let override = "New Session Prompt"
        settings.setSessionOverride(systemPrompt: override, ttsInstruction: nil)

        #expect(settings.activeSystemPrompt == override)

        settings.setSessionOverride(systemPrompt: "   ", ttsInstruction: nil)
        #expect(settings.activeSystemPrompt == settings.availableSystemPrompts.first(where: { $0.id == "learn-anything" })?.fullPrompt)

        settings.clearSessionOverride()
        #expect(settings.activeSystemPrompt != override)
    }

    @Test @MainActor func systemPromptWithUserProfile() async {
        let settings = SettingsService()
        settings.updateUserProfile(displayName: "Eduard", description: "iOS Developer", enabled: true, completedInitialSetup: true)

        let prompt = settings.activeSystemPromptWithUserProfile
        #expect(prompt?.contains("Eduard") == true)
        #expect(prompt?.contains("iOS Developer") == true)

        settings.updateUserProfile(displayName: "Eduard", description: "iOS Developer", enabled: false, completedInitialSetup: true)
        let promptWithoutProfile = settings.activeSystemPromptWithUserProfile
        #expect(promptWithoutProfile?.contains("Eduard") == false)
        #expect(promptWithoutProfile?.contains("iOS Developer") == false)
    }

    @Test @MainActor func invalidStoredModelSelectionIsMigratedToProviderDefault() throws {
        guard let settingsURL = settingsFileURL() else {
            Issue.record("Could not resolve settings file path")
            return
        }

        let existingData = try? Data(contentsOf: settingsURL)
        defer {
            if let existingData {
                try? existingData.write(to: settingsURL, options: .atomicWrite)
            } else {
                try? FileManager.default.removeItem(at: settingsURL)
            }
        }

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var staleSettings = SettingsData()
        staleSettings.selectedModelIdPerProvider = [
            .openai: "retired-openai-model",
            .claude: "claude-opus-4.6"
        ]
        let encoded = try JSONEncoder().encode(staleSettings)
        try encoded.write(to: settingsURL, options: .atomicWrite)

        let settings = SettingsService()
        let expectedOpenAIDefault = settings.availableModels.first(where: { $0.provider == .openai })?.id

        #expect(settings.activeModelId(for: .openai) == expectedOpenAIDefault)
        #expect(settings.activeModelId(for: .claude) == "claude-opus-4.6")
    }

    @Test @MainActor func availableModelsReflectUpdatedIdsAndDefaultOrder() async {
        let settings = SettingsService()

        let claudeDefaults = settings.availableModels.filter { $0.provider == .claude }
        let openAIDefaults = settings.availableModels.filter { $0.provider == .openai }
        let geminiDefaults = settings.availableModels.filter { $0.provider == .gemini }
        let xaiDefaults = settings.availableModels.filter { $0.provider == .xai }

        #expect(claudeDefaults.first?.id == "claude-opus-4.6")
        #expect(openAIDefaults.first?.id == "gpt-5.2")
        #expect(geminiDefaults.first?.id == "gemini-3-pro")
        #expect(xaiDefaults.first?.id == "grok-4.1")

        #expect(openAIDefaults.contains(where: { $0.id == "gpt-5.3-codex" && $0.name == "Codex 5.3" }))
        #expect(geminiDefaults.contains(where: { $0.id == "gemini-3-flash-preview" }))
        #expect(geminiDefaults.contains(where: { $0.id == "gemini-3-flash" }) == false)
    }

    @Test @MainActor func reasoningLevelSupportReflectsSelectedModel() async {
        let settings = SettingsService()

        settings.updateDefaultProvider(provider: .openai)
        settings.updateSelectedModel(provider: .openai, modelId: "gpt-5.2")
        #expect(settings.selectedModelSupportsReasoningLevels == true)

        settings.updateDefaultProvider(provider: .claude)
        settings.updateSelectedModel(provider: .claude, modelId: "claude-sonnet-4.6")
        #expect(settings.selectedModelSupportsReasoningLevels == false)

        settings.updateSelectedModel(provider: .claude, modelId: "claude-opus-4.6")
        #expect(settings.selectedModelSupportsReasoningLevels == true)

        settings.updateDefaultProvider(provider: .gemini)
        settings.updateSelectedModel(provider: .gemini, modelId: "gemini-3-pro")
        #expect(settings.selectedModelSupportsReasoningLevels == true)

        settings.updateDefaultProvider(provider: .xai)
        settings.updateSelectedModel(provider: .xai, modelId: "grok-4-fast")
        #expect(settings.selectedModelSupportsReasoningLevels == false)

        settings.updateDefaultProvider(provider: .moonshot)
        settings.updateSelectedModel(provider: .moonshot, modelId: "kimi-k2.5")
        #expect(settings.selectedModelSupportsReasoningLevels == false)
    }

    private func settingsFileURL() -> URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("settings.json")
    }
}
