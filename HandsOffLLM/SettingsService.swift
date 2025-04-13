// SettingsService.swift
import Foundation
import OSLog

class SettingsService {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SettingsService")

    // --- API Keys (Read-only access for now) ---
    var anthropicAPIKey: String? { APIKeys.anthropic }
    var geminiAPIKey: String? { APIKeys.gemini }
    var openaiAPIKey: String? { APIKeys.openai }

    // --- Prompts (Read-only access for now) ---
    var systemPrompt: String? { Prompts.chatPrompt }
    var ttsInstructions: String? { Prompts.ttsInstructions }

    // --- Hardcoded Model Names (As per requirement) ---
    let claudeModel = "claude-3-7-sonnet-20250219"
    let geminiModel = "gemini-2.0-flash"
    let openAITTSModel = "gpt-4o-mini-tts"
    let openAITTSVoice = "nova"
    let openAITTSFormat = "wav"
    let maxTTSChunkLength = 4000

    init() {
        validateKeysAndPrompts()
    }

    private func validateKeysAndPrompts() {
        if anthropicAPIKey == nil || anthropicAPIKey!.isEmpty || anthropicAPIKey == "YOUR_ANTHROPIC_API_KEY" {
             logger.warning("Anthropic API Key is not set in APIKeys.swift.")
         }
         if geminiAPIKey == nil || geminiAPIKey!.isEmpty || geminiAPIKey == "YOUR_GEMINI_API_KEY" {
             logger.warning("Gemini API Key is not set in APIKeys.swift.")
         }
         if openaiAPIKey == nil || openaiAPIKey!.isEmpty || openaiAPIKey == "YOUR_OPENAI_API_KEY" {
             logger.warning("OpenAI API Key is not set in APIKeys.swift.")
         }

        if systemPrompt == nil || systemPrompt!.isEmpty {
             logger.info("System prompt is empty.")
        } else if systemPrompt == "You are a helpful voice assistant. Keep your responses concise and conversational." {
            logger.warning("Using the default placeholder system prompt. Edit Prompts.swift to customize.")
        } else {
             logger.info("Custom system prompt loaded.")
        }
    }

    // --- Future Methods (Placeholders) ---
    // func saveSettings(...)
    // func loadSettings(...)
}