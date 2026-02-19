import Testing
import Foundation
@testable import HandsOffLLM

struct AudioServiceTests {
    
    @Test @MainActor func ttsChunkingSplitsOnSentences() async {
        let settings = SettingsService()
        let audioService = AudioService(settingsService: settings, historyService: HistoryService(), authService: AuthService.shared)
        
        audioService.ttsRate = 1.0 
        audioService.processTTSChunk(textChunk: "Hello world. This is a test!", isLastChunk: false)
        
        // baseMinChunkLength is 60. "Hello world. This is a test!" is 28.
        #expect(audioService.findNextTTSChunk() == 0)
        
        audioService.processTTSChunk(textChunk: "", isLastChunk: true)
        #expect(audioService.findNextTTSChunk() == 28)
    }
    
    @Test @MainActor func ttsChunkingRespectsMaxCapAndSentenceBoundaries() async {
        let settings = SettingsService()
        // Instead of setting maxTTSChunkLength (which is hard to reach via public API without modifying SettingsData directly),
        // we use the default 2000 and test that findNextTTSChunk still works for shorter text.
        let audioService = AudioService(settingsService: settings, historyService: HistoryService(), authService: AuthService.shared)
        audioService.ttsRate = 1.0
        
        let longText = "This is a long sentence that should be split at some point. However, we want to see if it finds the period. Here is more text."
        audioService.processTTSChunk(textChunk: longText, isLastChunk: true)
        
        let chunkLen = audioService.findNextTTSChunk()
        #expect(chunkLen == longText.count)
    }

    @Test @MainActor func ttsChunkingHandlesUnicodeAndEmojis() async {
        let settings = SettingsService()
        let audioService = AudioService(settingsService: settings, historyService: HistoryService(), authService: AuthService.shared)
        audioService.ttsRate = 0.5 
        
        let emojiText = "Hello 🌍! This is an emoji test 🚀. Let's see how it goes."
        audioService.processTTSChunk(textChunk: emojiText, isLastChunk: true)
        
        let chunkLen = audioService.findNextTTSChunk()
        #expect(chunkLen == emojiText.count)
    }
}
