import XCTest
@testable import OpenUsage

/// Sanitized, schema-shaped fixtures for LimitsOUT / UsageLimits from Mistral's OpenAPI.
/// No customer credentials or live billing data are needed to exercise the integration.
enum MistralFixtures {
    static let capped = #"{"limits":{"currency":"EUR","completion":{"monthly_limit_reached":false,"no_monthly_limit":false,"usage":8.25,"vibe_usage":4,"total_usage":12.25,"usage_limit":100},"last_payment_failure":false,"last_payment_failure_protection":null}}"#
    static let unlimited = #"{"limits":{"currency":"USD","completion":{"monthly_limit_reached":false,"no_monthly_limit":true,"total_usage":0,"usage_limit":100}}}"#
    static let empty = #"{"limits":{"currency":"EUR","completion":{"monthly_limit_reached":false,"total_usage":null,"usage_limit":null}}}"#
}

final class MistralUsageMapperTests: XCTestCase {
    func testUsesProviderTotalAndCurrencyWithoutPricingOrSummingComponents() throws {
        let usage = try MistralUsageMapper.map(Data(MistralFixtures.capped.utf8))
        XCTAssertNil(usage.plan)
        XCTAssertEqual(usage.lines, [.progress(label: "Monthly Usage", used: 12.25, limit: 100, format: .currency(code: "EUR"))])
    }

    func testUnlimitedZeroUsageIsNotAnEmptyBalanceOrFabricatedCap() throws {
        let usage = try MistralUsageMapper.map(Data(MistralFixtures.unlimited.utf8))
        XCTAssertEqual(usage.lines, [.values(label: "Monthly Usage", values: [MetricValue(number: 0, kind: .dollars, currencyCode: "USD")])])
    }

    func testAbsentOrNullCapShowsReportedSpendOnly() throws {
        for cap in ["", ",\"usage_limit\":null"] {
            let body = "{\"limits\":{\"currency\":\"eur\",\"completion\":{\"monthly_limit_reached\":false,\"total_usage\":7.5\(cap)}}}"
            XCTAssertEqual(try MistralUsageMapper.map(Data(body.utf8)).lines, [
                .values(label: "Monthly Usage", values: [MetricValue(number: 7.5, kind: .dollars, currencyCode: "EUR")])
            ])
        }
    }

    func testZeroCapAndOverageAreNotClampedAway() throws {
        for cap in [0, 10] {
            let body = "{\"limits\":{\"currency\":\"USD\",\"completion\":{\"monthly_limit_reached\":true,\"total_usage\":12.25,\"usage_limit\":\(cap)}}}"
            XCTAssertEqual(try MistralUsageMapper.map(Data(body.utf8)).lines, [
                .progress(label: "Monthly Usage", used: 12.25, limit: Double(cap), format: .currency(code: "USD"))
            ])
        }
    }

