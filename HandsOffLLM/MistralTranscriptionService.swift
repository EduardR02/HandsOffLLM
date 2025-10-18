import Foundation
import AVFoundation
import OSLog

class MistralTranscriptionService {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MistralTranscriptionService")
    private let apiKey: String
    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default)
    }()
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func transcribeAudio(audioData: Data) async throws -> String {
        guard let url = URL(string: "https://api.mistral.ai/v1/audio/transcriptions") else {
            throw LlmError.invalidURL
        }
        
        // Always use WAV - no conversion needed
        let filename = "audio.wav"
        let contentType = "audio/wav"
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        let body = createMultipartBody(
            boundary: boundary,
            audioData: audioData,
            model: "voxtral-mini-latest",
            filename: filename,
            contentType: contentType
        )
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.upload(for: request, from: body)
        } catch {
            throw LlmError.networkError(error)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlmError.networkError(URLError(.badServerResponse))
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "N/A"
            logger.error("Mistral transcription error: Status \(httpResponse.statusCode). Body: \(errorBody)")
            throw LlmError.invalidResponse(statusCode: httpResponse.statusCode, body: errorBody)
        }
        
        let transcriptionResponse: MistralTranscriptionResponse
        do {
            transcriptionResponse = try JSONDecoder().decode(MistralTranscriptionResponse.self, from: data)
        } catch {
            throw LlmError.responseDecodingError(error)
        }
        
        logger.info("Transcription successful: \(transcriptionResponse.text)")
        return transcriptionResponse.text
    }
    
    private func createMultipartBody(
        boundary: String,
        audioData: Data,
        model: String,
        filename: String,
        contentType: String
    ) -> Data {
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
