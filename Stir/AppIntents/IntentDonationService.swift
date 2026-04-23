// IntentDonationService
//
// Wraps `Intent.donate()` calls with a 24h cooldown per intent so
// we don't spam Siri's suggestion engine on power users who solve
// nightly. Cooldown is tracked in SharedStorage (not UserDefaults)
// so reinstalls reset it cleanly.
//
// Step-7 prompt default: "don't donate if last donation was <24h ago".

import AppIntents
import Foundation
import OSLog

@MainActor
struct IntentDonationService {
    private let clock: () -> Date
    private let storage: UserDefaults

    init(
        clock: @escaping () -> Date = Date.init,
        suiteName: String = AppGroup.identifier,
    ) {
        self.clock = clock
        self.storage = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Donate `StartNewDinnerSolveIntent` after a successful solve.
    /// Respects the 24h cooldown; returns true if the donation
    /// actually fired (useful for tests).
    @discardableResult
    func donateStartNewDinnerSolveIfEligible() async -> Bool {
        await donateIfEligible(
            intent: StartNewDinnerSolveIntent(),
            key: "intentDonation.startSolve.lastAt",
        )
    }

    /// Donate `AddToGroceryIntent` after a successful grocery export.
    @discardableResult
    func donateAddToGroceryIfEligible() async -> Bool {
        await donateIfEligible(
            intent: AddToGroceryIntent(),
            key: "intentDonation.addGrocery.lastAt",
        )
    }

    // MARK: - Private

    private func donateIfEligible<I: AppIntent>(
        intent: I,
        key: String,
    ) async -> Bool {
        let now = clock()
        if let lastDonatedAt = storage.object(forKey: key) as? Date,
           now.timeIntervalSince(lastDonatedAt) < 24 * 3_600 {
            return false
        }
        do {
            try await intent.donate()
            storage.set(now, forKey: key)
            Logger.app.info("intent donated: \(String(describing: I.self), privacy: .public)")
            return true
        } catch {
            Logger.app.warning(
                "intent donate failed: \(error.localizedDescription, privacy: .public)",
            )
            return false
        }
    }
}
