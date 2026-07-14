import SwiftUI

struct FeelingFlower: View {
    let level: Int
    let size: CGFloat
    let filledColor: Color
    let outlineColor: Color

    init(
        level: Int,
        size: CGFloat = 22,
        filledColor: Color = AppTheme.accent,
        outlineColor: Color = AppTheme.divider
    ) {
        self.level = min(max(level, 0), 5)
        self.size = size
        self.filledColor = filledColor
        self.outlineColor = outlineColor
    }

    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < level ? filledColor : Color.clear)
                    .overlay {
                        Capsule()
                            .stroke(
                                index < level ? filledColor : outlineColor,
                                lineWidth: 1
                            )
                    }
                    .frame(width: size * 0.24, height: size * 0.43)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(Double(index) * 72))
            }

            Circle()
                .fill(level > 0 ? filledColor : outlineColor)
                .frame(width: size * 0.18, height: size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
