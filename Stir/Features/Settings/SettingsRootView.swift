// SettingsRootView
//
// Settings shell per spec §6 — rebuilt 2026-04-28 onto the custom Stir
// design system. The pre-rebuild file rendered everything through
// SwiftUI's default `List`/`Form`, which inherited iOS's grey grouped
// background, default serif-less section headers, and SF Symbol
// multicolor renderings on `Label("…", systemImage:)` rows. The result
// drifted visibly from Tonight + Saved (same warm paper50 surface,
// New York display titles, ember-tinted glyph tiles in paper100 cards
// with ink100 dividers) and clipped the bottom of the scroll under
// the floating `StirCustomTabBar`.
//
// Visual grammar (mirrors mockup `14_settings.html`):
//   - paper50 screen background, principal-toolbar New York title
//     matching Saved's pattern.
//   - Each section: small UPPERCASE labelEyebrow ink500 header + a
//     paper100 card (`stirCard`) containing one or more rows.
//   - Rows: 32×32 ember100 tile with an ember600 glyph, title in
//     labelLg, optional bodySm subtitle, trailing chevron / value /
//     toggle. Multi-row cards use 1pt ink100 internal dividers.
//   - 64pt bottom padding to clear the −14pt-encroach `StirCustomTabBar`
//     (same pattern Tonight uses, see RootView §StirCustomTabBar).
//
// Plan & Billing keeps its state-machine surface (free / trial / active
// / grace / cancelled / expired) but renders through one unified
// `planBillingCard` instead of `List` Section header + footer + button
// rows. Notifications push, Household push, Sync status, About links,
// Build version, and the DEBUG-only Voice Diagnostics push are all
// preserved. Restore flow, paywall trigger plumbing, and all
// telemetry are unchanged.
//
// The trial-reminder card was removed 2026-04-28 — it duplicated the
// (now also removed) trial-reminder toggle in the Notifications page,
// and the two were wired to different stores so they could disagree.
// The `TrialReminderScheduler` and `Preferences.trialReminder` field
// are now dead code; removable in a follow-up cleanup.

import OSLog
import SwiftUI
import UIKit

struct SettingsRootView: View {
    @Environment(EntitlementService.self) private var entitlements
    @Environment(CloudKitAvailabilityStore.self) private var cloudKit
    @Environment(RootCoordinator.self) private var coordinator

    @State private var isRestoring = false
    @State private var restoreToast: StirToastPayload?

    var body: some View {
        // `@Bindable` wraps the @Observable coordinator so we can vend a
        // Binding to its `activeProComparison` slot below. The sheet
        // observation lives HERE rather than at RootView because:
        //   1. Settings is the only origin of pro-comparison presentation
        //      (Free "See Pro features" + Premium "Upgrade to Pro" rows),
        //      so the sheet only needs to be reachable from this surface.
        //   2. Stacking a `.sheet(item:)` adjacent to RootView's
        //      `.fullScreenCover(item: $activePaywallTrigger)` introduced
        //      a regression on iOS 26: when CookModeRoot's mirrored
        //      paywall fullScreenCover (`CookModeRoot.swift:287`) and
        //      RootView's paywall fullScreenCover both fired on a voice-
        //      quota tap, iOS reconciled the three-modifier stack by
        //      tearing down Cook Mode mid-presentation — the paywall
        //      flashed, then both dismissed, dropping the user on Tonight.
        //      Hosting the sheet on the Settings surface keeps RootView's
        //      modifier stack at two and avoids the conflict.
        //
        // The explicit `return` below is required because `body` now has
        // a declaration before the view expression — Swift's implicit-
        // return only kicks in for single-expression view bodies.
        @Bindable var coordinator = coordinator
        return ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                planBillingSection
                notificationsSection
                householdSection
                pantrySection
                syncSection
                helpSection
                aboutSection
                buildSection
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            // Match Tonight's clearance for the −14pt-encroach floating
            // tab bar. The bar's measured frame is shorter than its
            // visual extent, so the system-reserved bottom inset alone
            // leaves the last row clipped (the original-bug screenshot).
            .padding(.bottom, CGFloat.Stir.space7 + CGFloat.Stir.space4) // 64pt
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Principal item renders the screen title in the Stir
            // display serif, matching Saved (`SavedMealsView`). The
            // default `navigationTitle` chrome would fall back to SF
            // Pro and break the cross-tab visual rhythm.
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .stirToast($restoreToast)
        // SCA-13 Phase 1 — entry-point pantry coach mark. Anchors on
        // the "Manage pantry" row inside `pantrySection`. The in-list
        // walkthrough lives on PantryListView under a separate
        // `pantryInListTour` key (SCA-14) so each surface owns its own
        // replay loop.
        .coachMarks(
            key: .pantryManagement,
            steps: PantryCoachMarks.steps,
        )
        .sheet(item: $coordinator.activeProComparison) { entry in
            // SwiftUI invokes this content closure once per `item`
            // identity change (i.e., per presentation), not per
            // render — so a fresh `PaywallViewModel` is built exactly
            // once per sheet open. Subsequent re-renders of the
            // already-presented sheet reuse this VM via the binding.
            let vm = coordinator.makePaywallViewModel(trigger: entry.trigger)
            ProComparisonSheet(viewModel: vm)
                .task {
                    if case .idle = vm.state {
                        await vm.load()
                    }
                }
                .onDisappear {
                    coordinator.dismissProComparison()
                }
        }
    }

