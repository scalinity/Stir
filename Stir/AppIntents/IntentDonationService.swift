// IntentDonationService
//
// Wraps `Intent.donate()` calls with a 24h cooldown per intent so
// we don't spam Siri's suggestion engine on power users who solve
// nightly. Cooldown is tracked in the App Group UserDefaults (same
// suite SharedStorage reads) so a reinstall clears it and widget /
// share-ext / main-app observers all see the same timestamp.
//
// Step-7 prompt default: "don't donate if last donation was <24h ago".
//
// Suite-fallback posture: if the App Group suite isn't reachable
// (ENTITLEMENT bug only — production builds always have it), we log
// at error severity and no-op the donation. Falling through to
// UserDefaults.standard would let the cooldown read from local-only
// state, diverging from the rest of SharedStorage and hiding the
// misconfiguration (S1).

import AppIntents
import Foundation
import OSLog

@MainActor
struct IntentDonationService {
    private let clock: () -> Date
    private let storage: UserDefaults?

    init(
        clock: @escaping () -> Date = Date.init,
        suiteName: String = AppGroup.identifier,
    ) {
        self.clock = clock
        self.storage = UserDefaults(suiteName: suiteName)
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

    /// Static so tests + callers can reuse the same hardcoded window
    /// without reaching into an instance. 24 hours in seconds.
    private static let cooldownSeconds: TimeInterval = 24 * 3_600

    private func donateIfEligible<I: AppIntent>(
        intent: I,
        key: String,
    ) async -> Bool {
        guard let storage else {
            Logger.app.error(
                "IntentDonationService: App Group suite missing — donation skipped. Check entitlement.",
            )
            return false
        }
        let now = clock()
        if let lastDonatedAt = storage.object(forKey: key) as? Date,
           now.timeIntervalSince(lastDonatedAt) < Self.cooldownSeconds {
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
