import Testing
import Foundation
@testable import HandsOffLLM

struct ProxyServiceDecisionTests {

    @Test @MainActor func shouldUseProxyWhenNoKey() async {
        let settings = SettingsService()
        settings.setOpenAIAPIKey(nil)
        settings.useOwnOpenAIKey = false

        let auth = AuthService.shared
        let proxy = ProxyService(authService: auth, settingsService: settings)

        #expect(proxy.shouldUseProxy(for: LLMProvider.openai) == true)
    }

    @Test @MainActor func shouldNotUseProxyWhenKeyProvided() async {
        let settings = SettingsService()
        settings.setOpenAIAPIKey("test-key")
        settings.useOwnOpenAIKey = true

        let auth = AuthService.shared
        let proxy = ProxyService(authService: auth, settingsService: settings)

        #expect(proxy.shouldUseProxy(for: LLMProvider.openai) == false)
    }

    @Test @MainActor func shouldUseProxyWhenOwnKeyEnabledButOnlyWhitespaceIsStored() async {
        let settings = SettingsService()
        settings.setOpenAIAPIKey("   ")
        settings.useOwnOpenAIKey = true

        let proxy = ProxyService(authService: AuthService.shared, settingsService: settings)
        #expect(proxy.shouldUseProxy(for: .openai) == true)
    }
}