    // MARK: - Plan & Billing

    private var planBillingSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Plan & Billing")
            VStack(spacing: 0) {
                planHeader
                rowDivider
                planStateRows
                rowDivider
                restoreRow
            }
            .stirCard()
        }
    }

    private var planHeader: some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) { // 2pt — matches every other title→subtitle pair in this file
                Text(entitlements.tier.displayName)
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
                Text(entitlements.billingStateHelpText)
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textTertiary)
                    .multilineTextAlignment(.leading)
            }
            // Without `fixedSize`, a long `billingStateHelpText` (trial-
            // day-counter copy, cancellation-with-date copy) competing
            // with the trailing tier badge would ellipsize before
            // wrapping. Force vertical growth, never horizontal.
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: CGFloat.Stir.space2)
            // Free uses `.sparkles` (the project's Premium-upsell glyph,
            // muted to ink500 here to read as "you could be using more"
            // rather than "this is active"). Paid tiers get `.tierCrown`
            // — the same crown for both Premium and Pro because the
            // tier name (`Tier.displayName`) is the discriminator. The
            // dedicated `.tierCrown` semantic in `Icons.swift` keeps
            // this contextual use distinct from `.premium`/`.pro` which
            // are the upsell-tile feature glyphs (Design-System.md §6).
            tierBadge
                .font(.system(size: CGFloat.Stir.iconMd, weight: .semibold))
                .foregroundStyle(
                    entitlements.tier == .free
                        ? Color.Stir.textTertiary
                        : Color.Stir.ember600,
                )
        }
        .padding(.horizontal, CGFloat.Stir.space3Half) // 14pt
        .padding(.vertical, CGFloat.Stir.space3Half)
    }

    private var tierBadge: Image {
        entitlements.tier == .free ? Image.Stir.sparkles : Image.Stir.tierCrown
    }

    /// Plan-state surface — assembles up to two rows depending on tier:
    ///
    ///   * Premium subscribers in `.active` / `.trial` / `.cancelledActive`
    ///     get a Pro-upsell row as the primary CTA above the existing
    ///     admin row. `.cancelledActive` is included because cancellation
    ///     recovery shouldn't strand the user from Pro — they may want
    ///     to switch tier rather than un-cancel back into Premium.
    ///     Suppressed during `.grace` (fix payment first; Apple won't
    ///     allow tier-change with failed billing anyway) and the
    ///     defensive `.none` arm.
    ///   * Free users on the steady-state `.none` get the existing
    ///     "Upgrade to Premium" row PLUS a "See Pro features" secondary
    ///     row, so Pro isn't hidden two taps deep behind PaywallView's
    ///     "Compare plans" link. Suppressed on `.expired` so the
    ///     focused Resubscribe recovery copy is the only CTA.
    ///   * Pro users keep the existing single-row admin surface — Apple
    ///     handles tier downgrade via cross-grade in the manage-
    ///     subscriptions sheet.
    @ViewBuilder
    private var planStateRows: some View {
        let placement = Self.proUpsellPlacement(
            tier: entitlements.tier,
            billingState: entitlements.billingState,
        )
        if placement == .above {
            proRow(placement: .above)
            rowDivider
        }
        primaryPlanStateRow
        if placement == .below {
            rowDivider
            proRow(placement: .below)
        }
    }

    /// Where the Pro-upsell row sits relative to the primary admin row,
    /// or `.none` if it shouldn't render. Pure function on `(Tier,
    /// BillingState)` so the matrix is testable without spinning up the
    /// view. Exhaustive on both enums — adding a new tier or billing
    /// state forces an update at compile time.
    static func proUpsellPlacement(
        tier: Tier,
        billingState: BillingState,
    ) -> ProUpsellPlacement {
        switch (tier, billingState) {
        // Premium subscribers in healthy or recoverable states — Pro
        // upgrade is the call-to-action above admin chrome.
        case (.premium, .active),
             (.premium, .trial),
             (.premium, .cancelledActive):
            return .above
        // Free users on the steady-state — Pro discovery is secondary
        // to the primary "Upgrade to Premium" row.
        case (.free, .none),
             (.free, .active),
             (.free, .trial),
             (.free, .grace),
             (.free, .cancelledActive):
            return .below
        // Free + .expired: focused Resubscribe recovery only — no Pro
        // upsell competing with the win-back CTA.
        case (.free, .expired):
            return .none
        // Premium + .grace: payment must be fixed before tier-change.
        // Premium + .none: defensive (paid tier without billing state)
        // — neutral admin row only.
        // Premium + .expired: dead under server's effectiveTier()
        // sanitization (server demotes .expired tier → .free), but
        // listed for switch exhaustiveness.
        case (.premium, .grace),
             (.premium, .none),
             (.premium, .expired):
            return .none
        // Pro tier: never upsell upward (no higher tier). Apple handles
        // downgrade via cross-grade in the manage-subscriptions sheet.
        case (.pro, _):
            return .none
        }
    }

    enum ProUpsellPlacement: Equatable {
        /// Above the primary admin row (Premium subscribers).
        case above
        /// Below the primary admin row (Free users discovering Pro).
        case below
        /// No Pro upsell rendered.
        case none
    }

    /// Primary admin / state-recovery row — one of upgrade / manage /
    /// update payment / keep / resubscribe based on the (tier,
    /// billing_state) pair. Each arm has its own copy rather than
    /// threading conditionals through one shared row, so the strings
    /// stay greppable.
    ///
    /// Note: `entitlements.tier` is the SERVER-EFFECTIVE tier — Backend
    /// `_shared/entitlements.ts:effectiveTier()` demotes `.expired` and
    /// `.none` to `.free` before serializing, so any `(_, .expired)`
    /// arm will only see `tier == .free`. Match `(.free, .expired)`
    /// FIRST to catch the win-back recovery moment; ordering matters.
    @ViewBuilder
    private var primaryPlanStateRow: some View {
        switch (entitlements.tier, entitlements.billingState) {
        case (.free, .expired):
            // Win-back path. Server demoted a previously-paid sub to
            // `.free` while preserving `billing_state == .expired`,
            // so this arm is the reachable Resubscribe surface.
            settingsActionRow(
                icon: Image.Stir.sparkles,
                title: "Resubscribe",
                subtitle: "Your previous plan ended. Start again?",
                action: { coordinator.presentPaywall(.settingsUpgrade) },
            )
        case (.free, _):
            // Free user (any non-expired billing_state — `.none` is the
            // steady-state for free; the others can occur transiently
            // when an entitlement just downgraded).
            settingsActionRow(
                icon: Image.Stir.sparkles,
                title: "Upgrade to Premium",
                action: { coordinator.presentPaywall(.settingsUpgrade) },
            )
        case (.premium, .none), (.pro, .none):
            // Defensive — paid tier with billing_state == .none
            // shouldn't happen (the RevenueCat webhook fan-out is
            // supposed to set billing_state when tier flips paid). If
            // we ever land here, neither "Upgrade" nor "Manage" copy
            // is honest: the user IS on a paid tier, and there's no
            // verified sub for Apple to surface. Route to the Apple
            // page (source of truth) with neutral copy + log a
            // breadcrumb so the team sees this when it actually fires.
            settingsActionRow(
                icon: Image.Stir.manageAccount,
                title: "Manage your plan",
                subtitle: "We couldn't read your subscription state. Check it in your App Store account.",
                action: {
                    Logger.settings.warning(
                        "defensive paid+none arm rendered tier=\(entitlements.tier.rawValue, privacy: .public)",
                    )
                    // OSLog alone may not reach Sentry without the
                    // Sentry SDK's OSLog bridge — emit an explicit
                    // breadcrumb so this surfaces in dashboards. Fires
                    // only on the row tap (not on every render) to
                    // avoid breadcrumb-spam if the user lingers.
                    SentryReporter.shared.breadcrumb(
                        category: "billing.state",
                        message: "defensive paid+none arm rendered",
                        data: ["tier": entitlements.tier.rawValue],
                    )
                    openManageSubscriptions()
                },
            )
        case (_, .grace):
            settingsActionRow(
                icon: Image.Stir.creditCard,
                title: "Update payment method",
                subtitle: "Apple couldn't renew your subscription. Update billing to keep \(entitlements.tier.displayName) features.",
                accent: .amber,
                action: { openManageSubscriptions() },
            )
        case (_, .cancelledActive):
            settingsActionRow(
                icon: Image.Stir.uncancel,
                title: "Keep \(entitlements.tier.displayName)",
                subtitle: cancelledSubtitle,
                action: { openManageSubscriptions() },
            )
        case (_, .trial), (_, .active):
            settingsActionRow(
                icon: Image.Stir.manageAccount,
                title: "Manage subscription",
                action: { openManageSubscriptions() },
            )
        case (_, .expired):
            // Unreachable on the wire (server demotes `.expired` tier to
            // `.free`, caught by `(.free, .expired)` above). Listed only
            // for switch exhaustiveness — if the wire contract ever
            // changes (`raw_tier` exposed, etc.), this arm activates.
            settingsActionRow(
                icon: Image.Stir.sparkles,
                title: "Resubscribe",
                subtitle: "Your \(entitlements.tier.displayName) plan ended. Start again?",
                action: { coordinator.presentPaywall(.settingsUpgrade) },
            )
        }
    }

    /// Pro-upgrade / Pro-discovery row — one helper, two placements.
    /// The Pro CTA is the same destination (`ProComparisonSheet`); the
    /// only difference is framing — "Upgrade to Pro" for paying users
    /// who already understand value, "See Pro features" for free users
    /// where discovery is the goal. Strings stay at the call sites
    /// (here) so they're greppable; the shared shape avoids the
    /// 22-line drift the two former row builders had.
    private func proRow(placement: ProUpsellPlacement) -> some View {
        let title: String
        let subtitle: String
        switch placement {
        case .above:
            title = "Upgrade to Pro"
            subtitle = "Voice for every dinner, multi-image scan, \(Tier.pro.displayPantryCap) pantry items."
        case .below:
            title = "See Pro features"
            subtitle = "Compare Premium and Pro side by side."
        case .none:
            // Should never render — the call sites are gated on
            // `placement != .none`. EmptyView keeps the function total.
            title = ""
            subtitle = ""
        }
        return settingsActionRow(
            icon: Image.Stir.pro,
            title: title,
            subtitle: subtitle,
            action: { presentProComparison() },
        )
    }

    private var cancelledSubtitle: String? {
        // Mirror `EntitlementService+Display.swift`'s cancelledActive
        // help-text fallback so the same nil-`expiresAt` state doesn't
        // produce divergent header (with fallback string) vs row
        // (with collapsed/missing subtitle) treatments.
        let tierName = entitlements.tier.displayName
        guard let expires = entitlements.expiresAt else {
            return "Cancels at end of current period. You still have \(tierName) until then."
        }
        let date = expires.formatted(date: .abbreviated, time: .omitted)
        return "Cancels \(date). You still have \(tierName) until then."
    }

    /// Present the Premium-vs-Pro comparison sheet via the coordinator.
    /// Trigger is `.settingsProComparison` — distinct from
    /// `.settingsUpgrade` (which routes to the full PaywallView) so
    /// PostHog dashboards filtering on `paywall_viewed.trigger` keep
    /// the Premium-trial funnel and the Pro-comparison funnel separate.
    /// `current_tier` on the event further discriminates Free→Pro
    /// discovery from Premium→Pro upgrade. Spec §15 documents both
    /// trigger values.
    ///
    /// Idempotent — the coordinator no-ops if a comparison sheet (or
    /// the full paywall) is already presenting, so a fast double-tap
    /// can't duplicate-emit `paywall_viewed`.
    private func presentProComparison() {
        coordinator.presentProComparison(trigger: .settingsProComparison)
    }

    private var restoreRow: some View {
        Button {
            Task { await restore() }
        } label: {
            HStack(alignment: .center, spacing: CGFloat.Stir.space3) {
                iconTile(Image.Stir.restore)
                Text("Restore purchases")
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.ember600)
                Spacer(minLength: CGFloat.Stir.space2)
                if isRestoring {
                    ProgressView()
                        .tint(Color.Stir.ember600)
                } else {
                    Image.Stir.disclosure
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                        .foregroundStyle(Color.Stir.ink300)
                }
            }
            .padding(.horizontal, CGFloat.Stir.space3Half)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRestoring)
        .accessibilityLabel("Restore purchases")
    }

    // MARK: - Help

    /// Help section. Pushes into `TutorialReplayView` for per-tutorial
    /// replay (SCA-17 W9). With 9 distinct tours shipped, the prior
    /// all-or-nothing reset was high-friction enough that users who
    /// wanted to re-see one specific tour wouldn't bother. The
    /// per-key surface preserves the bulk-reset path as a button
    /// inside the sub-screen for the new-user-experience case.
    private var helpSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Help")
            NavigationLink {
                TutorialReplayView()
            } label: {
                settingsRowContent(
                    icon: Image.Stir.info,
                    title: "Replay tutorials",
                    subtitle: "Pick a tour to walk through again.",
                    trailing: .chevron,
                )
                .stirCard()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            // Single-row section — eyebrow added for visual rhythm
            // consistency with Household / Sync / About / Debug. The
            // duplication ("NOTIFICATIONS" eyebrow over a row also
            // titled "Notifications") is acceptable: the eyebrow is
            // 11pt UPPERCASE tracked tertiary text, the row title is
            // 15pt ink900 — they read as group + member, not echo.
            sectionEyebrow("Notifications")
            NavigationLink {
                NotificationPrefsView()
            } label: {
                settingsRowContent(
                    icon: Image.Stir.notifications,
                    title: "Notifications",
                    trailing: .chevron,
                )
                .stirCard()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Household

    private var householdSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Household")
            NavigationLink {
                HouseholdPreferencesView()
            } label: {
                settingsRowContent(
                    icon: Image.Stir.profile,
                    title: "Household preferences",
                    trailing: .chevron,
                )
                .stirCard()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pantry

    /// Pantry section — entry to `PantryListView` (Settings →
    /// Manage pantry). Tagged with
    /// `.coachMarkAnchor(.settingsManagePantryRow)` so the entry-
    /// point coach mark in `PantryCoachMarks.steps` can spotlight
    /// this row the first time the user reaches Settings post-launch.
    ///
    /// Per ADR-0028, pantry is a low-frequency surface (users update
    /// it after weekly scans, or to spot-check the grocery diff) so
    /// it lives under Settings rather than as a top-level tab.
    private var pantrySection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Pantry")
            NavigationLink {
                PantryListView(coordinator: coordinator)
            } label: {
                settingsRowContent(
                    icon: Image.Stir.pantry,
                    title: "Manage pantry",
                    subtitle: "View, edit, or remove ingredients Stir remembers.",
                    trailing: .chevron,
                )
                .stirCard()
            }
            .buttonStyle(.plain)
            .coachMarkAnchor(.settingsManagePantryRow)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Sync")
            HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
                // Status dot in lieu of an icon tile — sage when syncing,
                // amber when iCloud unavailable. Both pair with the
                // status copy so screen readers + sighted users get
                // the same signal (color-independence per §3.3).
                //
                // Wrapped in a labelLg-line-height (20pt) container so
                // the dot stays vertically centered on the title's cap
                // height under Dynamic Type — a literal `padding(.top:)`
                // would drift the dot off-baseline as the title scales.
                Circle()
                    .fill(cloudKit.isAvailable ? Color.Stir.sage600 : Color.Stir.amber600)
                    .frame(width: 10, height: 10) // dot, intentionally smaller than iconSm
                    .frame(width: Self.iconTileSize, height: 20, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                    Text(cloudKit.isAvailable ? "iCloud synced" : "Local only")
                        .stirFont(.labelLg)
                        .foregroundStyle(Color.Stir.textPrimary)
                    Text(
                        cloudKit.isAvailable
                            ? "Your kitchen syncs across your devices."
                            : "iCloud Sync isn't available. Stir will work on this device only for now.",
                    )
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textTertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, CGFloat.Stir.space3Half)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .stirCard()
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("About")
            VStack(spacing: 0) {
                aboutLink("Privacy Policy", url: "https://getstir.app/privacy")
                rowDivider
                aboutLink("Terms of Service", url: "https://getstir.app/terms")
                rowDivider
                // EULA points at Apple's standard licensed-application
                // terms (no custom Stir EULA; ToS covers Stir-specific
                // usage). Symmetric with the paywall's three-link
                // disclosure footer.
                aboutLink(
                    "End User License Agreement",
                    url: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/",
                )
                rowDivider
                aboutLink("Support", url: "mailto:support@getstir.app")
            }
            .stirCard()
        }
    }

    /// About rows are plain ember links per mockup 14 — no trailing
    /// glyph. The earlier draft added an `arrow.up.right` chevron, but
    /// it wasn't in `Icons.swift`'s semantic map (Design-System.md §6
    /// requires additions to Icons.swift + the §6 table in the same
    /// PR), and the mockup's About rows are deliberately glyph-free.
    private func aboutLink(_ title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) {
                UIApplication.shared.open(u)
            }
        } label: {
            Text(title)
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.ember600)
                .padding(.horizontal, CGFloat.Stir.space3Half)
                .padding(.vertical, CGFloat.Stir.space3Half)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Build version

    private var buildSection: some View {
        HStack {
            Text("Build")
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.textSecondary)
            Spacer()
            Text(Self.versionDisplay)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textTertiary)
        }
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3Half)
        .stirCard()
    }

    /// Bundle short-version + build number, resolved once at type-load
    /// rather than on every `body` re-eval (entitlement state changes
    /// alone re-evaluate this view; the bundle keys are immutable).
    private static let versionDisplay: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }()

    // MARK: - DS primitives

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text)
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
            .padding(.horizontal, CGFloat.Stir.space1)
    }

    /// Width + height of the row's leading icon tile (and the sync-row's
    /// status-dot column, which aligns to the same gutter). Hoisted to a
    /// single constant so divider insets, tile frames, and the sync-dot
    /// column never drift apart on a future tile-size adjustment.
    private static let iconTileSize: CGFloat = 32

    private var rowDivider: some View {
        // Internal hairline for multi-row cards. Inset by the icon-tile
        // column so the divider visually starts at the title baseline,
        // matching mockup 14 grouped-list rows.
        Rectangle()
            .fill(Color.Stir.divider)
            .frame(height: 1)
            .padding(.leading, CGFloat.Stir.space3Half + Self.iconTileSize + CGFloat.Stir.space3)
    }

    /// 32×32 tile with an ember600 glyph on an ember100 fill — the
    /// dominant settings-row glyph treatment from mockup 14. Optional
    /// accent flips the tile to amber for the grace-period state.
    private enum RowAccent { case ember, amber }

    private func iconTile(_ icon: Image, accent: RowAccent = .ember) -> some View {
        let fill: Color = accent == .ember ? Color.Stir.ember100 : Color.Stir.amber100
        let glyph: Color = accent == .ember ? Color.Stir.ember600 : Color.Stir.amber600
        return ZStack {
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusSm, style: .continuous)
                .fill(fill)
            icon
                .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                .foregroundStyle(glyph)
        }
        .frame(width: Self.iconTileSize, height: Self.iconTileSize)
    }

    private enum TrailingAffordance {
        case chevron
        case none
    }

    /// Static row content (icon + title + optional subtitle + trailing).
    /// Used when the row's interactivity is owned by an outer
    /// `NavigationLink` or `Button`.
    private func settingsRowContent(
        icon: Image,
        title: String,
        subtitle: String? = nil,
        trailing: TrailingAffordance = .none,
    ) -> some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: CGFloat.Stir.space3) {
            iconTile(icon)
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                Text(title)
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.textTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: CGFloat.Stir.space2)
            switch trailing {
            case .chevron:
                Image.Stir.disclosure
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink300)
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3Half)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Action row — the settings-row equivalent of an inline button.
    /// Title + icon render in ember (it's a CTA, not navigation), so
    /// it visually matches the original `.foregroundStyle(ember600)`
    /// labels but in the rebuilt grouped-card grammar.
    private func settingsActionRow(
        icon: Image,
        title: String,
        subtitle: String? = nil,
        accent: RowAccent = .ember,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: CGFloat.Stir.space3) {
                iconTile(icon, accent: accent)
                VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                    Text(title)
                        .stirFont(.labelLg)
                        .foregroundStyle(accent == .amber ? Color.Stir.textPrimary : Color.Stir.ember600)
                    if let subtitle {
                        Text(subtitle)
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.textTertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: CGFloat.Stir.space2)
                Image.Stir.disclosure
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink300)
            }
            .padding(.horizontal, CGFloat.Stir.space3Half)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .modifier(OptionalAccessibilityHint(hint: subtitle))
    }

    // MARK: - Helpers

    private func openManageSubscriptions() {
        // Apple-provided deep link. Fails silently on simulator w/o App Store.
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            UIApplication.shared.open(url)
        }
    }

    @MainActor
    private func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }

        // Build a VM only to reuse `restore()` telemetry + refresh wiring.
        // The .settingsUpgrade trigger is used as the viewed context but
        // no paywall_viewed event fires since we don't call load().
        let vm = coordinator.makePaywallViewModel(trigger: .settingsUpgrade)
        let outcome = await vm.restore(origin: .settings)
        let payload: StirToastPayload
        switch outcome {
        case .restored:
            payload = StirToastPayload(id: UUID(), message: "Restored. Welcome back.", kind: .success)
        case .nothingToRestore:
            payload = StirToastPayload(id: UUID(), message: "No active purchase to restore.", kind: .info)
        case .failed(let e):
            payload = StirToastPayload(id: UUID(), message: "Couldn't restore: \(e.userFacingMessage)", kind: .failed)
        }

        // Race guard: a second tap within 2.5s would cause the first
        // task's clear to dismiss the second toast prematurely.
        // StirToastPayload carries a UUID id — only clear if the
        // currently-presented toast is still the one this task set.
        let myID = payload.id
        restoreToast = payload
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if restoreToast?.id == myID {
            restoreToast = nil
        }
    }

}

// MARK: - Display helpers on typed enums

extension Tier {
    var displayName: String {
        switch self {
        case .free:    return "Free"
        case .premium: return "Premium"
        case .pro:     return "Pro"
        }
    }

    /// Remembered-pantry-item cap, formatted with thousands separator
    /// for marketing copy. Source of truth: spec §entitlements / CLAUDE.md
    /// tier table. Free=25, Premium=250, Pro=1,000. Lifted out of inline
    /// strings so a future cap revision doesn't leave stale "1,000" /
    /// "250" literals scattered across paywall + Settings copy.
    var displayPantryCap: String {
        switch self {
        case .free:    return "25"
        case .premium: return "250"
        case .pro:     return "1,000"
        }
    }
}

// `billingStateHelpText` lives in `Core/Services/EntitlementService+Display.swift`
// per the step-5 review (SRP: EntitlementService extensions belong with the
// service, not in feature files).

// MARK: - Accessibility helpers

/// Applies `.accessibilityHint(_:)` only when a hint is provided.
/// `accessibilityHint("")` is benign but pollutes the accessibility tree
/// with empty hints; this keeps the tree clean for VoiceOver.
private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint, !hint.isEmpty {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}
