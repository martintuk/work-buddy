import AppKit
import SwiftUI

struct ActivityView: View {
    let activity: ActivityLog
    @Binding var isExpanded: Bool
    let close: () -> Void
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text(.activityTitle)).font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if activity.runningCount > 0 {
                    ProgressView().controlSize(.mini)
                    Text(String(activity.runningCount)).font(.system(size: 10)).monospacedDigit()
                }
                Spacer(minLength: 0)
                iconButton("trash", title: L10n.text(.activityClear)) { activity.clearCompleted() }
                    .disabled(!activity.entries.contains { $0.status.isComplete })
                iconButton(isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           title: L10n.text(isExpanded ? .activityCollapse : .activityExpand)) {
                    isExpanded.toggle()
                }
                iconButton("xmark", title: L10n.text(.activityClose), action: close)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            if activity.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 22))
                    Text(L10n.text(.activityEmpty)).font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(activity.entries) { entry in
                            row(entry)
                            Divider().padding(.leading, 40)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { activity.setVisible(true) }
        .onDisappear { activity.setVisible(false) }
    }

    private func row(_ entry: ActivityLog.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.symbol).frame(width: 18, height: 18).foregroundStyle(.secondary)
                .padding(.top, 1)
            Button {
                selectedID = selectedID == entry.id ? nil : entry.id
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.title.text).fontWeight(.medium)
                        Text(entry.target).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(entry.status.text).lineLimit(selectedID == entry.id ? nil : 1)
                            .foregroundStyle(statusColor(entry.status))
                        Spacer(minLength: 0)
                        Text(entry.source.title)
                        Text(entry.date, style: .time).monospacedDigit()
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    if selectedID == entry.id, !entry.detail.isEmpty {
                        Text(entry.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.title.text), \(entry.target), \(entry.source.title), \(entry.status.text)")
            .accessibilityValue(L10n.text(selectedID == entry.id ? .sectionHide : .sectionShow))
            statusIcon(entry.status).frame(width: 14, height: 18)
            if let url = entry.url {
                iconButton("arrow.up.forward.square", title: L10n.text(.activityOpen)) {
                    NSWorkspace.shared.open(url)
                }
                .frame(height: 18)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 9)
        .help([entry.title.text, entry.target, entry.detail, entry.status.text, entry.source.title,
               entry.date.formatted(date: .abbreviated, time: .standard)].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private func iconButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 16, height: 20) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }

    private func statusColor(_ status: ActivityLog.Status) -> Color {
        switch status {
        case .failed: .red
        case .succeeded: .green
        default: .secondary
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ActivityLog.Status) -> some View {
        switch status {
        case .checking, .running: ProgressView().controlSize(.mini)
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}
