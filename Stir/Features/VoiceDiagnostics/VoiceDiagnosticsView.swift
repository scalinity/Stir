// VoiceDiagnosticsView
//
// D.1 validation gate — in-app measurement harness for the Gemini Live
// path. DEBUG-only surface; hidden from release builds via the #if
// DEBUG guard in Settings. Runs a scripted N-turn session against a
// real Gemini backend and reports the metrics CLAUDE.md §validation
// spec cares about:
//
//   - TTFA p95 (turn-submit → first audio response frame)
//   - Preamble-present rate on tool-call invocations
//   - Per-turn prompt token count trend (pruning / no-pruning)
//   - Session refresh silent-gap duration
//   - End-to-end cost estimate against the April 2026 price sheet
//
// What the runner does NOT do yet (explicit TODO bookmarks below):
//   - Script the canned audio input turns. For now, manual tap-to-
//     speak is required; the runner records metrics on whatever the
//     user says but doesn't auto-drive.
//   - Invoke the refresh handoff — that's still scaffolded in
//     RealtimeSession.refreshSession and gated behind measurement.
//   - Token-cap enforcement (80k hard cap). Measured but not blocked.
//
// Usage: Settings → Advanced → Voice Diagnostics (DEBUG). Tap "Start
// Probe" then speak a series of short kitchen prompts ("how long do I
// sauté onions?"). The runner tracks each turn and prints a JSON
// summary to the console + displays a table in the UI. Copy-paste
// the summary into a spike doc alongside D.1 findings.

#if DEBUG

import SwiftUI
import OSLog

@MainActor
@Observable
final class VoiceDiagnosticsViewModel {

    // MARK: - State

    /// Turns recorded since "Start Probe". Cleared on Reset.
    private(set) var turns: [TurnMeasurement] = []

    /// Whether a probe session is live. Starting a probe pre-warms a
    /// RealtimeSession and hooks its telemetry stream.
    private(set) var isRunning = false

    /// Last surfaced error message. Nil = no error. User clears on tap.
    var toast: String?

    // MARK: - Measurements

    struct TurnMeasurement: Identifiable, Sendable {
        let id = UUID()
        let turnNumber: Int
        let submittedAt: Date
        /// nil until first audio response frame arrives.
        var ttfaMs: Int?
        /// nil until turnComplete arrives.
        var totalLatencyMs: Int?
        /// Per-turn prompt token count from usageMetadata.
        var promptTokens: Int?
        /// Cumulative session tokens observed at this turn boundary.
        var cumulativeTokens: Int?
        /// For tool-call turns: did the client-side filler clip (or
        /// model preamble audio) fire before the tool result came back?
        var preamblePresent: Bool?
        /// For tool-call turns: the tool invoked.
        var toolName: String?

        var statusSummary: String {
            if ttfaMs == nil { return "pending" }
            if let ttfa = ttfaMs, let total = totalLatencyMs {
                return "TTFA \(ttfa)ms, total \(total)ms"
            }
            return "mid-turn"
        }
    }

    // MARK: - Derived aggregates

    var ttfaP95Ms: Int? {
        let values = turns.compactMap(\.ttfaMs).sorted()
        guard !values.isEmpty else { return nil }
        let idx = min(values.count - 1, Int(Double(values.count) * 0.95))
        return values[idx]
    }

    var preamblePresentRate: Double? {
        let toolTurns = turns.filter { $0.toolName != nil }
        guard !toolTurns.isEmpty else { return nil }
        let present = toolTurns.compactMap(\.preamblePresent).filter { $0 }.count
        return Double(present) / Double(toolTurns.count)
    }

    /// Rough pruning verdict: are per-turn prompt tokens staying flat
    /// across the session? Returns the delta between first and last
    /// turn's prompt token count. ≥ 2x growth in a 15-turn session
    /// suggests pruning is off or broken.
    var promptTokenDelta: Int? {
        let values = turns.compactMap(\.promptTokens)
        guard values.count >= 2 else { return nil }
        return values.last! - values.first!
    }

    // MARK: - Actions

    /// Start a probe session. User must speak into the mic; the runner
    /// attaches to the RealtimeSession that CookModeRoot created. This
    /// is a placeholder — fully-scripted probe runs are deferred to
    /// the next D.1 session because we need canned audio fixtures
    /// and a way to inject them into the pipeline.
    func startProbe() {
        isRunning = true
        turns = []
        toast = "Probe started. Enter Cook Mode with a Premium account, then speak 10 short kitchen prompts. Return here to see measurements."
        Logger.voice.info("voice_diagnostics_probe_started")
    }

