import Foundation

/// Public billing budget response used by browser-issued workspace keys.
/// Percentages come directly from Mistral; initial budgets are never converted into spend.
struct MistralBudget: Decodable, Sendable {
    let api_budget: Detail?
    let vibe_budget: Detail?

    struct Detail: Decodable, Sendable {
        let usage_percentage: Double
        let initial_budget: Double
        let reset_at: String?
        let payg_enabled: Bool?

        var reset: Date? { reset_at.flatMap(OpenUsageISO8601.date(from:)) }

        func validate() throws {
            guard usage_percentage.isFinite, usage_percentage >= 0,
                  initial_budget.isFinite, initial_budget >= 0 else { throw ProviderError.invalidResponse }
            if let reset_at, OpenUsageISO8601.date(from: reset_at) == nil { throw ProviderError.invalidResponse }
        }
    }

    static func decode(_ body: Data) throws -> Self {
        guard let budget = try? JSONDecoder().decode(Self.self, from: body) else { throw ProviderError.invalidResponse }
        try budget.api_budget?.validate()
        try budget.vibe_budget?.validate()
        guard budget.api_budget != nil || budget.vibe_budget != nil else {
            throw ProviderError.unavailable("Mistral has not reported any usage budgets for this workspace.")
        }
        return budget
    }
}
