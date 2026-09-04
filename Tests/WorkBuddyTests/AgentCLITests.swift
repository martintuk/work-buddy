import AppKit
import Foundation
import Testing

@testable import WorkBuddy

struct AgentCLITests {
    @Test("Project paths remain literal and CLI arguments reach the agent intact", arguments: ["/bin/zsh", "/bin/bash"])
    func literalFolder(shell: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project ' \" $HOME `whoami`\nnext line")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try runShell(shell, AgentTerminalLauncher.shellCommand(
            folder: folder, command: "printf '%s\\n' \"$PWD\" 'argument with spaces'"
        ))
        #expect(result.status == 0)
        #expect(result.output == folder.path + "\nargument with spaces\n")
    }

    @Test("Failure to enter the project never runs any part of a custom command")
    func missingDirectory() throws {
        let folder = URL(fileURLWithPath: "/tmp/work-buddy-missing-\(UUID().uuidString)")
        let result = try runShell("/bin/zsh", AgentTerminalLauncher.shellCommand(
            folder: folder, command: "printf first; printf second\nprintf third"
        ))
        #expect(result.status != 0)
        #expect(result.output.isEmpty)
    }

    @Test("AppleScript transport preserves command text without evaluating interpolation")
    func appleScriptLiteral() throws {
        let value = "quotes '\" backslash \\ newline\nreturn\r $(touch nope)"
        let result = try AgentTerminalLauncher.execute("return " + AgentTerminalLauncher.appleScriptQuote(value))
        #expect(result == value + "\n")
    }

    @Test("Terminal adapters compile against the installed scripting dictionaries")
    @MainActor
    func scriptingDictionaries() throws {
        for terminal in AgentTerminal.allCases {
            guard let identifier = terminal.bundleIdentifier,
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil else { continue }
            let source = try AgentTerminalLauncher.script(terminal: terminal, folder: URL(fileURLWithPath: "/tmp/Project ' one"), command: "printf 'hello world'")
            let script = try #require(NSAppleScript(source: source))
            var details: NSDictionary?
            let compiled = script.compileAndReturnError(&details)
            #expect(compiled, "\(terminal.name): \(String(describing: details))")
        }
    }

    @Test("Custom terminal passes quoted project paths and agent arguments through the launch command")
    func customTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project ' \" $HOME `whoami`")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launch = try CustomTerminalLaunch(
            template: "printf '%s\\n' \"$WORK_BUDDY_FOLDER\"; /bin/zsh -c \"$WORK_BUDDY_COMMAND\"",
            folder: folder, command: "printf '%s\\n' \"$PWD\" 'argument with spaces'"
        )
        try launch.start()
        #expect(try launch.finish() == folder.path + "\n" + folder.path + "\nargument with spaces\n")
    }

    @Test("Custom terminal failures are reported and empty launch commands are rejected")
    func customTerminalFailure() throws {
        let folder = FileManager.default.temporaryDirectory
        #expect(throws: AgentLaunchError.self) {
            try CustomTerminalLaunch(template: "  ", folder: folder, command: "codex")
        }
        let launch = try CustomTerminalLaunch(template: "printf 'launcher failed' >&2; exit 7", folder: folder, command: "codex")
        try launch.start()
        #expect(throws: AgentLaunchError.self) { try launch.finish() }
    }

    private func runShell(_ executable: String, _ command: String) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", command]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
