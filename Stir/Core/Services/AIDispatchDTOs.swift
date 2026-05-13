// AIDispatchDTOs
//
// Wire-format types for /v1/ai/pantry-parse and /v1/ai/dinner-solve.
// Mirrors the step-3 Deno handler shapes in
// Backend/supabase/functions/{pantry-parse,dinner-solve}/index.ts.
//
// Keep these in lockstep with the backend. Any snake_case drift on
// the wire should land here with explicit CodingKeys.

import Foundation

// MARK: - Pantry Parse

struct PantryParseRequest: Encodable, Sendable, Equatable {
    /// Cap on photos per multi-image request. Mirrors Zod
    /// `images.max(4)` in
    /// `Backend/supabase/functions/_shared/validation.ts` (SCA-35).
    /// Bump both sides together if the cap ever changes.
    static let multiImageMax = 4

    /// `clientRequestID` is non-optional — always emit. If anyone ever
    /// makes this Optional, drop the `encode` call below for an
    /// `encodeIfPresent` to keep the wire shape stable.
    let clientRequestID: UUID
    /// Singular path: present iff `images` is nil. Mutually exclusive
    /// with `images` per backend Zod superRefine — exactly one must be
    /// populated. See `singleImage(...)` / `multiImage(...)` factories.
    let imageBase64: String?
    let imageMimeType: String?
    /// Multi-image path: 2..4 photos of the same kitchen, merged
    /// server-side via the v1.1.0 prompt. Pro-only — backend returns
    /// ENT-MULTI-IMAGE-01 for non-Pro callers.
    let images: [ImagePart]?
    let householdProfileHash: String?

    enum CodingKeys: String, CodingKey {
        case clientRequestID = "client_request_id"
        case imageBase64 = "image_base64"
        case imageMimeType = "image_mime_type"
        case images
        case householdProfileHash = "household_profile_hash"
    }

    struct ImagePart: Encodable, Sendable, Equatable {
        let base64: String
        let mimeType: String

        enum CodingKeys: String, CodingKey {
            case base64
            case mimeType = "mime_type"
        }
    }

    /// Single-image factory — the back-compat path used for every Free
    /// and Premium scan, and the first-photo scan for Pro.
    static func singleImage(
        clientRequestID: UUID,
        imageData: Data,
        mimeType: String,
        householdProfileHash: String?,
    ) -> PantryParseRequest {
        PantryParseRequest(
            clientRequestID: clientRequestID,
            imageBase64: imageData.base64EncodedString(),
            imageMimeType: mimeType,
            images: nil,
            householdProfileHash: householdProfileHash,
        )
    }

    /// Multi-image factory (Pro-only). `images.count` must be in 2...4.
    /// SCA-36 S1: in DEBUG this is a hard `assertionFailure` (caller
    /// bug — fail fast in development). In release builds we throw
    /// `StirError.validation` instead so a runtime caller bug surfaces
    /// as a typed error rather than crashing the app. The view-model's
    /// pre-shutter gate (`canAppendCapturedImage`) makes this branch
    /// unreachable in normal flow.
    static func multiImage(
        clientRequestID: UUID,
        images: [(data: Data, mimeType: String)],
        householdProfileHash: String?,
    ) throws -> PantryParseRequest {
        guard images.count >= 2, images.count <= multiImageMax else {
            assertionFailure(
                "PantryParseRequest.multiImage requires 2...\(multiImageMax) images, got \(images.count)",
            )
            throw StirError.validation(
                fieldErrors: [],
                message: "PantryParseRequest.multiImage requires 2...\(multiImageMax) images, got \(images.count)",
            )
        }
        let parts = images.map { ImagePart(base64: $0.data.base64EncodedString(), mimeType: $0.mimeType) }
        return PantryParseRequest(
            clientRequestID: clientRequestID,
            imageBase64: nil,
            imageMimeType: nil,
            images: parts,
            householdProfileHash: householdProfileHash,
        )
    }

    /// Custom encoder skips nil keys instead of emitting `null`. Backend
    /// Zod superRefine treats `image_base64=null` and `images=null` as
    /// "both fields populated" (failing mutual-exclusivity); omitting
    /// the unused branch keeps the wire shape cleanly one-or-the-other.
    /// (SCA-36 W12: rationale here is wire-mutex, distinct from the
    /// CloudKit-empty-string skip pattern used elsewhere in this file
    /// — those skip empty strings, this skips nil to disambiguate
    /// "absent" from "explicitly null" for the Zod refine.)
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientRequestID, forKey: .clientRequestID)
        try c.encodeIfPresent(imageBase64, forKey: .imageBase64)
        try c.encodeIfPresent(imageMimeType, forKey: .imageMimeType)
        try c.encodeIfPresent(images, forKey: .images)
        try c.encodeIfPresent(householdProfileHash, forKey: .householdProfileHash)
    }
}

struct PantryParseResponse: Decodable, Sendable, Equatable {
    let parseID: UUID
    let ingredients: [ParsedIngredient]
    let overallConfidence: Double
    let promptVersion: String
    let latencyMS: Int
    let retryCount: Int

    enum CodingKeys: String, CodingKey {
        case parseID = "parse_id"
        case ingredients
        case overallConfidence = "overall_confidence"
        case promptVersion = "prompt_version"
        case latencyMS = "latency_ms"
        case retryCount = "retry_count"
    }

    struct ParsedIngredient: Decodable, Sendable, Equatable, Identifiable {
        // Client-side ID — not on the wire. Generated at decode time so
        // SwiftUI List/ForEach has a stable Hashable key without relying
        // on display_name collisions.
        let id: UUID
        let displayName: String
        let canonicalSlug: String?
        let confidence: PantryItemConfidence
        let amountText: String?
        let boundingBox: BoundingBox?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
            case confidence
            case amountText = "amount_text"
            case boundingBox = "bounding_box"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = UUID()
            self.displayName = try c.decode(String.self, forKey: .displayName)
            self.canonicalSlug = try c.decodeIfPresent(String.self, forKey: .canonicalSlug)
            self.confidence = try c.decode(PantryItemConfidence.self, forKey: .confidence)
            self.amountText = try c.decodeIfPresent(String.self, forKey: .amountText)
            self.boundingBox = try c.decodeIfPresent(BoundingBox.self, forKey: .boundingBox)
        }

