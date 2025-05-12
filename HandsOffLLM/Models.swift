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
struct ConversationIndexEntry: Identifiable, Codable, Equatable {
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
    var advancedTemperatureEnabled: Bool = false
    var advancedMaxTokensEnabled: Bool = false
    var advancedSystemPromptEnabled: Bool = false
    var advancedTTSInstructionEnabled: Bool = false

    var selectedTTSVoice: String?
    var selectedDefaultProvider: LLMProvider?
    var selectedDefaultPlaybackSpeed: Float?
    var webSearchEnabled: Bool? = false
    var energySaverEnabled: Bool? = false
    
    // Default values can be set here or when initializing SettingsService
    init() {
        // Sensible defaults if needed
    }
}

// MARK: - OpenAI TTS API Structures
struct OpenAITTSRequest: Codable {
    let model: String
    let input: String
    let voice: String
    let response_format: String
    let instructions: String?
}

// MARK: - API response structures

struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

struct OpenAIResponseEvent: Decodable {
    let type: String
    let delta: String?
}

struct ClaudeEvent: Decodable {
    let type: String
    struct Delta: Decodable { let text: String? }
    let delta: Delta?
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
    case openai = "OpenAI"
    var id: String { self.rawValue }
}
