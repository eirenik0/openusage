import Foundation

/// Keeps transient transport/server failures local to one browser sign-in attempt. Like Vibe,
/// stop after three consecutive failures; a successful poll resets the failure count.
actor MistralSignInPoll {
    private let http: any HTTPClient
    private let url: URL
    private var consecutiveFailures = 0

    init(http: any HTTPClient, url: URL) {
        self.http = http
        self.url = url
    }

    func request() async throws -> DeviceCodePollResult<String> {
        try Task.checkCancellation()
        let response: HTTPResponse
        do {
            response = try await LoginHTTP.get(url, using: http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            try Task.checkCancellation()
            return retryOrFail()
        }
        try Task.checkCancellation()
        if response.statusCode == 410 { return .failed("Mistral browser sign-in expired. Try again.") }
        if response.statusCode == 429 || (500...599).contains(response.statusCode) { return retryOrFail() }
        let poll = try LoginHTTP.decode(Poll.self, from: response)
        consecutiveFailures = 0
        switch poll.status {
        case "pending": return .pending
        case "completed":
            guard let token = poll.exchange_token, !token.isEmpty else { throw LoginError.invalidResponse }
            return .complete(token)
        case "denied": return .failed("Mistral browser sign-in was denied.")
        case "expired": return .failed("Mistral browser sign-in expired. Try again.")
        case "error": return .failed("Mistral browser sign-in failed. Try again.")
        default: throw LoginError.invalidResponse
        }
    }

    private func retryOrFail() -> DeviceCodePollResult<String> {
        consecutiveFailures += 1
        return consecutiveFailures < 3 ? .pending
            : .failed("Mistral browser sign-in could not retrieve its status. Try again.")
    }

    private struct Poll: Decodable {
        let status: String
        let exchange_token: String?
    }
}
