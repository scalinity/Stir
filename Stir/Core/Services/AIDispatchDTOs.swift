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
    let clientRequestID: UUID
    let imageBase64: String
    let imageMimeType: String
    let imageCount: Int?
    let householdProfileHash: String?

    enum CodingKeys: String, CodingKey {
        case clientRequestID = "client_request_id"
        case imageBase64 = "image_base64"
        case imageMimeType = "image_mime_type"
        case imageCount = "image_count"
        case householdProfileHash = "household_profile_hash"
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

    enum CodingKeys: String, CodingKey {
        case solveRequestID = "solve_request_id"
        case parseID = "parse_id"
        case ingredients
        case constraints
        case householdContext = "household_context"
    }

    struct IngredientLite: Encodable, Sendable {
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
            let amountText: String
            let isOptional: Bool

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case canonicalSlug = "canonical_slug"
                case amountText = "amount_text"
                case isOptional = "is_optional"
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
    }

    struct HouseholdContext: Encodable, Sendable {
        let dietaryRules: [DinnerSolveRequest.DietaryRuleLite]
        let availableEquipment: [String]
        let pantrySnapshot: [PantrySnapshotItem]

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
    /// Nullable — some steps have no timer. Server passes through as
    /// zero when null (prompt template displays `0` literally in that
    /// case; consumer reads "no timer" from a zero timerSeconds).
    let currentStepTimerSeconds: Int?
    let remainingIngredients: [RemainingIngredient]

    enum CodingKeys: String, CodingKey {
        case title
        case servings
        case estimatedMinutes = "estimated_minutes"
        case totalSteps = "total_steps"
        case currentStepText = "current_step_text"
        case currentStepTimerSeconds = "current_step_timer_seconds"
        case remainingIngredients = "remaining_ingredients"
    }

    struct RemainingIngredient: Encodable, Sendable {
        let displayName: String
        let canonicalSlug: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case canonicalSlug = "canonical_slug"
        }
    }
}

struct RealtimeHouseholdContext: Encodable, Sendable {
    let dietaryRules: [DinnerSolveRequest.DietaryRuleLite]
    let availableEquipment: [String]
    let pantrySnapshot: [PantrySnapshotItem]

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

    enum CodingKeys: String, CodingKey {
        case clientRequestID = "client_request_id"
        case cookingSessionID = "cooking_session_id"
        case recipePlanID = "recipe_plan_id"
        case currentStepNumber = "current_step_number"
        case recipeContext = "recipe_context"
        case householdContext = "household_context"
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

    enum CodingKeys: String, CodingKey {
        case authToken = "auth_token"
        case expiresAt = "expires_at"
        case sessionID = "session_id"
        case wsURL = "ws_url"
        case promptVersion = "prompt_version"
    }
}
