// VoiceTurnRepository
//
// Persists VoiceTurn rows per spec §4.12. Every user and model turn on
// BOTH the Gemini Live path and the text fallback path writes a row here.
// Rows cascade-delete with their parent CookingSession.
//
// Thread-safety: @MainActor — matches other repositories. Writes funnel
// through a single actor since CookModeViewModel lives there too.

import CoreData
import Foundation

@MainActor
final class VoiceTurnRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
        self.controller = controller
    }

    /// Persist one voice turn. Not Sendable because it carries a
    /// CookingSession NSManagedObject — consumed on @MainActor only.
    struct PersistInput {
        let session: CookingSession
        let speaker: VoiceTurn.Speaker
        /// 1-indexed turn number within the session. Caller supplies;
        /// typically `existingCount + 1`.
        let turnIndex: Int
        let transcriptText: String
        let inputMode: VoiceTurn.InputMode
        /// End-to-end latency in ms for this turn (user speech complete
        /// → model turn first-frame). Caller measures. Pass 0 when
        /// latency isn't measurable (e.g. initial system turn).
        let latencyMs: Int
        let resultType: VoiceTurn.ResultType
        /// Only set when `resultType == .error`. Stable slug identifying
        /// the failure class (e.g. "turnComplete_timeout"). nil otherwise.
        /// Callers that don't pass it default to nil.
        var errorCode: String? = nil
    }

    @discardableResult
    func persist(_ input: PersistInput) throws -> VoiceTurn {
        let context = controller.viewContext
        let turn = VoiceTurn(context: context)
        turn.id = UUID()
        turn.cookingSessionId = input.session.id
        turn.cookingSession = input.session
        turn.turnIndex = Int16(input.turnIndex)
        turn.typedSpeaker = input.speaker
        turn.transcriptText = input.transcriptText
        turn.typedInputMode = input.inputMode
        turn.latencyMs = Int32(input.latencyMs)
        turn.typedResultType = input.resultType
        turn.errorCode = input.errorCode
        turn.createdAt = Date()
        try context.save()
        return turn
    }

    /// All turns for a session, ordered by turnIndex ascending. Use for
    /// ops replay and for computing the next turnIndex on persist.
    func turns(for session: CookingSession) -> [VoiceTurn] {
        guard let sessionId = session.id else { return [] }
        let context = controller.viewContext
        let fetch = NSFetchRequest<VoiceTurn>(entityName: "VoiceTurn")
        fetch.predicate = NSPredicate(format: "cookingSessionId == %@", sessionId as CVarArg)
        fetch.sortDescriptors = [NSSortDescriptor(key: "turnIndex", ascending: true)]
        return (try? context.fetch(fetch)) ?? []
    }

    /// Next turn index for a session — read-modify-write helper so callers
    /// don't reach into Core Data to compute it. Returns 1 for the first
    /// turn (spec §4.12 is 1-indexed implicitly via "turnIndex").
    func nextTurnIndex(for session: CookingSession) -> Int {
        let existing = turns(for: session)
        let maxIdx = existing.map(\.turnIndex).max() ?? 0
        return Int(maxIdx) + 1
    }
}

// MARK: - Typed enum extensions

extension VoiceTurn {
    /// Spec §4.12 speaker enum. Only user / model are valid.
    enum Speaker: String, Sendable, Equatable {
        case user
        case model
    }

    /// Spec §4.12 inputMode enum. v1 always `voice`. `text` reserved for
    /// future keyboard input path.
    enum InputMode: String, Sendable, Equatable {
        case voice
        case text
    }

    /// Spec §4.12 resultType enum.
    ///   - normal: model responded with spoken audio only
    ///   - tool_call: model turn triggered a function call (substitution_check,
    ///     start_timer, advance_step)
    ///   - error: model turn failed (Gemini error, pruning failure, etc.)
    enum ResultType: String, Sendable, Equatable {
        case normal
        case toolCall = "tool_call"
        case error
    }

    var typedSpeaker: Speaker {
        get { Speaker(rawValue: speaker ?? "model") ?? .model }
        set { speaker = newValue.rawValue }
    }

    var typedInputMode: InputMode {
        get { InputMode(rawValue: inputMode ?? "voice") ?? .voice }
        set { inputMode = newValue.rawValue }
    }

    var typedResultType: ResultType {
        get { ResultType(rawValue: resultType ?? "normal") ?? .normal }
        set { resultType = newValue.rawValue }
    }
}
