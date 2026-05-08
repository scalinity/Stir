// RepeatCandidateCard
//
// SCA-66 — "Save this as a one-tap weeknight meal?" prompt shown
// after the user rates a meal ≥ 4 stars on a recipe they haven't
// already favorited. Spec §8 row 947.
//
// Presentation: `.sheet` (not `.fullScreenCover`) so the user keeps
// context of whatever they're returning to (Tonight Home, in
// practice). Mid presentationDetent so the prompt feels like a card,
// not a takeover.
//
// Tier behavior:
//   * Premium+: "Yes" → SolveRepository.setFavorite(true, on:) +
//     dismiss + analytics.favorite_saved with source=post_meal_feedback
//   * Free: "Yes" → dismiss + present PaywallTrigger.savedFavoritesGate
//     via the host coordinator. The paywall's own conversion event
//     fires there.
//
// "Don't ask again" suppresses the prompt for this recipe lifetime
// via RepeatCandidateSuppressionStore.

import OSLog
import SwiftUI

/// Identifiable wrapper around a recipePlanId so CookModeRoot can use
/// `.sheet(item: $repeatCandidateContext)`. Lives at file scope so
/// any future host (Saved, Tonight) can also present this card with
/// the same Identifiable handle.
struct RepeatCandidateContext: Identifiable, Equatable {
    let id: UUID
}

struct RepeatCandidateCard: View {
    /// The recipePlan to favorite. The host (CookModeRoot) holds the
    /// RecipePlan reference and presents this view when the
    /// PostSubmitIntent decision routes here.
    let recipePlan: RecipePlan
    let entitlements: EntitlementService
    let solveRepository: SolveRepository
    let analytics: PostHogClient
    let suppressionStore: RepeatCandidateSuppressionStore
    let presentPaywall: (PaywallTrigger) -> Void
    let onDismiss: () -> Void

    /// SCA-111 fix: surfaces persistence-failure on the Premium "Save
    /// as a favorite" path. `SolveRepository.setFavorite` returns a
    /// Bool; on Core Data save failure the sheet stayed up as if
    /// successful AND `favorite_saved` was emitted regardless,
    /// corrupting the conversion-funnel anchor. Now: on `false`, set
    /// this banner, do NOT emit telemetry, do NOT dismiss the sheet
    /// so the user can retry or cancel deliberately.
    @State private var saveError: String?

    init(
        recipePlan: RecipePlan,
        entitlements: EntitlementService,
        solveRepository: SolveRepository = SolveRepository(),
        analytics: PostHogClient = .shared,
        suppressionStore: RepeatCandidateSuppressionStore = .shared,
        presentPaywall: @escaping (PaywallTrigger) -> Void,
        onDismiss: @escaping () -> Void,
    ) {
        self.recipePlan = recipePlan
        self.entitlements = entitlements
        self.solveRepository = solveRepository
        self.analytics = analytics
        self.suppressionStore = suppressionStore
        self.presentPaywall = presentPaywall
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                Text("Save this for next time?")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.ink900)
                Text(promptBody)
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink700)
            }
            if let saveError {
                errorBanner(saveError)
            }
            VStack(spacing: CGFloat.Stir.space2) {
                PrimaryButton(title: yesButtonTitle, action: handleYes)
                SecondaryButton(title: "Not for this one", action: handleNotForThisOne)
                TextButton(title: "Don't ask again", action: handleDontAskAgain)
            }
        }
        .padding(CGFloat.Stir.screenMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Stir.paper50)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            analytics.capture(.repeatCandidateCardShown, properties: [
                "recipe_plan_id": recipePlan.id?.uuidString ?? "",
                "tier": entitlements.effectiveTier.rawValue,
            ])
        }
    }

    // MARK: - Copy

    private var promptBody: String {
        let title = recipePlan.title ?? "this meal"
        return "You loved \(title). Save it as a one-tap weeknight option for later?"
    }

    private var yesButtonTitle: String {
        switch entitlements.effectiveTier {
        case .premium, .pro: return "Save as a favorite"
        case .free:          return "See plans to save favorites"
        }
    }

    // MARK: - Actions

    private func handleYes() {
        let tier = entitlements.effectiveTier
        switch tier {
        case .premium, .pro:
            // SCA-111 fix: setFavorite returns Bool indicating
            // persistence success/failure (rolls back the context on
            // Core Data save error per its doc). Pre-fix dropped the
            // return on the floor: on disk-full / corruption / validation
            // failures, the sheet dismissed as if successful AND
            // favorite_saved fired anyway, corrupting the
            // conversion-funnel anchor. Now: branch on the return —
            // only emit telemetry + dismiss on true. On false, surface
            // the error in-card and keep the sheet up so the user can
            // retry or cancel.
            let saved = solveRepository.setFavorite(true, on: recipePlan)
            if saved {
                // SCA-66: extend favorite_saved with `source` for funnel
                // analysis. Spec §15 favorite_saved property table
                // includes `source ∈ {tonight, post_meal_feedback,
                // saved_replay}` per audit ticket A3.
                analytics.capture(.favoriteSaved, properties: [
                    "recipe_origin": recipePlan.origin ?? "ai",
                    "source": "post_meal_feedback",
                ])
                onDismiss()
            } else {
                // SolveRepository.setFavorite already logged the
                // underlying NSError + rolled back the context (per its
                // doc-comment); Logger.coreData routes through Sentry's
                // breadcrumb integration. Surface the banner so the
                // user sees the failure instead of getting silently
                // dismissed.
                Logger.coreData.warning(
                    "RepeatCandidateCard setFavorite returned false — keeping sheet up",
                )
                saveError = "We couldn't save that. Try again, or pick another option."
            }
        case .free:
            analytics.capture(.repeatCandidateCardDismissed, properties: [
                "recipe_plan_id": recipePlan.id?.uuidString ?? "",
                "outcome": "paywall_routed",
            ])
            onDismiss()
            // Route to paywall AFTER dismiss so iOS doesn't try to
            // stack a fullScreenCover behind this sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                presentPaywall(.savedFavoritesGate)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.Stir.crimson600)
                .accessibilityHidden(true)
            Text(message)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.crimson600)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3)
        .stirCard(
            fill: Color.Stir.crimson100,
            borderColor: Color.Stir.crimson600.opacity(0.3),
        )
    }

    private func handleNotForThisOne() {
        analytics.capture(.repeatCandidateCardDismissed, properties: [
            "recipe_plan_id": recipePlan.id?.uuidString ?? "",
            "outcome": "deferred",
        ])
        onDismiss()
    }

    private func handleDontAskAgain() {
        if let id = recipePlan.id {
            suppressionStore.suppress(recipePlanId: id)
        }
        analytics.capture(.repeatCandidateCardDismissed, properties: [
            "recipe_plan_id": recipePlan.id?.uuidString ?? "",
            "outcome": "suppressed",
        ])
        onDismiss()
    }
}
