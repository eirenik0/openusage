import XCTest
@testable import OpenUsage

final class MistralBrowserLoginTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let budget = #"{"api_budget":{"usage_percentage":12.5,"initial_budget":100,"reset_at":"2027-02-01T00:00:00Z"},"vibe_budget":{"usage_percentage":42.5,"initial_budget":300,"reset_at":"2027-02-01T00:00:00Z","payg_enabled":false}}"#

    private static func process(
        signIn: String = "https://console.mistral.ai/codestral/cli/authenticate#process_id=process-1&state=server-state&complete_token=complete-secret",
        poll: String = "https://console.mistral.ai/api/vibe/sign-in/poll/poll-secret",
        id: String = "process-1", expiry: Date = now.addingTimeInterval(300)
    ) -> HTTPResponse {
        .init(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: [
            "process_id": id, "sign_in_url": signIn, "poll_url": poll,
            "expires_at": OpenUsageISO8601.string(from: expiry)
        ]))
    }

    func testBrowserPKCEPollExchangeAndUsageValidation() async throws {
        let promptCount = TestSwitch(0)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/vibe/sign-in": return Self.process()
            case "/api/vibe/sign-in/poll/poll-secret": return .json(#"{"status":"completed","exchange_token":"exchange-secret"}"#)
            case "/api/vibe/sign-in/process-1/exchange": return .json(#"{"api_key":"browser-issued-key"}"#)
            case "/v1/billing/budget":
                XCTAssertEqual(request.headers["x-api-key"], "browser-issued-key")
                XCTAssertNil(request.headers["Authorization"])
                return .json(Self.budget)
            default: XCTFail("Unexpected endpoint: \(request.url.path)"); return .json("{}", status: 404)
            }
        }
        let login = MistralLogin(http: http, now: { Self.now })
        let result = try await login.login(prompt: { prompt in
            guard case .browser(let url, let pasted) = prompt else { return XCTFail("Expected browser") }
            XCTAssertEqual(url.host, "console.mistral.ai")
            XCTAssertTrue(url.fragment?.contains("complete-secret") == true)
            XCTAssertFalse(pasted)
            promptCount.value += 1
        }, pastedCode: AsyncStream { $0.finish() })
        guard case .oauth(let stored) = result.credential else { return XCTFail("Expected browser credential") }
        XCTAssertEqual(result.label, "Mistral")
        XCTAssertEqual(stored.accessToken, "browser-issued-key")
        XCTAssertEqual(stored.extras[MistralLogin.browserKey], "true")
        XCTAssertNil(stored.refreshToken)
        XCTAssertNil(stored.expiresAt)
        XCTAssertEqual(promptCount.value, 1)
        let requests = http.requests
        XCTAssertEqual(requests.count, 4)
        let start = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].body)) as? [String: String])
        let exchange = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[2].body)) as? [String: String])
        XCTAssertEqual(start["code_challenge_method"], "S256")
        XCTAssertEqual(start["code_challenge"], PKCE.challenge(for: try XCTUnwrap(exchange["code_verifier"])))
        XCTAssertNil(start["code_verifier"])
        XCTAssertEqual(exchange["exchange_token"], "exchange-secret")
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "POST", "GET"])
    }

    func testPendingPollWaitsAndCanExpireWithoutExchanging() async throws {
        let clock = TestClock(Self.now)
        let http = RoutingHTTPClient { request in
            request.method == "POST" ? Self.process(expiry: Self.now.addingTimeInterval(5)) : .json(#"{"status":"pending"}"#)
        }
        let login = MistralLogin(http: http, now: { clock.now }, sleep: { seconds in
            clock.set(clock.now.addingTimeInterval(seconds))
        })
        do {
            _ = try await login.login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })
            XCTFail("Should expire")
        } catch {
            guard case LoginError.failed(let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(message, "Mistral browser sign-in expired. Try again.")
        }
        XCTAssertFalse(http.requests.contains { $0.url.path.hasSuffix("exchange") })
        XCTAssertEqual(clock.now, Self.now.addingTimeInterval(5))
    }

    func testTransientPollFailuresRecoverAndASuccessfulPollResetsTheCount() async throws {
        let count = TestSwitch(0)
        let clock = TestClock(Self.now)
        let http = RoutingHTTPClient { request in
            switch request.url.path {
            case "/api/vibe/sign-in": return Self.process()
            case "/api/vibe/sign-in/poll/poll-secret":
                count.value += 1
                switch count.value {
                case 1, 2: return .json("private server error", status: 503)
                case 3: return .json(#"{"status":"pending"}"#)
                case 4: throw URLError(.timedOut)
                case 5: return .json("private rate limit", status: 429)
                default: return .json(#"{"status":"completed","exchange_token":"secret"}"#)
                }
            case "/api/vibe/sign-in/process-1/exchange": return .json(#"{"api_key":"issued-key"}"#)
            case "/v1/billing/budget": return .json(Self.budget)
            default: XCTFail("Unexpected endpoint"); return .json("{}", status: 404)
            }
        }
        let login = MistralLogin(http: http, now: { clock.now }, sleep: { clock.set(clock.now.addingTimeInterval($0)) })
        let result = try await login.login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })
        guard case .oauth(let tokens) = result.credential else { return XCTFail("No browser credential") }
        XCTAssertEqual(tokens.accessToken, "issued-key")
        XCTAssertEqual(count.value, 6)
        XCTAssertEqual(clock.now, Self.now.addingTimeInterval(15))
    }

    func testThreeConsecutivePollFailuresStopWithoutExchangingOrLeakingTheBody() async {
        for status in [500, 429, 0] {
            let clock = TestClock(Self.now)
            let http = RoutingHTTPClient { request in
                if request.method == "POST" { return Self.process() }
                if status == 0 { throw URLError(.timedOut) }
                return .json("private server error", status: status)
            }
            let login = MistralLogin(http: http, now: { clock.now }, sleep: { clock.set(clock.now.addingTimeInterval($0)) })
            do {
                _ = try await login.login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })
                XCTFail("Repeated poll failures must stop sign-in")
            } catch {
                guard case LoginError.failed(let message) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(message, "Mistral browser sign-in could not retrieve its status. Try again.")
            }
            XCTAssertEqual(http.requests.count, 4, "Start plus exactly three failed polls")
            XCTAssertEqual(clock.now, Self.now.addingTimeInterval(6))
            XCTAssertFalse(http.requests.contains { $0.url.path.hasSuffix("exchange") })
        }
    }

    func testCancelledTransportDoesNotRetry() async {
        let clock = TestClock(Self.now)
        let http = RoutingHTTPClient { request in
            if request.method == "POST" { return Self.process() }
            throw URLError(.cancelled)
        }
        let login = MistralLogin(http: http, now: { clock.now }, sleep: { clock.set(clock.now.addingTimeInterval($0)) })
        do {
            _ = try await login.login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })
            XCTFail("Cancelled transport must stop sign-in")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(clock.now, Self.now)
    }

    func testUntrustedURLsExpiredAttemptsAndInvalidProcessIDsNeverOpenABrowser() async throws {
        let cases: [HTTPResponse] = [
            Self.process(signIn: "https://attacker.example/login"),
            Self.process(signIn: "http://console.mistral.ai/login"),
            Self.process(poll: "https://attacker.example/api/vibe/sign-in/poll/secret"),
            Self.process(poll: "https://console.mistral.ai:444/api/vibe/sign-in/poll/secret"),
            Self.process(poll: "https://user:pass@console.mistral.ai/api/vibe/sign-in/poll/secret"),
            Self.process(poll: "https://console.mistral.ai/api/vibe/sign-in/poll/../escape"),
            Self.process(id: "../escape"), Self.process(expiry: Self.now)
        ]
        for response in cases {
            let http = RoutingHTTPClient { _ in response }
            do {
                _ = try await MistralLogin(http: http, now: { Self.now }).login(prompt: { _ in XCTFail("Unsafe prompt") }, pastedCode: AsyncStream { $0.finish() })
                XCTFail("Accepted invalid process")
            } catch { XCTAssertEqual(String(describing: error), String(describing: LoginError.invalidResponse)) }
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testDeniedExpiredUnknownAndMissingExchangeTokenDoNotExchange() async {
        for (status, body) in [(200, #"{"status":"denied"}"#), (410, "{}"), (200, #"{"status":"alien"}"#),
                               (200, #"{"status":"completed"}"#), (200, #"{"status":"error","message":"private error"}"#)] {
            let http = RoutingHTTPClient { request in
                request.method == "POST" ? Self.process() : .json(body, status: status)
            }
            do {
                _ = try await MistralLogin(http: http, now: { Self.now }).login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })
                XCTFail("Accepted failed poll")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private error")) }
            XCTAssertEqual(http.requests.count, 2)
        }
    }

    func testPollingSecretsAreNotLogged() {
        for path in ["/api/vibe/sign-in/poll/poll-secret", "/api/vibe/sign-in/process-1/exchange"] {
            let request = HTTPRequest(method: "GET", url: URL(string: "https://console.mistral.ai" + path)!)
            let diagnostic = URLSessionHTTPClient.diagnostic(for: request, response: .json("{}"), duration: .seconds(1))
            XCTAssertFalse(diagnostic.contains("poll-secret"))
            XCTAssertFalse(diagnostic.contains("process-1"))
            XCTAssertTrue(diagnostic.contains("<redacted>"))
        }
    }

    func testCancellationNeverExchangesOrSavesAKey() async throws {
        let held = HeldResponse()
        let http = RoutingHTTPClient { request in
            if request.method == "POST" { return Self.process() }
            await held.hold()
            return .json(#"{"status":"completed","exchange_token":"secret"}"#)
        }
        let task = Task {
            try await MistralLogin(http: http, now: { Self.now }).login(prompt: { _ in }, pastedCode: AsyncStream { $0.finish() })
        }
        await held.waitUntilHeld()
        task.cancel()
        await held.release()
        do { _ = try await task.value; XCTFail("Cancelled sign-in succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(http.requests.count, 2)
    }
}
