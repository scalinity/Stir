// TonightHomeView
//
// Tonight Home — Stir's default control center (Spec §6 + mockup 03).
//
// Step 9 visual rebuild (2026-04-25):
//   - Reduced to the strict reference: greeting + bookmark jump button
//     in the header, optional resumable-cooking banner, and either a
//     hero "Tonight's pick" card (when the household has a completed
//     solve) or the first-use empty state.
//   - The previous in-Tonight surfaces — Scan / Import / Cook Saved
//     primary actions, Recent meals list, "Type it in" tile, the
//     top-trailing Settings push — were moved out: Saved + Settings
//     became their own tabs in `StirTabRoot`; Scan retains its first-
//     use entry plus the deep-link path; Import is reachable through
//     the share extension and (future) Saved tab actions.
//   - The drift note in the prior file disclaimed mockup 03's hero
//     pattern as "needs a 'last solve' entity that doesn't exist".
//     `SolveRepository.latestTonightPick(for:)` IS that entity now —
//     the mockup pattern is finally backed by a real query.
//
// Hero card visual grammar (mirrors mockup 03 § Default state):
//   - 20pt-radius card (Tonight-specific accent radius; not in the
//     token table — kept as a one-off justified literal here so the
//     mockup-to-iOS provenance stays auditable. Promote to a token
//     if a second screen wants the same value.)
//   - paper.200 plate pedestal up top with `HIGH MATCH` badge (sage)
//     top-left and `SOLVED N MIN AGO` eyebrow top-right
//   - SwiftUI-rendered `StirPlate(.hero)` — illustrated, not a photo
//     (per Spec §13: "photos of yet-to-be-cooked meals are always a
//     lie")
//   - paper.100 body with TONIGHT'S PICK (ember eyebrow), serif title,
//     time/servings/pan-count meta, sage-tinted diet chips, ember
//     `Start cooking →` PrimaryButton

import OSLog
import SwiftUI

struct TonightHomeView: View {
    let coordinator: RootCoordinator

    @Environment(EntitlementService.self) private var entitlements
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Scales the 36pt hero camera glyph inside the 80pt empty-state
    /// tile with Dynamic Type. Review finding W-F W25 (FD1).
    @ScaledMetric(relativeTo: .largeTitle) private var emptyStateCameraSize: CGFloat = 36

    @State private var toastMessage: String?
    @State private var resumableSession: CookingSession?
    @State private var tonightPick: SolveRepository.TonightPick?
    @State private var useSoonCandidate: UseSoonCandidate?
    @State private var widgetNudgeVisible = false
    @State private var activeModal: ActiveModal?
    // SCA-251 (W3 from /review-5): widget guide state lifted out of
    // ActiveModal. The scan cover and the widget setup guide are
    // semantically different presentations (camera fullScreen vs
    // instructional NavigationStack sheet) and were sharing a slot
    // through `tonightCoverHost`'s scanCoverContent switch. Side
    // effects of the conflation: (a) `.onChange(of: activeModal)`
    // ran `refreshState()` after dismissing the instructional sheet
    // (wasted Core Data fetches); (b) scanCoverContent grew a switch
    // case unrelated to scan flows. Now: separate `@State` flag,
    // mounted via `.sheet(isPresented:)`.
    @State private var widgetGuidePresented = false

    enum ActiveModal: String, Identifiable {
        case scan
        var id: String { rawValue }
    }

    struct UseSoonCandidate: Equatable {
        let id: UUID
        let displayName: String
        let expiresAt: Date