        // Memberwise init for tests + view model construction.
        init(
            id: UUID = UUID(),
            displayName: String,
            canonicalSlug: String?,
            confidence: PantryItemConfidence,
            amountText: String?,
            boundingBox: BoundingBox?,
        ) {
            self.id = id
            self.displayName = displayName
            self.canonicalSlug = canonicalSlug
            self.confidence = confidence
            self.amountText = amountText
            self.boundingBox = boundingBox
        }
    }

    enum PantryItemConfidence: String, Decodable, Sendable, Equatable {
        case confirmed
        case needsReview = "needs_review"
        case likelyStaple = "likely_staple"
    }

    struct BoundingBox: Decodable, Sendable, Equatable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }
}

// MARK: - Dinner Solve

struct DinnerSolveRequest: Encodable, Sendable {
    let solveRequestID: UUID
    let parseID: UUID?
    let ingredients: [IngredientLite]
    let constraints: Constraints?
    let householdContext: HouseholdContext
    // Step-7 leftovers mode. When contextHint == .leftovers, backend
    // canary-selects the v1.1.0 prompt and requires leftoversItems.
    // Zod-level refine rejects the combinations `leftovers + []` and
    // `standard + non-empty leftoversItems`; iOS must honor the same
    // invariant before POSTing.
    let contextHint: ContextHint?
    let leftoversItems: [LeftoversItem]?
    /// SCA-44 preference-memory loop. On-device digest of recent
    /// OutcomeFeedback rows windowed by tier (free 30d / premium 90d /
    /// pro 365d). Nil when there's nothing in the window — JSON encoder
    /// omits the key so backend `.strict()` Zod sees the field as
    /// absent rather than null. See PreferenceMemoryService for the
    /// builder + ADR 0029 for the on-device-digest rationale.
    let feedbackSummary: FeedbackSummary?

    enum ContextHint: String, Encodable, Sendable {
        case standard
        case leftovers
    }

    enum CodingKeys: String, CodingKey {
        case solveRequestID = "solve_request_id"
        case parseID = "parse_id"
        case ingredients
        case constraints
        case householdContext = "household_context"
        case contextHint = "context_hint"
        case leftoversItems = "leftovers_items"
        case feedbackSummary = "feedback_summary"
    }

    /// Skip encoding `feedback_summary` and `leftovers_items` when nil
    /// rather than emitting `null`. Backend Zod schema is `.strict()` —
    /// declares both fields `.optional()`, so absent + null are
    /// equivalent at the schema level, but emitting `null` for
    /// `feedbackSummary` would fail `.refine` checks that test
    /// `feedback_summary !== undefined`. Same wire-mutex rationale as
    /// `PantryParseRequest.encode(to:)` for the imageBase64/images
    /// branches.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(solveRequestID, forKey: .solveRequestID)
        try c.encodeIfPresent(parseID, forKey: .parseID)
        try c.encode(ingredients, forKey: .ingredients)
        try c.encodeIfPresent(constraints, forKey: .constraints)
        try c.encode(householdContext, forKey: .householdContext)
        try c.encodeIfPresent(contextHint, forKey: .contextHint)
        try c.encodeIfPresent(leftoversItems, forKey: .leftoversItems)
        try c.encodeIfPresent(feedbackSummary, forKey: .feedbackSummary)
    }

    struct LeftoversItem: Encodable, Sendable {
        let displayName: String
        let canonicalSlug: String?
        let approximateAmountText: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
            case approximateAmountText = "approximate_amount_text"
        }
    }

    /// `Equatable` conformance lets `RootCoordinator.SolveAgainEntry`
    /// synthesize Equatable so a SwiftUI `.onChange(of:)` on the seeded
    /// pantry binding fires only when the actual ingredient list shifts
    /// (CR2-W7 rationale, 2026-05-04). All three stored fields are
    /// already Equatable, so the synthesis is free.
    struct IngredientLite: Encodable, Sendable, Equatable {
        let displayName: String
        let canonicalSlug: String?
        let amountText: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
            case amountText = "amount_text"
        }
    }

    struct Constraints: Encodable, Sendable {
        let maxTimeMinutes: Int?
        let cuisineLeaning: String?
        let useFirst: [String]?
        let avoidEquipment: [String]?
        let goal: String?

        enum CodingKeys: String, CodingKey {
            case maxTimeMinutes = "max_time_minutes"
            case cuisineLeaning = "cuisine_leaning"
            case useFirst = "use_first"
            case avoidEquipment = "avoid_equipment"
            case goal
        }
    }

    struct HouseholdContext: Encodable, Sendable {
        let servings: Int
        let dietaryRules: [DietaryRuleLite]
        let availableEquipment: [String]

        enum CodingKeys: String, CodingKey {
            case servings
            case dietaryRules = "dietary_rules"
            case availableEquipment = "available_equipment"
        }
    }

    struct DietaryRuleLite: Encodable, Sendable {
        let kind: String
        let value: String
        let severity: String
    }

    /// SCA-44 preference-memory digest. Bounded payload (~600 prompt
    /// tokens) projecting recent OutcomeFeedback rows from CloudKit
    /// into a shape the dinner-solve prompt can use to break ties
    /// between similarly-ranked options. NEVER overrides hard rules —
    /// the prompt template is explicit about that.
    ///
    /// Wire shape pinned here; backend Zod (`Backend/supabase/
    /// functions/_shared/validation.ts`) MUST stay in lockstep. New
    /// optional fields are safe to add either side independently;
    /// breaking changes need a version bump.
    struct FeedbackSummary: Encodable, Sendable, Equatable {
        let recentMealCount: Int
        let windowDays: Int
        let recentMeals: [MealEntry]
        let aggregates: Aggregates?
        let dislikedMeals: [String]
        let highlightNotes: [NoteSnippet]

        enum CodingKeys: String, CodingKey {
            case recentMealCount = "recent_meal_count"
            case windowDays = "window_days"
            case recentMeals = "recent_meals"
            case aggregates
            case dislikedMeals = "disliked_meals"
            case highlightNotes = "highlight_notes"
        }

        struct MealEntry: Encodable, Sendable, Equatable {
            let title: String
            let rating: Int
            let workload: String
            let taste: String
            let spiceLevel: String
            let wouldRepeat: Bool
            let cookedDaysAgo: Int

            enum CodingKeys: String, CodingKey {
                case title
                case rating
                case workload
                case taste
                case spiceLevel = "spice_level"
                case wouldRepeat = "would_repeat"
                case cookedDaysAgo = "cooked_days_ago"
            }
        }

        struct Aggregates: Encodable, Sendable, Equatable {
            let averageRating: Double
            let dominantTaste: String
            let dominantSpiceLevel: String
            let dominantWorkload: String
            /// Fraction (0.0–1.0) of meals in the window rated ≥4★.
            let highRatedRate: Double
            /// Fraction (0.0–1.0) of meals in the window where
            /// wouldRepeat == true.
            let wouldRepeatRate: Double

            enum CodingKeys: String, CodingKey {
                case averageRating = "average_rating"
                case dominantTaste = "dominant_taste"
                case dominantSpiceLevel = "dominant_spice_level"
                case dominantWorkload = "dominant_workload"
                case highRatedRate = "high_rated_rate"
                case wouldRepeatRate = "would_repeat_rate"
            }
        }

        struct NoteSnippet: Encodable, Sendable, Equatable {
            let title: String
            let rating: Int
            /// Sanitized to ≤100 chars, fence-markers stripped, single-
            /// line. See `PreferenceMemoryService.sanitizeNote`.
            let note: String
        }
    }
}

