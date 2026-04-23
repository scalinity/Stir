// GroceryRemindersService
//
// EventKit wrapper for writing a GroceryList to iOS Reminders. iOS 17
// requires `requestFullAccessToReminders()`; older ask-once style is
// deprecated. The flow is:
//
//   1. Request full access (silent if already granted; prompts once if
//      not-determined; throws on denied).
//   2. Create a Reminders list titled "Stir — <recipe title>" in the
//      same source as the user's default Reminders list (iCloud when
//      available, Local otherwise).
//   3. Insert one EKReminder per GroceryItem (title = item + amount,
//      notes = "For <recipe title>"). Commit as a single batch so a
//      partial failure rolls back nothing halfway.
//   4. Return the list identifier + per-item identifier map so
//      `GroceryRepository.markExported` can persist the correlation
//      for re-open later.
//
// Permission denial path: caller handles the `denied` error by showing
// the in-app list fallback and keeping `GroceryList.status = .draft`
// per spec §4.16.

import EventKit
import Foundation
import OSLog

@MainActor
final class GroceryRemindersService {
    enum Failure: Error, LocalizedError {
        case authorizationDenied
        case noReminderSource
        case saveFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                return "Reminders access is off. You can turn it on in Settings → Privacy & Security → Reminders."
            case .noReminderSource:
                return "No Reminders store is configured on this device."
            case .saveFailed(let underlying):
                return "Couldn't write to Reminders: \(underlying.localizedDescription)"
            }
        }
    }

    struct ExportedItem {
        let itemID: UUID
        let reminderID: String
    }

    struct ExportResult {
        let calendarIdentifier: String
        let items: [ExportedItem]
    }

    struct InputItem: Sendable {
        let id: UUID
        let displayName: String
        let quantityText: String?
    }

    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    // MARK: - Authorization

    /// Current authorization status — read before calling `export` so
    /// the caller can surface a tailored prompt.
    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    /// Request full-access if needed. iOS 17+ only API; returns true on
    /// grant, throws `.authorizationDenied` on deny.
    ///
    /// v1 ships write-only: we insert reminders into a new "Stir — " list
    /// and never re-read for sync. If step-N adds Reminders-to-Stir
    /// round-tripping, upgrade the docstring + request full access.
    @discardableResult
    func requestAccess() async throws -> Bool {
        switch authorizationStatus {
        case .fullAccess:
            return true
        case .writeOnly:
            // Write-only is sufficient for inserting new reminders in v1.
            return true
        case .restricted, .denied:
            throw Failure.authorizationDenied
        case .notDetermined:
            let granted = try await store.requestFullAccessToReminders()
            return granted
        @unknown default:
            return false
        }
    }

    // MARK: - Export

    /// Create a new Reminders list + inserts one reminder per item.
    /// Atomic at the pending-changes layer — failure BEFORE commit calls
    /// store.reset() to discard; failure AT commit deletes the (just-
    /// committed, now-orphan) calendar with a follow-up
    /// store.removeCalendar(..., commit: true) so retries don't
    /// accumulate empty "Stir — Pasta" lists (CA2-16).
    func export(
        items: [InputItem],
        recipeTitle: String,
    ) async throws -> ExportResult {
        try await requestAccess()

        guard let source = reminderSource() else {
            throw Failure.noReminderSource
        }

        // Create the list. The title pattern matches ADR-style expectation
        // ("Stir — " prefix so Reminders users can spot Stir-authored
        // lists at a glance).
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = "Stir — \(recipeTitle)"
        calendar.source = source

        do {
            try store.saveCalendar(calendar, commit: false)
        } catch {
            throw Failure.saveFailed(underlying: error)
        }

        var exported: [ExportedItem] = []
        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = Self.reminderTitle(for: item)
            reminder.notes = "For \(recipeTitle)"
            do {
                try store.save(reminder, commit: false)
            } catch {
                // Roll back by discarding the uncommitted list + items.
                store.reset()
                throw Failure.saveFailed(underlying: error)
            }
            exported.append(ExportedItem(
                itemID: item.id,
                reminderID: reminder.calendarItemIdentifier,
            ))
        }

        do {
            try store.commit()
        } catch {
            // Commit failed AFTER some rows may have landed. store.reset()
            // only clears PENDING changes — the partially-committed
            // calendar stays on disk and every retry would create a new
            // orphan. Explicitly remove it.
            do {
                try store.removeCalendar(calendar, commit: true)
            } catch {
                Logger.ui.warning(
                    "grocery export: orphan calendar cleanup failed: \(error.localizedDescription, privacy: .public)",
                )
            }
            throw Failure.saveFailed(underlying: error)
        }

        Logger.ui.info(
            "grocery export to reminders: \(exported.count, privacy: .public) items in list \(calendar.calendarIdentifier, privacy: .public)",
        )
        return ExportResult(
            calendarIdentifier: calendar.calendarIdentifier,
            items: exported,
        )
    }

    // MARK: - Private

    /// Pick the source the user's default Reminders list lives in. Falls
    /// back to the first LOCAL source (never calDAV by default — work
    /// Exchange or corp CalDAV accounts shouldn't silently receive
    /// "Stir — Pasta" reminders, CA2-15). If only calDAV is available,
    /// filter to iCloud-titled sources so we still land somewhere
    /// reasonable but skip Exchange/work accounts.
    private func reminderSource() -> EKSource? {
        if let defaultCal = store.defaultCalendarForNewReminders() {
            return defaultCal.source
        }
        if let local = store.sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        return store.sources.first { source in
            guard source.sourceType == .calDAV else { return false }
            // Only iCloud-titled calDAV sources — skip Exchange /
            // corporate / work accounts that happen to expose
            // reminders.
            return source.title.lowercased().contains("icloud")
        }
    }

    static func reminderTitle(for item: InputItem) -> String {
        guard let qty = item.quantityText?.trimmingCharacters(in: .whitespaces), !qty.isEmpty else {
            return item.displayName
        }
        return "\(item.displayName) — \(qty)"
    }
}
