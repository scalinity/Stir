// PreferenceMemoryService
//
// Builds the bounded preference-memory digest sent to /v1/ai/dinner-solve
// as `feedback_summary`. Closes the loop the OutcomeFeedbackView header
// promises ("I'll learn for next time" — SCA-44).
//
// Pipeline:
//   1. Read completed CookingSessions for the current household.
//   2. Filter to sessions with an OutcomeFeedback row whose createdAt is
//      within the tier window (free: 30d, premium: 90d, pro: 365d —
//      CLAUDE.md tier-entitlements table, previously dead).
//   3. Project into a digest (≤600 prompt tokens budget) — the K most
//      recent rated meals + aggregates (when N ≥ aggregateMinSamples) +
//      disliked-titles list + highlight notes from extreme ratings.
//
// Why on-device:
//   North-star constraint #3 ("user content lives in CloudKit, not
//   Postgres") rules out a server-side feedback mirror. Aggregating on
//   iOS keeps the data path identical to how household_context and
//   pantry already flow — transient request body, never persisted
//   server-side. ADR 0029 documents the rejected alternatives.
//
// Why bounded:
//   Sending raw OutcomeFeedback rows for a power-user with 365 days of
//   history blows the prompt token budget (each row ≈100-200 tokens).
//   The digest is K-bounded + char-bounded so a Pro user with 800
//   ratings produces the same payload size as a Premium user with 40.
//
// Sanitization:
//   `notes` is free-text user input — wrapped in USER_DATA markers
//   server-side as defense against indirect prompt injection. We strip
//   the markers client-side too so a user can't pre-stage a fence
//   escape, mirroring the renderPrompt sanitizer in
//   _shared/prompt_versions.ts.

import CoreData
import Foundation

@MainActor
final class PreferenceMemoryService {
    /// Per-tier window in days. Mirrors CLAUDE.md §Tier-entitlements
    /// "Preference memory window" row. Centralized here so a future
    /// tier adjustment lands in one place.
    static func windowDays(for tier: Tier) -> Int {
        switch tier {
        case .free:    return 30
        case .premium: return 90
        case .pro:     return 365
        }
    }

    /// Minimum rated-meal count before aggregate signals are computed.
    /// Below this, dominant-X aggregates would be over-confident statements
    /// from too few samples — the backend prompt is instructed to weight
    /// them as preferences, not absolutes, so we keep them out entirely
    /// when the sample is too small.
    static let aggregateMinSamples = 5

    /// Cap on `recent_meals` items returned. 10 is enough to capture
    /// recency-weighted preferences without blowing token budget. Each
    /// entry serializes to ≈30-40 tokens once JSON-stringified.
    static let recentMealsCap = 10

    /// Cap on disliked-meals titles. Beyond this we trust the
    /// recent_meals + aggregates to convey the same signal.
    static let dislikedMealsCap = 5

    /// Cap on highlight-note snippets. 3 keeps the prompt focused on
    /// the strongest taste signals (top 2 highly-rated notes + 1
    /// strongly-disliked note).
    static let highlightNotesCap = 3

    /// Per-note character cap. 100 chars ≈25 prompt tokens. With 3
    /// snippets at 100 chars + 10 recent meals + aggregates + disliked
    /// list, total payload sits comfortably below 600 prompt tokens.
    static let noteCharCap = 100

    private let sessionRepo: CookingSessionRepository
    private let entitlementService: EntitlementService
    private let now: () -> Date

    init(
        sessionRepo: CookingSessionRepository = CookingSessionRepository(),
        entitlementService: EntitlementService,
        now: @escaping () -> Date = Date.init,
    ) {
        self.sessionRepo = sessionRepo
        self.entitlementService = entitlementService
        self.now = now
    }