        // SCA-267 (S1 from /review-5): collapsed the static + instance
        // overloads into one instance method. The static form was a
        // vestige of an earlier draft; only the instance form was
        // called externally (UseSoonCard.body), and no test referenced
        // the static directly. Single name, single body, no shadowing.
        //
        // SCA-269 (S3 from /review-5): day-boundary computation now uses
        // `Calendar.dateComponents([.day], from: now, to: expiresAt)`
        // to avoid the DST off-by-one that `Int(remaining / 86_400)`
        // produces across daylight-savings transitions. Hour-bucket
        // math stays on raw seconds — sub-day, no DST surface.
        func subtitle(now: Date = Date()) -> String {
            let remaining = expiresAt.timeIntervalSince(now)
            guard remaining > 0 else { return "Expires soon" }
            if remaining < 86_400 {
                let hours = max(1, Int(ceil(remaining / 3600)))
                return "Expires in \(hours)h"
            }
            let days = Calendar.current
                .dateComponents([.day], from: now, to: expiresAt).day ?? 1
            return "Expires in \(max(1, days))d"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                greetingHeader
                resumableBanner
                mainContent
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space2)
            // Generous bottom padding so the last row (Rescan / Solve
            // again secondary tiles) clears the floating tab bar with
            // headroom even at max scroll. Earlier 24pt was just barely
            // sufficient when the bar used a positive bottom inset, but
            // the bar's current −12pt encroach into the home-indicator
            // strip means the safe-area-reserved height is smaller than
            // its visual extent — the ScrollView reserves the smaller
            // measurement, leaving the visual fill to clip the bottom
            // of scroll content. 64pt fully clears it.
            .padding(.bottom, CGFloat.Stir.space7 + CGFloat.Stir.space4)  // 64pt
        }
        .background(Color.Stir.paper50)
        .overlay(alignment: .top) { toastOverlay }
        .onChange(of: coordinator.pendingDeepLinkScan) { _, new in
            guard new != nil, activeModal == nil else { return }
            activeModal = .scan
            coordinator.clearDeepLinkScan()
        }
        // S18 from /review-5 (parent SCA-243): pendingUseSoonPrefill
        // onChange has a narrow race with `.task { await refreshState() }`
        // on cold-launch deep-links. If a use-soon notification tap
        // wakes the app and onChange fires before `refreshState()` has
        // populated `useSoonCandidate`, `handleUseSoonPrefill`'s no-ID
        // branch reads a nil fallback and toasts "no longer in your
        // pantry" even when an eligible ingredient exists. Bounded
        // failure mode:
        //   - Pantry-ID branch (notification with use_first=<uuid>):
        //     unaffected — fetches household-scoped via
        //     pantryItemRepository.fetch(id:for:); independent of
        //     useSoonCandidate. SCA-259 (W11) tightened that path so
        //     a stale ID also produces the toast rather than a
        //     wrong-row substitution.
        //   - No-ID branch (older notifications, future generic
        //     "open with displayed candidate"): reads
        //     useSoonCandidate?.displayName, may be nil during the
        //     pre-refreshState window. Toast on miss is the right
        //     UX — the user retries by foreground-relaunching.
        // The race is non-deterministic but always fail-soft (toast,
        // never wrong-row). Documenting here rather than `await`-ing
        // refreshState synchronously because (a) the toast is the
        // correct failure mode and (b) blocking the onChange handler
        // on a Core Data refresh would stall the SwiftUI render
        // pass for measurably longer than the cold-launch is willing
        // to wait.
        .onChange(of: coordinator.pendingUseSoonPrefill) { _, entry in
            guard let entry else { return }
            handleUseSoonPrefill(entry)
            coordinator.clearUseSoonPrefill()
        }
        // When the scan cover dismisses (activeModal flips back to nil
        // after being .scan), refresh state so a new completed solve
        // surfaces as the hero card on the same render. TabView keeps
        // Tonight's view tree alive across tab selections, so `.task`
        // only runs once at first mount — relying on it for refresh
        // would leave Tonight on a stale (or empty) state after a
        // user scans → solves → dismisses without starting Cook Mode.
        .onChange(of: activeModal) { old, new in
            if old != nil && new == nil {
                Task { await refreshState() }
            }
        }
        // SCA-94: the four .fullScreenCover modifiers are applied via
        // `tonightCoverHost(...)` (TonightCoverHost.swift) rather than
        // chained directly on body. Inline 4-deep `.fullScreenCover` +
        // `Binding(get:set:)` ladders pushed body past SwiftUI's
        // typechecker reasonable-time threshold; the extension hides
        // the chain behind a single opaque `some View` so adding new
        // body modifiers (use-soon card SCA-86, widget-nudge SCA-87)
        // has clear headroom again.
        .tonightCoverHost(
            activeModal: $activeModal,
            coordinator: coordinator,
            scanCover: scanCoverContent,
            cookLaunchCover: cookLaunchCoverContent,
            solveAgainCover: solveAgainCoverContent,
            otherOptionsCover: otherOptionsCoverContent,
        )
        // SCA-251 (W3 from /review-5): widget setup guide is a sheet-
        // shaped instructional surface, not a fullScreen-cover-shaped
        // camera flow. Mounted here so its dismiss doesn't trigger
        // the activeModal onChange path that fires refreshState().
        .sheet(isPresented: $widgetGuidePresented, content: widgetGuideSheet)
        // SCA-5 / SCA-19 — first-run feature tour. See
        // `tonightTourShouldPresent` for the gating contract.
        .tutorial(
            key: .tonightTour,
            content: { TonightTour() },
            shouldPresent: tonightTourShouldPresent,
        )
        .task { await refreshState() }
    }

    // MARK: - Tutorial gating (SCA-5)

    /// `true` when the Tonight feature-tour cover is allowed to present.
    /// Combines:
    ///   - `phase == .ready` so PostHog is initialized + entitlement
    ///     state has hydrated (telemetry won't drop on cold launch).
    ///   - `household.profile.onboardingCompleted` so the setup-
    ///     onboarding flow has run to completion (defense-in-depth;
    ///     the bootstrap router already prevents the un-onboarded
    ///     `.ready` path).
    ///   - All other modal/cover signals are clear, so the tutorial
    ///     never races a deep-link scan, cook launch, solve-again,
    ///     other-options, or paywall trigger for the single-cover
    ///     slot SwiftUI provides per host.
    /// `TutorialManager.isCompleted` is checked inside the presenter
    /// modifier against an `@Observable` source of truth, so a
    /// Settings → "Show tour again" reset re-opens the gate without
    /// needing a host-side observer here.
    private var tonightTourShouldPresent: Bool {
        guard coordinator.phase == .ready else { return false }
        guard coordinator.household.profile?.onboardingCompleted == true else { return false }
        guard activeModal == nil else { return false }
        guard coordinator.activeCookLaunch == nil else { return false }
        guard coordinator.activeSolveAgain == nil else { return false }
        guard coordinator.activeOtherOptions == nil else { return false }
        guard coordinator.activePaywallTrigger == nil else { return false }
        return true
    }

    // MARK: - Cover content (extracted)
    //
    // Body's `.fullScreenCover` blocks were inline `switch`-over-enum
    // closures that pushed the SwiftUI typechecker close to its
    // expression-complexity limit (line-81 timeout warning persisted
    // for several turns). Extracting each cover's body into a
    // dedicated `@ViewBuilder` method reduces `body`'s modifier-chain
    // complexity to a flat O(n) list of method references and lets
    // each cover's switch type-check in isolation. Functionally
    // identical to the inline form.

    // SCA-251 (W3): scanCoverContent is now scan-only. The widget
    // setup guide moved to a dedicated `.sheet(isPresented:)`
    // attached to `body` directly (see widgetGuideSheet below).
    @ViewBuilder
    private func scanCoverContent(modal: ActiveModal) -> some View {
        switch modal {
        case .scan:
            let capturedCoordinator = coordinator
            ScanFlowRoot(
                aiDispatch: coordinator.aiDispatch,
                pantryRepo: coordinator.pantryItemRepository,
                solveRepo: coordinator.solveRepository,
                householdStore: coordinator.household,
                entitlements: entitlements,
                presentPaywall: { trigger in
                    capturedCoordinator.presentPaywall(trigger)
                },
            )
        }
    }

    /// SCA-251 (W3): WidgetSetupGuideView is sheet-shaped (NavigationStack
    /// over a scrolling list of three numbered steps), not fullScreen-cover-
    /// shaped. Mounted as a separate `.sheet(isPresented:)` adjacent to
    /// `tonightCoverHost(...)` in body so its dismiss doesn't trigger
    /// the activeModal onChange path that fires `refreshState()`.
    @ViewBuilder
    private func widgetGuideSheet() -> some View {
        WidgetSetupGuideView(onDone: {
            widgetGuidePresented = false
        })
    }

    @ViewBuilder
    private func solveAgainCoverContent(
        entry: RootCoordinator.SolveAgainEntry,
    ) -> some View {
        let capturedCoordinator = coordinator
        SolveAgainRoot(
            ingredients: entry.ingredients,
            useFirstPrefill: entry.useFirstPrefill,
            aiDispatch: coordinator.aiDispatch,
            solveRepo: coordinator.solveRepository,
            householdStore: coordinator.household,
            entitlements: entitlements,
            presentPaywall: { trigger in
                capturedCoordinator.presentPaywall(trigger)
            },
            onDismiss: {
                coordinator.dismissSolveAgain()
                Task { await refreshState() }
            },
        )
    }

    @ViewBuilder
    private func otherOptionsCoverContent(
        entry: RootCoordinator.OtherOptionsEntry,
    ) -> some View {
        let capturedCoordinator = coordinator
        OtherOptionsRoot(
            currentPickSuggestedDishId: entry.currentPickSuggestedDishId,
            aiDispatch: coordinator.aiDispatch,
            solveRepo: coordinator.solveRepository,
            householdStore: coordinator.household,
            entitlements: entitlements,
            presentPaywall: { trigger in
                capturedCoordinator.presentPaywall(trigger)
            },
            onDismiss: {
                coordinator.dismissOtherOptions()
                Task { await refreshState() }
            },
        )
    }

    @ViewBuilder
    private func cookLaunchCoverContent(
        launch: RootCoordinator.CookModeLaunch,
    ) -> some View {
        switch launch {
        case let .fresh(launch):
            CookModeRoot(
                recipePlan: launch.recipePlan,
                household: launch.household,
                aiDispatch: coordinator.aiDispatch,
                source: .solve,
                onDismiss: {
                    coordinator.dismissCookMode()
                    Task { await refreshState() }
                },
            )
        case let .resume(session):
            if !session.isDeleted,
               let plan = session.recipePlan,
               let household = session.household {
                CookModeRoot(
                    recipePlan: plan,
                    household: household,
                    aiDispatch: coordinator.aiDispatch,
                    source: .saved,
                    existingSession: session,
                    onDismiss: {
                        coordinator.dismissCookMode()
                        Task { await refreshState() }
                    },
                )
            } else {
                VStack(spacing: CGFloat.Stir.space3) {
                    Text("Couldn't load this dish")
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.ink900)
                    PrimaryButton(title: "Close") {
                        coordinator.dismissCookMode()
                        Task { await refreshState() }
                    }
                }
                .padding(CGFloat.Stir.space7 - 8)  // 40pt — hero error margin
            }
        }
    }

    // MARK: - Header

    private var greetingHeader: some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                Text("Tonight")
                    .stirFont(.displayLg)
                    .foregroundStyle(Color.Stir.ink900)
                    .accessibilityAddTraits(.isHeader)

                // Subtitle re-renders at every minute boundary
                // (HH:MM:00) so the displayed minute always matches
                // the wall clock. Earlier draft used `.periodic(from:
                // .now, by: 60)` — that ticks every 60s counted from
                // first appearance, so the minute label could lag the
                // status-bar clock by up to 59 seconds. `.everyMinute`
                // is the boundary-aligned schedule (iOS 16+).
                TimelineView(.everyMinute) { context in
                    Text(greetingSubtitle(now: context.date))
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink500)
                }
            }

            Spacer(minLength: CGFloat.Stir.space2)

            bookmarkJumpButton
        }
    }

    /// Weekday + locale-short time. `now` comes from the `TimelineView`
    /// context so each minute tick re-evaluates against a fresh Date
    /// rather than a stale captured value. `Date.FormatStyle` is
    /// value-type and cheap to invoke per tick — review finding W-E W21
    /// (CA3) — so the periodic recompute doesn't reintroduce the
    /// per-eval `DateFormatter()` allocator churn the prior
    /// implementation was migrated away from.
    private func greetingSubtitle(now: Date) -> String {
        let weekday = now.formatted(.dateTime.weekday(.wide))
        let time = now.formatted(date: .omitted, time: .shortened)
        return "\(weekday) · \(time)"
    }

    /// Circular paper-200 button hosting the bookmark glyph — mockup
    /// 03 Default state's only top-bar affordance. Tap switches the
    /// shell to the Saved tab. Wider 44pt content shape on top of the
    /// visible 40pt circle to clear the HIG floor without growing the
    /// chrome.
    private var bookmarkJumpButton: some View {
        Button {
            coordinator.selectedTab = .saved
        } label: {
            Image.Stir.bookmark
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.Stir.ink700)
                .frame(width: 40, height: 40)
                .background(
                    Circle().fill(Color.Stir.paper200),
                )
                .overlay(
                    Circle().strokeBorder(Color.Stir.divider, lineWidth: 1),
                )
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Saved meals")
        .accessibilityHint("Open the Saved tab")
    }

    // MARK: - Resumable banner

    @ViewBuilder
    private var resumableBanner: some View {
        if let session = resumableSession, let plan = session.recipePlan {
            Button {
                coordinator.resumeCookMode(session)
            } label: {
                HStack(spacing: CGFloat.Stir.space3) {
                    Image.Stir.play
                        .font(.system(size: CGFloat.Stir.iconLg, weight: .semibold))
                        .foregroundStyle(Color.Stir.ember600)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                                .fill(Color.Stir.ember100),
                        )

                    VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                        Text("Resume cooking")
                            .stirFont(.labelLg)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.Stir.ink900)
                        Text(plan.title ?? "In progress")
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink500)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image.Stir.disclosure
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                        .foregroundStyle(Color.Stir.ink300)
                }
                .padding(CGFloat.Stir.space3Half) // 14pt
                .stirCard(
                    fill: Color.Stir.ember100,
                    borderColor: Color.Stir.ember600.opacity(0.4),
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume cooking \(plan.title ?? "in progress")")
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: CGFloat.Stir.space4) {
            primaryTonightContent
            supportingCards
        }
    }

    @ViewBuilder
    private var primaryTonightContent: some View {
        if let pick = tonightPick {
            VStack(spacing: CGFloat.Stir.space4) {           // 16pt — gap between hero and secondary tiles per mockup-03
                TonightPickHeroCard(
                    title: pick.title,
                    solvedAt: pick.solvedAt,
                    isHighMatch: pick.confidence >= 0.7,
                    estimatedMinutes: pick.estimatedMinutes,
                    servings: pick.servings,
                    chips: pick.chips,
                    onStartCooking: { startCooking(pick) },
                    onOtherOptions: { presentOtherOptions(for: pick) },
                    onSaveForLater: { saveForLater(pick) },
                )
                secondaryTiles(for: pick)
            }
        } else {
            firstUseEmpty
        }
    }

    @ViewBuilder
    private var supportingCards: some View {
        if let useSoonCandidate {
            UseSoonCard(
                candidate: useSoonCandidate,
                onSolve: { handleUseSoonTap(useSoonCandidate) },
            )
        }
        if widgetNudgeVisible {
            WidgetNudgeCard(
                onGuide: showWidgetGuide,
                onDismiss: dismissWidgetNudge,
            )
        }
    }

    /// Rescan + Solve again secondary tile row beneath the hero card
    /// (mockup-03 §Default state). Rescan opens `ScanFlowRoot`; Solve
    /// again opens `SolveAgainRoot` — the constraints-sheet →
    /// DinnerOptionsView → DishPreviewView flow seeded with the latest
    /// pantry snapshot, bypassing the camera. Rescan renders icon +
    /// label only (centered) so its tile is visually quieter than
    /// Solve again. Rescan honors `disable_scan_parse` with a disabled
    /// visual + unavailable copy (subtitle returns in that state).
    private func secondaryTiles(for pick: SolveRepository.TonightPick) -> some View {
        HStack(spacing: CGFloat.Stir.space2 + 2) {           // 10pt
            secondaryTile(
                icon: Image.Stir.camera,
                title: scanIsKillSwitched ? "Scan unavailable" : "Rescan",
                subtitle: scanIsKillSwitched ? "Temporarily paused" : nil,
                isEnabled: !scanIsKillSwitched,
                action: handleScanTap,
            )
            secondaryTile(
                icon: Image.Stir.sparkles,
                title: "Solve again",
                subtitle: "Different idea",
                isEnabled: true,
                action: handleSolveAgainTap,
            )
        }
    }

    private func secondaryTile(
        icon: Image,
        title: String,
        subtitle: String?,
        isEnabled: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        let iconTint = isEnabled ? Color.Stir.ember600 : Color.Stir.ink300
        let titleColor = isEnabled ? Color.Stir.ink900 : Color.Stir.ink500
        return Button(action: action) {
            HStack(spacing: CGFloat.Stir.space2 + 2) {       // 10pt
                icon
                    .font(.system(size: CGFloat.Stir.iconMd, weight: .regular))
                    .foregroundStyle(iconTint)
                if let subtitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .stirFont(.labelLg)
                            .fontWeight(.semibold)
                            .foregroundStyle(titleColor)
                        Text(subtitle)
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink500)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Hidden 2-line shape anchors the row to the same
                    // height as the with-subtitle tile so paired tiles
                    // (Rescan / Solve again) stay visually balanced.
                    // Visible title centers inside the ZStack; HStack's
                    // default .center alignment then puts the icon at
                    // the same vertical midpoint.
                    ZStack {
                        VStack(spacing: 2) {
                            Text(title).stirFont(.labelLg).fontWeight(.semibold)
                            Text(" ").stirFont(.bodySm)
                        }
                        .hidden()
                        Text(title)
                            .stirFont(.labelLg)
                            .fontWeight(.semibold)
                            .foregroundStyle(titleColor)
                    }
                }
            }
            .padding(CGFloat.Stir.space3 + 2)               // 14pt
            .frame(maxWidth: .infinity)
            .stirCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
    }

    /// Re-solve from the latest pantry snapshot, no camera. Reads the
    /// snapshot off the most-recent completed `MealSolveRequest` (the
    /// same row that fed `tonightPick`), converts to the
    /// `IngredientLite` shape the dinner-solve endpoint wants, and
    /// hands off to `coordinator.requestSolveAgain(...)` which drives
    /// the `SolveAgainRoot` cover. If the snapshot is missing or empty
    /// (shouldn't happen when the hero card is visible — both depend
    /// on a completed solve), bail with a toast and refresh state so
    /// the stale Solve again button doesn't keep failing.
    private func handleSolveAgainTap() {
        guard let household = coordinator.household.profile else {
            toastMessage = "Couldn't open Solve again. Try again."
            return
        }
        guard
            let ingredients = coordinator.solveRepository.latestPantryIngredients(
                for: household,
            )
        else {
            toastMessage = "No pantry to solve from. Try a fresh scan."
            Task { await refreshState() }
            return
        }
        coordinator.requestSolveAgain(ingredients: ingredients)
    }

    private func handleUseSoonTap(_ candidate: UseSoonCandidate) {
        openSolveAgain(useFirstDisplayName: candidate.displayName)
        // SCA-317: route through UseSoonScheduler so the unactioned-streak
        // counter clears AND telemetry fires from a single seam. Prior
        // direct PostHog.capture() left history.markMostRecentActioned()
        // un-called, so two consecutive card-only taps would silently arm
        // the 14-day suppression even though the user was engaging.
        UseSoonScheduler.shared.recordAction()
    }

    private func handleUseSoonPrefill(_ entry: RootCoordinator.UseSoonPrefillEntry) {
        guard let household = coordinator.household.profile else { return }
        // SCA-259 (W11 from /review-5): the displayed-card fallback is
        // ONLY valid when the deep-link entry has no pantryItemID
        // (notification-without-id branch — older notifications, or
        // a use-soon card tap that bypassed the pantryItemID path).
        // When pantryItemID IS provided and the lookup misses, the
        // user tapped a notification for a SPECIFIC ingredient that
        // no longer exists in their pantry. Substituting whichever
        // ingredient happens to be on the displayed card means the
        // user opens Solve again prefilled with a different
        // ingredient than the one they tapped — and use_soon
        // conversion telemetry attributes the conversion to the
        // wrong source. Surface "no longer in your pantry" toast
        // and abort instead.
        let displayName: String?
        if let pantryItemID = entry.pantryItemID {
            if let item = try? coordinator.pantryItemRepository.fetch(id: pantryItemID, for: household),
               let name = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                displayName = name
            } else {
                // Specific-ID miss: the user tapped a notification
                // for an ingredient that's been deleted/expired.
                // Surface and stop — no fallback substitution.
                toastMessage = "That ingredient is no longer in your pantry."
                return
            }
        } else {
            // No-ID branch: fall back to whatever the displayed
            // use-soon card surfaces (a still-eligible expiring
            // ingredient at the time of tap), if any.
            displayName = useSoonCandidate?.displayName
        }
        guard let displayName else {
            toastMessage = "That ingredient is no longer in your pantry."
            return
        }
        openSolveAgain(useFirstDisplayName: displayName)
    }

    private func openSolveAgain(useFirstDisplayName: String) {
        guard let household = coordinator.household.profile else {
            toastMessage = "Couldn't open dinner ideas. Try again."
            return
        }
        let ingredients: [DinnerSolveRequest.IngredientLite]
        do {
            ingredients = try coordinator.pantryItemRepository.fetchAll(for: household)
                .compactMap(Self.ingredientLite)
        } catch {
            Logger.ui.error("TonightHome use-soon pantry refresh failed: \(error.localizedDescription, privacy: .public)")
            toastMessage = "Couldn't read your pantry. Try a fresh scan."
            return
        }
        guard !ingredients.isEmpty else {
            toastMessage = "No pantry to solve from. Try a fresh scan."
            return
        }
        coordinator.requestSolveAgain(
            ingredients: ingredients,
            useFirstPrefill: [useFirstDisplayName],
        )
    }

    private func showWidgetGuide() {
        coordinator.widgetNudgeService.recordActed()
        widgetNudgeVisible = false
        // SCA-251 (W3): present the instructional sheet via the
        // dedicated `widgetGuidePresented` flag, not through
        // ActiveModal's scan-cover slot.
        widgetGuidePresented = true
    }

    private func dismissWidgetNudge() {
        coordinator.widgetNudgeService.recordDeferred()
        widgetNudgeVisible = false
    }

    private static func ingredientLite(_ item: PantryItem) -> DinnerSolveRequest.IngredientLite? {
        guard let displayName = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else { return nil }
        return DinnerSolveRequest.IngredientLite(
            displayName: displayName,
            canonicalSlug: item.canonicalIngredientSlug?.isEmpty == true ? nil : item.canonicalIngredientSlug,
            amountText: item.amountText,
        )
    }

    private static func useSoonCandidate(_ item: PantryItem) -> UseSoonCandidate? {
        guard let id = item.id,
              let expiresAt = item.expiresAt,
              let displayName = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else { return nil }
        return UseSoonCandidate(id: id, displayName: displayName, expiresAt: expiresAt)
    }

    /// Present the alts from the same MealSolveRequest as the current
    /// pick. `OtherOptionsRoot` rehydrates DishCards from persisted
    /// Core Data (no AI spend) and reuses `DishPreviewView` as the
    /// destination, so users land on the same full-detail surface
    /// they get from a fresh solve. Coordinator drives the
    /// fullScreenCover via `activeOtherOptions` (mirrors SolveAgain).
    private func presentOtherOptions(for pick: SolveRepository.TonightPick) {
        coordinator.requestOtherOptions(currentPickSuggestedDishId: pick.suggestedDishId)
    }

    /// Save-for-later writes to `RecipePlan.isFavorite` so the dish
    /// surfaces in the Saved tab. Free tier hits the favorites paywall
    /// (`PaywallTrigger.savedFavoritesGate`) — the matching UX in
    /// `SavedMealsView`'s star-toggle uses the same trigger.
    ///
    /// Idempotent on repeat tap: if the dish is already marked
    /// favorite, surface "Already in Saved" rather than silently
    /// re-writing the same value. Toast copy explicitly says "Saved
    /// to favorites" so the user understands the v1 model — Save for
    /// later is a favorite-mark, not a separate snooze/reminder
    /// concept (different vocabulary at the mockup layer; same
    /// destination at the data layer).
    private func saveForLater(_ pick: SolveRepository.TonightPick) {
        guard
            let plan = coordinator.solveRepository.fetchRecipePlan(
                forSuggestedDishId: pick.suggestedDishId,
            ),
            !plan.isSoftDeleted
        else {
            toastMessage = "This dish is no longer available."
            Task { await refreshState() }
            return
        }
        entitlements.gate(
            .savedFavorites,
            paywall: { coordinator.presentPaywall(.savedFavoritesGate) },
            allow: {
                if plan.isFavorite {
                    toastMessage = "Already in Saved."
                    return
                }
                _ = coordinator.solveRepository.setFavorite(true, on: plan)
                toastMessage = "Saved to favorites."
            },
        )
    }

    private func startCooking(_ pick: SolveRepository.TonightPick) {
        guard let household = coordinator.household.profile else {
            toastMessage = "Couldn't start this dish. Try again."
            return
        }
        // Resolve the live RecipePlan via the dish id at tap time —
        // `tonightPick` only carries the stable UUID, never the managed-
        // object reference, so we sidestep the @State-holds-NSManagedObject
        // dangling-fault risk. If the plan was soft-deleted between the
        // last refresh and this tap (e.g. CloudKit conflict resolution
        // marked it), bail with a toast and trigger a fresh refresh so
        // the stale hero card disappears.
        guard
            let plan = coordinator.solveRepository.fetchRecipePlan(
                forSuggestedDishId: pick.suggestedDishId,
            ),
            !plan.isSoftDeleted
        else {
            toastMessage = "This dish is no longer available. Pick another."
            Task { await refreshState() }
            return
        }
        coordinator.startCookMode(recipePlan: plan, household: household)
    }

    /// Empty-state branch — the household has no completed solves
    /// yet. Mockup 03 §First-use empty: dashed-border card + ember-
    /// tint camera tile + Scan Kitchen CTA + sample-fallback link.
    private var firstUseEmpty: some View {
        VStack(spacing: CGFloat.Stir.space3 + 2) { // 14pt
            // Camera glyph tile — 80pt rounded ember-tint square
            ZStack {
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusHero, style: .continuous)
                    .fill(Color.Stir.ember100)
                Image.Stir.camera
                    .font(.system(size: emptyStateCameraSize, weight: .regular)) // justification: 36pt hero camera inside the 80pt tile — one-off per §4.1, scaled via @ScaledMetric
                    .foregroundStyle(Color.Stir.ember600)
            }
            .frame(width: CGFloat.Stir.iconHero, height: CGFloat.Stir.iconHero)

            VStack(spacing: CGFloat.Stir.space2) {
                Text("Let's see what you've got.")
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                    .multilineTextAlignment(.center)

                Text("Scan your fridge and pantry. I'll find three dinners you can make right now.")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink500)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            PrimaryButton(title: "Scan your kitchen") {
                handleScanTap()
            }
            .padding(.top, CGFloat.Stir.space1 + 2) // 6pt

            TextButton(title: "Try the sample instead") {
                toastMessage = "Sample scan is coming soon."
            }
        }
        .padding(.horizontal, CGFloat.Stir.space5)
        .padding(.vertical, CGFloat.Stir.space6 + 8) // 40pt
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusHero, style: .continuous)
                .strokeBorder(
                    Color.Stir.ink300,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]),
                ),
        )
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusHero, style: .continuous)
                .fill(Color.Stir.paper100),
        )
    }

    private func handleScanTap() {
        if scanIsKillSwitched {
            toastMessage = "Kitchen scan is temporarily unavailable. Try a saved meal instead."
        } else {
            activeModal = .scan
        }
    }

    // MARK: - State helpers

    // SCA-279 (S13 from /review-5): no `@MainActor` annotation needed.
    // `TonightHomeView` is a SwiftUI `View` struct, which is implicitly
    // main-actor-isolated for body evaluation. The two callers are
    // `.task { await refreshState() }` (inherits the host's main-actor
    // isolation) and `.onChange { Task { await refreshState() } }`
    // (same — `Task {}` inherits the enclosing context's actor). The
    // explicit annotation was redundant and read like the function
    // might be reachable off-main, which it isn't.
    private func refreshState() async {
        guard let household = coordinator.household.profile else { return }
        // CR1-W4 fix: route through coordinator.cookingSessionRepository
        // instead of constructing a fresh repo per refresh — symmetric
        // with every other repo read on this screen and stub-able from tests.
        let cookingRepo = coordinator.cookingSessionRepository
        let solveRepo = coordinator.solveRepository
        do {
            self.resumableSession = try cookingRepo.resumableSession(for: household)
        } catch {
            Logger.ui.error("TonightHome resumable refresh failed: \(error.localizedDescription, privacy: .public)")
            self.resumableSession = nil
        }
        // SolveRepository.latestTonightPick is non-throwing (returns
        // nil on lookup failure) — wrap in MainActor isolation since
        // both Repository and view are @MainActor and Core Data
        // lives in viewContext.
        self.tonightPick = solveRepo.latestTonightPick(for: household)
        refreshUseSoonCandidate(household: household, cookingRepo: cookingRepo)
        refreshWidgetNudge(household: household, cookingRepo: cookingRepo)
    }

    private func refreshUseSoonCandidate(
        household: HouseholdProfile,
        cookingRepo: CookingSessionRepository,
    ) {
        let now = Date()
        if let completedAt = try? cookingRepo.mostRecentCompletedAt(for: household),
           now.timeIntervalSince(completedAt) < 24 * 3600 {
            useSoonCandidate = nil
            return
        }
        do {
            useSoonCandidate = try coordinator.pantryItemRepository
                .fetchExpiringSoon(now: now, for: household)
                .compactMap(Self.useSoonCandidate)
                .first
        } catch {
            Logger.ui.error("TonightHome use-soon refresh failed: \(error.localizedDescription, privacy: .public)")
            useSoonCandidate = nil
        }
    }

    private func refreshWidgetNudge(
        household: HouseholdProfile,
        cookingRepo: CookingSessionRepository,
    ) {
        let flagEnabled = entitlements.flagBool(forKey: "widget_nudge_enabled") ?? false
        guard flagEnabled else {
            widgetNudgeVisible = false
            return
        }
        let now = Date()
        // SCA-262 (W14 from /review-5): count-only Core Data query.
        // Pre-fix this materialized up to 50 CookingSession
        // NSManagedObjects per refresh just to filter-and-count
        // those within the 14-day window. Push the predicate +
        // count into Core Data via `recentCompletedSessionsCount`
        // (resultType=.countResultType). Same hot path semantics,
        // zero materialization.
        let recentCount = (try? cookingRepo.recentCompletedSessionsCount(
            for: household,
            since: now.addingTimeInterval(-14 * 86_400),
        )) ?? 0
        // SCA-254 (W6 from /review-5): always re-evaluate shouldShowNudge.
        // Pre-fix, an early-return when widgetNudgeVisible was already
        // true skipped the eligibility re-check on every refresh, so a
        // server-side `widget_nudge_enabled` flip-to-false (kill switch)
        // OR `sessionsInLast14Days` aging out below the threshold left
        // the card visible until the user dismissed or tab-switched.
        // Now: shouldShowNudge is the single source of truth on every
        // refresh. The wasShown guard below keeps `markShown` (which
        // emits widget_nudge_shown telemetry) firing only on the
        // false→true transition, not on every refresh while the card
        // is already up.
        let wasShown = widgetNudgeVisible
        guard coordinator.widgetNudgeService.shouldShowNudge(
            now: now,
            sessionsInLast14Days: recentCount,
            flagEnabled: flagEnabled,
        ) else {
            widgetNudgeVisible = false
            return
        }
        widgetNudgeVisible = true
        if !wasShown {
            coordinator.widgetNudgeService.markShown(at: now)
        }
    }

    // MARK: - Kill switch

    private var scanIsKillSwitched: Bool {
        entitlements.flagBool(forKey: "disable_scan_parse") ?? false
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            Text(toastMessage)
                .stirFont(.bodySm)
                .fontWeight(.medium)
                .foregroundStyle(Color.Stir.paper50)
                .padding(.horizontal, CGFloat.Stir.space3 + 2) // 14pt
                .padding(.vertical, CGFloat.Stir.space2 + 2)   // 10pt
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.Stir.ink900.opacity(0.85)),
                )
                .padding(.top, CGFloat.Stir.space3)
                // Reduce Motion drops the slide + opacity transition
                // to an identity swap. The toast still appears and
                // auto-dismisses at 2s; only the motion is suppressed.
                // Review finding W-F W24 (FD1).
                .transition(reduceMotion
                    ? .identity
                    : .move(edge: .top).combined(with: .opacity))
                .id(toastMessage)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    withStirAnimation(.Stir.standard, reduceMotion: reduceMotion) {
                        self.toastMessage = nil
                    }
                }
        }
    }
}

