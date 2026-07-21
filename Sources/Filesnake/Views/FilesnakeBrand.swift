import SwiftUI

/// Shared visual language for Filesnake's interface.
enum FilesnakeTheme {
    static let accent = Color(red: 0.15, green: 0.51, blue: 0.87)
    static let accentDeep = Color(red: 0.10, green: 0.40, blue: 0.79)
}

/// Filesnake's final mark: one clean white wave on blue.
struct FilesnakeLogo: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [FilesnakeTheme.accent, FilesnakeTheme.accentDeep],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            SnakeWaveMark()
                .stroke(
                    .white,
                    style: StrokeStyle(
                        lineWidth: size * 0.085,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SnakeWaveMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.18, y: rect.height * 0.57))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.50, y: rect.height * 0.50),
            control1: CGPoint(x: rect.width * 0.31, y: rect.height * 0.34),
            control2: CGPoint(x: rect.width * 0.42, y: rect.height * 0.34)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.79, y: rect.height * 0.45),
            control1: CGPoint(x: rect.width * 0.59, y: rect.height * 0.69),
            control2: CGPoint(x: rect.width * 0.70, y: rect.height * 0.68)
        )
        return path
    }
}

struct ShortcutKey: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }
    }
}
