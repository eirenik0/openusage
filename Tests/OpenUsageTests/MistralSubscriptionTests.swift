import XCTest
@testable import OpenUsage

final class MistralSubscriptionMapperTests: XCTestCase {
    func testIncludesAPIAndSubscriptionUsageAndTheirOwnResetsWithoutEstimatingSpend() throws {
        let usage = try MistralUsageMapper.browserBudgets(Data(MistralBrowserLoginTests.budget.utf8), plan: "INDIVIDUAL")
        XCTAssertEqual(usage.plan, "INDIVIDUAL")
        XCTAssertEqual(usage.lines, [
            .percent("Monthly Usage", 12.5, resetsAt: OpenUsageISO8601.date(from: "2027-02-01T00:00:00Z")),
            .percent("Subscription Usage", 42.5, resetsAt: OpenUsageISO8601.date(from: "2027-02-01T00:00:00Z"))
        ])
        XCTAssertEqual(usage.lineTitles["Monthly Usage"], "API Usage")
    }

    func testSubscriptionOnlyAccountDoesNotRequireAnAPIBudget() throws {
        let body = #"{"api_budget":null,"vibe_budget":{"usage_percentage":0,"initial_budget":300,"reset_at":"2027-02-01T00:00:00Z"}}"#
        let usage = try MistralUsageMapper.browserBudgets(Data(body.utf8))
        XCTAssertEqual(usage.lines, [.percent("Subscription Usage", 0, resetsAt: OpenUsageISO8601.date(from: "2027-02-01T00:00:00Z"))])
    }

    func testAPIOnlyAccountDoesNotInventSubscriptionUsage() throws {
        let body = #"{"api_budget":{"usage_percentage":130,"initial_budget":50,"reset_at":null},"vibe_budget":null}"#
        XCTAssertEqual(try MistralUsageMapper.browserBudgets(Data(body.utf8)).lines, [.percent("Monthly Usage", 130)])
    }

    func testEmptyBudgetsAndMalformedSubscriptionUsageDoNotBecomeZero() {
        for body in [
            #"{"api_budget":null,"vibe_budget":null}"#,
            #"{"vibe_budget":{"usage_percentage":true,"initial_budget":300,"reset_at":null}}"#,
            #"{"vibe_budget":{"usage_percentage":-1,"initial_budget":300,"reset_at":null}}"#,
            #"{"vibe_budget":{"usage_percentage":10,"initial_budget":300,"reset_at":"bad date"}}"#
        ] {
            XCTAssertThrowsError(try MistralUsageMapper.browserBudgets(Data(body.utf8)))
        }
    }

    func testSubscriptionPlanIsReportedRatherThanInferredFromTheBudget() throws {
        XCTAssertEqual(try MistralUsageMapper.subscriptionPlan(Data(#"{"plan_name":"INDIVIDUAL","payg_enabled":true,"vibe_payg_enabled":false,"enterprise":false}"#.utf8)), "INDIVIDUAL")
        for body in ["{}", #"{"plan_name":""}"#, #"{"plan_name":false}"#] {
            XCTAssertThrowsError(try MistralUsageMapper.subscriptionPlan(Data(body.utf8)))
        }
    }
}

@MainActor
final class MistralSubscriptionRuntimeTests: XCTestCase {
    func testBothBudgetsShowInTheApprovedOrderAndExportAsConsumption() async throws {
        let runtime = AccountProviderRuntime(account: Account(kind: .mistral, label: "Personal"), vault: InMemoryCredentialVault())
        let usage = try MistralUsageMapper.browserBudgets(Data(MistralBrowserLoginTests.budget.utf8), plan: "INDIVIDUAL")
        var snapshot = ProviderSnapshot(provider: runtime.provider, plan: usage.plan, lines: usage.lines)
        snapshot.lineTitles = usage.lineTitles
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        store.snapshots[runtime.provider.id] = snapshot
        let shown = runtime.widgetDescriptors.map { store.data(for: $0) }.filter(\.hasData)
        XCTAssertEqual(shown.map(\.title), ["Subscription Usage", "API Usage"])
        XCTAssertEqual(shown.map(\.used), [42.5, 12.5])
        XCTAssertTrue(shown.allSatisfy { $0.kind == .percent && $0.limit == 100 && $0.resetsAt != nil })
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: LimitsEnvelope.encode(.init(
            registry: .from([runtime]), snapshots: [runtime.provider.id: snapshot]
        ))) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let provider = try XCTUnwrap(providers[runtime.provider.id] as? [String: Any])
        let resources = try XCTUnwrap(provider["resources"] as? [String: [String: Any]])
        for (key, used) in [("subscriptionUsage", 42.5), ("monthlyUsage", 12.5)] {
            let resource = try XCTUnwrap(resources[key])
            XCTAssertEqual(resource["kind"] as? String, "consumption")
            XCTAssertEqual(resource["unit"] as? String, "percent")
            XCTAssertEqual(resource["used"] as? Double, used)
            XCTAssertEqual(resource["limit"] as? Double, 100)
            XCTAssertNotNil(resource["resetsAt"])
            XCTAssertNil(resource["available"])
        }
    }

    func testMissingBudgetHidesOnlyItsOwnRow() throws {
        for field in ["api_budget", "vibe_budget"] {
            let body = "{\"\(field)\":{\"usage_percentage\":0,\"initial_budget\":100,\"reset_at\":null}}"
            let runtime = AccountProviderRuntime(account: Account(kind: .mistral, label: "Personal"), vault: InMemoryCredentialVault())
            let usage = try MistralUsageMapper.browserBudgets(Data(body.utf8))
            let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
            store.snapshots[runtime.provider.id] = ProviderSnapshot(provider: runtime.provider, plan: nil, lines: usage.lines)
            let shown = runtime.widgetDescriptors.filter { store.data(for: $0).hasData }
            XCTAssertEqual(shown.map(\.key), field == "vibe_budget" ? ["subscription"] : ["monthly"])
        }
    }

    func testBrowserRuntimeReadsBothBudgetsAndCachesTheSubscriptionName() async throws {
        let account = Account(kind: .mistral, label: "Personal")
        let vault = InMemoryCredentialVault()
        try vault.save(.oauth(OAuthTokens(accessToken: "browser-key", extras: [MistralLogin.browserKey: "true"])), for: account.id)
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["x-api-key"], "browser-key")
            switch request.url.path {
            case "/v1/billing/budget": return .json(MistralBrowserLoginTests.budget)
            case "/v1/billing/subscription": return .json(#"{"plan_name":"INDIVIDUAL"}"#)
            default: XCTFail("Unexpected URL"); return .json("{}", status: 404)
            }
        }
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http)
        let first = try await runtime.refresh().get()
        XCTAssertEqual(first.plan, "INDIVIDUAL")
        XCTAssertNotNil(first.line(label: "Monthly Usage"))
        XCTAssertNotNil(first.line(label: "Subscription Usage"))
        _ = try await runtime.refresh().get()
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/subscription") }.count, 1)
        runtime.forgetHourlyReads()
        _ = try await runtime.refresh().get()
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/subscription") }.count, 2)
    }
}
