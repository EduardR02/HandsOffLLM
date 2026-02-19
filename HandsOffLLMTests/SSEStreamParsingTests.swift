import Testing
import Foundation
@testable import HandsOffLLM

struct SSEStreamParsingTests {
    
    @Test func openAIDecodesDelta() {
        let client = OpenAIClient()
        let chunk = "{\"type\": \"response.output_text.delta\", \"delta\": \"Hello\"}"
        #expect(client.decodeChunk(chunk) == "Hello")
    }
    
    @Test func claudeDecodesDelta() {
        let client = ClaudeClient()
        let chunk = "{\"type\": \"content_block_delta\", \"delta\": {\"type\": \"text_delta\", \"text\": \"Hello\"}}"
        #expect(client.decodeChunk(chunk) == "Hello")
    }
    
    @Test func geminiDecodesDelta() {
        let client = GeminiClient()
        let chunk = "{\"candidates\": [{\"content\": {\"parts\": [{\"text\": \"Hello\"}]}}]}"
        #expect(client.decodeChunk(chunk) == "Hello")
    }
    
    @Test func xAIDecodesDelta() {
        let client = XAIClient()
        let chunk = "{\"choices\": [{\"delta\": {\"content\": \"Hello\"}}]}"
        #expect(client.decodeChunk(chunk) == "Hello")
    }
}