// Streamed card emitted by the SSE handler. Mirrors the backend's
// CandidateDish shape from hard_rules.ts.
struct DishCard: Decodable, Sendable, Equatable, Identifiable, Hashable {
    let rank: Int
    let title: String
    let totalTimeMinutes: Int
    let whyItFits: String
    let missingIngredientCount: Int
    let fitLabelPrimary: String
    let fitLabelSecondary: String?
    let hardConstraintPass: Bool
    let recipePlan: RecipePlanWire
    let reasoningSummary: String

    var id: Int { rank }

    enum CodingKeys: String, CodingKey {
        case rank, title
        case totalTimeMinutes = "total_time_minutes"
        case whyItFits = "why_it_fits"
        case missingIngredientCount = "missing_ingredient_count"
        case fitLabelPrimary = "fit_label_primary"
        case fitLabelSecondary = "fit_label_secondary"
        case hardConstraintPass = "hard_constraint_pass"
        case recipePlan = "recipe_plan"
        case reasoningSummary = "reasoning_summary"
    }

    struct RecipePlanWire: Decodable, Sendable, Equatable, Hashable {
        let servings: Int
        let difficulty: Int
        let cuisine: String?
        let ingredients: [IngredientWire]
        let steps: [StepWire]

        struct IngredientWire: Decodable, Sendable, Equatable, Hashable {
            let displayName: String
            let canonicalSlug: String?
            /// Optional on the wire (`hard_rules.ts` DishIngredient declares
            /// `amount_text?: string`). Gemini occasionally omits the key
            /// — previously this crashed iOS decode with the generic
            /// "isn't in the correct format" error. Default to empty
            /// string and let the UI layer render "to taste" fallback.
            let amountText: String
            /// Optional on the wire (`is_optional?: boolean`). Kept
            /// nullable on iOS too: defaulting to `false` on a missing
            /// key would silently flip ambiguous ingredients into
            /// required; `nil` preserves "no strong signal" so the
            /// UI only renders the "(optional)" suffix when the model
            /// explicitly said `true`.
            let isOptional: Bool?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case canonicalSlug = "canonical_slug"
                case amountText = "amount_text"
                case isOptional = "is_optional"
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.displayName = try c.decode(String.self, forKey: .displayName)
                self.canonicalSlug = try c.decodeIfPresent(String.self, forKey: .canonicalSlug)
                self.amountText = try c.decodeIfPresent(String.self, forKey: .amountText) ?? ""
                self.isOptional = try c.decodeIfPresent(Bool.self, forKey: .isOptional)
            }
        }

        struct StepWire: Decodable, Sendable, Equatable, Hashable {
            let stepNumber: Int
            let instructionText: String
            let timerSeconds: Int?
            let cautionTags: [String]?

            enum CodingKeys: String, CodingKey {
                case stepNumber = "step_number"
                case instructionText = "instruction_text"
                case timerSeconds = "timer_seconds"
                case cautionTags = "caution_tags"
            }
        }
    }
}

extension DishCard.RecipePlanWire.IngredientWire {
    /// Memberwise init — Swift suppresses the implicit one because this
    /// struct declares a custom `init(from:)` decoder. Restored here so
    /// rehydrators (e.g. `SolveRepository.rehydrateDishCard`) can build
    /// an IngredientWire from persisted Core Data without round-tripping
    /// through JSON.
    init(displayName: String, canonicalSlug: String?, amountText: String, isOptional: Bool?) {
        self.displayName = displayName
        self.canonicalSlug = canonicalSlug
        self.amountText = amountText
        self.isOptional = isOptional
    }
}

/// SSE event the AIDispatch stream yields.
enum DinnerSolveEvent: Sendable {
    case dish(DishCard)
    case slotError(rank: Int, code: ErrorCode)
    case done(solveRequestID: UUID, totalCostUSD: Double, dishesReturned: Int, retryCount: Int, promptVersion: String)
}

struct DinnerSolveDoneFrame: Decodable, Sendable {
    let solveRequestID: UUID
    let totalCostUSD: Double
    let dishesReturned: Int
    let retryCount: Int
    let promptVersion: String

