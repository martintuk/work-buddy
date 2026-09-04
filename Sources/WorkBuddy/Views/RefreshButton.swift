import SwiftUI

/// El mismo botón indica la carga, sin reemplazarse por un spinner.
struct RefreshButton: View {
    let isRefreshing: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRefreshing)) { context in
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing
                        ? context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1) * 360
                        : 0))
            }
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isRefreshing ? L10n.text(.commonRefreshing) : "")
        .disabled(isRefreshing)
    }
}
