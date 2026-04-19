// StirToast
//
// Small capsule toast shown as a bottom overlay. One component replacing
// two duplicate implementations (PaywallView.RestoreToastView + inline
// toast in SettingsRootView). Previously the two diverged slightly in
// shadow opacity (0.1 vs 0.12) and padding — a living drift risk.
//
// Race safety: callers pair the toast value with a UUID id; the dismiss
// task checks the id before clearing so a rapid re-tap doesn't let the
// first task dismiss the second toast.
//
// Intentionally generic on copy — kinds (.success, .info, .failed) map
// to color accents. The DesignSystem (step 9) will replace these with
// brand tokens; the component API stays stable.

import SwiftUI

/// Discriminator that maps to a color accent + icon. Keep this small;
/// more nuanced messaging lives in the `message` string.
enum StirToastKind: Equatable, Sendable {
    case success
    case info
    case failed
}

struct StirToastPayload: Equatable {
    /// Stable identifier the dismiss task uses to guard against
    /// overriding a freshly-set toast. Callers generate `UUID()`.
    let id: UUID
    let message: String
    let kind: StirToastKind
}

struct StirToast: View {
    let payload: StirToastPayload

    var body: some View {
        HStack(spacing: 8) {
            if let icon = icon {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(payload.message)
                .font(.footnote)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String? {
        switch payload.kind {
        case .success: return "checkmark.circle.fill"
        case .info:    return nil
        case .failed:  return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch payload.kind {
        case .success: return .green
        case .info:    return .secondary
        case .failed:  return .orange
        }
    }
}

// MARK: - View modifier for easy bottom-overlay mounting

extension View {
    /// Attach a `StirToast` overlay at the bottom of the receiver. The
    /// binding drives presentation + animation; the caller is responsible
    /// for setting + clearing the binding (with UUID-guarded dismiss
    /// logic on rapid re-taps).
    func stirToast(_ payload: Binding<StirToastPayload?>) -> some View {
        self
            .overlay(alignment: .bottom) {
                if let toast = payload.wrappedValue {
                    StirToast(payload: toast)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: payload.wrappedValue)
    }
}
