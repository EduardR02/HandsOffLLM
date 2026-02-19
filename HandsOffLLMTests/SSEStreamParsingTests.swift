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

    @Test func decodeChunkReturnsNilForGarbageInput() {
        let clients: [any LLMClient] = [OpenAIClient(), ClaudeClient(), GeminiClient(), XAIClient(), MoonshotClient()]
        let garbageInputs = ["", "not-json", "{", "[]"]

        for client in clients {
            for input in garbageInputs {
                #expect(client.decodeChunk(input) == nil)
            }
        }
    }

    @Test func decodeChunkReturnsNilForUnsupportedEvents() {
        #expect(OpenAIClient().decodeChunk("{\"type\":\"response.completed\"}") == nil)
        #expect(ClaudeClient().decodeChunk("{\"type\":\"message_start\"}") == nil)
        #expect(GeminiClient().decodeChunk("{\"candidates\":[{\"content\":{\"parts\":[]}}]}") == nil)
        #expect(XAIClient().decodeChunk("{\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}") == nil)
    }
}
