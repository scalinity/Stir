// PantryItemRepository
//
// CRUD over pantry rows, scoped to a HouseholdProfile.
//
// Step-3 added the scan write path (`upsertFromScan`); step 4 added
// soft-delete; the pantry management surface (ADR 0028) added read,
// count, manual insert, and edit. Step 7 will layer leftovers +
// expiration on top.
//
// Upsert semantics (used by both scan and manual paths): within a
// household, an ingredient is keyed on
// (canonicalIngredientSlug || displayName_lowercased). Existing
// rows bump lastSeenAt / amountText; new rows insert.

import CoreData
import Foundation
import OSLog

@MainActor
final class PantryItemRepository {
    /// SCA-101 (a) review S2: page size for `fetchAll`'s row faulting.
    /// 50 ≈ a typical screen of pantry rows on Pro at ~16pt row
    /// height + section headers; tunable. Tighten if Instruments
    /// shows the in-view set is consistently smaller; widen if the
    /// scroll-to-load delay becomes visible.
    private static let pantryFaultBatchSize = 50

    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    struct ScanIngredient: Sendable {
        let displayName: String
        let canonicalSlug: String?
        let amountText: String?
        let confidence: Double
        let parseConfidence: PantryItem.ParseConfidence
    }

    /// Outcome of `upsertFromScan` carrying the persisted rows AND the
    /// number of ingredients whose `.likelyStaple` parseConfidence was
    /// downgraded to `.ephemeral` because the household's
    /// `.remembered` slot count would otherwise exceed `cap`. Caller
    /// surfaces `truncatedToEphemeral` as a "you're at your pantry
    /// limit — these stayed for tonight only" toast (review C1).
    struct ScanUpsertOutcome: Sendable {
        let rows: [PantryItem]
        let truncatedToEphemeral: Int
    }

    /// Upsert a batch of confirmed-by-user ingredients onto the household's
    /// pantry. Existing rows bump lastSeenAt + userConfirmed=true; new rows
    /// insert with source=.scan. All in one save.
    ///
    /// Cap enforcement: when `cap` is provided, NEW rows that would be
    /// `.remembered` (i.e. parseConfidence == .likelyStaple) downgrade
    /// to `.ephemeral` once the running cap is exhausted, rather than
    /// silently inserting unbounded `.remembered` rows. Existing-row
    /// upserts and `.ephemeral` rows are unaffected by the cap. Caller
    /// passes the entitlement service's `(usedRemembered, cap)` pair;
    /// pass `cap: nil` to skip enforcement (legacy/test paths).
    ///
    /// Without this gate, a Free user (cap 25) at quota could scan a
    /// fridge full of staples and the repo would happily insert all
    /// of them as `.remembered` — the next manual-add would refuse
    /// with "cap reached" while the header read e.g. "73 of 25 saved",
    /// breaking the upsell story for the highest-volume populate path
    /// (review C1).
    func upsertFromScan(
        _ ingredients: [ScanIngredient],
        on household: HouseholdProfile,
        usedRemembered: Int = 0,
        cap: Int? = nil,
    ) throws -> ScanUpsertOutcome {
        let context = controller.viewContext
        let now = Date()
        var results: [PantryItem] = []
        var liveUsed = usedRemembered
        var truncated = 0

        for ing in ingredients {
            let match = try fetchExisting(
                slug: ing.canonicalSlug,
                displayName: ing.displayName,
                on: household,
                context: context,
            )

            if let existing = match {
                existing.lastSeenAt = now
                existing.updatedAt = now
                existing.userConfirmed = true
                existing.confidence = max(existing.confidence, ing.confidence)
                // SCA-23: re-scan amount refresh. Previously this only
                // wrote when the existing amountText was blank, which
                // silently dropped fresher info ("almost gone"
                // replacing "1 jar"). Freshness wins now: any non-
                // empty new amountText overwrites the existing value.
                // Trim defensively so a whitespace-only new value
                // doesn't blank out a real existing one.
                if let newAmount = ing.amountText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !newAmount.isEmpty {
                    if let prior = existing.amountText, prior != newAmount {
                        Logger.coreData.debug(
                            "PantryItemRepository upsertFromScan refreshed amountText for slug=\(ing.canonicalSlug ?? "", privacy: .public)",
                        )
                    }
                    existing.amountText = newAmount
                }
                results.append(existing)
                continue
            }

            // Decide the new row's memory state with cap awareness. The
            // model's parseConfidence is the proposal; the cap is the
            // ceiling.
            let proposed: PantryItem.MemoryState =
                ing.parseConfidence == .likelyStaple ? .remembered : .ephemeral
            let resolved: PantryItem.MemoryState
            if proposed == .remembered, let cap, liveUsed >= cap {
                resolved = .ephemeral
                truncated += 1
            } else {
                resolved = proposed
                if resolved == .remembered {
                    liveUsed += 1
                }
            }

            let row = PantryItem(context: context)
            row.id = UUID()
            row.household = household
            row.canonicalIngredientSlug = ing.canonicalSlug ?? ""
            row.displayName = ing.displayName
            row.amountText = ing.amountText
            row.confidence = ing.confidence
            row.userConfirmed = true
            row.typedSource = .scan
            row.typedMemoryState = resolved
            // SCA-22: ephemeral rows auto-expire on the next morning's
            // foreground sweep. `.remembered` rows leave expiresAt nil
            // (standing pantry, no time-based decay).
            if resolved == .ephemeral {
                row.expiresAt = Self.expiresAtForEphemeral(now: now)
            }
            row.lastSeenAt = now
            row.createdAt = now
            row.updatedAt = now
            results.append(row)
        }

        try controller.save()
        Logger.coreData.info(
            "PantryItemRepository upserted \(results.count, privacy: .public) rows (\(truncated, privacy: .public) downgraded to ephemeral due to cap)",
        )
        return ScanUpsertOutcome(rows: results, truncatedToEphemeral: truncated)
    }

