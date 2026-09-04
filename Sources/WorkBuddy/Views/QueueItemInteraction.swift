import SwiftUI

/// Selección inmediata y apertura con doble click, sin interceptar los controles superpuestos.
struct QueueItemInteraction: ViewModifier {
    let isSelected: Bool
    var isHovering = false
    let openTitle: String
    let select: () -> Void
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.primary.opacity(0.14)
                          : isHovering ? Color.primary.opacity(0.07) : .clear)
            )
            .contentShape(.rect)
            .onTapGesture(perform: select)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    select()
                    open()
                }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
            .accessibilityAction(named: Text(openTitle)) { open() }
    }
}
