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
    case slotError(rank: Int, code: String)
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
    let code: String
}