    enum CodingKeys: String, CodingKey {
        case solveRequestID = "solve_request_id"
        case totalCostUSD = "total_cost_usd"
        case dishesReturned = "dishes_returned"
        case retryCount = "retry_count"
        case promptVersion = "prompt_version"
    }
}

struct DinnerSolveSlotError: Decodable, Sendable {
    let rank: Int
    let code: ErrorCode
}

// MARK: - Substitution (step 4)

struct SubstitutionRequest: Encodable, Sendable {
    let subEventID: UUID
    let cookingSessionID: UUID
    let recipePlanID: UUID
    let missingIngredient: MissingIngredient
    let userProblem: String
    let householdContext: HouseholdContext
    let recipeContext: RecipeContext

    enum CodingKeys: String, CodingKey {
        case subEventID = "sub_event_id"
        case cookingSessionID = "cooking_session_id"
        case recipePlanID = "recipe_plan_id"
        case missingIngredient = "missing_ingredient"
        case userProblem = "user_problem"
        case householdContext = "household_context"
        case recipeContext = "recipe_context"
    }

    struct MissingIngredient: Encodable, Sendable {
        let displayName: String
        let canonicalSlug: String?
        let amountText: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
            case amountText = "amount_text"
        }

        /// Skip encoding `canonical_slug` and `amount_text` when blank —
        /// Core Data string attrs default to "" (RecipeIngredient.amountText
        /// has `defaultValueString=""`; the dinner-solve decoder coalesces
        /// missing slugs to nil but not "" — so a stored "" can flow
        /// straight through). Backend Zod is `.min(1).max(128).optional()`
        /// on both fields, so an empty pass-through trips VAL-01 and
        /// surfaces in the sheet as "Something went wrong". Encoding the
        /// key as absent keeps the field "optional" per the schema intent.
        /// Same pattern as RealtimeRecipeContext.RemainingIngredient.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(displayName, forKey: .displayName)
            if let slug = canonicalSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
               !slug.isEmpty
            {
                try c.encode(slug, forKey: .canonicalSlug)
            }
            if let amount = amountText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !amount.isEmpty
            {
                try c.encode(amount, forKey: .amountText)
            }
        }
    }

    struct HouseholdContext: Encodable, Sendable {
        let dietaryRules: [DinnerSolveRequest.DietaryRuleLite]
        let availableEquipment: [String]
        let pantrySnapshot: [PantrySnapshotItem]

        /// P2-I (2026-04-23): construct from shared
        /// `VoiceContextSnapshot` projection so this endpoint sees
        /// exactly the same pantry filter as the Realtime mint.
        /// Prior inline builder accepted unconfirmed items — a latent
        /// correctness gap that could reach the hard-rule validator.
        init(snapshot: VoiceContextSnapshot) {
            self.dietaryRules = snapshot.dietaryRules.map {
                DinnerSolveRequest.DietaryRuleLite(
                    kind: $0.kind,
                    value: $0.value,
                    severity: $0.severity,
                )
            }
            self.availableEquipment = snapshot.availableEquipment
            self.pantrySnapshot = snapshot.pantry.map {
                PantrySnapshotItem(
                    displayName: $0.displayName,
                    canonicalSlug: $0.canonicalSlug,
                )
            }
        }

        /// Legacy memberwise init retained for tests.
        init(
            dietaryRules: [DinnerSolveRequest.DietaryRuleLite],
            availableEquipment: [String],
            pantrySnapshot: [PantrySnapshotItem],
        ) {
            self.dietaryRules = dietaryRules
            self.availableEquipment = availableEquipment
            self.pantrySnapshot = pantrySnapshot
        }

        enum CodingKeys: String, CodingKey {
            case dietaryRules = "dietary_rules"
            case availableEquipment = "available_equipment"
            case pantrySnapshot = "pantry_snapshot"
        }

        struct PantrySnapshotItem: Encodable, Sendable {
            let displayName: String
            let canonicalSlug: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case canonicalSlug = "canonical_slug"
            }

            /// See MissingIngredient.encode(to:) — same rationale.
            /// PantryItemRepository writes `canonicalIngredientSlug = ""`
            /// when the pantry-parse response had a nil slug, so the
            /// substitution snapshot is a hot source of empty strings.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(displayName, forKey: .displayName)
                if let slug = canonicalSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !slug.isEmpty
                {
                    try c.encode(slug, forKey: .canonicalSlug)
                }
            }
        }
    }

    struct RecipeContext: Encodable, Sendable {
        let title: String
        let currentStepNumber: Int
        let totalSteps: Int
        let remainingIngredients: [RemainingIngredient]

        enum CodingKeys: String, CodingKey {
            case title
            case currentStepNumber = "current_step_number"
            case totalSteps = "total_steps"
            case remainingIngredients = "remaining_ingredients"
        }

        struct RemainingIngredient: Encodable, Sendable {
            let displayName: String
            let canonicalSlug: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case canonicalSlug = "canonical_slug"
            }

            /// See MissingIngredient.encode(to:) — same rationale.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(displayName, forKey: .displayName)
                if let slug = canonicalSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !slug.isEmpty
                {
                    try c.encode(slug, forKey: .canonicalSlug)
                }
            }
        }
    }
}

struct SubstitutionResponse: Decodable, Sendable {
    let subEventID: UUID
    let substitutionText: String
    let amountConversion: String?
    let constraintSafe: Bool
    let constraintViolationReason: String?
    let reasoning: String
    let confidence: Confidence
    let promptVersion: String
    let latencyMS: Int
    let retryCount: Int

    enum Confidence: String, Decodable, Sendable {
        case high
        case medium
        case low
    }

    enum CodingKeys: String, CodingKey {
        case subEventID = "sub_event_id"
        case substitutionText = "substitution_text"
        case amountConversion = "amount_conversion"
        case constraintSafe = "constraint_safe"
        case constraintViolationReason = "constraint_violation_reason"
        case reasoning
        case confidence
        case promptVersion = "prompt_version"
        case latencyMS = "latency_ms"
        case retryCount = "retry_count"
    }
}

