import AppKit
import SwiftUI

/// Selección, acciones, progreso y resultados permanecen al pie de la lista.
struct PullRequestBatchBar: View {
    let batch: PullRequestBatch
    let start: (PullRequestBatchAction) -> Void
    @State private var showingResults = false

    var body: some View {
        VStack(spacing: 8) {
            if batch.isRunning {
                ProgressView(value: Double(batch.completedCount), total: Double(max(1, batch.entries.count)))
                    .tint(.accentColor)
                HStack {
                    resultsButton
                    Text(L10n.text(.batchProgress, String(batch.completedCount), String(batch.entries.count)))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                    Button(L10n.text(batch.stopRequested ? .batchStopping : .batchStop)) { batch.stop() }
                        .disabled(batch.stopRequested)
                        .help(L10n.text(.batchStopHelp))
                }
            } else {
                if !batch.entries.isEmpty {
                    HStack { resultsButton; Spacer() }
                }
                HStack(spacing: 8) {
                    Text(L10n.text(.batchSelectedCount, String(batch.selectedIDs.count)))
                        .font(.system(size: 11)).monospacedDigit().lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ForEach(PullRequestBatchAction.allCases, id: \.self) { action in
                        let count = batch.selected(action).count
                        Button(action.buttonTitle(count)) { showingResults = false; start(action) }
                            .buttonStyle(BatchActionButtonStyle())
                            .disabled(count == 0)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .queueControlSurface()
        .popover(isPresented: $showingResults, arrowEdge: .top) { results }
    }

    private var resultsButton: some View {
        Button { showingResults.toggle() } label: {
            HStack(spacing: 9) {
                if batch.succeededCount > 0 {
                    Label(String(batch.succeededCount), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if batch.skippedCount > 0 {
                    Label(String(batch.skippedCount), systemImage: "minus.circle").foregroundStyle(.secondary)
                }
                if batch.failedCount > 0 {
                    Label(String(batch.failedCount), systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                Image(systemName: "list.bullet").foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .frame(minHeight: 20)
        }
        .buttonStyle(.plain)
        .help(L10n.text(.batchViewResults))
        .accessibilityLabel([L10n.text(.batchViewResults),
                             L10n.text(.batchSucceededCount, String(batch.succeededCount)),
                             L10n.text(.batchSkippedCount, String(batch.skippedCount)),
                             L10n.text(.batchFailedCount, String(batch.failedCount))].joined(separator: ", "))
    }

    private var results: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(batch.entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.candidate.action.symbol).foregroundStyle(.secondary).frame(width: 16)
                            .help(entry.candidate.action.title)
                        Text(entry.pullRequest.shortRepository).lineLimit(1).truncationMode(.middle)
                        Text("#\(entry.pullRequest.number)").foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 0)
                        BatchStatusIcon(status: entry.status).frame(width: 16)
                    }
                    .font(.system(size: 11, weight: .medium)).frame(height: 24)
                    .help("\(entry.pullRequest.title)\n\(entry.status.text)")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.pullRequest.repository) #\(entry.pullRequest.number), \(entry.candidate.action.title), \(entry.status.text)")
                }
            }
            .padding(12)
        }
        .frame(width: 300, height: min(280, CGFloat(batch.entries.count * 30 + 24)))
    }
}

struct BatchStatusIcon: View {
    let status: PullRequestBatch.Status
    var body: some View {
        switch status {
        case .checking, .executing: ProgressView().controlSize(.small)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}

private struct BatchActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)
                        : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }
}
