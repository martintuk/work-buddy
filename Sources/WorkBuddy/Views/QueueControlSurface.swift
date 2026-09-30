import SwiftUI

/// Superficie común para separar los controles persistentes del listado de PRs.
private struct QueueControlSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var isDark: Bool { colorScheme == .dark }
    private var background: Color {
        isDark ? Color(red: 0.18, green: 0.20, blue: 0.23)
               : Color(red: 0.90, green: 0.925, blue: 0.95)
    }

    func body(content: Content) -> some View {
        content
            .background {
                Rectangle()
                    .fill(background)
                    .shadow(color: .black.opacity(isDark ? 0.25 : 0.10), radius: 5, y: -3)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(contrast == .increased ? 0.45 : 0.16))
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func queueControlSurface() -> some View { modifier(QueueControlSurface()) }
}