    /// Soft-delete a pantry item.
    func softDelete(_ item: PantryItem) throws {
        applySoftDeleteFields(item, at: Date())
        try controller.save()
    }

    /// Bump `lastSeenAt` on the pantry row matching the given name +
    /// optional slug. Used by `SubstitutionSheetViewModel.accept` to
    /// signal that the swap-in ingredient was just used (SCA-24).
    /// Recency drives downstream voice-prompt prioritization
    /// (RealtimeSession's up-to-1000-item walk uses lastSeenAt).
    ///
    /// Match is the same three-tier chain as `fetchExisting`. Returns
    /// `true` if a row was matched + bumped, `false` on no match.
    /// No-op (and no save) on no match — substitution accept that
    /// references an ingredient the user doesn't have remembered
    /// shouldn't generate a phantom CloudKit notification.
    @discardableResult
    func bumpLastSeenAt(
        displayName: String,
        slug: String? = nil,
        on household: HouseholdProfile,
        now: Date = Date(),
    ) throws -> Bool {
        let context = controller.viewContext
        guard let row = try fetchExisting(
            slug: slug,
            displayName: displayName,
            on: household,
            context: context,
        ) else {
            return false
        }
        row.lastSeenAt = now
        row.updatedAt = now
        try controller.save()
        return true
    }

