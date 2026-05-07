// StepSevenTelemetryTests
//
// Snapshot test that locks in the spec §15 canonical property names for
// every step-7 telemetry event. Catches drift where a future contributor
// emits `export_target` instead of `destination`, `confidence` instead
// of `parse_quality`, `needed_edits` instead of `edit_required`, or
// invents `widget_tapped` — all of which were explicitly ruled out in
// CLAUDE.md §"What NOT to do by default".

import XCTest
@testable import Stir

@MainActor
final class StepSevenTelemetryTests: XCTestCase {
    // MARK: - Event-name allow-list

    func test_stepSevenEvents_areRegisteredInTelemetryEnum() {
        // Every step-7 event must be present in the TelemetryEvent enum.
        // Absence = event silently dropped by the PostHog capture path.
        let names = TelemetryEvent.allCases.map(\.rawValue)
        XCTAssertTrue(names.contains("recipe_import_started"))
        XCTAssertTrue(names.contains("recipe_import_completed"))
        XCTAssertTrue(names.contains("widget_added"))
        XCTAssertTrue(names.contains("shortcut_run"))
        XCTAssertTrue(names.contains("grocery_list_exported"))
        XCTAssertTrue(names.contains("reactivation_notification_opened"))
        XCTAssertTrue(names.contains("leftovers_dish_selected"))
    }

    func test_widgetTapped_isNOTAnEvent_perSpec() {
        // Spec §15 has no `widget_tapped` — widget deep-link taps fire
        // `app_opened` with the URL param. Adding `widget_tapped` without
        // updating spec + CLAUDE.md is banned.
        let names = TelemetryEvent.allCases.map(\.rawValue)
        XCTAssertFalse(names.contains("widget_tapped"))
    }

    // MARK: - Property-name snapshot

    func test_recipeImportStarted_emitsOnlySourceType() {
        let props = StepSevenTelemetry.recipeImportStarted(source: .url)
        XCTAssertEqual(props.count, 1, "recipe_import_started has exactly one property per spec §15")
        XCTAssertEqual(props["source_type"] as? String, "url")
    }

    func test_recipeImportCompleted_emitsSpecPropertyNames() {
        let props = StepSevenTelemetry.recipeImportCompleted(
            source: .screenshotOCR,
            parseQuality: "high",
            editRequired: true,
        )
        XCTAssertEqual(props["source_type"] as? String, "screenshot_ocr")
        XCTAssertEqual(props["parse_quality"] as? String, "high")
        XCTAssertEqual(props["edit_required"] as? Bool, true)
        // Drift guards — these are the known-wrong names the snapshot test
        // exists to catch.
        XCTAssertNil(props["confidence"], "use parse_quality not confidence")
        XCTAssertNil(props["needed_edits"], "use edit_required not needed_edits")
        XCTAssertNil(props["ingredient_count"], "not in spec §15")
        XCTAssertNil(props["step_count"], "not in spec §15")
    }

    func test_widgetAdded_emitsOnlySource() {
        let props = StepSevenTelemetry.widgetAdded(source: "home_screen")
        XCTAssertEqual(props.count, 1)
        XCTAssertEqual(props["source"] as? String, "home_screen")
    }

    func test_shortcutRun_emitsOnlyIntentName() {
        let props = StepSevenTelemetry.shortcutRun(intentName: "StartNewDinnerSolveIntent")
        XCTAssertEqual(props.count, 1)
        XCTAssertEqual(props["intent_name"] as? String, "StartNewDinnerSolveIntent")
    }

    func test_groceryListExported_destinationValuesMatchSpec() {
        let remindersProps = StepSevenTelemetry.groceryListExported(itemCount: 7, destination: .reminders)
        XCTAssertEqual(remindersProps["item_count"] as? Int, 7)
        XCTAssertEqual(remindersProps["destination"] as? String, "reminders")
        XCTAssertNil(remindersProps["export_target"], "use destination not export_target")

        let inAppProps = StepSevenTelemetry.groceryListExported(itemCount: 3, destination: .inApp)
        XCTAssertEqual(inAppProps["destination"] as? String, "in_app", "in_app uses underscore per spec §15")
    }

    func test_groceryListExported_destinationEnum_hasOnlyTwoSpecValues() {
        // Spec §15 permits exactly {reminders, in_app}.
        XCTAssertEqual(
            Set(StepSevenTelemetry.Destination.allCases.map(\.rawValue)),
            Set(["reminders", "in_app"]),
            "destination enum must match spec §15 exactly — no new values without updating spec",
        )
    }

    func test_reactivationNotificationOpened_emitsOnlyTriggerKind() {
        let props = StepSevenTelemetry.reactivationNotificationOpened(triggerKind: "cook_reminder")
        XCTAssertEqual(props.count, 1)
        XCTAssertEqual(props["trigger_kind"] as? String, "cook_reminder")
    }
}
