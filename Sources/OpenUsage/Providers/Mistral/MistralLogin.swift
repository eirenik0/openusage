import Foundation

/// Mistral's Vibe browser sign-in provisions a workspace API key. It is not OAuth and has no
/// callback or refresh token. The existing browser-login credential container keeps this key
/// in OpenUsage's own Keychain and enables Sign In Again when Mistral revokes it.
struct MistralLogin: ProviderLogin {
    static let baseURL = URL(string: "https://console.mistral.ai/api/vibe/sign-in")!
    static let browserKey = "mistral_browser_key"
    var http: any HTTPClient = URLSessionHTTPClient()
    var now: @Sendable () -> Date = Date.init
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    func login(
        prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>
    ) async throws -> (label: String, credential: AccountCredential) {
        try Task.checkCancellation()
        let pkce = PKCE.generate()
        let response = try await LoginHTTP.postJSON(Self.baseURL, fields: [
            "code_challenge": pkce.challenge, "code_challenge_method": "S256"
        ], using: http)
        let process = try LoginHTTP.decode(Process.self, from: response)
        guard Self.validProcessID(process.process_id),
              Self.isConsoleURL(process.sign_in_url),
              Self.isConsoleURL(process.poll_url), process.poll_url.fragment == nil,
              process.poll_url.path.hasPrefix("/api/vibe/sign-in/poll/"),
              Self.validProcessID(String(process.poll_url.path.dropFirst("/api/vibe/sign-in/poll/".count))),
              let expiry = OpenUsageISO8601.date(from: process.expires_at), expiry > now() else {
            throw LoginError.invalidResponse
        }
        try Task.checkCancellation()
        await prompt(.browser(process.sign_in_url, acceptsPastedCode: false))
        let poller = MistralSignInPoll(http: http, url: process.poll_url)
        let exchangeToken: String = try await DeviceCodePoller.poll(
            interval: 3, expiresIn: min(900, expiry.timeIntervalSince(now())),
            expirationMessage: "Mistral browser sign-in expired. Try again.", now: now, sleep: sleep
        ) { try await poller.request() }
        try Task.checkCancellation()
        let exchange = try await LoginHTTP.postJSON(
            Self.baseURL.appendingPathComponent(process.process_id).appendingPathComponent("exchange"),
            fields: ["exchange_token": exchangeToken, "code_verifier": pkce.verifier], using: http
        )
        let key = try LoginHTTP.decode(Exchange.self, from: exchange).api_key
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw LoginError.invalidResponse }
        try Task.checkCancellation()
        // Validate that the issued key can read usage before saving an account. Never save a key
        // that only permits inference, or substitute another account's cached usage.
        let budget = try await MistralUsageClient(http: http).fetchBudget(apiKey: key)
        _ = try MistralUsageMapper.browserBudgets(budget.body)
        return ("Mistral", .oauth(OAuthTokens(accessToken: key, extras: [Self.browserKey: "true"])))
    }

    static func isConsoleURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "console.mistral.ai" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    private static func validProcessID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private struct Process: Decodable {
        let process_id: String
        let sign_in_url: URL
        let poll_url: URL
        let expires_at: String
    }

    private struct Exchange: Decodable {
        let api_key: String
    }
}
