import SwiftUI
import UIKit
import XCTest
@testable import Stir

@MainActor
final class DesignSystemAccessibilityTests: XCTestCase {
    func test_longSelectableChipWrapsAtTheAvailableWidth() {
        let chip = SelectableChip(
            label: "Strongly flavored vegetables and unfamiliar ingredients",
            tone: .danger,
            isSelected: true,
            action: {},
        )
        let narrow = fittingSize(chip, width: 220)
        let wide = fittingSize(chip, width: 700)
        XCTAssertLessThanOrEqual(narrow.width, 220)
        XCTAssertGreaterThan(narrow.height, wide.height)
    }

    func test_flowLayoutKeepsCompactChipsTogetherAndWrapsLongLabelsAtAccessibilitySize() {
        let compact = ChipFlowLayout(spacing: 8) {
            SelectableChip(label: "Tofu", isSelected: true, action: {})
            SelectableChip(label: "Eggplant", isSelected: true, action: {})
        }
        XCTAssertLessThan(fittingSize(compact, width: 320).height, 80)

        let long = ChipFlowLayout(spacing: 8) {
            SelectableChip(label: "Eat more vegetables", isSelected: true, action: {})
        }
        .environment(\.dynamicTypeSize, .accessibility3)
        let narrow = fittingSize(long, width: 220)
        let wide = fittingSize(long, width: 700)
        XCTAssertLessThanOrEqual(narrow.width, 220)
        XCTAssertGreaterThan(narrow.height, wide.height)
    }

    private func fittingSize(_ view: some View, width: CGFloat) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

}
