import SwiftUI

/// Una única cabecera en ambos estados; al expandir se agrega la cola debajo.
struct PullRequestAutopilotBar: View {
    let autopilot: PullRequestAutopilot
    let setEnabled: @MainActor (Bool) -> Void
    @State private var showingResults = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Autopilot")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize()
                Button(L10n.text(autopilot.isActive ? .autopilotStop : .autopilotStart)) {
                    setEnabled(!autopilot.isEnabled)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .fixedSize()
                .tint(autopilot.isActive ? Color.secondary : Color.accentColor)
                .font(.system(size: 11, weight: .semibold))
                .disabled(!autopilot.isEnabled && autopilot.current != nil)
                .help(L10n.text(autopilot.isActive ? .batchStopHelp : .autopilotHelp))
                .accessibilityLabel("\(L10n.text(autopilot.isActive ? .autopilotStop : .autopilotStart)) · \(L10n.text(.autopilotHelp))")
                headerStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                if !autopilot.history.isEmpty {
                    Button { showingResults.toggle() } label: {
                        Image(systemName: autopilot.notice == nil ? "clock.arrow.circlepath" : "exclamationmark.circle.fill")
                            .foregroundStyle(autopilot.notice == nil ? Color.secondary : Color.red)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text(.batchViewResults)).accessibilityLabel(L10n.text(.batchViewResults))
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { autopilot.isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(String(autopilot.queue.count)).monospacedDigit()
                        Image(systemName: autopilot.isExpanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                    }.frame(minWidth: 30, minHeight: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .fixedSize()
                .help(L10n.text(.autopilotQueue, String(autopilot.queue.count)))
                .accessibilityLabel(L10n.text(.autopilotQueue, String(autopilot.queue.count)))
                .accessibilityValue(L10n.text(autopilot.isExpanded ? .autopilotExpanded : .autopilotCollapsed))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if autopilot.isExpanded {
                Divider()
                VStack(spacing: 6) {
                    if autopilot.current == nil && autopilot.queue.isEmpty {
                        Text(L10n.text(.autopilotEmpty))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                if let current = autopilot.current { queueRow(current.candidate, status: current.status) }
                                ForEach(autopilot.queue) { queueRow($0, status: nil) }
                            }
                        }
                        .frame(height: min(168, CGFloat(autopilot.queue.count + (autopilot.current == nil ? 0 : 1)) * 44))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .queueControlSurface()
        .popover(isPresented: $showingResults, arrowEdge: .top) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(autopilot.history.enumerated().reversed()), id: \.offset) { _, entry in
                        queueRow(entry.candidate, status: entry.status)
                    }
                }.padding(12)
            }.frame(width: 320, height: min(280, CGFloat(autopilot.history.count * 44 + 24)))
        }
    }

    @ViewBuilder
    private var headerStatus: some View {
        if !autopilot.isExpanded, let current = autopilot.current {
            HStack(spacing: 6) {
                Image(systemName: current.candidate.action.symbol)
                    .foregroundStyle(Color.accentColor)
                Text("\(autopilot.isEnabled ? current.status.text : L10n.text(.batchStopping)) · \(current.pullRequest.shortRepository) #\(current.pullRequest.number)")
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .help("\(current.candidate.action.title) · \(current.pullRequest.repository) #\(current.pullRequest.number)\n\(current.status.text)")
        } else if autopilot.current == nil && (autopilot.isEnabled || autopilot.notice != nil) {
            HStack(spacing: 6) {
                Image(systemName: autopilot.notice == nil ? "clock" : "exclamationmark.circle")
                Text(L10n.text(autopilot.notice == nil ? .autopilotWaiting : .autopilotPaused))
                    .lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .help(autopilot.notice?.text ?? L10n.text(.autopilotWaiting))
        } else {
            Spacer(minLength: 0)
        }
    }

    private func queueRow(_ candidate: PullRequestBatch.Candidate, status: PullRequestBatch.Status?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: candidate.action.symbol).frame(width: 14)
                .foregroundStyle(status.map { !$0.isComplete } ?? false ? Color.accentColor : Color.secondary)
            PullRequestSummary(pullRequest: candidate.pullRequest, titleLineLimit: 1)
            if let status { BatchStatusIcon(status: status).frame(width: 14, height: 14) }
        }
        .font(.system(size: 11, weight: .medium)).frame(height: 42)
        .padding(.horizontal, 6)
        .background(Color.accentColor.opacity(status.map { !$0.isComplete } ?? false ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5))
        .help("\(candidate.action.title) · \(candidate.pullRequest.repository) #\(candidate.pullRequest.number)\n\(candidate.pullRequest.title)\n\(status?.text ?? L10n.text(.batchPending))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(candidate.action.title), \(candidate.pullRequest.title), \(candidate.pullRequest.repository) #\(candidate.pullRequest.number), \(status?.text ?? L10n.text(.batchPending))")
    }
}
