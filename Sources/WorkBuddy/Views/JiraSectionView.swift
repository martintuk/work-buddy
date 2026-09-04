import AppKit
import SwiftUI

struct JiraSectionView: View {
    static let loginCommand = "acli jira auth login"

    let store: JiraStore

    @State private var copiedLoginCommand = false

    var body: some View {
        Group {
            switch store.state {
            case .idle, .checking:
                ProgressView("Consultando Jira…")
                    .controlSize(.small)
            case .signedOut:
                signedOut
            case .authenticated:
                ContentUnavailableView {
                    Label("Jira conectado", systemImage: "checkmark.circle")
                }
            case .unavailable:
                ContentUnavailableView {
                    Label("ACLI no está instalado", systemImage: "terminal")
                } description: {
                    Text("Instalalo fuera de work-buddy y volvé a verificar.")
                } actions: {
                    retryButton
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("No pude consultar Jira", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).font(.caption)
                } actions: {
                    retryButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.refresh() }
    }

    private var signedOut: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Conectá Jira desde Terminal")
                .font(.headline)

            HStack(spacing: 8) {
                Text(Self.loginCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    copyLoginCommand()
                } label: {
                    Image(systemName: copiedLoginCommand ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(copiedLoginCommand ? "Comando copiado" : "Copiar comando")
                .accessibilityLabel(copiedLoginCommand ? "Comando copiado" : "Copiar comando")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            retryButton
        }
        .padding(16)
    }

    private var retryButton: some View {
        Button("Volver a verificar") { store.refresh() }
            .controlSize(.small)
            .disabled(store.isChecking)
    }

    private func copyLoginCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.loginCommand, forType: .string)
        copiedLoginCommand = true
    }
}
