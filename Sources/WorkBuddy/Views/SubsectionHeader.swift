import SwiftUI

struct SubsectionHeader<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    private let trailing: Trailing

    init(title: String, onBack: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.onBack = onBack
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help(L10n.text(.commonBack))
                .accessibilityLabel(L10n.text(.commonBack))
                Spacer()
                trailing
            }
            .overlay {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(height: 24)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()
        }
    }
}

extension SubsectionHeader where Trailing == EmptyView {
    init(title: String, onBack: @escaping () -> Void) {
        self.init(title: title, onBack: onBack) { EmptyView() }
    }
}