/// AIDispatch-level projection of SubstitutionResponse so UI code branches
/// on the product state, not the wire shape.
enum SubstitutionResult: Sendable {
    /// Model returned a safe substitution. Fields are ready to render.
    case safe(
        subEventID: UUID,
        text: String,
        amountConversion: String?,
        reasoning: String,
        confidence: SubstitutionResponse.Confidence,
        promptVersion: String
    )
    /// Hard-rule violation after retry — server returned the canned safety
    /// copy. UI shows a red warning card with NO Accept button.
    case unsafe(
        subEventID: UUID,
        reason: String,
        message: String,
        promptVersion: String
    )
}

// MARK: - Cook Turn (step 6 — Live API text fallback)
//
// Wire-format for /v1/ai/cook-turn. Sent by SpeechFallbackService after
// on-device transcription; returned from the backend with a spoken
// response + an optional suggested UI action (advance step, start timer).

struct CookTurnRequest: Encodable, Sendable {
    let clientRequestID: UUID
    let cookingSessionID: UUID
    let recipePlanID: UUID
    let currentStepNumber: Int
    /// <500 chars, enforced by backend Zod. Caller truncates if needed.
    let transcript: String
    let recipeContext: RealtimeRecipeContext
    let householdContext: RealtimeHouseholdContext

    enum CodingKeys: String, CodingKey {
        case clientRequestID = "client_request_id"
        case cookingSessionID = "cooking_session_id"
        case recipePlanID = "recipe_plan_id"
        case currentStepNumber = "current_step_number"
        case transcript
        case recipeContext = "recipe_context"
        case householdContext = "household_context"
    }
}

/// Mirror of the backend RealtimeRecipeContext — shared between
/// cook-turn and realtime-session so both paths send the same shape.
struct RealtimeRecipeContext: Encodable, Sendable {
    let title: String
    let servings: Int
    let estimatedMinutes: Int
    let totalSteps: Int
    let currentStepText: String
    /// Seconds for the current step's timer; 0 = no timer. Must be
    /// present on every request — backend schema is
    /// `z.number().int().min(0).max(36000).nullable()`, meaning the key
    /// is REQUIRED even when the step has no timer. Prior Optional<Int>
    /// shape caused JSONEncoder to omit the key on nil, tripping
    /// VAL-01 "Required" on the mint. Using non-Optional forces
    /// explicit 0 on no-timer steps.
    let currentStepTimerSeconds: Int
    /// Full numbered list of every step. Without this the model
    /// hallucinates when asked about non-current steps (observed
    /// 2026-04-22: model claimed step 3 was "sautéing with garlic"
    /// when the real step 3 was "add kale to boiling water").
    let allSteps: [StepDescription]
    let remainingIngredients: [RemainingIngredient]

    enum CodingKeys: String, CodingKey {
        case title
        case servings
        case estimatedMinutes = "estimated_minutes"
        case totalSteps = "total_steps"
        case currentStepText = "current_step_text"
        case currentStepTimerSeconds = "current_step_timer_seconds"
        case allSteps = "all_steps"
        case remainingIngredients = "remaining_ingredients"
    }

    struct StepDescription: Encodable, Sendable {
        let stepNumber: Int
        let text: String
        /// Seconds for this step's timer; 0 = no timer. Non-Optional
        /// because the backend schema is
        /// `z.number().int().min(0).max(36000).nullable()` — the key is
        /// REQUIRED on the wire even when there's no timer. Prior
        /// `Int?` shape caused JSONEncoder to omit the key on nil and
        /// tripped VAL-01 `timer_seconds=Required` on the mint. Same
        /// pattern as `RealtimeRecipeContext.currentStepTimerSeconds`.
        let timerSeconds: Int

        enum CodingKeys: String, CodingKey {
            case stepNumber = "step_number"
            case text
            case timerSeconds = "timer_seconds"
        }
    }

    struct RemainingIngredient: Encodable, Sendable {
        let displayName: String
        let canonicalSlug: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
        }

        /// Skip encoding `canonical_slug` when blank — Core Data string
        /// attrs default to "" and backend Zod enforces `.min(1)` on
        /// the optional slug, so an empty pass-through trips VAL-01.
        /// Encoding the key as absent keeps the field "optional" per
        /// the schema intent.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(displayName, forKey: .displayName)
            if let slug = canonicalSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
               !slug.isEmpty
            {
                try c.encode(slug, forKey: .canonicalSlug)
            }
        }
    }
}

struct RealtimeHouseholdContext: Encodable, Sendable {
    let dietaryRules: [DinnerSolveRequest.DietaryRuleLite]
    let availableEquipment: [String]
    let pantrySnapshot: [PantrySnapshotItem]

    /// P2-I (2026-04-23): construct from the shared
    /// `VoiceContextSnapshot` projection so Realtime mint + VM use
    /// identical filters.
    init(snapshot: VoiceContextSnapshot) {
        self.dietaryRules = snapshot.dietaryRules.map {
            DinnerSolveRequest.DietaryRuleLite(
                kind: $0.kind,
                value: $0.value,
                severity: $0.severity,
            )
        }
        self.availableEquipment = snapshot.availableEquipment
        self.pantrySnapshot = snapshot.pantry.map {
            PantrySnapshotItem(
                displayName: $0.displayName,
                canonicalSlug: $0.canonicalSlug,
            )
        }
    }

    /// Legacy field-wise initializer retained for tests that stub a
    /// context without a real Core Data HouseholdProfile. Production
    /// code paths should prefer `init(snapshot:)`.
    init(
        dietaryRules: [DinnerSolveRequest.DietaryRuleLite],
        availableEquipment: [String],
        pantrySnapshot: [PantrySnapshotItem],
    ) {
        self.dietaryRules = dietaryRules
        self.availableEquipment = availableEquipment
        self.pantrySnapshot = pantrySnapshot
    }

    enum CodingKeys: String, CodingKey {
        case dietaryRules = "dietary_rules"
        case availableEquipment = "available_equipment"
        case pantrySnapshot = "pantry_snapshot"
    }

