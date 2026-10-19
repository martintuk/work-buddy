import AppKit
import Observation
import UniformTypeIdentifiers

struct EditorApplication: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let bundleIdentifier: String
    var id: String { url.path }

    init?(url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              bundle.executableURL != nil else { return nil }
        self.url = url
        name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        bundleIdentifier = identifier
    }

    private static let knownIdentifiers: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3",
        "dev.zed.Zed", "com.panic.Nova", "com.exafunction.windsurf"
    ]

    private var isEditor: Bool {
        Self.knownIdentifiers.contains(bundleIdentifier)
            || (bundleIdentifier.lowercased().hasPrefix("com.jetbrains.")
                && bundleIdentifier.lowercased() != "com.jetbrains.toolbox")
    }

    /// Also search Toolbox installations without descending into app bundles.
    static func discover() -> [Self] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps", isDirectory: true)
        ]
        return discover(in: roots)
    }

    static func discover(in roots: [URL]) -> [Self] {
        let manager = FileManager.default
        var editors: [String: Self] = [:]
        for root in roots {
            guard let enumerator = manager.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    if let editor = Self(url: url), editor.isEditor {
                        editors[editor.id] = editor
                    }
                } else if enumerator.level >= 6 {
                    enumerator.skipDescendants()
                }
            }
        }
        return editors.values.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

@MainActor
@Observable
final class EditorStore {
    private enum Key {
        static let path = "editor.applicationPath"
        static let bundleIdentifier = "editor.bundleIdentifier"
    }

    private let defaults: UserDefaults
    private(set) var selectedURL: URL?
    private(set) var installed: [EditorApplication] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedURL = defaults.string(forKey: Key.path).map { URL(fileURLWithPath: $0) }
    }

    var selectedName: String? {
        selectedURL.map { EditorApplication(url: $0)?.name ?? $0.deletingPathExtension().lastPathComponent }
    }

    var choices: [EditorApplication] {
        guard let selectedURL, let selected = EditorApplication(url: selectedURL),
              !installed.contains(where: { $0.id == selected.id }) else { return installed }
        return installed + [selected]
    }

    func refresh() async {
        installed = await Task.detached(priority: .userInitiated) {
            EditorApplication.discover()
        }.value
    }

    func select(_ editor: EditorApplication) {
        selectedURL = editor.url
        defaults.set(editor.url.path, forKey: Key.path)
        defaults.set(editor.bundleIdentifier, forKey: Key.bundleIdentifier)
    }

    @discardableResult
    func chooseOther() throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = L10n.text(.editorChoose)
        panel.prompt = L10n.text(.editorSelect)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard let editor = EditorApplication(url: url) else { throw EditorError.invalidApplication }
        select(editor)
        return true
    }

    func open(_ folder: URL) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else {
            throw EditorError.missingFolder
        }
        // Toolbox may relocate an updated bundle; recover the app by identifier.
        var editor = selectedURL.flatMap { EditorApplication(url: $0) }
        if editor == nil, let identifier = defaults.string(forKey: Key.bundleIdentifier),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            editor = EditorApplication(url: url)
        }
        guard let editor else { throw EditorError.missingApplication }
        select(editor)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(
            [folder], withApplicationAt: editor.url, configuration: configuration
        )
    }

    enum EditorError: LocalizedError {
        case invalidApplication, missingApplication, missingFolder

        var errorDescription: String? {
            switch self {
            case .invalidApplication: L10n.text(.editorInvalidApplication)
            case .missingApplication: L10n.text(.editorMissingApplication)
            case .missingFolder: L10n.text(.editorMissingFolder)
            }
        }
    }
}
