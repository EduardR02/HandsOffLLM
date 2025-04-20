// Models.swift
import Foundation

// MARK: - Chat Message Structure
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var role: String // e.g., "user", "assistant", "assistant_partial", "assistant_error"
    var content: String
}

// MARK: - Conversation History Structure
struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title: String? // Optional: can be generated later
    var messages: [ChatMessage] = []
    var createdAt: Date = Date()
    var parentConversationId: UUID? // To link continued conversations
    // Optional: Map message ID to saved audio file paths (multiple chunks per message)
    var ttsAudioPaths: [UUID: [String]]? // Optional: Map message ID to array of saved audio file paths
}
// MARK: - Conversation Index Entry
/// Minimal metadata for listing conversations without loading full messages
struct ConversationIndexEntry: Identifiable, Codable {
    let id: UUID
    let title: String?
    let createdAt: Date
}

// MARK: - Settings Structures

struct ModelInfo: Identifiable, Codable, Hashable {
    let id: String // e.g., "claude-3-opus-20240229"
    let name: String // User-facing name, e.g., "Claude 3 Opus"
    let description: String // e.g., "Most powerful model"
    let provider: LLMProvider // Link back to the provider enum
}

struct PromptPreset: Identifiable, Codable, Hashable {
    let id: String // Unique ID for the preset, e.g., "casual-friend"
    let name: String // User-facing name, e.g., "Casual Friend"
    let description: String // Short description for UI
    let fullPrompt: String // The actual prompt text
}

struct SettingsData: Codable {
    // Model Selections: Store the ID of the selected model for each provider
    var selectedModelIdPerProvider: [LLMProvider: String] = [:]
    
    // Preset Selections: Store the ID of the selected preset
    var selectedSystemPromptPresetId: String?
    var selectedTTSInstructionPresetId: String?
    
    // Advanced Overrides
    var advancedTemperature: Float?
    var advancedMaxTokens: Int?
    var advancedSystemPrompt: String?
    var advancedTTSInstruction: String?
    
    // Default values can be set here or when initializing SettingsService
    init() {
        // Sensible defaults if needed
    }
}

// MARK: - Claude API Structures
struct ClaudeRequest: Codable {
    let model: String
    let system: String?
    let messages: [MessageParam]
    let stream: Bool
    let max_tokens: Int
    let temperature: Float
}

struct MessageParam: Codable {
    let role: String
    let content: String
}

struct ClaudeStreamEvent: Decodable {
    let type: String
    let delta: Delta?
    let message: ClaudeResponseMessage? // For message_stop event
}
struct Delta: Decodable {
    let type: String?
    let text: String?
}
struct ClaudeResponseMessage: Decodable {
    let id: String
    let role: String
    let usage: UsageData?
}
struct UsageData: Decodable {
    let input_tokens: Int
    let output_tokens: Int
}

// MARK: - OpenAI TTS API Structures
struct OpenAITTSRequest: Codable {
    let model: String
    let input: String
    let voice: String
    let response_format: String
    let instructions: String?
}

// MARK: - Gemini API Structures
struct GeminiRequest: Codable {
    let contents: [GeminiContent]
}

struct GeminiContent: Codable {
    let role: String
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String
}

struct GeminiResponseChunk: Decodable {
    let candidates: [GeminiCandidate]?
}
struct GeminiCandidate: Decodable {
    let content: GeminiContent?
}

// MARK: - Error Enum
enum LlmError: Error, LocalizedError {
    case apiKeyMissing(provider: String)
    case invalidURL
    case requestEncodingError(Error)
    case networkError(Error)
    case invalidResponse(statusCode: Int, body: String?)
    case responseDecodingError(Error)
    case streamingError(String)
    case ttsError(String) // Added for specific TTS errors
    
    var errorDescription: String? {
        switch self {
        case .apiKeyMissing(let provider): return "\(provider) API Key is missing."
        case .invalidURL: return "Invalid API endpoint URL."
        case .requestEncodingError(let error): return "Failed to encode request: \(error.localizedDescription)"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .invalidResponse(let statusCode, let body): return "Invalid response from server: Status \(statusCode). Body: \(body ?? "N/A")"
        case .responseDecodingError(let error): return "Failed to decode response: \(error.localizedDescription)"
        case .streamingError(let message): return "Streaming error: \(message)"
        case .ttsError(let message): return "TTS error: \(message)"
        }
    }
}

// MARK: - LLM Provider Enum
enum LLMProvider: String, CaseIterable, Identifiable, Codable, Hashable {
    case gemini = "Gemini"
    case claude = "Claude"
    var id: String { self.rawValue }
}
