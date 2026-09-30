import AppKit
import SwiftUI

/// Pantalla dentro del popover: navegación, selección y resultados comparten
/// el mismo espacio. No abre diálogos ni pierde la selección con el refresh.
struct DependabotApprovalBatchView: View {
    let batch: DependabotApprovalBatch
    let start: () -> Void
    let close: () -> Void
    let newBatch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider()
            if batch.entries.isEmpty {
                ContentUnavailableView(L10n.text(.batchEmpty), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(batch.entries) { entry in row(entry) }
                    }
                    .padding(10)
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: close)
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button(action: close) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .frame(width: 24, height: 28)
                .help(L10n.text(.commonBack))
                .accessibilityLabel(L10n.text(.commonBack))
            Text(L10n.text(.batchTitle))
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if batch.phase == .selecting {
                Text("\(batch.selectedIDs.count) / \(batch.entries.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text(.batchSelectionCount,
                                                 String(batch.selectedIDs.count), String(batch.entries.count)))
                Button { batch.toggleAll() } label: {
                    Image(systemName: batch.selectedIDs.isEmpty ? "square"
                          : batch.selectedIDs.count == batch.entries.count ? "checkmark.square.fill" : "minus.square.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 14))
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("a", modifiers: .command)
                .disabled(batch.entries.isEmpty)
                .help(selectionHelp)
                .accessibilityLabel(selectionHelp)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var selectionHelp: String {
        L10n.text(batch.selectedIDs.count == batch.entries.count ? .batchDeselectAll : .batchSelectAll)
    }

    private func row(_ entry: DependabotApprovalBatch.Entry) -> some View {
        let pr = entry.pullRequest
        let selected = batch.selectedIDs.contains(pr.id)
        return HStack(spacing: 4) {
            if batch.phase == .selecting {
                Button { batch.toggle(pr.id) } label: { rowDetails(entry, selected: selected) }
                    .buttonStyle(.plain)
                    .help(pr.title)
                    .accessibilityLabel("\(pr.title), \(pr.repository) #\(pr.number)")
                    .accessibilityValue(selected ? L10n.text(.batchSelected) : L10n.text(.batchNotSelected))
            } else {
                rowDetails(entry, selected: selected)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(pr.title), \(pr.repository) #\(pr.number)")
                    .accessibilityValue(entry.status.text)
            }

            Button { NSWorkspace.shared.open(pr.url) } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(L10n.text(.prOpen))
            .accessibilityLabel("\(L10n.text(.prOpen)): \(pr.shortRepository) #\(pr.number)")
            .padding(.trailing, 4)
        }
        .background((batch.phase == .selecting && selected ? Color.accentColor.opacity(0.07)
                     : Color.primary.opacity(0.025)), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(batch.phase == .selecting && selected
                              ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07))
        }
    }

    private func rowDetails(_ entry: DependabotApprovalBatch.Entry, selected: Bool) -> some View {
        let pr = entry.pullRequest
        return HStack(alignment: .center, spacing: 9) {
            statusIcon(entry, selected: selected)
                .frame(width: 18, height: 20)
            HStack(spacing: 5) {
                Text(pr.shortRepository)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Text("#\(pr.number)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(pr.repository) #\(pr.number)\n\(pr.title)")
        }
        .padding(.leading, 10)
        .frame(height: 32)
        .help(batch.phase == .selecting ? pr.title : entry.status.text)
        .contentShape(.rect)
    }

    @ViewBuilder
    private func statusIcon(_ entry: DependabotApprovalBatch.Entry, selected: Bool) -> some View {
        if batch.phase == .selecting {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        } else {
            switch entry.status {
            case .checking, .approving:
                ProgressView().controlSize(.small)
            case .approved:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .skipped:
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .pending:
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 8) {
            if batch.phase == .running {
                ProgressView(value: Double(batch.completedCount), total: Double(max(1, batch.entries.count)))
                    .tint(.accentColor)
            }
            HStack(spacing: 10) {
                switch batch.phase {
                case .selecting:
                    Button(L10n.text(.commonCancel), action: close).buttonStyle(.borderless)
                    Spacer()
                    Button(L10n.text(.batchApproveCount, String(batch.selectedIDs.count)), action: start)
                        .buttonStyle(BatchPrimaryButtonStyle())
                        .disabled(batch.selectedIDs.isEmpty)
                case .running:
                    Text(L10n.text(.batchProgress, String(batch.completedCount), String(batch.entries.count)))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text(batch.stopRequested ? .batchStopping : .batchStop)) { batch.stop() }
                        .disabled(batch.stopRequested)
                        .help(L10n.text(.batchStopHelp))
                case .finished:
                    results
                    Spacer(minLength: 0)
                    Button(L10n.text(.batchDone), action: close).buttonStyle(BatchPrimaryButtonStyle())
                }
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var results: some View {
        HStack(spacing: 8) {
            if batch.approvedCount > 0 { resultCount(.batchApprovedCount, count: batch.approvedCount, tint: .green) }
            if batch.skippedCount > 0 { resultCount(.batchSkippedCount, count: batch.skippedCount, tint: .secondary) }
            if batch.failedCount > 0 { resultCount(.batchFailedCount, count: batch.failedCount, tint: .red) }
            Button(action: newBatch) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(L10n.text(.batchNew))
                .accessibilityLabel(L10n.text(.batchNew))
        }
        .font(.system(size: 10, weight: .medium))
    }

    private func resultCount(_ key: L10n.Key, count: Int, tint: Color) -> some View {
        Text(L10n.text(key, String(count)))
            .foregroundStyle(tint)
            .fixedSize()
    }
}

private struct BatchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)
                        : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}