    /// Build the digest for the current household. Returns nil when
    /// there's nothing to send (no rated meals in the window) so the
    /// JSON encoder can omit the key entirely — backend treats absent
    /// `feedback_summary` and `feedback_summary: null` identically, but
    /// omitting saves a few bytes on the wire and keeps `.strict()` Zod
    /// happy regardless of whether the field is declared `.nullable()`
    /// or `.optional()`.
    func buildDigest(for household: HouseholdProfile) -> DinnerSolveRequest.FeedbackSummary? {
        let tier = entitlementService.tier
        let windowDays = Self.windowDays(for: tier)
        // Pull a generous slab of recent sessions. The repo prefetches
        // outcomeFeedback so we don't N+1 the relationship traversal
        // below. 100 is enough headroom that even a Pro user with daily
        // cooking + a 365-day window samples representative recency
        // (≥3 months of data); aggregates beyond that don't shift.
        let sessions: [CookingSession]
        do {
            sessions = try sessionRepo.recentCompletedSessions(for: household, limit: 100)
        } catch {
            // CoreData read failure is non-fatal — solving without
            // feedback is the existing behavior. Don't block the
            // dinner-solve hot path on a feedback read.
            return nil
        }

        let cutoff = now().addingTimeInterval(-Double(windowDays) * 86_400)
        let entries: [Entry] = sessions.compactMap { session in
            guard let feedback = session.outcomeFeedback,
                  let createdAt = feedback.createdAt,
                  createdAt >= cutoff,
                  let title = session.recipePlan?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else {
                return nil
            }
            let daysAgo = max(0, Int(now().timeIntervalSince(createdAt) / 86_400))
            return Entry(
                title: Self.sanitizeTitle(title),
                rating: feedback.clampedRating,
                workload: feedback.typedWorkload,
                taste: feedback.typedTaste,
                spiceLevel: feedback.typedSpiceLevel,
                wouldRepeat: feedback.wouldRepeat,
                notes: feedback.notes,
                cookedDaysAgo: daysAgo,
            )
        }

        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.cookedDaysAgo < $1.cookedDaysAgo }

        let recentMeals = Array(sorted.prefix(Self.recentMealsCap))
            .map { entry in
                DinnerSolveRequest.FeedbackSummary.MealEntry(
                    title: entry.title,
                    rating: entry.rating,
                    workload: entry.workload.rawValue,
                    taste: entry.taste.rawValue,
                    spiceLevel: entry.spiceLevel.rawValue,
                    wouldRepeat: entry.wouldRepeat,
                    cookedDaysAgo: entry.cookedDaysAgo,
                )
            }

        let dislikedMeals = Self.dislikedTitles(from: sorted)
        let highlightNotes = Self.highlightNotes(from: sorted)
        let aggregates = sorted.count >= Self.aggregateMinSamples
            ? Self.computeAggregates(from: sorted)
            : nil

