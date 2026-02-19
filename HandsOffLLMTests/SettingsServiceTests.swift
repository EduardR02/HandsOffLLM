import Testing
import Foundation
@testable import HandsOffLLM

struct SettingsServiceTests {
    
    @Test @MainActor func settingsHierarchyDefaults() async {
        let settings = SettingsService()
        // Check default system prompt
        #expect(settings.activeSystemPrompt != nil)
        #expect(settings.activeTemperature == 1.0)
    }
    
    @Test @MainActor func sessionOverrideTakesPrecedence() async {
        let settings = SettingsService()
        settings.updateSelectedSystemPrompt(presetId: "learn-anything")
        
        let override = "New Session Prompt"
        settings.setSessionOverride(systemPrompt: override, ttsInstruction: nil)
        
        #expect(settings.activeSystemPrompt == override)
        
        settings.clearSessionOverride()
        #expect(settings.activeSystemPrompt != override)
    }
    
    @Test @MainActor func systemPromptWithUserProfile() async {
        let settings = SettingsService()
        settings.updateUserProfile(displayName: "Eduard", description: "iOS Developer", enabled: true, completedInitialSetup: true)
        
        let prompt = settings.activeSystemPromptWithUserProfile
        #expect(prompt?.contains("Eduard") == true)
        #expect(prompt?.contains("iOS Developer") == true)
    }
}
