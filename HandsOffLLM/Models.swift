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
    var updatedAt: Date? = nil // Optional for backward compatibility
    var parentConversationId: UUID? // To link continued conversations
    // Optional: Map message ID to saved audio file paths (multiple chunks per message)
    var ttsAudioPaths: [UUID: [String]]? // Optional: Map message ID to array of saved audio file paths

    // Helper: Get the effective "last activity" date for sorting
    var lastActivityDate: Date {
        updatedAt ?? createdAt
    }
}
// MARK: - Conversation Index Entry
/// Minimal metadata for listing conversations without loading full messages
struct ConversationIndexEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String?
    let createdAt: Date
    let updatedAt: Date? // Optional for backward compatibility

    // Helper: Get the effective "last activity" date for sorting
    var lastActivityDate: Date {
        updatedAt ?? createdAt
    }
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

struct VoiceInfo: Identifiable, Hashable {
    let id: String // e.g., "af_bella"
    let displayName: String // e.g., "Bella (American English)"
}

struct SettingsData: Codable {
    // Model Selections: Store the ID of the selected model for each provider
    var selectedModelIdPerProvider: [LLMProvider: String] = [:]
    var reasoningEffort: ReasoningEffort?
    var reasoningEnabled: Bool? = nil
    
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
    var selectedKokoroVoice: String?
    var selectedTTSProvider: TTSProvider? = nil
    var selectedDefaultProvider: LLMProvider?
    var selectedDefaultPlaybackSpeed: Float?
    var webSearchEnabled: Bool? = false
    var energySaverEnabled: Bool? = false

    // Personalization Settings
    var userDisplayName: String?
    var userProfileDescription: String?
    var userProfileEnabled: Bool = true
    var hasCompletedInitialSetup: Bool = false
    
    var vadSilenceThreshold: Double? = 1.0

    // User API Keys Toggle (for bypassing proxy)
    var useOwnOpenAIKey: Bool = false
    var useOwnAnthropicKey: Bool = false
    var useOwnGeminiKey: Bool = false
    var useOwnXAIKey: Bool = false
    var useOwnMoonshotKey: Bool = false
    var useOwnMistralKey: Bool = false
    var useOwnReplicateKey: Bool = false

    init() {
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

// MARK: - Replicate TTS API Structures
struct ReplicateTTSRequest: Codable {
    let version: String
    let input: ReplicateTTSInput
}

struct ReplicateTTSInput: Codable {
    let text: String
    let voice: String
    let speed: Double
}

struct ReplicateTTSResponse: Codable {
    let id: String
    let status: String
    let outputURL: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, status, output, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        if let errorString = try? container.decode(String.self, forKey: .error) {
            error = errorString
        } else if let errorValue = try? container.decode(ReplicateJSONValue.self, forKey: .error) {
            error = errorValue.bestEffortDescription
        } else {
            error = nil
        }

        if let output = try? container.decode(ReplicateJSONValue.self, forKey: .output) {
            outputURL = output.firstURLString
        } else {
            outputURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(outputURL, forKey: .output)
    }
}

private enum ReplicateJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([ReplicateJSONValue])
    case object([String: ReplicateJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let array = try? container.decode([ReplicateJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: ReplicateJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Replicate JSON value")
        }
    }

    var firstURLString: String? {
        switch self {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") || trimmed.hasPrefix("data:audio") {
                return trimmed
            }
            return nil
        case .array(let values):
            for value in values {
                if let url = value.firstURLString {
                    return url
                }
            }
            return nil
        case .object(let values):
            let preferredKeys = ["audio", "audio_url", "url", "uri", "file", "src"]
            for key in preferredKeys {
                if let url = values[key]?.firstURLString {
                    return url
                }
            }
            for value in values.values {
                if let url = value.firstURLString {
                    return url
                }
            }
            return nil
        case .number, .bool, .null:
            return nil
        }
    }

    var bestEffortDescription: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .array(let values):
            let rendered = values.map { $0.bestEffortDescription }.joined(separator: ", ")
            return "[\(rendered)]"
        case .object(let values):
            if let message = values["message"]?.bestEffortDescription {
                return message
            }
            if let detail = values["detail"]?.bestEffortDescription {
                return detail
            }
            let rendered = values
                .map { "\($0.key): \($0.value.bestEffortDescription)" }
                .sorted()
                .joined(separator: ", ")
            return "{\(rendered)}"
        case .null:
            return "null"
        }
    }
}

// MARK: - Mistral Transcription API Structures
struct MistralTranscriptionResponse: Codable {
    let model: String
    let text: String
    let language: String?
    let segments: [MistralTranscriptionSegment]?
    let usage: MistralTranscriptionUsage?
}

struct MistralTranscriptionSegment: Codable {
    let text: String
    let start: Double
    let end: Double
    let type: String
}

struct MistralTranscriptionUsage: Codable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let total_tokens: Int?
    let prompt_audio_seconds: Double?
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

struct OpenAICompatibleResponseEvent: Decodable {
    struct ChoiceDelta: Decodable {
        let content: String?
        let reasoning_content: String?
    }

    struct Choice: Decodable {
        let delta: ChoiceDelta?
    }

    let choices: [Choice]?
}

typealias XAIResponseEvent = OpenAICompatibleResponseEvent

enum ReasoningEffort: String, CaseIterable, Codable, Equatable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Max"
        }
    }
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
    case xai = "xAI"
    case moonshot = "Moonshot AI"
    case replicate = "Replicate" // Internal only for TTS proxy routing

    var id: String { self.rawValue }

    /// User-selectable providers (excludes internal-only providers like Replicate)
    static var userFacing: [LLMProvider] {
        [.gemini, .claude, .openai, .xai, .moonshot]
    }

    static func provider(forModelId modelId: String) -> LLMProvider? {
        let normalized = modelId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return nil }

        if normalized.hasPrefix("gpt-")
            || normalized.hasPrefix("chatgpt-")
            || normalized.hasPrefix("codex-")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4") {
            return .openai
        }
        if normalized.hasPrefix("claude-") {
            return .claude
        }
        if normalized.hasPrefix("gemini-") {
            return .gemini
        }
        if normalized.hasPrefix("grok-") {
            return .xai
        }
        if normalized.hasPrefix("kimi-") {
            return .moonshot
        }

        return nil
    }
}

// MARK: - TTS Provider Enum
enum TTSProvider: String, CaseIterable, Identifiable, Codable, Hashable {
    case openai = "OpenAI"
    case kokoro = "Kokoro (Replicate)"
    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .kokoro: return "Kokoro (Replicate)"
        }
    }
}