// SCA-250 (W2 from /review-5): UseSoonCard, WidgetNudgeCard, and
// WidgetSetupGuideView were extracted to dedicated files alongside
// this one (`UseSoonCard.swift`, `WidgetNudgeCard.swift`,
// `WidgetSetupGuideView.swift`). Pre-extraction they were inlined
// here as `private struct`s — see those files for the rationale and
// the SwiftUI typecheck-ceiling history.

// MARK: - TonightPickHeroCard

/// Mockup 03 §Default state hero. Plate pedestal on top
/// (paper-200) carrying the HIGH MATCH + SOLVED N MIN AGO badges over
/// a SwiftUI-drawn plate illustration; paper-100 body underneath with
/// the TONIGHT'S PICK eyebrow, serif title, meta row, sage-tinted
/// chips, and the ember `Start cooking` PrimaryButton.
private struct TonightPickHeroCard: View {
    let title: String
    let solvedAt: Date
    let isHighMatch: Bool
    let estimatedMinutes: Int
    let servings: Int
    let chips: [String]
    let onStartCooking: () -> Void
    let onOtherOptions: () -> Void
    let onSaveForLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            pedestal
            cardDetails
        }
        .background(
            // 20pt corner radius is a Tonight-specific one-off — in the
            // mockup palette but not in the shared radius tokens
            // (radiusLg = 16, radiusAccent = 18, radiusXl = 22). Kept
            // literal so the mockup→iOS provenance is auditable; promote
            // to a token if a second screen adopts the same value.
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusHero, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusHero, style: .continuous)
                .strokeBorder(Color.Stir.divider, lineWidth: 1),
        )
        .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusHero, style: .continuous))
        // Intentionally NOT `.accessibilityElement(children: .combine)`:
        // combining flattens the inner `Start cooking` button into a
        // single mega-element and forces VoiceOver users to commit to
        // cooking just to hear the card description. Letting the
        // children stand as separate elements (eyebrows, title-as-
        // header, meta row, chips, button) preserves the inspect-then-
        // commit flow. The title carries `.isHeader`; the PrimaryButton
        // self-labels.
    }

    // MARK: Plate pedestal

    private var pedestal: some View {
        ZStack(alignment: .top) {
            Color.Stir.paper200
                .frame(maxWidth: .infinity)

            VStack {
                Spacer().frame(height: CGFloat.Stir.space4) // 16pt
                StirPlate(.hero, size: 180)
                Spacer().frame(height: CGFloat.Stir.space1Half) // 6pt
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .top) {
                // SCA-302: the prior leftovers eyebrow path was fully
                // retired — leftovers solves never reach Tonight (filtered
                // at the predicate in `latestCompletedSolve`), so the
                // hero card only ever needs the high-match badge slot.
                if isHighMatch {
                    highMatchBadge
                }
                Spacer(minLength: CGFloat.Stir.space2)
                solvedAgoLabel
            }
            .padding(.horizontal, CGFloat.Stir.space3)
            .padding(.top, CGFloat.Stir.space3)
        }
    }

    private var highMatchBadge: some View {
        HStack(spacing: CGFloat.Stir.space1) {
            Circle()
                .fill(Color.Stir.sage600)
                .frame(width: 6, height: 6)
            Text("HIGH MATCH")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.sage600)
        }
        .padding(.horizontal, CGFloat.Stir.space2 + 2) // 10pt
        .padding(.vertical, CGFloat.Stir.space1)       // 4pt
        .background(
            Capsule(style: .continuous)
                .fill(Color.Stir.paper50),
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.Stir.sage100, lineWidth: 1),
        )
    }

    /// Eyebrow that ticks every minute via `TimelineView` so a user
    /// who lingers on Tonight sees the time-since-solve advance live
    /// rather than freeze at first render. CA3-H2 fix: switched from
    /// `.periodic(from: .now, by: 60)` (anchored to first appearance,
    /// drifts up to 59s from wall clock and restarts on scroll-off) to
    /// `.everyMinute` (boundary-aligned, matches the greeting eyebrow
    /// already used a few hundred lines up). The TimelineView is scoped
    /// to JUST this Text — re-renders elsewhere on the card don't
    /// retrigger from the periodic schedule.
    private var solvedAgoLabel: some View {
        TimelineView(.everyMinute) { context in
            Text(solvedAgoText(now: context.date))
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
        }
    }

    /// "SOLVED 3 MIN AGO" / "SOLVED 2 HR AGO" / "SOLVED YESTERDAY".
    /// Custom rendering rather than `.relative(presentation: .named)`
    /// because the mockup uses an UPPERCASE "SOLVED N MIN AGO" form
    /// with a leading verb — the framework's relative formatter ships
    /// "3 minutes ago" and lacks the verb. `now` comes from the
    /// `TimelineView` context so each tick re-evaluates against a
    /// fresh boundary instead of a stale captured `Date()`.
    private func solvedAgoText(now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(solvedAt))
        let minutes = Int(elapsed / 60)
        let hours = Int(elapsed / 3600)
        let days = Int(elapsed / 86_400)
        if elapsed < 60 {
            return "Just solved"
        } else if minutes < 60 {
            return "Solved \(minutes) min ago"
        } else if hours < 24 {
            return "Solved \(hours) hr ago"
        } else if days == 1 {
            return "Solved yesterday"
        } else {
            return "Solved \(days) days ago"
        }
    }

    // MARK: Body content

    private var cardDetails: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Tonight's pick")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ember600)

            Text(title)
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, CGFloat.Stir.space1)

            metaRow

            if !chips.isEmpty {
                chipsRow
            }

            // Trailing arrow matches mockup-03's `Start cooking →` form.
            // PrimaryButton's `trailingIcon` parameter renders the glyph
            // at 16pt with `.paper50` fill and `.accessibilityHidden(true)`
            // so VoiceOver still reads "Start cooking" cleanly.
            PrimaryButton(
                title: "Start cooking",
                trailingIcon: Image.Stir.arrowRight,
                action: onStartCooking,
            )
            .padding(.top, CGFloat.Stir.space2)

            // Secondary 2-up row beneath the hero CTA — mockup-03's
            // "Other options" + "Save for later" pair. 40pt height
            // (smaller than `SecondaryButton`'s 52pt; the mockup
            // calls for a tighter scale here so the hero CTA stays
            // dominant), `radius.md`, paper-50 fill, 1pt divider
            // border, ink.700 medium label.
            HStack(spacing: CGFloat.Stir.space2) {           // 8pt
                heroSecondaryButton(title: "Other options", action: onOtherOptions)
                heroSecondaryButton(title: "Save for later", action: onSaveForLater)
            }
            .padding(.top, CGFloat.Stir.space2 + 2)          // 10pt
        }
        .padding(.horizontal, CGFloat.Stir.space4 + 2) // 18pt — mockup uses 18px body padding
        .padding(.top, CGFloat.Stir.space3 + 2)        // 14pt
        .padding(.bottom, CGFloat.Stir.space4 + 2)     // 18pt
    }

    /// Compact secondary button used only inside the hero card. Distinct
    /// from `SecondaryButton` (52pt, paper-100 fill) — this variant is
    /// 44pt with a paper-50 fill so it reads as "tucked under the
    /// primary CTA" rather than competing with it. 44pt is the HIG tap
    /// target floor; the mockup's nominal 40pt visual is reconciled to
    /// the floor rather than papered with `.contentShape` extension
    /// (the earlier draft chained `.frame(height: 40).frame(minHeight:
    /// 44)` which silently rendered at 44pt anyway — height conflict
    /// resolved in favor of the floor). Kept private to the hero card
    /// to avoid cluttering the DesignSystem with a near-twin component.
    private func heroSecondaryButton(
        title: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Text(title)
                .stirFont(.labelMd)
                .fontWeight(.medium)
                .foregroundStyle(Color.Stir.ink700)
                .frame(maxWidth: .infinity)
                .frame(height: 44)                              // HIG floor; doubles as the visual height
                .background(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .fill(Color.Stir.paper50),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .strokeBorder(Color.Stir.divider, lineWidth: 1),
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var metaRow: some View {
        // "22 min · 4 servings" with a leading clock glyph on the time
        // bucket. The mockup also shows "1 pan" but the data model has
        // no pan-count field; rather than ship a hardcoded "1 pan" lie
        // for every recipe, the meta row is two segments. Promote to
        // three when `RecipePlan.panCount` (or equivalent) lands.
        HStack(spacing: CGFloat.Stir.space3 + 2) { // 14pt
            HStack(spacing: CGFloat.Stir.space1) {
                Image.Stir.clock
                    .font(.system(size: CGFloat.Stir.iconSm))
                    .foregroundStyle(Color.Stir.ink500)
                Text("\(estimatedMinutes) min")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink700)
                    .fontWeight(.semibold)
            }
            metaSeparator
            Text(servingsText)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
                .fontWeight(.semibold)
        }
    }

    /// Manual inflection because Stir's localization is US-English-only
    /// at v1 (CLAUDE.md: "English / US-only launch"); the AttributedString
    /// `^[N serving](inflect: true)` form would need a strings table to
    /// fire correctly. This is the only place the rule lives, so a
    /// ternary is clearer than a strings-catalog round-trip.
    private var servingsText: String {
        servings == 1 ? "1 serving" : "\(servings) servings"
    }

    private var metaSeparator: some View {
        Text("·")
            .stirFont(.bodySm)
            .foregroundStyle(Color.Stir.ink500)
    }

    private var chipsRow: some View {
        // Sage-tinted pills — `chips` is at most three entries from
        // SolveRepository.derivedChips. Wrap so a long dietary value
        // doesn't overflow on smaller widths / Dynamic Type sizes.
        HStack(spacing: CGFloat.Stir.space1Half) { // 6pt — tight inter-chip
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.sage600)
                    .padding(.horizontal, CGFloat.Stir.space2 + 2) // 10pt
                    .padding(.vertical, CGFloat.Stir.space1)       // 4pt
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.Stir.sage100),
                    )
            }
        }
    }

}

