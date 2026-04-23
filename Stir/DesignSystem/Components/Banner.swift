// Banner
//
// Top-of-screen strip for persistent state (Specs/Design-System.md §8.7).
// Three variants keyed to semantic intent:
//   - `.info`    → paper.200 bg + info icon (SYNC-01, offline)
//   - `.warning` → amber.100 bg + amber triangle (BILL-01 grace period,
//                   AI-VOICE-01 reduced-quality fallback)
//   - `.error`   → crimson.100 bg + crimson triangle (rare; most errors
//                   inline, not banner)
//
// 44pt minimum height — HIG tap-target floor for the optional dismiss
// affordance. The `onDismiss` closure is optional because some banners
// (BILL-01 grace period) persist until their underlying state resolves.
//
// Accessibility:
//   - Banner announces as an alert to VoiceOver (`.isModal` trait would
//     be wrong — this is informational, not blocking). We use
//     accessibilityAddTraits(.isStaticText) + implicit priority from
//     message content.
//   - Icon is decorative (hidden from VO); the message text carries the
//     semantic.
//
// Intentionally generic copy surface — every concrete usage supplies its
// own message string.

import SwiftUI

enum BannerIntent {
    case info
    case warning
    case error
}

struct Banner: View {
    let intent: BannerIntent
    let message: String
    let onDismiss: (() -> Void)?

    init(
        intent: BannerIntent,
        message: String,
        onDismiss: (() -> Void)? = nil,
    ) {
        self.intent = intent
        self.message = message
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .center, spacing: CGFloat.Stir.space2) {
            icon
                .foregroundStyle(foreground)
                .accessibilityHidden(true)

            Text(message)
                .stirFont(.bodySm)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image.Stir.close
                        .foregroundStyle(foreground)
                        .frame(width: 44, height: 44) // HIG tap target
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss banner")
            }
        }
        .padding(.leading, CGFloat.Stir.space4)
        .padding(.trailing, onDismiss == nil ? CGFloat.Stir.space4 : 0)
        .frame(minHeight: 44)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    // MARK: - Intent → styling

    private var icon: Image {
        switch intent {
        case .info:     return Image.Stir.info
        case .warning:  return Image.Stir.softError
        case .error:    return Image.Stir.allergen
        }
    }

    private var foreground: Color {
        switch intent {
        case .info:     return Color.Stir.ink700
        case .warning:  return Color.Stir.amber600
        case .error:    return Color.Stir.crimson600
        }
    }

    private var background: Color {
        switch intent {
        case .info:     return Color.Stir.paper200
        case .warning:  return Color.Stir.amber100
        case .error:    return Color.Stir.crimson100
        }
    }
}

// MARK: - Previews

#Preview("Banner — light") {
    bannerGallery
        .preferredColorScheme(.light)
}

#Preview("Banner — dark") {
    bannerGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var bannerGallery: some View {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
        Text("Info — SYNC-01")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        Banner(
            intent: .info,
            message: "iCloud Sync isn't available. Stir will work on this device only for now.",
            onDismiss: {},
        )

        Text("Warning — AI-VOICE-01 (no dismiss)")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        Banner(
            intent: .warning,
            message: "Voice mode running in reduced quality — still here to help.",
        )

        Text("Warning — BILL-01 (dismissible)")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        Banner(
            intent: .warning,
            message: "We couldn't confirm your subscription right now.",
            onDismiss: {},
        )

        Text("Error — rare inline NET-01")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        Banner(
            intent: .error,
            message: "Couldn't reach Stir right now. Check your connection.",
            onDismiss: {},
        )

        Spacer()
    }
    .padding(CGFloat.Stir.space4)
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
