// CoachMarkAnchor
//
// Per-screen anchor registry. A view tags itself with
// `.coachMarkAnchor(.scanShutter)` and the modifier writes that view's
// bounds into the screen-local `CoachMarkAnchorPreference` map. The
// `CoachMarkPresenter` reads the map and looks up the active step's
// target frame to draw the spotlight.
//
// Anchor IDs are typed (one nested enum per screen) so a tutorial step
// referencing a non-existent anchor is a compile error, not a runtime
// "spotlight on (0,0)". The optional overload (`coachMarkAnchor(_:)`
// accepting `CoachMarkAnchorID?`) supports the "anchor only the rank-1
// card" pattern without sentinel index values — pass `nil` and no
// preference is written.

import SwiftUI

/// Stable, screen-scoped anchor identifier. Each screen owns one or
/// more cases — adding a new screen means adding new cases to this
/// enum, which closes the registry at the type system layer.
enum CoachMarkAnchorID: Hashable {
    // Scan capture
    case scanShutter

    // Scan review
    case scanConfirmedSection
    case scanNeedsReviewSection
    case scanAddChip
    case scanSolveButton

    // Dinner options — only the rank-1 card is anchored. The fit-label
    // step centers on the same frame; no separate fit-label anchor is
    // needed.
    case dinnerCardRank1

    // Dish preview
    case dishMeta
    case dishWhyItFits
    case dishStartCooking

    // Cook Mode (tap)
    case cookStepCard
    case cookTimerPill
    case cookSubstituteButton
    case cookNextButton

    // Voice mode — the listening pill IS the visible mic affordance,
    // so a single anchor suffices for both the intro and the
    // "watch the mic" steps.
    case voiceListeningPill
    case voiceExitButton

    // Pantry management.
    //   - `settingsManagePantryRow`: entry-point coach mark on the
    //     Settings row that pushes PantryListView. Lives in
    //     SettingsRootView; available now.
    //   - The other four anchors live inside PantryListView and its
    //     sheets. They're reserved here so the in-screen sequence
    //     compiles the moment that view ships.
    case settingsManagePantryRow
    case pantryAddButton
    case pantryHeaderStrip
    case pantryMemoryStatePicker
    case pantryFirstRow
}

/// Per-screen registry of anchor frames. Frames are stored in the
/// presenting view's coordinate space.
struct CoachMarkAnchorPreference: Equatable {
    var frames: [CoachMarkAnchorID: CGRect] = [:]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.frames == rhs.frames
    }
}

private struct CoachMarkAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CoachMarkAnchorPreference { .init() }
    static func reduce(
        value: inout CoachMarkAnchorPreference,
        nextValue: () -> CoachMarkAnchorPreference,
    ) {
        // Last writer wins per ID — covers the case where a single
        // anchor is re-tagged across a re-render.
        for (id, frame) in nextValue().frames {
            value.frames[id] = frame
        }
    }
}

/// Coordinate-space tag used by the presenter's `coordinateSpace(name:)`
/// + every anchor's `frame(in:)` lookup. The presenter scopes the name
/// per-key (`<base>.<tutorial_id>`) so simultaneously-mounted presenters
/// don't share a registry.
let coachMarkCoordinateSpaceBase = "coachMarkScreen"

/// Resolved coordinate-space name for a given tutorial key. Used both
/// by the presenter (coordinateSpace setup) and by anchors registered
/// inside that presenter (frame(in:) lookup).
func coachMarkCoordinateSpace(for key: TutorialKey) -> String {
    "\(coachMarkCoordinateSpaceBase).\(key.rawValue)"
}

/// Environment key that vends the active coordinate-space name down
/// the view tree, so anchors can resolve their frames without knowing
/// the parent presenter's tutorial key.
private struct CoachMarkCoordinateSpaceKey: EnvironmentKey {
    static let defaultValue: String = coachMarkCoordinateSpaceBase
}

extension EnvironmentValues {
    var coachMarkCoordinateSpaceName: String {
        get { self[CoachMarkCoordinateSpaceKey.self] }
        set { self[CoachMarkCoordinateSpaceKey.self] = newValue }
    }
}

extension View {
    /// Tag this view as a coach-mark anchor. The frame is captured in
    /// the screen-level coordinate space the presenter installs.
    func coachMarkAnchor(_ id: CoachMarkAnchorID) -> some View {
        modifier(CoachMarkAnchorModifier(id: id))
    }

    /// Optional-ID overload. When `id == nil`, no preference is
    /// written. Lets call sites express "anchor only when this slot
    /// matters" without sentinel index values:
    ///
    /// ```swift
    /// .coachMarkAnchor(slot.rank == 1 ? .dinnerCardRank1 : nil)
    /// ```
    @ViewBuilder
    func coachMarkAnchor(_ id: CoachMarkAnchorID?) -> some View {
        if let id {
            coachMarkAnchor(id)
        } else {
            self
        }
    }

    /// Internal: collect anchor frames at this level. Used by
    /// `CoachMarkPresenter` so per-screen anchors propagate up to the
    /// overlay regardless of where in the tree they live.
    func onCoachMarkAnchorsChanged(
        perform action: @escaping ([CoachMarkAnchorID: CGRect]) -> Void,
    ) -> some View {
        onPreferenceChange(CoachMarkAnchorPreferenceKey.self) { pref in
            action(pref.frames)
        }
    }
}

/// Reads the current coordinate-space name from the environment so
/// anchors automatically scope to the enclosing presenter's key. No
/// shared coordinate-space collisions even if presenters nest.
private struct CoachMarkAnchorModifier: ViewModifier {
    let id: CoachMarkAnchorID
    @Environment(\.coachMarkCoordinateSpaceName) private var spaceName

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(spaceName))
                Color.clear.preference(
                    key: CoachMarkAnchorPreferenceKey.self,
                    value: CoachMarkAnchorPreference(frames: [id: frame]),
                )
            },
        )
    }
}
