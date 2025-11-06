import Foundation
import OSLog

/// Service to route API requests through Supabase Edge Function proxy
@MainActor
class ProxyService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ProxyService")
    private let authService: AuthService
    private let settingsService: SettingsService

    init(authService: AuthService, settingsService: SettingsService) {
        self.authService = authService
        self.settingsService = settingsService
    }

    /// Determines if request should go through proxy or direct to provider
    func shouldUseProxy(for provider: LLMProvider) -> Bool {
        switch provider {
        case .openai:
            return settingsService.useOwnOpenAIKey == false || settingsService.openaiAPIKey?.isEmpty != false
        case .claude:
            return settingsService.useOwnAnthropicKey == false || settingsService.anthropicAPIKey?.isEmpty != false
        case .gemini:
            return settingsService.useOwnGeminiKey == false || settingsService.geminiAPIKey?.isEmpty != false
        case .xai:
            return settingsService.useOwnXAIKey == false || settingsService.xaiAPIKey?.isEmpty != false
        case .replicate:
            return true // Always use proxy for Replicate
        }
    }

    /// Creates a proxied request
    func makeProxiedRequest(
        provider: LLMProvider,
        endpoint: String,
        method: String = "POST",
        headers: [String: String],
        body: [String: Any]
    ) async throws -> URLRequest {
        let jwt = try await authService.getCurrentJWT()

        guard let supabaseURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String else {
            throw ProxyError.missingConfiguration("SUPABASE_URL not found in Info.plist")
        }

        let proxyEndpoint = "\(supabaseURL)/functions/v1/proxy"
        guard let url = URL(string: proxyEndpoint) else {
            throw ProxyError.invalidURL(proxyEndpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let proxyPayload: [String: Any] = [
            "provider": provider.rawValue.lowercased(),
            "endpoint": endpoint,
            "method": method,
            "headers": headers,
            "bodyData": body
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: proxyPayload)

        logger.info("Routing \(provider.rawValue) request through proxy")
        return request
    }

    /// Creates a proxied transcription request (for audio file uploads)
    func makeProxiedTranscriptionRequest(
        audioData: Data,
        model: String = "voxtral-mini-latest",
        filename: String,
        contentType: String
    ) async throws -> URLRequest {
        let jwt = try await authService.getCurrentJWT()

        guard let supabaseURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String else {
            throw ProxyError.missingConfiguration("SUPABASE_URL not found in Info.plist")
        }

        let proxyEndpoint = "\(supabaseURL)/functions/v1/transcribe"
        guard let url = URL(string: proxyEndpoint) else {
            throw ProxyError.invalidURL(proxyEndpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model)\r\n")

        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        logger.info("Routing Mistral transcription request through dedicated proxy")
        return request
    }

    /// Creates a direct request (when user has own API keys)
    func makeDirectRequest(
        endpoint: String,
        method: String = "POST",
        headers: [String: String],
        body: [String: Any]
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw ProxyError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        headers.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum ProxyError: Error, LocalizedError {
    case missingConfiguration(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let message):
            return "Configuration error: \(message)"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
