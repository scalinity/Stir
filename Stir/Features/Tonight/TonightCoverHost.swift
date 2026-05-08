// TonightCoverHost
//
// SCA-94: typechecker-relief shim for `TonightHomeView.body`.
//
// Pre-this-file, `body` chained four `.fullScreenCover` modifiers
// (scan, cook launch, solve again, other options) directly on the
// ScrollView. Each cover takes an Identifiable-bound `Item` and a
// content closure; the four-deep modifier chain plus the surrounding
// `.background` / `.overlay` / `.onChange` / `.tutorial` / `.task`
// pushed SwiftUI's expression typechecker into a "couldn't resolve
// in reasonable time" warning that re-emits on any modifier addition.
// The actual swiftc compile still succeeded, but the warning is a
// hard ceiling — adding the use-soon card (SCA-86) or the widget-
// nudge card (SCA-87) tips the build over.
//
// This extension consolidates the four covers into one
// `.tonightCoverHost(...)` modifier call. Inside the extension the
// chain is identical, but the typechecker resolves it in isolation
// and `body` sees a single opaque `some View` instead of four nested
// generic ResultBuilder type-graphs.
//
// Generic content types (S/C/SA/O) avoid AnyView so SwiftUI keeps
// structural identity for each cover's body — small/no perf or
// animation regressions — while the call site stays clean (one
// method reference per cover, no AnyView wrapping required).

import SwiftUI

extension View {
    /// SCA-94: applies Tonight Home's four `.fullScreenCover` modifiers
    /// in a single call. Each cover binds to a coordinator-owned
    /// `Identifiable?` item and presents the corresponding content
    /// closure when set.
    ///
    /// The bindings for cookLaunch / solveAgain / otherOptions are
    /// constructed inline against the `RootCoordinator` so the call site
    /// stays a flat parameter list rather than the prior 4-level
    /// `Binding(get:set:)` ladder embedded in the modifier chain.
    @ViewBuilder
    func tonightCoverHost<S: View, C: View, SA: View, O: View>(
        activeModal: Binding<TonightHomeView.ActiveModal?>,
        coordinator: RootCoordinator,
        scanCover: @escaping (TonightHomeView.ActiveModal) -> S,
        cookLaunchCover: @escaping (RootCoordinator.CookModeLaunch) -> C,
        solveAgainCover: @escaping (RootCoordinator.SolveAgainEntry) -> SA,
        otherOptionsCover: @escaping (RootCoordinator.OtherOptionsEntry) -> O,
    ) -> some View {
        self
            .fullScreenCover(item: activeModal, content: scanCover)
            .fullScreenCover(
                item: Binding(
                    get: { coordinator.activeCookLaunch },
                    set: { coordinator.activeCookLaunch = $0 },
                ),
                content: cookLaunchCover,
            )
            .fullScreenCover(
                item: Binding(
                    get: { coordinator.activeSolveAgain },
                    set: { coordinator.activeSolveAgain = $0 },
                ),
                content: solveAgainCover,
            )
            .fullScreenCover(
                item: Binding(
                    get: { coordinator.activeOtherOptions },
                    set: { coordinator.activeOtherOptions = $0 },
                ),
                content: otherOptionsCover,
            )
    }
}
