// HouseholdProfile type-safety extensions.
//
// Wraps the string-typed Core Data attribute `preferredUnits` in a typed enum
// and exposes deterministic accessors for the NSSet relationships. All heavy
// validation still lives in `HouseholdProfileRepository`; this file is about
// making the raw NSManagedObject ergonomic from Swift.

import CoreData
import Foundation

extension HouseholdProfile {
    enum PreferredUnits: String, CaseIterable, Sendable {
        case imperial
        case metric
    }

    var typedPreferredUnits: PreferredUnits {
        get { preferredUnits.flatMap(PreferredUnits.init(rawValue:)) ?? .imperial }
        set { preferredUnits = newValue.rawValue }
    }

    /// DietaryRule array derived from the NSSet relationship, sorted by `createdAt`.
    var dietaryRuleArray: [DietaryRule] {
        let set = dietaryRules as? Set<DietaryRule> ?? []
        return set.sorted { (a, b) in
            (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
        }
    }

    /// KitchenEquipment array derived from the NSSet relationship, sorted by `code`.
    var kitchenEquipmentArray: [KitchenEquipment] {
        let set = kitchenEquipment as? Set<KitchenEquipment> ?? []
        return set.sorted { (a, b) in (a.code ?? "") < (b.code ?? "") }
    }

    /// Whether the profile is soft-deleted (spec §4.1: deletedAt non-nil).
    var isSoftDeleted: Bool { deletedAt != nil }

    // MARK: - Voice context shared seam (P2-I)

    /// Canonical voice-context projection used by both the Realtime mint
    /// (system-instruction context) AND the voice-path substitution
    /// round-trip. Prior to P2-I (2026-04-23) these lived as three
    /// separate implementations in CookModeViewModel, RealtimeSession
    /// (mint), and RealtimeSession (dispatchSubstitution) with
    /// **inconsistent pantry filters**: mint + VM used
    /// `deletedAt == nil && userConfirmed`, substitution used
    /// `!displayName.isEmpty`. The filter drift was a latent
    /// correctness gap — unconfirmed or soft-deleted pantry items
    /// could reach the substitution validator.
    ///
    /// Single filter rule: pantry item is included iff it is
    /// `userConfirmed`, NOT soft-deleted, AND has a non-empty
    /// `displayName`. Dietary rules are included verbatim (all are
    /// user-confirmed at onboarding/settings time). Equipment is
    /// filtered by the stored `isAvailable` flag.
    ///
    /// The returned value is a small value-type seam; DTOs map from
    /// it rather than reading Core Data directly.
    ///
    /// SCA-431: the pantry-filter half of this projection is now
    /// shared with the sheet substitution + grocery generate paths
    /// via `confirmedActivePantry()`. All three AI-invocation sites
    /// now consume the same predicate; any future code that re-
    /// inlines `.filter { $0.deletedAt == nil && $0.userConfirmed }`
    /// is reintroducing the same drift class SCA-424 caught.
    func voiceContextSnapshot() -> VoiceContextSnapshot {
        let rules: [VoiceContextSnapshot.DietaryRule] = dietaryRuleArray.map {
            VoiceContextSnapshot.DietaryRule(
                kind: $0.kind ?? "",
                value: $0.value ?? "",
                severity: $0.severity ?? "soft",
            )
        }
        let equipment: [String] = kitchenEquipmentArray
            .filter { $0.isAvailable }
            .compactMap { $0.code }
        let pantry: [VoiceContextSnapshot.PantryItem] = confirmedActivePantry()
            .compactMap { item in
                guard let display = item.displayName, !display.isEmpty else { return nil }
                return VoiceContextSnapshot.PantryItem(
                    displayName: display,
                    canonicalSlug: item.canonicalIngredientSlug,
                )
            }
            .sorted { $0.displayName < $1.displayName }
        return VoiceContextSnapshot(
            dietaryRules: rules,
            availableEquipment: equipment,
            pantry: pantry,
        )
    }

    /// Canonical pantry filter — SCA-424 + SCA-431. Returns only
    /// `PantryItem` rows that pass `deletedAt == nil && userConfirmed`.
    /// All three AI prompt sites (voice mint via `voiceContextSnapshot`,
    /// substitution sheet, grocery generate) consume this helper so the
    /// filter never drifts again. Inline `.filter` predicates at any of
    /// those call sites is a regression of SCA-424 — pre-2026-05-15 each
    /// site had its own predicate and the substitution sheet's "only
    /// non-empty name" check shipped soft-deleted + unconfirmed pantry
    /// rows to the model, producing "Use the baguette slices from your
    /// pantry" hallucinations against an empty pantry.
    ///
    /// Sort order is unspecified — callers that need deterministic order
    /// (e.g. voice transcript priming) should `.sorted` themselves;
    /// callers that don't (substitution + grocery prompts) save the work.
    func confirmedActivePantry() -> [PantryItem] {
        let set = pantryItems as? Set<PantryItem> ?? []
        return set.filter { $0.deletedAt == nil && $0.userConfirmed }
    }
}

/// Value-type snapshot of a HouseholdProfile projected for voice-path
/// consumers (Realtime mint + voice-invoked substitution). Intentionally
/// minimal — only the fields backend prompts reference, in the forms
/// they need them. DTOs in `AIDispatchDTOs.swift` convert from this
/// type into their endpoint-specific encodable shapes.
///
/// P2-I (2026-04-23): shared-seam extraction.
struct VoiceContextSnapshot: Sendable, Equatable {
    let dietaryRules: [DietaryRule]
    let availableEquipment: [String]
    let pantry: [PantryItem]

    struct DietaryRule: Sendable, Equatable {
        let kind: String
        let value: String
        let severity: String
    }

    struct PantryItem: Sendable, Equatable {
        let displayName: String
        let canonicalSlug: String?
    }

    static let empty = VoiceContextSnapshot(
        dietaryRules: [],
        availableEquipment: [],
        pantry: [],
    )
}
