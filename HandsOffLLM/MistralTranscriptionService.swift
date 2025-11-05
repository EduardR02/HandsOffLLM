import Foundation
import OSLog

final class MistralTranscriptionService: @unchecked Sendable {
    let apiKey: String
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HandsOffLLM", category: "MistralTranscriptionService")
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribeAudio(data: Data, filename: String, contentType: String, model: String = "voxtral-mini-latest") async throws -> String {
        guard let url = URL(string: "https://api.mistral.ai/v1/audio/transcriptions") else {
            throw LlmError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = createMultipartBody(
            boundary: boundary,
            data: data,
            filename: filename,
            contentType: contentType,
            model: model
        )

        let (responseData, response): (Data, URLResponse)
        do {
            (responseData, response) = try await urlSession.upload(for: request, from: body)
        } catch {
            throw LlmError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "<non-utf8 body>"
            logger.error("Mistral transcription error: Status \(httpResponse.statusCode). Body: \(errorBody)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody)
        }

        let transcriptionResponse: MistralTranscriptionResponse
        do {
            transcriptionResponse = try JSONDecoder().decode(MistralTranscriptionResponse.self, from: responseData)
        } catch {
            throw LlmError.responseDecodingError(error)
        }

        logger.info("Transcription successful: \(transcriptionResponse.text)")
        return transcriptionResponse.text
    }

    private func createMultipartBody(
        boundary: String,
        data: Data,
        filename: String,
        contentType: String,
        model: String
    ) -> Data {
        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model)\r\n")

        body.append("--\(boundary)--\r\n")

        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
