import AppKit
import SwiftUI

struct ActivityView: View {
    let activity: ActivityLog
    @Binding var isExpanded: Bool
    let close: () -> Void
    var canVerify: (ActivityLog.Entry) -> Bool = { _ in false }
    var verify: (ActivityLog.Entry) -> Void = { _ in }
    var canRetry: (ActivityLog.Entry) -> Bool = { _ in false }
    var retry: (ActivityLog.Entry) -> Void = { _ in }
    var focus: ActivityLog.Focus? = nil
    var clearFocus: () -> Void = {}
    var canShowInList: (ActivityLog.Entry) -> Bool = { _ in false }
    var showInList: (ActivityLog.Entry) -> Void = { _ in }
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
                if focus != nil {
                    iconButton("line.3.horizontal.decrease.circle.fill", title: L10n.text(.activityShowAll), action: clearFocus)
                }
                iconButton("trash", title: L10n.text(.activityClear)) { activity.clearCompleted(focus: focus) }
                    .disabled(!activity.filtered(focus).contains { $0.status.isClearable })
                iconButton(isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           title: L10n.text(isExpanded ? .activityCollapse : .activityExpand)) {
                    isExpanded.toggle()
                }
                iconButton("xmark", title: L10n.text(.activityClose), action: close)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            if activity.filtered(focus).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 22))
                    Text(L10n.text(.activityEmpty)).font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(activity.filtered(focus)) { entry in
                            row(entry)
                            Divider().padding(.leading, 40)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { activity.setVisible(true, focus: focus) }
        .onChange(of: focus) { _, focus in activity.setVisible(true, focus: focus) }
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
                        Text(entry.statusText).lineLimit(selectedID == entry.id ? nil : 1)
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
            .accessibilityLabel("\(entry.title.text), \(entry.target), \(entry.source.title), \(entry.statusText)")
            .accessibilityValue(L10n.text(selectedID == entry.id ? .sectionHide : .sectionShow))
            ActivityStatusIcon(status: entry.status).frame(width: 14, height: 18)
            if canVerify(entry) {
                iconButton("arrow.clockwise.circle", title: L10n.text(.activityVerify)) { verify(entry) }
                    .frame(height: 18)
            } else if canRetry(entry) {
                iconButton("arrow.clockwise", title: L10n.text(.activityRetry)) { retry(entry) }
                    .frame(height: 18)
            }
            if canShowInList(entry) {
                iconButton("list.bullet", title: L10n.text(.activityShowInList)) { showInList(entry) }
                    .frame(height: 18)
            }
            if let url = entry.url {
                iconButton("arrow.up.forward.square", title: L10n.text(.activityOpen)) {
                    NSWorkspace.shared.open(url)
                }
                .frame(height: 18)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 9)
        .help([entry.title.text, entry.target, entry.detail, entry.statusText, entry.source.title,
               entry.date.formatted(date: .abbreviated, time: .standard)].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private func iconButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 16, height: 20) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }

    private func statusColor(_ status: ActivityLog.Status) -> Color {
        switch status {
        case .failed: .red
        case .uncertain: .orange
        case .succeeded: .green
        default: .secondary
        }
    }

}

struct ActivityStatusIcon: View {
    let status: ActivityLog.Status
    @ViewBuilder
    var body: some View {
        switch status {
        case .checking, .running: ProgressView().controlSize(.mini)
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .uncertain: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}
