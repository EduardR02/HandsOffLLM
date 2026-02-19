import Testing
import Foundation
@testable import HandsOffLLM

struct AudioServiceTests {

    @Test @MainActor func ttsChunkingWaitsForMinimumLengthUntilFinalChunk() async {
        let settings = SettingsService()
        let audioService = AudioService(settingsService: settings, historyService: HistoryService(), authService: AuthService.shared)

        audioService.ttsRate = 1.0
        audioService.processTTSChunk(textChunk: "Hello world. This is a test!", isLastChunk: false)

        #expect(audioService.findNextTTSChunk() == 0)

        audioService.processTTSChunk(textChunk: "", isLastChunk: true)
        #expect(audioService.findNextTTSChunk() == 28)
    }
}
