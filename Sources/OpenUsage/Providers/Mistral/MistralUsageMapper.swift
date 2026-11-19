import Foundation

/// GET /v1/admin/spend-limit, as documented by https://docs.mistral.ai/openapi.yaml.
/// Only the provider's total is used: no summing partial usage or applying price catalogs.
enum MistralUsageMapper {
    /// Display order is defined by widgetDescriptors: Monthly, then API Usage.
    /// A missing API allocation must not hide an available subscription allocation (or vice versa).
    static func browserBudgets(_ body: Data, plan: String? = nil) throws -> ProviderUsage {
        let budget = try MistralBudget.decode(body)
        var lines: [MetricLine] = []
        if let api = budget.api_budget {
            lines.append(.percent("Monthly Usage", api.usage_percentage, resetsAt: api.reset))
        }
        if let subscription = budget.vibe_budget {
            lines.append(.percent("Subscription Usage", subscription.usage_percentage, resetsAt: subscription.reset))
        }
        return ProviderUsage(plan: plan, lines: lines, lineTitles: ["Monthly Usage": "API Usage"])
    }

    static func subscriptionPlan(_ body: Data) throws -> String {
        struct Subscription: Decodable { let plan_name: String }
        guard let plan = try? JSONDecoder().decode(Subscription.self, from: body).plan_name,
              !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.invalidResponse }
        return plan
    }

    static func map(_ body: Data) throws -> ProviderUsage {
        guard let response = try? JSONDecoder().decode(Response.self, from: body) else {
            throw ProviderError.invalidResponse
        }
        let limits = response.limits
        let currency = limits.currency.uppercased()
        guard Locale.commonISOCurrencyCodes.contains(currency) else { throw ProviderError.invalidResponse }
        let completion = limits.completion
        guard let used = completion.total_usage else {
            throw ProviderError.unavailable("Mistral has not reported total monthly usage for this organization.")
        }
        guard used.isFinite, used >= 0 else { throw ProviderError.invalidResponse }
        if let cap = completion.usage_limit, !cap.isFinite || cap < 0 { throw ProviderError.invalidResponse }

        let line: MetricLine
        if completion.no_monthly_limit != true, let cap = completion.usage_limit {
            line = .progress(label: "Monthly Usage", used: used, limit: cap, format: .currency(code: currency))
        } else {
            line = .values(label: "Monthly Usage", values: [MetricValue(number: used, kind: .dollars, currencyCode: currency)])
        }
        // This endpoint reports neither the subscription name nor a reset timestamp.
        return ProviderUsage(plan: nil, lines: [line])
    }

    private struct Response: Decodable {
        let limits: Limits
    }

    private struct Limits: Decodable {
        let currency: String
        let completion: Completion
    }

    private struct Completion: Decodable {
        let total_usage: Double?
        let usage_limit: Double?
        let no_monthly_limit: Bool?
        let monthly_limit_reached: Bool
    }
}
