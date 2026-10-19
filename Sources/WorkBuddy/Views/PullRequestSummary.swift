import SwiftUI

/// Shared visual identity for the main list and action queue.
struct PullRequestSummary<Metadata: View>: View {
    let pullRequest: PullRequest
    var titleLineLimit = 2
    var titleTrailingPadding: CGFloat = 0
    var usesRepositoryOverlay = false
    @ViewBuilder let metadata: () -> Metadata

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pullRequest.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(titleLineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .padding(.trailing, titleTrailingPadding)
            HStack(spacing: 5) {
                if usesRepositoryOverlay {
                    Text(pullRequest.shortRepository)
                        .hidden()
                        .accessibilityHidden(true)
                        .anchorPreference(key: RepositoryLabelBounds.self, value: .bounds) { $0 }
                } else {
                    Text(pullRequest.shortRepository).foregroundStyle(.secondary)
                }
                Text("#\(String(pullRequest.number))").foregroundStyle(.secondary)
                metadata()
            }
            .font(.system(size: 10))
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

extension PullRequestSummary where Metadata == EmptyView {
    init(pullRequest: PullRequest, titleLineLimit: Int = 2) {
        self.pullRequest = pullRequest
        self.titleLineLimit = titleLineLimit
        self.metadata = { EmptyView() }
    }
}

struct RepositoryLabelBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
