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
        let pantrySet = pantryItems as? Set<PantryItem> ?? []
        let pantry: [VoiceContextSnapshot.PantryItem] = pantrySet
            .filter { $0.deletedAt == nil && $0.userConfirmed }
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
