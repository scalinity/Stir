// StirGlyph
//
// Tiny brand mark used in widget/live-activity surfaces where space
// prohibits the full app icon. A rounded-square ember tile with a
// serif-weight "S" centered inside, matching the 14pt / 16pt / 22pt
// glyph sizes used across mockup 13 (widgets) + 07 (cook mode voice).
//
// Compiled into Shared/ so both the main Stir target and StirWidgets
// render the mark with a single implementation. The full-resolution
// app icon lives in Assets.xcassets; this is the in-content mark.

import SwiftUI

struct StirGlyph: View {
    let size: CGFloat
    let tint: Color

    init(size: CGFloat = 14, tint: Color = Color.Stir.ember600) {
        self.size = size
        self.tint = tint
    }

    var body: some View {
        let cornerRadius = max(3, size * 0.3)
        let letterSize = size * 0.68
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint)
            Text("S")
                .font(.system(size: letterSize, weight: .bold, design: .serif))
                .foregroundStyle(.white)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
    }
}