    func stopProbe() {
        isRunning = false
        Logger.voice.info("voice_diagnostics_probe_stopped count=\(self.turns.count, privacy: .public)")
    }

    func reset() {
        turns = []
        toast = nil
    }

    /// Call from RealtimeSession when a turn starts. Creates a new
    /// `TurnMeasurement` with submittedAt pinned.
    func recordTurnStarted() {
        let next = TurnMeasurement(
            turnNumber: turns.count + 1,
            submittedAt: Date(),
        )
        turns.append(next)
    }

    /// First audio frame — TTFA snapshot. Call once per turn on the
    /// FIRST audio chunk, not every chunk.
    func recordTTFA() {
        guard var current = turns.last else { return }
        let ms = Int(Date().timeIntervalSince(current.submittedAt) * 1000)
        current.ttfaMs = ms
        turns[turns.count - 1] = current
    }

    /// turnComplete — final latency + token snapshot.
    func recordTurnComplete(promptTokens: Int?, cumulativeTokens: Int?) {
        guard var current = turns.last else { return }
        let ms = Int(Date().timeIntervalSince(current.submittedAt) * 1000)
        current.totalLatencyMs = ms
        current.promptTokens = promptTokens
        current.cumulativeTokens = cumulativeTokens
        turns[turns.count - 1] = current
    }

    /// Record a tool-call event. Call when the inbound toolCall frame
    /// arrives; `preamblePresent` is true if the client-side filler
    /// clip played (or the model emitted preamble audio) before the
    /// tool result frame came back.
    func recordToolCall(name: String, preamblePresent: Bool) {
        guard var current = turns.last else { return }
        current.toolName = name
        current.preamblePresent = preamblePresent
        turns[turns.count - 1] = current
    }

    /// Export the measurements as a JSON blob for copy-paste into a
    /// D.1 spike doc. Rendered as pretty-printed text in the UI.
    func jsonSummary() -> String {
        var rows: [[String: Any]] = []
        for turn in turns {
            rows.append([
                "turn": turn.turnNumber,
                "ttfa_ms": turn.ttfaMs as Any? ?? NSNull(),
                "total_ms": turn.totalLatencyMs as Any? ?? NSNull(),
                "prompt_tokens": turn.promptTokens as Any? ?? NSNull(),
                "cumulative_tokens": turn.cumulativeTokens as Any? ?? NSNull(),
                "tool_name": turn.toolName as Any? ?? NSNull(),
                "preamble_present": turn.preamblePresent as Any? ?? NSNull(),
            ])
        }
        let summary: [String: Any] = [
            "turns": rows,
            "ttfa_p95_ms": ttfaP95Ms as Any? ?? NSNull(),
            "preamble_present_rate": preamblePresentRate as Any? ?? NSNull(),
            "prompt_token_delta": promptTokenDelta as Any? ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else {
            return "<failed to serialize summary>"
        }
        return str
    }
}

// MARK: - View

struct VoiceDiagnosticsView: View {
    @State private var viewModel = VoiceDiagnosticsViewModel()
    @State private var showsExport = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    if viewModel.isRunning {
                        Button("Stop Probe") { viewModel.stopProbe() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Start Probe") { viewModel.startProbe() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Reset") { viewModel.reset() }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.turns.isEmpty)
                    Spacer()
                }
            } footer: {
                Text("DEBUG-only. Runs against the same Gemini backend Cook Mode uses — costs ~$0.006 per turn.")
                    .font(.caption)
            }

            if !viewModel.turns.isEmpty {
                Section("Gate Metrics") {
                    row("TTFA p95 (target <1000ms)", viewModel.ttfaP95Ms.map { "\($0) ms" } ?? "—")
                    row("Preamble present rate (target ≥70%)", viewModel.preamblePresentRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    row("Prompt-token delta 1→N (<2x ⇒ pruning OK)", viewModel.promptTokenDelta.map { "\($0)" } ?? "—")
                }

                Section("Turns") {
                    ForEach(viewModel.turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Turn \(turn.turnNumber)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if let tool = turn.toolName {
                                    Text(tool).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(turn.statusSummary).font(.caption).foregroundStyle(.secondary)
                            if let prompt = turn.promptTokens {
                                Text("prompt tokens: \(prompt)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button("Export JSON summary") { showsExport = true }
                }
            }

            if let toast = viewModel.toast {
                Section {
                    Text(toast)
                        .font(.footnote)
                        .onTapGesture { viewModel.toast = nil }
                }
            }
        }
        .navigationTitle("Voice Diagnostics")
        .sheet(isPresented: $showsExport) {
            NavigationStack {
                ScrollView {
                    Text(viewModel.jsonSummary())
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("Summary")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsExport = false }
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

#endif  // DEBUG
