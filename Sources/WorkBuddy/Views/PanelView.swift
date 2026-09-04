import AppKit
import SwiftUI

/// Contenedor de las categorías del panel de la barra de menú.
struct PanelView: View {
    static let preferredSize = NSSize(width: 420, height: 560)

    let store: ReviewQueueStore

    @State private var selectedCategory: Category = .github
    @State private var showingConfiguration = false

    private enum Category: String, CaseIterable, Identifiable {
        case github = "GitHub"
        case jira = "Jira"

        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if showingConfiguration {
                Divider()
                ConfigurationView(store: store)
            } else {
                Picker("Categoría", selection: $selectedCategory) {
                    ForEach(Category.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                Divider()
                categoryContent
            }

            Divider()
            footer
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Work Buddy")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if case .loading = store.state {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    store.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Actualizar")
            }

            Button {
                showingConfiguration.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(showingConfiguration ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(showingConfiguration ? "Cerrar configuración" : "Configuración")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .github:
            GitHubSectionView(store: store)
        case .jira:
            ContentUnavailableView {
                Label("Jira", systemImage: "checklist")
            } description: {
                Text("Próximamente")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if let lastUpdated = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(LastUpdatedText.format(lastUpdated, relativeTo: context.date))
                }
            } else {
                Text("v\(Self.version)")
            }
            Spacer()
            Button("Salir") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
