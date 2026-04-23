// WidgetReloadCoordinator
//
// Coalesces WidgetKit timeline reloads behind a 500ms debounce so
// webhook/entitlement/solve thrash doesn't exhaust iOS's 40-reloads-
// per-hour budget (CA3-8). Every reload request is collected by kind
// within the debounce window; when the window elapses, one
// `WidgetCenter.shared.reloadTimelines(ofKind:)` call fires per unique
// kind. `.all` requests short-circuit to `reloadAllTimelines`.
//
// Why prefer `ofKind:` over `reloadAllTimelines`: StirWidgets ships
// exactly one widget kind (`TonightWidget`) today. Calling the kind-
// targeted API skips iOS's "is this kind configured?" walk and — more
// importantly — surfaces a clear signal in the coordinator code when
// a new widget kind is added (the switch-on-kind forces the update).
//
// The service is an actor so callers from different contexts (main-
// actor VM, background webhook ingest) can enqueue without synchronization
// concerns. The actual reloadTimelines call hops to the main actor
// because WidgetCenter is main-actor-only.

import Foundation
import WidgetKit

@MainActor
final class WidgetReloadCoordinator {
    /// Shared instance used by TonightSnapshotService + any future
    /// widget-writing surface. Tests inject their own via init.
    static let shared = WidgetReloadCoordinator()

    /// Kinds the app might ask to reload. `.all` is a fallback for the
    /// "I don't know which widgets are affected" case; prefer specific
    /// kinds when possible so iOS can do targeted invalidation.
    enum Kind: Hashable {
        case tonightWidget
        case all

        fileprivate var widgetKindString: String? {
            switch self {
            case .tonightWidget: return "TonightWidget"
            case .all:           return nil
            }
        }
    }

    private let debounceNanoseconds: UInt64
    private let reloadAll: @MainActor () -> Void
    private let reloadOfKind: @MainActor (String) -> Void

    private var pendingKinds: Set<Kind> = []
    private var flushTask: Task<Void, Never>?

    init(
        debounceMilliseconds: UInt64 = 500,
        reloadAll: @MainActor @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        reloadOfKind: @MainActor @escaping (String) -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: $0) },
    ) {
        self.debounceNanoseconds = debounceMilliseconds * 1_000_000
        self.reloadAll = reloadAll
        self.reloadOfKind = reloadOfKind
    }

    /// Enqueue a reload request. Multiple requests within the debounce
    /// window collapse into one batched flush.
    func requestReload(_ kind: Kind) {
        pendingKinds.insert(kind)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.debounceNanoseconds)
            } catch {
                return  // cancelled — next request will re-schedule
            }
            self.flush()
        }
    }

    /// Flush pending reloads immediately. Exposed for tests + for
    /// callsites that genuinely need the reload synchronously (e.g.
    /// logout / account delete, where the user sees the state change
    /// right away).
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        flush()
    }

    private func flush() {
        let kinds = pendingKinds
        pendingKinds.removeAll(keepingCapacity: true)
        if kinds.contains(.all) {
            reloadAll()
            return
        }
        for kind in kinds {
            if let kindString = kind.widgetKindString {
                reloadOfKind(kindString)
            }
        }
    }
}