    /// Bulk soft-delete every non-deleted PantryItem scoped to the
    /// household. Used by the "Delete all items" affordance on
    /// `PantryListView` (PantryListViewModel.deleteAllItems). Routes
    /// through `applySoftDeleteFields` for contract-consistency with
    /// single-row `softDelete` and the consume-time delete path —
    /// future side-effects on soft-delete (audit log, CloudKit hint)
    /// inherit on this path too. Single save at end so the entire
    /// batch lands as one CloudKit propagation unit (vs N individual
    /// tombstones flooding the sync queue). Idempotent: re-calling
    /// after all rows are deleted returns 0 because the fetch
    /// predicate filters `deletedAt == nil`.
    @discardableResult
    func softDeleteAll(for household: HouseholdProfile, now: Date = Date()) throws -> Int {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "household == %@", household),
            NSPredicate(format: "deletedAt == nil"),
        ])
        let context = controller.viewContext
        let rows: [PantryItem]
        do {
            rows = try context.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
        guard !rows.isEmpty else { return 0 }
        for row in rows {
            applySoftDeleteFields(row, at: now)
        }
        try controller.save()
        Logger.coreData.info("PantryItemRepository softDeleteAll: \(rows.count, privacy: .public) rows soft-deleted")
        return rows.count
    }

    /// Apply soft-delete fields without saving. Shared between
    /// `softDelete(_:)` (which saves immediately) and the ephemeral-
    /// delete branch in `consumeForRecipe` (which batches saves at the
    /// end of a multi-row mutation). Centralizing the field writes
    /// keeps the soft-delete contract in one place — if we ever add
    /// audit logging or a CloudKit hint, both paths inherit it.
    private func applySoftDeleteFields(_ item: PantryItem, at when: Date) {
        item.deletedAt = when
        item.updatedAt = when
    }

    /// Outcome of `consumeForRecipe`. Carries the affected rows so
    /// callers can surface a "Pantry updated · N items used" toast or
    /// drive a future undo affordance (deferred to SCA-27), and a
    /// count summary suitable for `pantry_auto_consume_resolved`
    /// telemetry. Counts are derived from the array lengths plus the
    /// pre-walked `unmatched` / `optionalSkipped` / `substitutedCount`
    /// fields so the caller doesn't re-traverse to emit telemetry.
    struct ConsumeOutcome: Equatable, Sendable {
        let ephemeralDeleted: [PantryItem]
        let rememberedBumped: [PantryItem]
        /// Effective ingredients (post-substitution, post-optional-skip)
        /// that produced no pantry-row match.
        let unmatched: Int
        /// Recipe ingredients skipped because `isOptional == true`.
        let optionalSkipped: Int
        /// Effective ingredients that came from an accepted
        /// `SubstitutionEvent` rather than the original recipe row.
        let substitutedCount: Int

        /// Telemetry projection — feed straight into PostHog.
        var telemetryProperties: [String: Any] {
            [
                "ephemeral_deleted": ephemeralDeleted.count,
                "remembered_bumped": rememberedBumped.count,
                "unmatched": unmatched,
                "optional_skipped": optionalSkipped,
                "substituted_count": substitutedCount,
            ]
        }
    }

    /// Auto-consume pantry items based on a completed recipe + the
    /// session's accepted substitutions. ADR 0029 spells out the rule;
    /// summary:
    ///
    /// - For each `RecipeIngredient` on the plan, skip if `isOptional`.
    /// - If an accepted `SubstitutionEvent` exists for the ingredient,
    ///   use the swap (`acceptedAlternativeText`, slug=nil) as the
    ///   "what was consumed" name. The original ingredient is left
    ///   alone — we don't infer "user has X" from "user chose not to
    ///   use X".
    /// - Look up via the existing `fetchExisting(slug:displayName:)`
    ///   so manual rows (slug=`""`) remain matchable through the name
    ///   fallback.
    /// - Apply by `typedMemoryState`:
    ///   * `.ephemeral` → soft-delete (recipe consumed a today-only thing)
    ///   * `.remembered` → bump `lastSeenAt = now` (standing items
    ///     aren't depleted by one cook; recency improves voice prompt
    ///     prioritization)
    ///   * `.expired` / `.unknown` → no-op (state is suspect; SCA-22's
    ///     `expiresAt` sweep is the only writer for those transitions)
    ///   * no match → no-op
    ///
    /// The `.ephemeral`-only delete rule is the safety mechanism that
    /// lets us skip both the upfront "mark items used" prompt and the
    /// v1 undo (SCA-27): standing pantry items are never destructively
    /// touched, so worst case is one ephemeral row deleted that the
    /// user actually still has — bounded recovery cost.
    ///
    /// All mutations land in a single `controller.save()`. Returns
    /// `ConsumeOutcome` carrying the affected rows + the count summary
    /// for telemetry. A no-op call (empty recipe, all optional, no
    /// matches) returns an all-zeros outcome and still requires a save
    /// only if there are bumps; the save is gated on actual mutations
    /// to avoid spurious CloudKit notifications.
    func consumeForRecipe(
        _ plan: RecipePlan,
        substitutions: [SubstitutionEvent],
        on household: HouseholdProfile,
        now: Date = Date(),
    ) throws -> ConsumeOutcome {
        let context = controller.viewContext

        // Build a lookup from RecipeIngredient → acceptedAlternativeText
        // so the per-ingredient walk doesn't repeatedly scan the
        // substitutions array. Only `.accepted` events count; pending
        // and rejected leave the original ingredient in place.
        var swapByIngredientID: [NSManagedObjectID: String] = [:]
        for event in substitutions where event.typedAcceptance == .accepted {
            guard
                let ingredient = event.recipeIngredient,
                let swap = event.acceptedAlternativeText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !swap.isEmpty
            else { continue }
            swapByIngredientID[ingredient.objectID] = swap
        }

        var ephemeralDeleted: [PantryItem] = []
        var rememberedBumped: [PantryItem] = []
        var unmatched = 0
        var optionalSkipped = 0
        var substitutedCount = 0

        for ingredient in plan.ingredientArray {
            if ingredient.isOptional {
                optionalSkipped += 1
                continue
            }

            // Effective name + slug. Substitution swaps drop the slug
            // because `acceptedAlternativeText` is free-form user/model
            // text with no canonical mapping — the name fallback in
            // `fetchExisting` is the only viable match path.
            let effectiveName: String
            let effectiveSlug: String?
            if let swap = swapByIngredientID[ingredient.objectID] {
                effectiveName = swap
                effectiveSlug = nil
                substitutedCount += 1
            } else {
                effectiveName = ingredient.displayName ?? ""
                effectiveSlug = ingredient.canonicalIngredientSlug
            }

            guard !effectiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // A recipe row with a blank effective name (model
                // hallucination, malformed import, or rejected swap
                // with empty original) can't be matched against the
                // pantry. Count as `unmatched` so the four counters
                // sum to the ingredients walked — keeps the dashboard
                // ratio in ADR 0029's "Trigger to revisit" honest.
                // The unmatched bucket is the catch-all for "no
                // pantry-row match" regardless of cause: malformed
                // input, fetch failure, or genuine no-match.
                unmatched += 1
                continue
            }

            let match: PantryItem?
            do {
                match = try fetchExisting(
                    slug: effectiveSlug,
                    displayName: effectiveName,
                    on: household,
                    context: context,
                )
            } catch {
                // A fetch failure on one ingredient shouldn't sink the
                // whole consume — log and treat as unmatched. The
                // session is already complete; partial pantry mutation
                // is better than reverting the whole batch.
                Logger.coreData.warning(
                    "consumeForRecipe fetchExisting failed for one ingredient: \(error.localizedDescription, privacy: .private)",
                )
                unmatched += 1
                continue
            }

            guard let row = match, row.deletedAt == nil else {
                unmatched += 1
                continue
            }

            switch row.typedMemoryState {
            case .ephemeral:
                applySoftDeleteFields(row, at: now)
                ephemeralDeleted.append(row)
            case .remembered:
                row.lastSeenAt = now
                row.updatedAt = now
                rememberedBumped.append(row)
            case .expired, .unknown:
                // Don't auto-mutate suspect states — SCA-22's
                // `expiresAt` sweep is the only writer for `.expired`
                // transitions; `.unknown` should never appear in
                // practice but is left untouched as a defensive
                // default.
                break
            }
        }

        // Gate the save on actual mutations so a no-op call doesn't
        // emit a spurious CloudKit change notification.
        if !ephemeralDeleted.isEmpty || !rememberedBumped.isEmpty {
            try controller.save()
        }

        Logger.coreData.info(
            "consumeForRecipe: \(ephemeralDeleted.count, privacy: .public) deleted, \(rememberedBumped.count, privacy: .public) bumped, \(unmatched, privacy: .public) unmatched, \(optionalSkipped, privacy: .public) optional, \(substitutedCount, privacy: .public) substituted",
        )

        return ConsumeOutcome(
            ephemeralDeleted: ephemeralDeleted,
            rememberedBumped: rememberedBumped,
            unmatched: unmatched,
            optionalSkipped: optionalSkipped,
            substitutedCount: substitutedCount,
        )
    }

    /// Read all PantryItem rows scoped to a household, sorted by
    /// `lastSeenAt` descending (most-recently-seen first). Soft-deleted
    /// rows are filtered by default; pass `includeSoftDeleted: true` for
    /// admin / debug surfaces.
    ///
    /// Returns NSManagedObjects (not value-types) because the pantry view
    /// uses `@ObservedObject` rows for live KVO redraws on edit — same
    /// pattern as `GroceryListView.AisleRow` consuming `GroceryItem`
    /// directly. Tonight Home uses a value-type projection because its
    /// hero card stores the dish across the lifetime of the screen and
    /// would race with CloudKit conflict resolution; the pantry list
    /// re-fetches on every view appear, so the fault risk is bounded.
    func fetchAll(
        for household: HouseholdProfile,
        includeSoftDeleted: Bool = false,
    ) throws -> [PantryItem] {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        var predicates: [NSPredicate] = [
            NSPredicate(format: "household == %@", household),
        ]
        if !includeSoftDeleted {
            predicates.append(NSPredicate(format: "deletedAt == nil"))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "lastSeenAt", ascending: false),
            NSSortDescriptor(key: "displayName", ascending: true),
        ]
        // SCA-101 (a): fault rows in pages of `pantryFaultBatchSize`.
        // Pro-tier 1000-row pantries pay only for what scrolls into
        // view; faulting cost dominated the warm-cache profile
        // pre-batch. Free / Premium (≤250 rows) are unaffected —
        // the array still materialises in one fetch round-trip, the
        // difference is per-row property realisation.
        request.fetchBatchSize = Self.pantryFaultBatchSize
        do {
            return try controller.viewContext.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Counts rows that count against the standing pantry cap (Free 25 /
    /// Premium 250 / Pro 1000 — CLAUDE.md authoritative). Counts only
    /// `.remembered`, non-deleted rows; everything else (`.ephemeral`,
    /// `.expired`, `.unknown`, soft-deleted) is excluded by the positive
    /// `memoryState == 'remembered'` predicate. Used by
    /// `PantryListViewModel` for client-side quota enforcement on
    /// manual adds.
    func countRemembered(for household: HouseholdProfile) throws -> Int {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "household == %@", household),
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "memoryState == %@", PantryItem.MemoryState.remembered.rawValue),
        ])
        do {
            return try controller.viewContext.count(for: request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Outcome of an `insertManual` call. Lets the caller route a
    /// cap-rejected attempt to the paywall while distinguishing it from
    /// a transient persistence failure (a paid user with a flaky save
    /// must not be upsold to Premium — review C4 / prior PantryAddResult
    /// fix). `.upserted` covers the dedupe path: an existing row's
    /// fields were bumped, no new row was created, so the cap was not
    /// consulted.
    enum InsertManualOutcome: Equatable {
        case inserted(PantryItem)
        case upserted(PantryItem)
        case capReached
    }

    /// Insert (or upsert) a manually-added pantry item with cap
    /// enforcement baked in. Dedupes by slug-then-name (see
    /// `fetchExisting`). Manual inserts always set
    /// `userConfirmed = true` and `confidence = 1.0` (the user typed
    /// it themselves; no AI hedge needed).
    ///
    /// Cap-bookkeeping contract: the caller passes `(used, cap)` —
    /// the entitlement service is the source of truth and it lives
    /// outside the repo, so we don't read it directly. The cap is
    /// checked ONLY on the new-row branch; an upsert against an
    /// existing remembered row is allowed even when `used == cap`,
    /// because no row would be added (review C4: re-typing an
    /// existing remembered name at cap was wrongly routing paid
    /// users to the paywall). Pass `cap: nil` to skip enforcement
    /// entirely (used by tests + non-cap-bound paths).
    ///
    /// Validation: rejects empty-after-trim displayName via
    /// `StirError.validation`. Length caps on displayName (200) and
    /// amountText (100) prevent self-DoS-via-paste from corrupting
    /// CloudKit sync (review W10 — CKErrorPartialFailure on oversize
    /// CloudKit String fields).
    func insertManual(
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState = .remembered,
        on household: HouseholdProfile,
        usedRemembered: Int? = nil,
        cap: Int? = nil,
    ) throws -> InsertManualOutcome {
        let context = controller.viewContext
        let now = Date()
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StirError.validation(
                fieldErrors: [FieldError(field: "displayName", issue: "must not be empty")],
                message: "displayName cannot be empty",
            )
        }
        guard trimmedName.count <= Self.maxDisplayNameLength else {
            throw StirError.validation(
                fieldErrors: [FieldError(
                    field: "displayName",
                    issue: "must be \(Self.maxDisplayNameLength) characters or fewer",
                )],
                message: "displayName too long",
            )
        }
        let trimmedAmount = amountText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedAmount, trimmedAmount.count > Self.maxAmountTextLength {
            throw StirError.validation(
                fieldErrors: [FieldError(
                    field: "amountText",
                    issue: "must be \(Self.maxAmountTextLength) characters or fewer",
                )],
                message: "amountText too long",
            )
        }

        if let existing = try fetchExisting(
            slug: nil,
            displayName: trimmedName,
            on: household,
            context: context,
        ) {
            existing.lastSeenAt = now
            existing.updatedAt = now
            existing.userConfirmed = true
            existing.confidence = 1.0
            existing.typedMemoryState = memoryState
            if let trimmedAmount, !trimmedAmount.isEmpty {
                existing.amountText = trimmedAmount
            }
            try controller.save()
            return .upserted(existing)
        }

        // New-row branch — apply cap only here. `.ephemeral` /
        // `.expired` / `.unknown` rows skip the cap entirely (only
        // `.remembered` counts against the standing-cap, mirroring
        // `countRemembered`).
        if memoryState == .remembered, let used = usedRemembered, let cap, used >= cap {
            return .capReached
        }

        let row = PantryItem(context: context)
        row.id = UUID()
        row.household = household
        row.displayName = trimmedName
        row.canonicalIngredientSlug = ""
        row.amountText = (trimmedAmount?.isEmpty ?? true) ? nil : trimmedAmount
        row.confidence = 1.0
        row.userConfirmed = true
        row.typedSource = .manual
        row.typedMemoryState = memoryState
        // SCA-22: ephemeral rows auto-expire daily; `.remembered` rows
        // leave expiresAt nil. Same rule applies to manually-added
        // rows so a manual "today only" entry doesn't outlive the
        // dinner cycle it was added for.
        if memoryState == .ephemeral {
            row.expiresAt = Self.expiresAtForEphemeral(now: now)
        }
        row.lastSeenAt = now
        row.createdAt = now
        row.updatedAt = now
        try controller.save()
        return .inserted(row)
    }

    /// Compute the expiry timestamp for a newly-inserted `.ephemeral`
    /// pantry row (SCA-22). The semantics are "today only" — items
    /// scanned for tonight's cooking should auto-clean by the next
    /// morning's app foreground.
    ///
    /// Formula: `startOfDay(now + 30h) + 6h`, evaluated in the user's
    /// local calendar. Concretely:
    ///   - Scan at 8am Mon: now+30h = Tue 2pm; startOfDay = Tue 0am;
    ///     +6h = Tue 6am. Window: 22h.
    ///   - Scan at 8pm Mon: now+30h = Wed 2am; startOfDay = Wed 0am;
    ///     +6h = Wed 6am. Window: 34h.
    ///   - Scan at 11pm Mon: now+30h = Wed 5am; startOfDay = Wed 0am;
    ///     +6h = Wed 6am. Window: 31h.
    ///
    /// Why not `startOfDay(now + 24h) + 6h`: a naive 24h offset gives
    /// late-night scans a window that can be ≤8h ("scan at 11pm Mon
    /// → expire Tue 6am"). The 30h offset guarantees the window
    /// crosses two midnights for any scan time, so the expiry always
    /// lands on a morning AFTER the cook session, not during it.
    ///
    /// Why 6am as the time-of-day anchor: empirically a quiet hour in
    /// kitchen-app usage. Foreground sweep on first morning open
    /// (typically 6-8am) finds the row already past expiry.
    private static func expiresAtForEphemeral(now: Date) -> Date {
        let calendar = Calendar.current
        let plus30h = now.addingTimeInterval(30 * 3600)
        let nextMorningStart = calendar.startOfDay(for: plus30h)
        let candidate = nextMorningStart.addingTimeInterval(6 * 3600)
        // SCA-178 (test_upsertFromScan_ephemeralRow_setsExpiresAt
        // floor invariant): `Calendar.startOfDay(for:)` snaps BACKWARD to
        // the same calendar day's midnight, so for `now` between roughly
        // 6am and 6pm the candidate can land 12-18h in the future —
        // shorter than the "survive a typical cook session" floor the
        // ephemeral-state contract promises (and shorter than the
        // foreground sweep's 24h cadence assumes). Bump one day forward
        // whenever the candidate falls inside the 18h floor.
        let minimum = now.addingTimeInterval(18 * 3600)
        if candidate < minimum {
            return candidate.addingTimeInterval(24 * 3600)
        }
        return candidate
    }

    /// Fetch ephemeral rows whose `expiresAt` is in the trailing 48-hour
    /// window — i.e. not yet expired but close enough that the user
    /// should burn them soon (SCA-64). Pre-existing soft-deletion sweep
    /// covers `expiresAt < now`; this carves out the lookahead window.
    /// Caller (UseSoonScheduler) decides what "soon" means; we accept
    /// it as a parameter so future tunings don't re-touch the
    /// repository surface.
    ///
    /// Spec §8 row 944 says "remembered item with `expiresAt <= 48h`",
    /// but `.remembered` rows leave `expiresAt` nil per the
    /// `.ephemeral` carve-out below — the spec text was approximate.
    /// The use-soon trigger applies to ephemeral (freshness-tracked)
    /// rows; remembered staples don't have a freshness clock and are
    /// out of scope.
    func fetchExpiringSoon(
        within window: TimeInterval = 48 * 3600,
        now: Date = Date(),
        for household: HouseholdProfile,
    ) throws -> [PantryItem] {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "household == %@", household),
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "memoryState == %@", PantryItem.MemoryState.ephemeral.rawValue),
            NSPredicate(
                format: "expiresAt != nil AND expiresAt > %@ AND expiresAt <= %@",
                now as NSDate,
                now.addingTimeInterval(window) as NSDate,
            ),
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "expiresAt", ascending: true)]
        do {
            return try controller.viewContext.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Bulk-soft-delete ephemeral pantry rows past their expiresAt.
    /// Wired to the foreground sweep at app `.scenePhase == .active`
    /// (SCA-22). Idempotent — re-call within the same minute returns
    /// 0 because the predicate filters `deletedAt == nil`. Routes
    /// through `applySoftDeleteFields` for soft-delete contract
    /// consistency. One save at the end so the entire batch lands
    /// as a single CloudKit propagation unit.
    ///
    /// Only `.ephemeral` rows are affected. `.remembered` rows with
    /// a non-nil expiresAt (a hypothetical that no current code path
    /// produces) are intentionally LEFT ALONE — the sweep is
    /// memoryState-typed so a future "remembered with explicit
    /// expiry" feature can opt-in via a separate sweep call.
    @discardableResult
    func softDeleteExpired(now: Date = Date(), for household: HouseholdProfile) throws -> Int {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "household == %@", household),
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "memoryState == %@", PantryItem.MemoryState.ephemeral.rawValue),
            NSPredicate(format: "expiresAt != nil AND expiresAt < %@", now as NSDate),
        ])
        let context = controller.viewContext
        let rows: [PantryItem]
        do {
            rows = try context.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
        guard !rows.isEmpty else { return 0 }
        for row in rows {
            applySoftDeleteFields(row, at: now)
        }
        try controller.save()
        Logger.coreData.info("PantryItemRepository softDeleteExpired: \(rows.count, privacy: .public) ephemeral rows swept")
        return rows.count
    }

    /// Length caps on user-typed pantry strings. Prevents a paste of
    /// (e.g.) a 1MB string from corrupting CloudKit sync — CloudKit's
    /// String fields tolerate ≤1MB but the sync envelope is much
    /// smaller and a CKErrorPartialFailure can block the entire batch.
    /// Values are advisory (not Core Data attribute constraints) so
    /// existing CloudKit-replicated rows that pre-date this guard
    /// still load — only writes are bounded.
    static let maxDisplayNameLength: Int = 200
    static let maxAmountTextLength: Int = 100

    /// Mutate an existing pantry row's user-editable fields. Used by
    /// `PantryEditSheet`. Bumps `updatedAt` so CloudKit sync propagates.
    /// Trims whitespace and reapplies the same nil-on-blank rule as
    /// `insertManual`.
    func update(
        _ item: PantryItem,
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState,
    ) throws {
        guard item.deletedAt == nil else {
            throw StirError.validation(
                fieldErrors: [FieldError(field: "deletedAt", issue: "cannot edit a soft-deleted item")],
                message: "Cannot edit a soft-deleted PantryItem",
            )
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StirError.validation(
                fieldErrors: [FieldError(field: "displayName", issue: "must not be empty")],
                message: "displayName cannot be empty",
            )
        }
        guard trimmedName.count <= Self.maxDisplayNameLength else {
            throw StirError.validation(
                fieldErrors: [FieldError(
                    field: "displayName",
                    issue: "must be \(Self.maxDisplayNameLength) characters or fewer",
                )],
                message: "displayName too long",
            )
        }
        let trimmedAmount = amountText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedAmount, trimmedAmount.count > Self.maxAmountTextLength {
            throw StirError.validation(
                fieldErrors: [FieldError(
                    field: "amountText",
                    issue: "must be \(Self.maxAmountTextLength) characters or fewer",
                )],
                message: "amountText too long",
            )
        }
        item.displayName = trimmedName
        item.amountText = (trimmedAmount?.isEmpty ?? true) ? nil : trimmedAmount
        item.typedMemoryState = memoryState
        item.updatedAt = Date()
        try controller.save()
    }

    // MARK: - Private

    /// Look up an existing PantryItem to dedupe against. Three-tier
    /// match strategy, cheapest first:
    ///
    /// **Tier 1 — slug match.** If a non-empty `slug` is provided,
    /// fetch by `canonicalIngredientSlug` first. Scan-vs-scan dedupes
    /// reliably here when both calls came from the same canonical
    /// vocabulary.
    /// **Tier 2 — exact case-insensitive name match.** Falls back to
    /// `displayName ==[c]`. Catches manual rows (slug = `""`) that a
    /// scan with a slug would otherwise miss, and round-trips two
    /// scans of the same ingredient that produced different slugs.
    /// **Tier 3 — tokenized normalized match (SCA-26).** Only runs
    /// when both prior tiers miss. Fetches all non-deleted rows
    /// scoped to the household and walks them in memory comparing
    /// `pantryMatchTokens()` for sorted-set equality. Catches
    /// "Red Onion" ↔ "red onions" ↔ "Red-Onion!" without false-
    /// matching "olive oil" ↔ "olive oil spray" (different token
    /// counts → set inequality). The O(N) walk is bounded — only
    /// the failure path of Tiers 1+2 — and N is capped by tier:
    /// Free 25, Premium 250, Pro 1000.
    ///
    /// Without Tier 3, ADR 0029's auto-consume routinely missed
    /// matches when dinner-solve's recipe ingredient names diverged
    /// from pantry-parse's stored names (different plural form,
    /// different modifier order, hyphenation differences). Trigger
    /// fired in the field 2026-05-06 — see SCA-26.
    private func fetchExisting(
        slug: String?,
        displayName: String,
        on household: HouseholdProfile,
        context: NSManagedObjectContext,
    ) throws -> PantryItem? {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        request.fetchLimit = 1

        let byHousehold = NSPredicate(format: "household == %@", household)
        let notDeleted = NSPredicate(format: "deletedAt == nil")
        let byName = NSPredicate(format: "displayName ==[c] %@", displayName)

        if let slug, !slug.isEmpty {
            // Tier 1: slug match.
            let bySlug = NSPredicate(format: "canonicalIngredientSlug == %@", slug)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted, bySlug])
            do {
                if let match = try context.fetch(request).first {
                    return match
                }
            } catch {
                throw StirError.coreData(underlying: error)
            }
            // Tier 2 (after slug miss): exact case-insensitive name.
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted, byName])
        } else {
            // Tier 2 only: name match — slug-less inputs (manual add,
            // substitution swap with empty slug).
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted, byName])
        }

        do {
            if let match = try context.fetch(request).first {
                return match
            }
        } catch {
            throw StirError.coreData(underlying: error)
        }

        // Tier 3: tokenized normalized match. Only reached when slug
        // (if any) and exact-name both missed.
        let lookupTokens = displayName.pantryMatchTokens()
        guard !lookupTokens.isEmpty else { return nil }

        let allRequest = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        allRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted])
        do {
            let allRows = try context.fetch(allRequest)
            return allRows.first { row in
                guard let name = row.displayName else { return false }
                return name.pantryMatchTokens() == lookupTokens
            }
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }
}
