import Foundation
import Testing

@testable import WorkBuddy

struct EditorStoreTests {
    @Test("Discovery includes nested JetBrains IDEs, skips Toolbox and bundle internals")
    func discovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rubyMine = try makeApplication(at: root.appendingPathComponent("RubyMine.app"),
                                          identifier: "com.jetbrains.rubymine")
        let pyCharm = try makeApplication(at: root.appendingPathComponent("Toolbox/apps/PyCharm/ch-0/123/PyCharm.app"),
                                         identifier: "com.jetbrains.pycharm")
        _ = try makeApplication(at: root.appendingPathComponent("Toolbox.app"), identifier: "com.jetbrains.toolbox")
        _ = try makeApplication(at: root.appendingPathComponent("Unrelated.app"), identifier: "example.unrelated")
        _ = try makeApplication(at: rubyMine.appendingPathComponent("Contents/Helper.app"),
                                identifier: "com.jetbrains.helper")
        let discovered = EditorApplication.discover(in: [root, root])
        #expect(Set(discovered.map(\.url)) == Set([rubyMine, pyCharm]))
        #expect(discovered.count == 2)
    }

    @Test("A custom editor with spaces in its path persists across store instances")
    @MainActor
    func persistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApplication(at: root.appendingPathComponent("Custom Editor.app"), identifier: "example.editor")
        let suite = "work-buddy.editor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorStore(defaults: defaults)
        #expect(store.selectedURL == nil)
        store.select(try #require(EditorApplication(url: url)))
        let restored = EditorStore(defaults: defaults)
        #expect(restored.selectedURL == url)
        #expect(restored.selectedName == "Custom Editor")
        #expect(restored.choices.map(\.url) == [url])
    }

    @Test("A removed repository is rejected before launching an editor")
    @MainActor
    func missingFolder() async throws {
        let suite = "work-buddy.editor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorStore(defaults: defaults)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: EditorStore.EditorError.missingFolder) {
            try await store.open(missing)
        }
    }

    @Test("Separate installations of the same editor remain available")
    func separateInstallations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let standard = try makeApplication(at: root.appendingPathComponent("Xcode.app"),
                                           identifier: "com.apple.dt.Xcode", name: "Xcode")
        let beta = try makeApplication(at: root.appendingPathComponent("Xcode-27-Beta.app"),
                                       identifier: "com.apple.dt.Xcode", name: "Xcode")
        let discovered = EditorApplication.discover(in: [root])
        #expect(Set(discovered.map(\.url)) == Set([standard, beta]))
        #expect(discovered.count == 2)
    }

    @Test("Refreshing installed editors does not select one")
    @MainActor
    func noAutomaticSelection() async throws {
        let suite = "work-buddy.editor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EditorStore(defaults: defaults)
        await store.refresh()
        #expect(store.selectedURL == nil)
        #expect(store.selectedName == nil)
        #expect(EditorStore(defaults: defaults).selectedURL == nil)
    }

    private func makeApplication(at url: URL, identifier: String, name: String? = nil) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name ?? url.deletingPathExtension().lastPathComponent,
            "CFBundleExecutable": "editor",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("MacOS/editor"))
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