// PlateIllustration moved to Stir/DesignSystem/Components/StirPlate.swift
// as `StirPlate(.hero, size:)` (SCA-96). The salmon-fillet GeometryReader
// (FD1-11) was retired during the move — the path is fully size-derived
// and never needed parent-frame measurement.

// SolveAgainRoot moved to Stir/Features/Solve/SolveAgainRoot.swift (CR1-W2 fix).

// MARK: - Previews

#Preview("Tonight Hero — light") {
    TonightPickHeroCard(
        title: "Miso-Glazed Salmon with Sesame Rice",
        solvedAt: Date().addingTimeInterval(-180),
        isHighMatch: true,
        estimatedMinutes: 22,
        servings: 4,
        chips: ["pescatarian", "nut-free", "quick"],
        onStartCooking: {},
        onOtherOptions: {},
        onSaveForLater: {},
    )
    .padding(CGFloat.Stir.space4)
    .background(Color.Stir.paper50)
    .preferredColorScheme(.light)
}

#Preview("Tonight Hero — dark") {
    TonightPickHeroCard(
        title: "Miso-Glazed Salmon with Sesame Rice",
        solvedAt: Date().addingTimeInterval(-180),
        isHighMatch: true,
        estimatedMinutes: 22,
        servings: 4,
        chips: ["pescatarian", "nut-free", "quick"],
        onStartCooking: {},
        onOtherOptions: {},
        onSaveForLater: {},
    )
    .padding(CGFloat.Stir.space4)
    .background(Color.Stir.paper50)
    .preferredColorScheme(.dark)
}