    struct PantrySnapshotItem: Encodable, Sendable {
        let displayName: String
        let canonicalSlug: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
        }

        /// See RemainingIngredient.encode(to:) — same rationale.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(displayName, forKey: .displayName)
            if let slug = canonicalSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
               !slug.isEmpty
            {
                try c.encode(slug, forKey: .canonicalSlug)
            }
        }
    }
}

struct CookTurnResponse: Decodable, Sendable {
    let spokenResponse: String
    let suggestedAction: SuggestedAction
    let actionParams: ActionParams?
    let promptVersion: String
    let latencyMS: Int
    let retryCount: Int

    enum SuggestedAction: String, Decodable, Sendable, Equatable {
        case advanceStep = "advance_step"
        case startTimer = "start_timer"
        case none
    }

    struct ActionParams: Decodable, Sendable {
        let seconds: Int?
        let label: String?
    }

    enum CodingKeys: String, CodingKey {
        case spokenResponse = "spoken_response"
        case suggestedAction = "suggested_action"
        case actionParams = "action_params"
        case promptVersion = "prompt_version"
        case latencyMS = "latency_ms"
        case retryCount = "retry_count"
    }
}

// MARK: - Realtime Session (step 6 C.2 — Gemini Live mint)
//
// Wire-format for /v1/ai/realtime-session. Called by RealtimeSession
// actor at Cook Mode entry on the Premium+ voice path. Backend mints a
// single-use ephemeral Gemini Live token and returns a ready-to-open
// WebSocket URL (access_token query param already embedded).
//
// Contract pinned here so a backend drift is a build break, not a
// runtime surprise. See Backend/supabase/functions/realtime-session/.

struct RealtimeSessionRequest: Encodable, Sendable {
    let clientRequestID: UUID
    let cookingSessionID: UUID
    let recipePlanID: UUID
    let currentStepNumber: Int
    let recipeContext: RealtimeRecipeContext
    let householdContext: RealtimeHouseholdContext
    /// Optional ~200-300 token compact recap of the last 3 voice turns +
    /// timer state. Backend appends to systemInstruction for continuity
    /// across session refresh handoffs (ADR 0014). Absent on initial mint.
    let recap: String?
    /// True when this mint is a silent refresh within an already-active
    /// cook session. Backend skips the voice_cook_session quota
    /// increment on refresh mints — the initial session start already
    /// consumed one slot (ADR 0014). Default false for all non-refresh
    /// call sites (Codable will omit the field when false if needed).
    let isRefresh: Bool

    init(
        clientRequestID: UUID,
        cookingSessionID: UUID,
        recipePlanID: UUID,
        currentStepNumber: Int,
        recipeContext: RealtimeRecipeContext,
        householdContext: RealtimeHouseholdContext,
        recap: String? = nil,
        isRefresh: Bool = false,
    ) {
        self.clientRequestID = clientRequestID
        self.cookingSessionID = cookingSessionID
        self.recipePlanID = recipePlanID
        self.currentStepNumber = currentStepNumber
        self.recipeContext = recipeContext
        self.householdContext = householdContext
        self.recap = recap
        self.isRefresh = isRefresh
    }

    enum CodingKeys: String, CodingKey {
        case clientRequestID = "client_request_id"
        case cookingSessionID = "cooking_session_id"
        case recipePlanID = "recipe_plan_id"
        case currentStepNumber = "current_step_number"
        case recipeContext = "recipe_context"
        case householdContext = "household_context"
        case recap
        case isRefresh = "is_refresh"
    }
}

// MARK: - Recipe Import (step 7)

struct RecipeImportRequest: Encodable, Sendable {
    let importID: UUID
    let sourceType: RecipeImportSource
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case importID = "import_id"
        case sourceType = "source_type"
        case payload
    }

    /// Shape varies per sourceType. The Edge Function's Zod schema rejects
    /// cross-mixing (e.g. url+ocr_text together) so iOS must populate only
    /// the one field appropriate for the chosen sourceType.
    struct Payload: Encodable, Sendable {
        let url: String?
        let ocrText: String?
        let pastedText: String?
        let ocrPageCount: Int?

        enum CodingKeys: String, CodingKey {
            case url
            case ocrText = "ocr_text"
            case pastedText = "pasted_text"
            case ocrPageCount = "ocr_page_count"
        }

        static func url(_ url: String) -> Payload {
            Payload(url: url, ocrText: nil, pastedText: nil, ocrPageCount: 0)
        }

        static func screenshotOCR(text: String, pageCount: Int) -> Payload {
            Payload(url: nil, ocrText: text, pastedText: nil, ocrPageCount: pageCount)
        }

        static func pastedText(_ text: String) -> Payload {
            Payload(url: nil, ocrText: nil, pastedText: text, ocrPageCount: 0)
        }
    }
}

struct RecipeImportResponse: Decodable, Sendable {
    let importID: UUID
    let status: Status
    let recipe: ImportedRecipe?
    let retryCount: Int
    let promptVersion: String
    let asyncJobID: String?

    enum Status: String, Decodable, Sendable {
        case completed
        case queued
    }

    enum CodingKeys: String, CodingKey {
        case importID = "import_id"
        case status
        case recipe
        case retryCount = "retry_count"
        case promptVersion = "prompt_version"
        case asyncJobID = "async_job_id"
    }

    struct ImportedRecipe: Decodable, Sendable {
        let title: String
        let servings: Int?
        let estimatedMinutes: Int?
        let ingredients: [Ingredient]
        let steps: [Step]
        let parseQuality: ParseQuality
        let editHints: [String]?

        enum ParseQuality: String, Decodable, Sendable {
            case high, medium, low
        }

        enum CodingKeys: String, CodingKey {
            case title
            case servings
            case estimatedMinutes = "estimated_minutes"
            case ingredients
            case steps
            case parseQuality = "parse_quality"
            case editHints = "edit_hints"
        }

        struct Ingredient: Decodable, Sendable {
            let displayName: String
            let canonicalSlug: String?
            let amountText: String?
            let group: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case canonicalSlug = "canonical_slug"
                case amountText = "amount_text"
                case group
            }
        }