        return DinnerSolveRequest.FeedbackSummary(
            recentMealCount: sorted.count,
            windowDays: windowDays,
            recentMeals: recentMeals,
            aggregates: aggregates,
            dislikedMeals: dislikedMeals,
            highlightNotes: highlightNotes,
        )
    }

    // MARK: - Aggregates

    private static func computeAggregates(from entries: [Entry]) -> DinnerSolveRequest.FeedbackSummary.Aggregates {
        let count = entries.count
        let avgRating = Double(entries.reduce(0) { $0 + $1.rating }) / Double(count)
        let highRated = entries.filter { $0.rating >= 4 }.count
        let wouldRepeat = entries.filter(\.wouldRepeat).count

        return .init(
            averageRating: roundTo2(avgRating),
            dominantTaste: dominantRawValue(of: \.taste, in: entries),
            dominantSpiceLevel: dominantRawValue(of: \.spiceLevel, in: entries),
            dominantWorkload: dominantRawValue(of: \.workload, in: entries),
            highRatedRate: roundTo2(Double(highRated) / Double(count)),
            wouldRepeatRate: roundTo2(Double(wouldRepeat) / Double(count)),
        )
    }

    /// Most-frequent raw value for an enum-typed field. Ties broken by
    /// the order returned by Dictionary iteration — deterministic-enough
    /// for prompt input (the model treats this as a soft preference,
    /// not a categorical assertion). Empty input returns "" which the
    /// backend Zod schema rejects, so callers must guard count > 0.
    private static func dominantRawValue<F: RawRepresentable>(
        of keyPath: KeyPath<Entry, F>,
        in entries: [Entry],
    ) -> String where F.RawValue == String {
        var counts: [String: Int] = [:]
        for e in entries {
            counts[e[keyPath: keyPath].rawValue, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? ""
    }

    private static func roundTo2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    // MARK: - Disliked titles

    private static func dislikedTitles(from entries: [Entry]) -> [String] {
        // "Disliked" = rated ≤2★ OR explicitly marked wouldRepeat=false.
        // Either signal is strong enough alone; the union catches the
        // case where a user gives a 3★ "good but never again" review.
        // Dedupe by title — repeating "Carbonara" twice in the list
        // wastes prompt tokens for the same signal.
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries {
            guard entry.rating <= 2 || !entry.wouldRepeat else { continue }
            if seen.insert(entry.title).inserted {
                out.append(entry.title)
                if out.count >= dislikedMealsCap { break }
            }
        }
        return out
    }

    // MARK: - Highlight notes

    private static func highlightNotes(from entries: [Entry]) -> [DinnerSolveRequest.FeedbackSummary.NoteSnippet] {
        // Two buckets so a stream of high ratings doesn't crowd out the
        // single low-rated note that carries the strongest "what went
        // wrong" signal. We take up to 2 high (≥4★) + up to 1 low (≤2★),
        // then trim to the global cap if both buckets fill.
        let high = entries
            .filter { $0.rating >= 4 && hasNonEmptyNote($0) }
            .prefix(2)
            .compactMap { makeSnippet(from: $0) }
        let low = entries
            .filter { $0.rating <= 2 && hasNonEmptyNote($0) }
            .prefix(1)
            .compactMap { makeSnippet(from: $0) }
        return Array((high + low).prefix(highlightNotesCap))
    }

    private static func hasNonEmptyNote(_ entry: Entry) -> Bool {
        guard let note = entry.notes else { return false }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func makeSnippet(from entry: Entry) -> DinnerSolveRequest.FeedbackSummary.NoteSnippet? {
        guard let raw = entry.notes else { return nil }
        let sanitized = sanitizeNote(raw)
        guard !sanitized.isEmpty else { return nil }
        return .init(title: entry.title, rating: entry.rating, note: sanitized)
    }

    // MARK: - Sanitization

    /// Title sanitizer: trim, collapse internal whitespace, strip the
    /// USER_DATA fence markers used by the backend renderer. The backend
    /// strips again as defense-in-depth; we strip here so a malicious
    /// title can't survive a future renderer regression.
    static func sanitizeTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "<<<USER_DATA_START>>>", with: "")
        s = s.replacingOccurrences(of: "<<<USER_DATA_END>>>", with: "")
        // Collapse internal whitespace (newlines/tabs from a paste) into
        // single spaces — keeps the wire JSON compact and avoids
        // accidentally mimicking prompt-instruction line breaks.
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Hard cap so a pathological 5000-char title can't dominate the
        // payload.
        if s.count > 80 { s = String(s.prefix(80)) }
        return s
    }

    /// Note sanitizer: same fence-strip + whitespace-collapse + length
    /// cap as titles, plus an explicit char cap. 100 chars is enough
    /// for "needed more salt, would halve the pepper" or similar
    /// tasting-note granularity without burning tokens on rambles.
    static func sanitizeNote(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "<<<USER_DATA_START>>>", with: "")
        s = s.replacingOccurrences(of: "<<<USER_DATA_END>>>", with: "")
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if s.count > noteCharCap {
            s = String(s.prefix(noteCharCap))
        }
        return s
    }

    // MARK: - Internal entry projection

    /// Internal projection so the digest builder works on Sendable
    /// value types instead of NSManagedObjects throughout the pipeline.
    /// Lets the aggregate / sort / filter steps be pure functions and
    /// keeps the unit tests trivial to seed without spinning a
    /// NSPersistentContainer.
    private struct Entry {
        let title: String
        let rating: Int
        let workload: OutcomeFeedback.Workload
        let taste: OutcomeFeedback.Taste
        let spiceLevel: OutcomeFeedback.SpiceLevel
        let wouldRepeat: Bool
        let notes: String?
        let cookedDaysAgo: Int
    }
}
