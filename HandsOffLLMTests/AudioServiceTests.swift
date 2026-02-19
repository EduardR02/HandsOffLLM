import Testing
import Foundation
@testable import HandsOffLLM

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MockRetryURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

struct AudioServiceTests {

    @Test @MainActor func ttsChunkingWaitsForMinimumLengthUntilFinalChunk() async {
        let settings = SettingsService()
        let audioService = AudioService(settingsService: settings, historyService: HistoryService(), authService: AuthService.shared)

        audioService.ttsRate = 1.0
        audioService.processTTSChunk(textChunk: "Hello world. This is a test!", isLastChunk: false)

        #expect(audioService.findNextTTSChunk() == 0)

        audioService.processTTSChunk(textChunk: "", isLastChunk: true)
        #expect(audioService.findNextTTSChunk() == 28)
    }

    @Test @MainActor func replicateSucceededObjectOutputUsesReturnedAudioURLWithoutPolling() async throws {
        let settings = SettingsService()
        settings.updateSelectedTTSProvider(.kokoro)
        settings.useOwnReplicateKey = true
        settings.setReplicateAPIKey("test-key")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRetryURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            MockRetryURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let expectedAudio = Data([0x52, 0x49, 0x46, 0x46])
        MockRetryURLProtocol.handler = { request in
            guard let url = request.url?.absoluteString else {
                throw URLError(.badURL)
            }

            if url == "https://api.replicate.com/v1/predictions" {
                let responseBody = """
                {"id":"pred_123","status":"succeeded","output":{"audio":"https://cdn.example.com/chunk.wav","duration":1.7}}
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(responseBody.utf8))
            }

            if url == "https://cdn.example.com/chunk.wav" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/wav"]
                )!
                return (response, expectedAudio)
            }

            Issue.record("Unexpected URL requested: \(url)")
            throw URLError(.badServerResponse)
        }

        let audioService = AudioService(
            settingsService: settings,
            historyService: HistoryService(),
            authService: AuthService.shared,
            urlSession: session
        )

        let result = try await audioService.fetchReplicateTTSAudio(
            text: "Hello from Kokoro",
            voice: settings.kokoroTTSVoice,
            speed: 1.0
        )

        #expect(result == expectedAudio)
    }

    @Test @MainActor func replicateRateLimit429RetriesUsingRetryAfterThenSucceeds() async throws {
        let settings = SettingsService()
        settings.updateSelectedTTSProvider(.kokoro)
        settings.useOwnReplicateKey = true
        settings.setReplicateAPIKey("test-key")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let expectedAudio = Data([0x52, 0x49, 0x46, 0x46])
        let attemptQueue = DispatchQueue(label: "AudioServiceTests.replicate429.attemptQueue")
        var predictionAttemptCount = 0

        MockURLProtocol.handler = { request in
            guard let url = request.url?.absoluteString else {
                throw URLError(.badURL)
            }

            if url == "https://api.replicate.com/v1/predictions" {
                let currentAttempt = attemptQueue.sync { () -> Int in
                    predictionAttemptCount += 1
                    return predictionAttemptCount
                }

                if currentAttempt == 1 {
                    let rateLimitBody = """
                    {"detail":"Rate limit exceeded","status":429,"retry_after":0}
                    """
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (response, Data(rateLimitBody.utf8))
                }

                if currentAttempt == 2 {
                    let responseBody = """
                    {"id":"pred_429_retry","status":"succeeded","output":{"audio":"https://cdn.example.com/retry.wav"}}
                    """
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (response, Data(responseBody.utf8))
                }

                Issue.record("Unexpected Replicate prediction attempt: \(currentAttempt)")
                throw URLError(.badServerResponse)
            }

            if url == "https://cdn.example.com/retry.wav" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/wav"]
                )!
                return (response, expectedAudio)
            }

            Issue.record("Unexpected URL requested: \(url)")
            throw URLError(.badServerResponse)
        }

        let audioService = AudioService(
            settingsService: settings,
            historyService: HistoryService(),
            authService: AuthService.shared,
            urlSession: session
        )

        let result = try await audioService.fetchReplicateTTSAudio(
            text: "Retry after 429",
            voice: settings.kokoroTTSVoice,
            speed: 1.0
        )

        let totalPredictionAttempts = attemptQueue.sync { predictionAttemptCount }

        #expect(result == expectedAudio)
        #expect(totalPredictionAttempts == 2)
    }
}