        struct Step: Decodable, Sendable {
            let stepNumber: Int
            let instructionText: String
            let timerSeconds: Int?
            let cautionTags: [String]?

            enum CodingKeys: String, CodingKey {
                case stepNumber = "step_number"
                case instructionText = "instruction_text"
                case timerSeconds = "timer_seconds"
                case cautionTags = "caution_tags"
            }
        }
    }
}

// MARK: - Grocery Generate (step 7)

struct GroceryGenerateRequest: Encodable, Sendable {
    let sourceID: UUID
    let sourceType: SourceType
    let ingredientsNeeded: [Ingredient]
    let pantrySnapshot: [PantryItemLite]
    let recipeTitle: String?

    enum SourceType: String, Encodable, Sendable {
        case recipe, session, leftovers
    }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case sourceType = "source_type"
        case ingredientsNeeded = "ingredients_needed"
        case pantrySnapshot = "pantry_snapshot"
        case recipeTitle = "recipe_title"
    }

    struct Ingredient: Encodable, Sendable {
        let displayName: String
        let canonicalSlug: String?
        let amountText: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
            case amountText = "amount_text"
        }

        /// Skip encoding `canonical_slug` and `amount_text` when blank
        /// or whitespace-only. Backend Zod is `.min(1).max(128).optional()`
        /// on both fields, so an empty pass-through trips VAL-01 →
        /// AIDispatch throws → GroceryViewModel's catch surfaces AI-01.
        /// Core Data string attrs default to `""` (RecipeIngredient.
        /// amountText has `defaultValueString=""`; the dinner-solve
        /// decoder coalesces missing slugs to nil but `""` flows
        /// straight through). This pattern mirrors
        /// `SubstitutionRequest.MissingIngredient.encode(to:)` —
        /// surfaced again on the rehydrated-alt-from-Other-Options
        /// path where ingredient strings sourced from older solves
        /// can carry persisted empties.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(displayName, forKey: .displayName)
            if let slug = canonicalSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
               !slug.isEmpty
            {
                try c.encode(slug, forKey: .canonicalSlug)
            }
            if let amount = amountText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !amount.isEmpty
            {
                try c.encode(amount, forKey: .amountText)
            }
        }
    }

    struct PantryItemLite: Encodable, Sendable {
        let displayName: String
        let canonicalSlug: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
        }

        /// Same blank-drop pattern as `Ingredient` above — pantry rows
        /// can carry persisted `""` for canonical_slug, which Zod's
        /// `.min(1).optional()` rejects. Drop when empty so the
        /// optional-field-absent path runs.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(displayName, forKey: .displayName)
            if let slug = canonicalSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
               !slug.isEmpty
            {
                try c.encode(slug, forKey: .canonicalSlug)
            }
        }
    }
}

struct GroceryGenerateResponse: Decodable, Sendable {
    let sourceID: UUID
    let sourceType: String
    let missingItems: [MissingItem]
    let alreadyHave: [AlreadyHave]
    let totalItemCount: Int
    let promptVersion: String
    let retryCount: Int

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case sourceType = "source_type"
        case missingItems = "missing_items"
        case alreadyHave = "already_have"
        case totalItemCount = "total_item_count"
        case promptVersion = "prompt_version"
        case retryCount = "retry_count"
    }

    struct MissingItem: Decodable, Sendable {
        let displayName: String
        let amountText: String?
        let canonicalSlug: String?
        let groceryCategory: String   // matches GroceryCategory raw value
        let priority: String          // "normal" | "low" | "high"

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case amountText = "amount_text"
            case canonicalSlug = "canonical_slug"
            case groceryCategory = "grocery_category"
            case priority
        }
    }

    struct AlreadyHave: Decodable, Sendable {
        let displayName: String
        let canonicalSlug: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
        }
    }
}

// MARK: - Push Register (step 7)

struct PushRegisterRequest: Encodable, Sendable {
    let apnsToken: String
    let environment: Environment
    let notificationPrefs: NotificationPrefs

    enum Environment: String, Encodable, Sendable {
        case production, sandbox
    }

    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case environment
        case notificationPrefs = "notification_prefs"
    }

    struct NotificationPrefs: Encodable, Sendable, Equatable {
        let importCompletion: Bool
        let reactivation: Bool
        // SCA-322: added so the wire schema covers every category
        // declared in `APNsCategory` (Backend/_shared/apns.ts).
        // cook_reminder has no backend enqueue path today but the
        // wire field exists so users opting out are honored the
        // moment that lands. billing_grace is already enqueued by
        // revenuecat-webhook on BILLING_ISSUE events; gating reads
        // `notification_prefs_json.billing_grace` so the iOS opt-out
        // is now actually plumbed through.
        let cookReminder: Bool
        let billingGrace: Bool

        enum CodingKeys: String, CodingKey {
            case importCompletion = "import_completion"
            case reactivation
            case cookReminder = "cook_reminder"
            case billingGrace = "billing_grace"
        }
    }
}

struct PushRegisterResponse: Decodable, Sendable {
    let installationID: String
    let environment: String

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case environment
    }
}

// MARK: - Users Delete Request (SCA-61)
//
// Wire shape for POST /v1/users/delete-request. Empty request body —
// server pulls canonical_user_key from the authenticated session JWT.
// Response carries the row id + state so the iOS surface can reflect
// "submitted" vs "already pending" without a separate GET.

struct UsersDeleteRequestResponse: Decodable, Sendable {
    /// CR1 review: typed enum mirrors the DB `deletion_request_state`
    /// ENUM (migration 20260508000002) + the ops-admin Zod schema. A
    /// backend-side state addition (e.g., 'cancelled') would otherwise
    /// go unnoticed by iOS until a surface tried to match.
    enum State: String, Decodable, Sendable {
        case pending
        case approved
        case processing
        case completed
        case failed
    }

