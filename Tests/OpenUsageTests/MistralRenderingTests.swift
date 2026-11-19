import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class MistralRenderingTests: XCTestCase {
    func testBothUsageRowsRenderInTheApprovedOrder() throws {
        let runtime = AccountProviderRuntime(account: Account(kind: .mistral, label: "Personal"), vault: InMemoryCredentialVault())
        let usage = try MistralUsageMapper.browserBudgets(Data(MistralBrowserLoginTests.budget.utf8), plan: "INDIVIDUAL")
        let store = WidgetDataStore.forTesting([runtime], defaults: isolatedDefaults())
        var snapshot = ProviderSnapshot(provider: runtime.provider, plan: usage.plan, lines: usage.lines)
        snapshot.lineTitles = usage.lineTitles
        store.snapshots[runtime.provider.id] = snapshot
        let lines = runtime.widgetDescriptors.map { DashboardLine(descriptor: $0, data: store.data(for: $0)) }
        let account = DashboardAccount(provider: runtime.provider, lines: lines)
        let family = DashboardFamily(id: account.id, provider: runtime.provider, accounts: [account])

        for appearance in [ColorScheme.light, .dark] {
            let png = try XCTUnwrap(ShareCardRenderer.png(for: ShareCardView(
                family: family, plans: [account.id: "INDIVIDUAL"], appearance: appearance
            )))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            let text = try recognizedLines(in: XCTUnwrap(bitmap.cgImage)).joined(separator: "\n").lowercased()
            let subscription = try XCTUnwrap(text.range(of: "monthly"), text)
            // Vision can read the short API acronym as Cyrillic; Usage uniquely identifies its row.
            // The runtime test separately asserts both complete titles exactly.
            let api = try XCTUnwrap(text.range(of: "usage"), text)
            XCTAssertLessThan(subscription.lowerBound, api.lowerBound, "The Monthly row must render before the API row")
            XCTAssertTrue(text.contains("mistral"), text)
            // Optional, explicit fixture-only exports for PR screenshots. No real account data.
            if let directory = ProcessInfo.processInfo.environment["OPENUSAGE_MISTRAL_SCREENSHOT_DIR"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("mistral-\(appearance == .light ? "light" : "dark").png"))
            }
        }
    }
}
