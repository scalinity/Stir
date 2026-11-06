import SwiftUI
import UIKit
import XCTest

// Shared/Colors.swift is compiled into this test target as well as the app.
// Avoid importing the app here so Color.Stir resolves to the local token copy.
@MainActor
final class DesignSystemContrastTests: XCTestCase {
    func test_enabledActionAndChipLabelsMeetNormalTextContrastInBothAppearances() {
        let pairs: [(String, Color, Color)] = [
            ("Primary and custom ember CTAs", Color.Stir.onAccent, Color.Stir.ember600),
            ("Selected accent chip", Color.Stir.ember600, Color.Stir.ember100),
            ("Selected dislike chip", Color.Stir.crimson600, Color.Stir.crimson100),
            ("Unselected chip", Color.Stir.ink700, Color.Stir.paper100),
        ]
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            for (role, foreground, background) in pairs {
                let first = luminance(foreground, traits: traits)
                let second = luminance(background, traits: traits)
                let ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(role), appearance \(appearance.rawValue): \(ratio)")
            }
        }
    }

    private func luminance(_ color: Color, traits: UITraitCollection) -> Double {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