    let deletionRequestID: UUID
    let state: State
    let requestedAt: String
    /// Surfaced when the server returned the most-recent `failed` row
    /// for this user (idempotent retry after a fulfillment-worker
    /// failure). iOS can show the user the prior reason; logged-only
    /// for now per CCPA-friendly UX (we don't want to dwell on a past
    /// failure when the SLA clock is what matters).
    let failureReason: String?
    let idempotent: Bool

    enum CodingKeys: String, CodingKey {
        case deletionRequestID = "deletion_request_id"
        case state
        case requestedAt = "requested_at"
        case failureReason = "failure_reason"
        case idempotent
    }
}

// MARK: - Voice Turn Usage (PostHog LLM Observability)
//
// Wire shape for POST /v1/ai/voice-turn-usage. Backend computes cost from
// server-authoritative MODEL_PRICING constants, inserts one ai_request_log
// row per turn (request_id = "voice:<session_id>:<turn_index>"), and
// captures one $ai_generation to PostHog. Fire-and-forget from iOS.
//
// Batch shape from day 1 even though RealtimeSession sends single-item
// arrays — future per-session buffering is a schema-free change.
//
// Do NOT compute cost on iOS. iOS sends tokens + latency only; the
// pricing constants live server-side as the single source of truth (ADR
// 0008).

struct VoiceTurnUsageRequest: Encodable, Sendable, Equatable {
    let sessionID: UUID
    let turns: [TurnUsage]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turns
    }

    struct TurnUsage: Encodable, Sendable, Equatable {
        let turnIndex: Int
        let promptTokensText: Int
        let promptTokensAudio: Int
        /// Gemini's raw `promptTokenCount` summed across generation
        /// passes. May exceed `text + audio` by the AUDIO-mode per-pass
        /// overhead (CLAUDE.md sharp-edge #15) which Gemini doesn't
        /// bucket into `promptTokensDetails`. Backend uses this for
        /// `ai_request_log.input_tokens` (accurate dashboards) and
        /// prices the uncategorized remainder at audio rate.
        let promptTokensTotal: Int
        /// Gemini Live `cachedContentTokenCount` — portion of
        /// `promptTokensTotal` served from implicit context cache. Nil
        /// when the accumulator was zero (caching didn't fire) — sent
        /// only when > 0 so the wire stays tight on the common path.
        /// Powers `ai_request_log.prompt_cached_tokens` + PostHog
        /// `$ai_cache_read_input_tokens`. The spec §9 cap-reversal
        /// trigger measures caching via this field.
        let promptTokensCached: Int?
        let responseTokensText: Int
        let responseTokensAudio: Int
        /// Gemini's raw `responseTokenCount` summed across generation
        /// passes. Same contract as `promptTokensTotal` on the response
        /// side — remainder priced at audio-out rate.
        let responseTokensTotal: Int
        let latencyMS: Int
        let endedReason: EndedReason
        let promptVersion: String
        let path: Path
        let endedAt: Date

        enum CodingKeys: String, CodingKey {
            case turnIndex = "turn_index"
            case promptTokensText = "prompt_tokens_text"
            case promptTokensAudio = "prompt_tokens_audio"
            case promptTokensTotal = "prompt_tokens_total"
            case promptTokensCached = "prompt_tokens_cached"
            case responseTokensText = "response_tokens_text"
            case responseTokensAudio = "response_tokens_audio"
            case responseTokensTotal = "response_tokens_total"
            case latencyMS = "latency_ms"
            case endedReason = "ended_reason"
            case promptVersion = "prompt_version"
            case path
            case endedAt = "ended_at"
        }

        /// Turn outcome from iOS's perspective. Mirrors the server enum.
        /// `turnComplete` is the normal happy-path exit; `toolResponse`
        /// marks a turn that ended on a Gemini tool call (substitution,
        /// advance_step, start_timer); `error` marks an upstream WS
        /// failure; `interrupted` marks a user barge-in.
        enum EndedReason: String, Encodable, Sendable {
            case turnComplete = "turn_complete"
            case toolResponse = "tool_response"
            case error
            case interrupted
        }

        /// Voice driver path. Stir v1 only writes `liveAPI` here —
        /// the backend Zod schema is `z.enum(['live_api'])` and will
        /// reject anything else with VAL-01. The fallback path uses
        /// `/v1/ai/cook-turn` which captures its own $ai_generation.
        /// Reopening this enum requires a deliberate ADR update so
        /// dashboards don't cross-contaminate semantically distinct
        /// rows.
        enum Path: String, Encodable, Sendable {
            case liveAPI = "live_api"
        }
    }
}

struct RealtimeSessionResponse: Decodable, Sendable {
    /// `auth_tokens/<hex>` — opaque value iOS passes unchanged as the
    /// WebSocket `access_token` query param. NOT an OAuth token.
    let authToken: String
    /// ISO-8601 hard session deadline (35 min past mint). The WebSocket
    /// MUST be closed and a new one opened before this expires.
    let expiresAt: String
    /// Server-minted correlation id for telemetry. Matches
    /// ai_request_log.id on the backend for this mint.
    let sessionID: String
    /// Full WebSocket URL ready to open. Already has
    /// `?access_token=<auth_token>` embedded.
    let wsURL: String
    /// Prompt version baked into the session (spec §15 telemetry tag).
    let promptVersion: String
    /// Pre-serialized `{"setup": {...}}` JSON blob that MUST be sent as
    /// the first WebSocket message after `ws.open`. Without it the
    /// server never emits `setupComplete` — even though the
    /// `bidiGenerateContentSetup` config was baked into the ephemeral
    /// token at mint time. Verified against the official
    /// google-gemini/gemini-live-api-examples reference app
    /// (2026-04-20): client still sends `sendInitialSetupMessages()` on
    /// the ephemeral-token path. iOS parses this blob via
    /// JSONSerialization and forwards it verbatim.
    let setupFrameJSON: String

    enum CodingKeys: String, CodingKey {
        case authToken = "auth_token"
        case expiresAt = "expires_at"
        case sessionID = "session_id"
        case wsURL = "ws_url"
        case promptVersion = "prompt_version"
        case setupFrameJSON = "setup_frame_json"
    }
}
