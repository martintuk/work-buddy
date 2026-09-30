import SwiftUI

/// La cola crece hacia arriba; el control de encendido siempre queda al pie.
struct PullRequestAutopilotBar: View {
    let autopilot: PullRequestAutopilot
    let setEnabled: @MainActor (Bool) -> Void
    @State private var showingResults = false

    var body: some View {
        VStack(spacing: 0) {
            if autopilot.isExpanded {
                VStack(spacing: 6) {
                    HStack {
                        Text("Dependabot").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                    }
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
                        .frame(height: min(168, CGFloat(autopilot.queue.count + (autopilot.current == nil ? 0 : 1)) * 28))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
            }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Toggle("Autopilot", isOn: Binding(get: { autopilot.isEnabled }, set: setEnabled))
                        .toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 11, weight: .medium))
                        .disabled(!autopilot.isEnabled && autopilot.current != nil)
                        .help(L10n.text(.autopilotHelp))
                        .accessibilityLabel(L10n.text(.autopilotHelp))
                    Spacer(minLength: 0)
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
                    .help(L10n.text(.autopilotQueue, String(autopilot.queue.count)))
                    .accessibilityLabel(L10n.text(.autopilotQueue, String(autopilot.queue.count)))
                    .accessibilityValue(L10n.text(autopilot.isExpanded ? .autopilotExpanded : .autopilotCollapsed))
                    if !autopilot.isActive {
                        Button { autopilot.close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(L10n.text(.autopilotClose)).accessibilityLabel(L10n.text(.autopilotClose))
                    }
                }
                if let current = autopilot.current {
                    HStack(spacing: 8) {
                        BatchStatusIcon(status: current.status).frame(width: 14, height: 14)
                        Text("\(autopilot.isEnabled ? current.status.text : L10n.text(.batchStopping)) · \(current.pullRequest.shortRepository) #\(current.pullRequest.number)")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("\(current.pullRequest.repository) #\(current.pullRequest.number)\n\(current.status.text)")
                } else if autopilot.isEnabled || autopilot.notice != nil {
                    HStack(spacing: 6) {
                        Image(systemName: autopilot.notice == nil ? "clock" : "exclamationmark.circle")
                        Text(L10n.text(autopilot.notice == nil ? .autopilotWaiting : .autopilotPaused))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(autopilot.notice?.text ?? L10n.text(.autopilotWaiting))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .popover(isPresented: $showingResults, arrowEdge: .top) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(autopilot.history.enumerated().reversed()), id: \.offset) { _, entry in
                        queueRow(entry.candidate, status: entry.status)
                    }
                }.padding(12)
            }.frame(width: 320, height: min(280, CGFloat(autopilot.history.count * 28 + 24)))
        }
    }

    private func queueRow(_ candidate: PullRequestBatch.Candidate, status: PullRequestBatch.Status?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: candidate.action.symbol).frame(width: 14).foregroundStyle(.secondary)
            Text(candidate.pullRequest.shortRepository).lineLimit(1).truncationMode(.middle)
            Text("#\(candidate.pullRequest.number)").foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 0)
            if let status { BatchStatusIcon(status: status).frame(width: 14, height: 14) }
        }
        .font(.system(size: 11, weight: .medium)).frame(height: 26)
        .padding(.horizontal, 6)
        .background(Color.accentColor.opacity(status.map { !$0.isComplete } ?? false ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5))
        .help("\(candidate.action.title) · \(candidate.pullRequest.repository) #\(candidate.pullRequest.number)\n\(candidate.pullRequest.title)\n\(status?.text ?? L10n.text(.batchPending))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(candidate.action.title), \(candidate.pullRequest.repository) #\(candidate.pullRequest.number), \(status?.text ?? L10n.text(.batchPending))")
    }
}