    func testMissingTotalDoesNotTurnIntoZeroOrPartialUsage() {
        for body in [MistralFixtures.empty, MistralFixtures.capped.replacingOccurrences(of: "\"total_usage\":12.25,", with: "")] {
            XCTAssertThrowsError(try MistralUsageMapper.map(Data(body.utf8))) { error in
                guard case ProviderError.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testMalformedResponsesFailAtTheBoundary() {
        let replacements = [
            ("\"EUR\"", "\"not-a-currency\""),
            ("\"EUR\"", "null"),
            ("12.25", "-1"),
            ("12.25", "true"),
            ("12.25", "1e999"),
            ("12.25", "\"NaN\""),
            ("\"usage_limit\":100", "\"usage_limit\":-1"),
            ("\"usage_limit\":100", "\"usage_limit\":true"),
            ("\"no_monthly_limit\":false", "\"no_monthly_limit\":\"false\""),
            ("\"monthly_limit_reached\":false", "\"monthly_limit_reached\":null")
        ]
        let malformed = ["{}", "[]", "not json", #"{"error":"denied"}"#] + replacements.map {
            MistralFixtures.capped.replacingOccurrences(of: $0.0, with: $0.1)
        }
        for body in malformed {
            XCTAssertThrowsError(try MistralUsageMapper.map(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ProviderError, .invalidResponse)
            }
        }
    }
}

@MainActor
final class MistralProviderTests: XCTestCase {
    func testCatalogAndAPIKeyLoginTrimAndValidateTheKey() async throws {
        XCTAssertTrue(ProviderLoginCatalog.login(for: .mistral, method: ProviderKind.mistral.authMethods[0], organization: "", domain: .github) is MistralLogin)
        XCTAssertTrue(ProviderLoginCatalog.login(for: .mistral, method: .apiKey(keyPage: URL(string: "https://console.mistral.ai/api-keys")!), organization: "", domain: .github) is APIKeyLogin)
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.absoluteString, "https://api.mistral.ai/v1/admin/spend-limit")
            XCTAssertEqual(request.headers["Authorization"], "Bearer test-admin-key")
            XCTAssertEqual(request.headers["Accept"], "application/json")
            XCTAssertNil(request.body)
            return .json(MistralFixtures.capped)
        }
        let login = APIKeyLogin(kind: .mistral, http: http)
        let result = try await login.login(prompt: { _ in XCTFail("API keys need no browser prompt") }, pastedCode: stream(" \n test-admin-key \n"))
        XCTAssertEqual(result.label, "Mistral")
        XCTAssertEqual(result.credential, .apiKey("test-admin-key"))
        XCTAssertEqual(http.requests.count, 1)
    }

    func testLoginRejectsBlankKeysWithoutSendingARequest() async {
        let http = RoutingHTTPClient { _ in XCTFail("Must not send an empty key"); return .json("{}") }
        do {
            _ = try await APIKeyLogin(kind: .mistral, http: http).login(prompt: { _ in }, pastedCode: stream(" \n "))
            XCTFail("Blank key accepted")
        } catch {
            guard case LoginError.invalidCode = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRejectedOrStandardKeyExplainsTheEnterpriseAdminRequirement() async throws {
        for status in [401, 403] {
            let http = RoutingHTTPClient { _ in .json(#"{"message":"private body must not reach the user"}"#, status: status) }
            do {
                _ = try await APIKeyLogin(kind: .mistral, http: http).login(prompt: { _ in }, pastedCode: stream("test"))
                XCTFail("Rejected key accepted")
            } catch {
                guard case ProviderError.unavailable(let message) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertTrue(message.contains("Enterprise Admin API key"))
                XCTAssertFalse(message.contains("private body"))
            }
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testRuntimeRefreshAndCLIExportPreserveCurrencyAndConsumptionSemantics() async throws {
        for body in [MistralFixtures.capped, MistralFixtures.unlimited] {
            let (runtime, http) = try runtime(body: body)
            let snapshot = try await runtime.refresh().get()
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(runtime.widgetDescriptors.map(\.key), ["subscription", "monthly"])
            let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
            store.snapshots[runtime.provider.id] = snapshot
            let descriptor = try XCTUnwrap(runtime.widgetDescriptors.first { $0.key == "monthly" })
            let widget = store.data(for: descriptor)
            XCTAssertTrue(widget.hasData)
            XCTAssertNil(descriptor.balance(in: widget))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: LimitsEnvelope.encode(.init(
                registry: .from([runtime]), snapshots: [runtime.provider.id: snapshot]
            ))) as? [String: Any])
            let providers = try XCTUnwrap(json["providers"] as? [String: Any])
            let provider = try XCTUnwrap(providers[runtime.provider.id] as? [String: Any])
            let resources = try XCTUnwrap(provider["resources"] as? [String: Any])
            let monthly = try XCTUnwrap(resources["monthlyUsage"] as? [String: Any])
            XCTAssertEqual(monthly["kind"] as? String, "consumption")
            XCTAssertNil(monthly["available"])
            XCTAssertNil(monthly["resetsAt"])
            if body == MistralFixtures.capped {
                XCTAssertEqual(widget.currencyCode, "EUR")
                XCTAssertEqual(monthly["unit"] as? String, "eur")
                XCTAssertEqual(monthly["used"] as? Double, 12.25)
                XCTAssertEqual(monthly["limit"] as? Double, 100)
                XCTAssertEqual(monthly["remaining"] as? Double, 87.75)
            } else {
                XCTAssertEqual(monthly["unit"] as? String, "usd")
                XCTAssertEqual(monthly["used"] as? Double, 0)
                XCTAssertNil(monthly["limit"])
            }
        }
    }

    func testHTTPFailuresAndMalformedBodiesDoNotProduceSnapshots() async throws {
        for (status, expected) in [(429, ProviderError.rateLimited(retryAfter: 60)), (500, .requestFailed(500))] {
            let http = RoutingHTTPClient { _ in
                HTTPResponse(statusCode: status, headers: ["retry-after": "60"], body: Data())
            }
            do {
                _ = try await MistralUsageClient(http: http).fetchUsage(apiKey: "test")
                XCTFail("HTTP failure accepted")
            } catch { XCTAssertEqual(error as? ProviderError, expected) }
        }
        let (runtime, _) = try runtime(body: "{}")
        let result = await runtime.refresh()
        XCTAssertNotNil(result.failure)
    }

    func testNoCredentialOrWrongCredentialDoesNotSendUsageRequests() async throws {
        let http = RoutingHTTPClient { _ in XCTFail("Must not send without an API key"); return .json("{}") }
        let runtime = AccountProviderRuntime(account: Account(kind: .mistral, label: "Work"), vault: InMemoryCredentialVault(), http: http)
        let result = await runtime.refresh()
        XCTAssertNotNil(result.failure)
        do {
            _ = try await runtime.readSnapshot(using: .oauth(OAuthTokens(accessToken: "wrong")))
            XCTFail("Wrong credential accepted")
        } catch { XCTAssertEqual(error as? ProviderError, .invalidResponse) }
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertNil(runtime.resetClaimService(refreshAccount: { .refreshed }))
    }

    private func runtime(body: String) throws -> (AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .mistral, label: "Work")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("test-admin-key"), for: account.id)
        let http = RoutingHTTPClient { _ in .json(body) }
        return (AccountProviderRuntime(account: account, vault: vault, http: http), http)
    }

    private func stream(_ value: String) -> AsyncStream<String> {
        AsyncStream { $0.yield(value); $0.finish() }
    }
}
