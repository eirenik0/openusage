import Foundation

struct MistralUsageClient: Sendable {
    static let spendLimitURL = URL(string: "https://api.mistral.ai/v1/admin/spend-limit")!
    static let budgetURL = URL(string: "https://api.mistral.ai/v1/billing/budget")!
    static let subscriptionURL = URL(string: "https://api.mistral.ai/v1/billing/subscription")!
    var http: any HTTPClient

    /// Browser-issued workspace keys use the public billing API, not the Enterprise Admin API.
    func fetchBudget(apiKey: String) async throws -> HTTPResponse {
        let response = try await LoginHTTP.get(Self.budgetURL, using: http, headers: [
            "x-api-key": apiKey, "Accept": "application/json"
        ])
        if response.statusCode == 403 {
            throw ProviderError.unavailable("This Mistral workspace does not permit reading organization usage. Ask its administrator for usage access (see_org_inference_usage).")
        }
        try ProviderError.requireSuccess(response, kind: .mistral)
        _ = try MistralBudget.decode(response.body)
        return response
    }

    func fetchSubscription(apiKey: String) async throws -> String {
        let response = try await LoginHTTP.get(Self.subscriptionURL, using: http, headers: [
            "x-api-key": apiKey, "Accept": "application/json"
        ])
        try ProviderError.requireSuccess(response, kind: .mistral)
        return try MistralUsageMapper.subscriptionPlan(response.body)
    }

    /// The current OpenAPI specifies AdminApiKey bearer authentication, not an inference key.
    func fetchUsage(apiKey: String) async throws -> HTTPResponse {
        let response = try await LoginHTTP.get(
            Self.spendLimitURL, bearerToken: apiKey, using: http, headers: ["Accept": "application/json"]
        )
        if ProviderError.isAuthFailure(response) {
            throw ProviderError.keyRejected(
                "Mistral requires a valid Enterprise Admin API key with access to this organization. Standard inference keys cannot read usage."
            )
        }
        try ProviderError.requireSuccess(response, kind: .mistral)
        return response
    }
}

extension AccountProviderRuntime {
    func refreshMistral(_ credential: AccountCredential) async throws -> ProviderUsage {
        let client = MistralUsageClient(http: http)
        switch credential {
        case .oauth(let tokens):
            guard tokens.extras[MistralLogin.browserKey] == "true" else { throw ProviderError.invalidResponse }
            let response = try await client.fetchBudget(apiKey: tokens.accessToken)
            if planRead.isDue(at: now()) {
                do {
                    planRead.record(try await client.fetchSubscription(apiKey: tokens.accessToken), at: now())
                } catch {
                    AppLog.warn(LogTag.plugin("mistral"), "subscription lookup failed; retrying in an hour: \(error.localizedDescription)")
                    planRead.record(nil, at: now())
                }
            }
            return try MistralUsageMapper.browserBudgets(response.body, plan: planRead.value)
        case .apiKey(let key):
            let response = try await client.fetchUsage(apiKey: key)
            return try MistralUsageMapper.map(response.body)
        }
    }
}
