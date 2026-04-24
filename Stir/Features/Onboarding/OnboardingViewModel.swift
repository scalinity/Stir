// OnboardingViewModel
//
// Step-2 onboarding VM. Backed by an already-created `HouseholdProfile`
// (pre-created at app launch by RootCoordinator; see commit 9 + the
// Round-1 Q4 decision). Buffers user toggles in-memory; writes to
// Core Data happen only on `savePreferences()` / `saveKitchen()` /
// `completeOnboarding()`.

import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    // MARK: - Dependencies

    let profile: HouseholdProfile
    private let dietaryRepo: DietaryRuleRepository
    private let equipmentRepo: KitchenEquipmentRepository
    private let profileRepo: HouseholdProfileRepository

    // MARK: - Setup 1 state (preferences)

    var selectedAllergens: Set<AllergenOption> = []
    var selectedDiets: Set<DietOption> = []
    /// Curated dislike selections from the ~12-option DislikeOption enum.
    /// Written to DietaryRule rows as `(kind: .dislike, severity: .soft)`.
    var selectedDislikes: Set<DislikeOption> = []
    /// Free-text dislikes from the "+ Add" affordance. Each entry is
    /// trimmed + lowercased + length-capped at `customDislikeMaxLength`
    /// on write via `addCustomDislike(_:)`. Each also gets a DietaryRule
    /// row with `kind: .dislike, severity: .soft` and the normalized
    /// string as `value`.
    var customDislikes: Set<String> = []
    var selectedGoals: Set<GoalOption> = []

    // MARK: - Setup 2 state (kitchen + servings)

    var selectedEquipment: Set<KitchenEquipment.CommonCode> = []
    var servingsDefault: Int16 = 2
    var preferredUnits: HouseholdProfile.PreferredUnits = .imperial

    // MARK: - Skip / telemetry state

    /// Step IDs that were bypassed via a Skip action. A step visited
    /// and then Skipped mid-form counts as partially-completed (state
    /// is saved) and is NOT recorded — only steps that come AFTER the
    /// current one and get jumped over are recorded. Attached to the
    /// `onboarding_completed` PostHog event via
    /// `fireOnboardingCompletedEvent()`.
    private(set) var skippedSteps: [String] = []

    /// Wall-clock anchor for the `duration_sec` property on
    /// `onboarding_completed`. Set at VM init — onboarding effectively
    /// starts when RootCoordinator instantiates the VM post-bootstrap,
    /// which matches when the user lands on Welcome. A user who
    /// abandons and re-enters onboarding (pre-completion kill +
    /// relaunch) gets a fresh anchor; duration captures per-session
    /// time, not calendar-time-to-complete. That matches PostHog's
    /// funnel semantics for resumed flows.
    let onboardingStartedAt: Date = .init()

    /// Idempotency guard for `fireOnboardingCompletedEvent()`. Closes
    /// the double-emit class of bugs at the VM layer regardless of
    /// caller debounce: any second invocation early-returns silently.
    /// Triggered by (a) double-tap on Skip/Continue handlers that
    /// each schedule their own `Task { savePreferences(); path.append(
    /// .completionTransition) }` before iOS disables the Button,
    /// (b) NavigationStack re-running `.task` on OnboardingCompletion-
    /// View re-appearance (e.g. back-nav during the 1.5s dwell). See
    /// review finding C4 in review-ui-migration-findings.md.
    private var hasFiredCompletedEvent = false

    /// Maximum grapheme-cluster count for a user-entered custom dislike.
    /// 32 chars is the user-visible cap driving the "+ Add" sheet UI.
    /// See also `customDislikeMaxBytes` (payload cap) — both apply.
    static let customDislikeMaxLength = 32

    /// Maximum UTF-8 byte payload for a user-entered custom dislike.
    /// 64 bytes lets ~20 CJK ideographs or 64 ASCII chars through —
    /// caps the Gemini context-bloat risk that `customDislikeMaxLength`
    /// alone misses when input is multi-byte. DietaryRule.value flows
    /// into every dinner-solve prompt via HouseholdProfile context;
    /// adversarial input could have been up to 32 × 4-byte CJK = 128
    /// bytes before this cap. Review finding W-B W9 (SA1+DB1).
    static let customDislikeMaxBytes = 64

    /// Maximum cardinality of `customDislikes`. 10 is well past any
    /// realistic preference set and caps a tap-storm / UI-loop bug
    /// class that could otherwise inflate the Gemini context payload
    /// linearly. Enforced at `addCustomDislike` intake.
    /// Review finding W-B W9 (SA1+DB1).
    static let customDislikesMaxCount = 10

    /// Unicode scalars stripped from normalized custom-dislike input to
    /// avoid prompt-injection hazards flowing into Gemini context on
    /// every dinner-solve (CWE-1336). Covers:
    ///   - C0/C1 control chars (null, backspace, escape, ...)
    ///   - bidi formatting marks (LRE/RLE/PDF/LRO/RLO, U+202A–U+202E)
    ///   - bidi isolate marks (LRI/RLI/FSI/PDI, U+2066–U+2069)
    ///   - zero-width + directional marks (U+200B–U+200F)
    ///   - line/paragraph separators (U+2028, U+2029)
    ///   - byte-order mark (U+FEFF)
    /// Stripping (not rejecting) is the gentler UX — user copy-pasting
    /// from a richtext source still gets their content through.
    /// Review finding W-B W8 (SA1).
    private static let customDislikeUnicodeHazards: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")
        set.insert(charactersIn: "\u{200B}"..."\u{200F}")
        set.insert("\u{2028}")
        set.insert("\u{2029}")
        set.insert("\u{FEFF}")
        return set
    }()

    // MARK: - Error surface

    var errorMessage: String?

    // MARK: - Init

    init(
        profile: HouseholdProfile,
        dietaryRepo: DietaryRuleRepository = DietaryRuleRepository(),
        equipmentRepo: KitchenEquipmentRepository = KitchenEquipmentRepository(),
        profileRepo: HouseholdProfileRepository = HouseholdProfileRepository(),
    ) {
        self.profile = profile
        self.dietaryRepo = dietaryRepo
        self.equipmentRepo = equipmentRepo
        self.profileRepo = profileRepo

        // Hydrate setup 2 defaults from existing profile (in case user is
        // re-running onboarding after a mid-flow kill).
        self.servingsDefault = profile.servingsDefault > 0 ? profile.servingsDefault : 2
        self.preferredUnits = profile.typedPreferredUnits

        // Hydrate setup 1 selections from already-saved DietaryRules
        // (same "resume where left off" motivation).
        for rule in profile.dietaryRuleArray where rule.isActive {
            switch rule.typedKind {
            case .allergy:
                if let raw = rule.value, let opt = AllergenOption(rawValue: raw) {
                    selectedAllergens.insert(opt)
                }
            case .diet:
                if let raw = rule.value, let opt = DietOption(rawValue: raw) {
                    selectedDiets.insert(opt)
                }
            case .goal:
                if let raw = rule.value, let opt = GoalOption(rawValue: raw) {
                    selectedGoals.insert(opt)
                }
            case .dislike:
                // Predefined dislikes hydrate into the enum set; any
                // value outside the curated 12 lands in `customDislikes`
                // as the free-text entry the user typed via "+ Add".
                // Two-step match + normalize-on-hydrate prevents phantom
                // duplicates from case/whitespace variance in historical
                // rows (e.g. "CILANTRO" + "cilantro" both re-written as
                // distinct rows on next savePreferences()). Review
                // finding W-B W11 (CA1+SA1).
                guard let raw = rule.value else { break }
                let lowered = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if let opt = DislikeOption(rawValue: lowered) {
                    selectedDislikes.insert(opt)
                } else if let opt = DislikeOption.allCases.first(where: {
                    $0.displayName.lowercased() == lowered
                }) {
                    // Historical rows may have been written with
                    // displayName semantics rather than rawValue.
                    selectedDislikes.insert(opt)
                } else if let normalized = normalizeCustomDislike(raw) {
                    customDislikes.insert(normalized)
                }
                // Else: row is empty post-normalization or all-hazard —
                // drop rather than carry invalid state into a fresh
                // dinner-solve payload.
            case .none:
                break
            }
        }

        // Hydrate equipment selection.
        for equipment in profile.kitchenEquipmentArray where equipment.isAvailable {
            if let typed = equipment.typedCode {
                selectedEquipment.insert(typed)
            }
        }
    }

    // MARK: - Validation

    /// Setup 2 requires servingsDefault ≥ 1 (guard against users clearing it).
    var canCompleteKitchenStep: Bool {
        servingsDefault >= 1 && servingsDefault <= 12
    }

    // MARK: - Writes

    /// Commit preferences (allergens/diets/dislikes/goals) to Core Data.
    /// Idempotent — re-runs on back-then-forward are safe. Deactivates
    /// rules no longer selected (isActive=false, not hard-delete — the
    /// repository reactivates in place if the user re-selects later),
    /// then upserts newly-selected rules via `DietaryRuleRepository.add()`
    /// which handles `(household, kind, value)` uniqueness.
    ///
    /// Dislikes split into two iterations: predefined `DislikeOption`
    /// cases write with the enum rawValue; custom strings from the
    /// "+ Add" affordance write the already-normalized free-text value.
    /// Both land as `(kind: .dislike, severity: .soft)` — the severity
    /// field is what prevents the hard-rule validator from treating a
    /// soft preference like an allergen (spec §4.2 orthogonal
    /// hard/soft enforcement axis).
    func savePreferences() throws {
        // Snapshot active rules before mutating. `profile.dietaryRuleArray`
        // is NSManagedObject-backed; `deactivate()` mutates the underlying
        // relationship set, which during iteration is undefined behavior
        // and can miss rows or crash. The `Array(...)` + filter captures
        // a stable list we can safely drive mutations from. Review
        // finding W-H W38 (CA1).
        let activeRules = Array(profile.dietaryRuleArray.filter { $0.isActive })
        // Deactivate any existing rules that are no longer selected.
        for rule in activeRules {
            let stillSelected: Bool
            switch rule.typedKind {
            case .allergy:
                stillSelected = rule.value.flatMap(AllergenOption.init(rawValue:))
                    .map(selectedAllergens.contains) ?? false
            case .diet:
                stillSelected = rule.value.flatMap(DietOption.init(rawValue:))
                    .map(selectedDiets.contains) ?? false
            case .goal:
                stillSelected = rule.value.flatMap(GoalOption.init(rawValue:))
                    .map(selectedGoals.contains) ?? false
            case .dislike:
                guard let raw = rule.value else {
                    stillSelected = false
                    break
                }
                if let opt = DislikeOption(rawValue: raw) {
                    stillSelected = selectedDislikes.contains(opt)
                } else {
                    stillSelected = customDislikes.contains(raw)
                }
            case .none:
                stillSelected = false
            }
            if !stillSelected {
                try dietaryRepo.deactivate(rule)
            }
        }

        // Add newly-selected rules.
        for opt in selectedAllergens {
            try dietaryRepo.add(
                to: profile, kind: .allergy, value: opt.rawValue, severity: .hard,
            )
        }
        for opt in selectedDiets {
            try dietaryRepo.add(
                to: profile, kind: .diet, value: opt.rawValue, severity: .hard,
            )
        }
        for opt in selectedDislikes {
            try dietaryRepo.add(
                to: profile, kind: .dislike, value: opt.rawValue, severity: .soft,
            )
        }
        for raw in customDislikes {
            try dietaryRepo.add(
                to: profile, kind: .dislike, value: raw, severity: .soft,
            )
        }
        for opt in selectedGoals {
            try dietaryRepo.add(
                to: profile, kind: .goal, value: opt.rawValue, severity: .soft,
            )
        }
    }

    /// Commit kitchen + servings to Core Data.
    func saveKitchen() throws {
        // Flip each kitchen code's availability based on current selection.
        // setAvailability() is idempotent.
        for code in KitchenEquipment.CommonCode.allCases {
            try equipmentRepo.setAvailability(
                selectedEquipment.contains(code), code: code, on: profile,
            )
        }

        try profileRepo.update(
            profile,
            servingsDefault: servingsDefault,
            preferredUnits: preferredUnits,
        )
    }

    /// Final step: mark onboardingCompleted = true. Caller (usually the
    /// Setup 2 Continue handler) saves preferences + kitchen first.
    func completeOnboarding() throws {
        try profileRepo.markOnboardingComplete(profile)
    }

    // MARK: - Custom dislike intake

    /// Normalizes a user-entered free-text dislike. Pipeline:
    ///   1. Trim whitespace + lowercase.
    ///   2. Strip Unicode hazards (control/bidi/zero-width/BOM) and
    ///      re-trim in case leading/trailing whitespace surfaced.
    ///   3. Length-cap: grapheme count AND UTF-8 byte count.
    ///   4. Fold into curated DislikeOption if there's an exact match.
    /// Returns nil if the input is empty, too long on either axis, or
    /// collapses to a predefined DislikeOption rawValue / displayName
    /// (in which case the caller can insert into `selectedDislikes`
    /// directly rather than adding a duplicate custom entry).
    func normalizeCustomDislike(_ raw: String) -> String? {
        var trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Strip Unicode prompt-injection hazards before length checks —
        // otherwise zero-width padding could fit under the grapheme cap
        // while still flowing into Gemini context. Re-trim in case the
        // strip exposed leading/trailing whitespace. Review finding
        // W-B W8 (SA1, CWE-1336).
        trimmed = trimmed
            .components(separatedBy: Self.customDislikeUnicodeHazards)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.count <= Self.customDislikeMaxLength,
            trimmed.utf8.count <= Self.customDislikeMaxBytes
        else {
            return nil
        }
        // If the user typed something matching a curated option, fold
        // into the enum set rather than doubling up as a custom entry.
        if DislikeOption.allCases.contains(where: {
            $0.rawValue == trimmed
                || $0.displayName.lowercased() == trimmed
        }) {
            return nil
        }
        return trimmed
    }

    /// Add a free-text custom dislike. Returns `true` if the input was
    /// accepted; `false` if it was empty, too long, or folded into the
    /// curated options. This helper deliberately does NOT cross the
    /// boundary between predefined and custom — if the user's typed
    /// input matches a curated option, the return is `false` and the
    /// UI can insert the matching `DislikeOption` into
    /// `selectedDislikes` directly.
    @discardableResult
    func addCustomDislike(_ raw: String) -> Bool {
        guard let normalized = normalizeCustomDislike(raw) else {
            return false
        }
        // Cap set cardinality. Refuse only when the new entry would
        // grow the set past the cap — re-adding an existing member is
        // always a no-op insert that returns `true`. Review finding
        // W-B W9.
        if !customDislikes.contains(normalized),
           customDislikes.count >= Self.customDislikesMaxCount
        {
            return false
        }
        customDislikes.insert(normalized)
        return true
    }

    // MARK: - Skip

    /// Record a step that was bypassed by a Skip action. `stepID` is
    /// the route identifier of the step that was jumped OVER (e.g.
    /// "setup_kitchen" when the user taps Skip on Setup 1 and fast-
    /// forwards past Setup 2). The current step isn't added — its
    /// state gets saved at skip-time, so it counts as "visited, not
    /// skipped" per decision (a).
    func recordSkip(over stepID: String) {
        guard !skippedSteps.contains(stepID) else { return }
        skippedSteps.append(stepID)
    }

    // MARK: - Telemetry

    /// Fire the `onboarding_completed` PostHog event with the Spec §15
    /// properties: `duration_sec` (wall-clock since VM init) +
    /// `skipped_steps` (array) + `canonical_user_key_hash`. Caller
    /// is responsible for ordering — fire AFTER
    /// `completeOnboarding()` saves durable onboardingCompleted=true,
    /// BEFORE any auto-advance dwell, so a user who kills during the
    /// dwell still counts as completed (decision b).
    ///
    /// Two emission sites:
    ///   - `OnboardingCompletionView.task` (normal flow via Setup 2 +
    ///     Skip shortcuts)
    ///   - `OnboardingRoot` "See a sample" Welcome handler (stub path
    ///     that bypasses Setup 1/2 entirely)
    /// RootCoordinator.handleOnboardingFinished no longer emits —
    /// ownership moved here so both ViewModel-mediated paths fire
    /// through a single helper.
    func fireOnboardingCompletedEvent() {
        // Belt-and-suspenders idempotency — even if both callers
        // (`OnboardingCompletionView.task` + WelcomeView "See a sample"
        // handler) are debounced, NavigationStack's `.task` re-fires
        // on view re-appearance and a double-tap in the handler queue
        // can land two dispatches before the first completes. Single
        // flag covers both cases.
        guard !hasFiredCompletedEvent else { return }
        hasFiredCompletedEvent = true

        let durationSec = max(0, Int(Date().timeIntervalSince(onboardingStartedAt)))
        // Omit `canonical_user_key_hash` entirely when the profile lacks a
        // canonicalUserKey (unbootstrapped race, or install-only identity
        // that hasn't re-resolved). Emitting `""` pollutes PostHog funnel
        // filters and turns this into a quiet cohort of "anonymous
        // completions that aren't actually anonymous". Review finding
        // W-A W7 (CR3).
        var properties: [String: Any] = [
            "duration_sec": durationSec,
            "skipped_steps": skippedSteps,
        ]
        if let key = profile.canonicalUserKey {
            properties["canonical_user_key_hash"] = CanonicalKeyHash.hash(key)
        }
        PostHogClient.shared.capture(.onboardingCompleted, properties: properties)
    }
}
