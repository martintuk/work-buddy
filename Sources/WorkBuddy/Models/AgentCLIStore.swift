import AppKit
import Observation

enum AgentTerminal: String, CaseIterable, Identifiable, Sendable {
    case terminal, ghostty, iterm, custom

    var id: Self { self }
    var name: String {
        switch self {
        case .terminal: "Terminal"
        case .ghostty: "Ghostty"
        case .iterm: "iTerm2"
        case .custom: L10n.text(.agentCustomTerminal)
        }
    }
    var bundleIdentifier: String? {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .ghostty: "com.mitchellh.ghostty"
        case .iterm: "com.googlecode.iterm2"
        case .custom: nil
        }
    }
}

enum AgentCLI: String, CaseIterable, Identifiable, Sendable {
    case none, codex, claude, gemini, custom

    var id: Self { self }
    var name: String {
        switch self {
        case .none: L10n.text(.agentChoose)
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .gemini: "Gemini CLI"
        case .custom: L10n.text(.agentCustom)
        }
    }

    func command(custom: String) -> String {
        switch self {
        case .none: ""
        case .custom: custom.trimmingCharacters(in: .whitespacesAndNewlines)
        case .codex, .claude, .gemini: rawValue
        }
    }
}

@MainActor
@Observable
final class AgentCLIStore {
    private let defaults: UserDefaults
    var terminal: AgentTerminal { didSet { defaults.set(terminal.rawValue, forKey: "agent.terminal") } }
    var agent: AgentCLI { didSet { defaults.set(agent.rawValue, forKey: "agent.cli") } }
    var customCommand: String { didSet { defaults.set(customCommand, forKey: "agent.customCommand") } }
    var customTerminalCommand: String { didSet { defaults.set(customTerminalCommand, forKey: "agent.customTerminalCommand") } }
    private(set) var installedTerminals: [AgentTerminal] = []
    private(set) var openingID: String?
    private(set) var error: Error?
    var isOpening: Bool { openingID != nil }
    var openTitle: String {
        switch agent {
        case .none: L10n.text(.agentOpen)
        case .custom: L10n.text(.agentOpenCustom)
        default: L10n.text(.agentOpenWith, agent.name)
        }
    }
    var isConfigured: Bool {
        !agent.command(custom: customCommand).isEmpty
            && (terminal != .custom || !customTerminalCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terminal = AgentTerminal(rawValue: defaults.string(forKey: "agent.terminal") ?? "") ?? .terminal
        agent = AgentCLI(rawValue: defaults.string(forKey: "agent.cli") ?? "") ?? .none
        customCommand = defaults.string(forKey: "agent.customCommand") ?? ""
        customTerminalCommand = defaults.string(forKey: "agent.customTerminalCommand") ?? ""
    }

    func refreshTerminals() {
        installedTerminals = AgentTerminal.allCases.filter {
            guard let identifier = $0.bundleIdentifier else { return false }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
        }
    }

    func dismissError() { error = nil }

    func open(_ folder: URL, id: String) async {
        guard !isOpening else { return }
        openingID = id
        error = nil
        defer { openingID = nil }
        do {
            try AgentTerminalLauncher.validate(folder: folder, command: agent.command(custom: customCommand))
            if terminal == .custom {
                let launch = try CustomTerminalLaunch(
                    template: customTerminalCommand, folder: folder, command: agent.command(custom: customCommand)
                )
                try launch.start()
                // Algunos ejecutables de terminal permanecen abiertos toda la sesión: no bloquear el panel.
                Task { [weak self] in
                    do {
                        _ = try await Task.detached(priority: .utility) { try launch.finish() }.value
                    } catch { self?.error = error }
                }
                return
            }
            guard let identifier = terminal.bundleIdentifier,
                  let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                throw AgentLaunchError.missingTerminal
            }
            if terminal == .ghostty {
                let version = Bundle(url: application)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                guard version.compare("1.3.0", options: .numeric) != .orderedAscending else {
                    throw AgentLaunchError.ghosttyVersion
                }
            }
            let script = try AgentTerminalLauncher.script(terminal: terminal, folder: folder,
                                                      command: agent.command(custom: customCommand))
            _ = try await Task.detached(priority: .userInitiated) {
                try AgentTerminalLauncher.execute(script)
            }.value
        } catch { self.error = error }
    }
}

enum AgentLaunchError: LocalizedError {
    case missingTerminal, missingCommand, missingTerminalCommand, ghosttyVersion, automationDenied, script(String)

    var errorDescription: String? {
        switch self {
        case .missingTerminal: L10n.text(.agentMissingTerminal)
        case .missingCommand: L10n.text(.agentChoose)
        case .missingTerminalCommand: L10n.text(.agentTerminalCommandMissing)
        case .ghosttyVersion: L10n.text(.agentGhosttyVersion)
        case .automationDenied: L10n.text(.agentAutomationDenied)
        case .script(let message): L10n.text(.agentLaunchFailed, message)
        }
    }
}

enum AgentTerminalLauncher {
    static func validate(folder: URL, command: String) throws {
        var isDirectory: ObjCBool = false
        guard folder.isFileURL,
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else {
            throw EditorStore.EditorError.missingFolder
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentLaunchError.missingCommand
        }
    }

    // El comando personalizado es shell explícito del usuario; la carpeta siempre es un argumento literal.
    static func shellCommand(folder: URL, command: String) -> String {
        // eval mantiene todo el comando del usuario detrás del cd, incluso si contiene varios comandos.
        // También funciona con fish, sin imponer sintaxis de agrupación exclusiva de shells POSIX.
        "cd \(shellQuote(folder.path)) && eval \(shellQuote(command))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func script(terminal: AgentTerminal, folder: URL, command: String) throws -> String {
        guard let identifier = terminal.bundleIdentifier else { throw AgentLaunchError.missingTerminal }
        let input = shellCommand(folder: folder, command: command)
        let body: String
        switch terminal {
        case .terminal:
            // Sin un destino, do script crea una ventana, nunca escribe en una sesión existente.
            body = "do script \(appleScriptQuote(input))\nactivate"
        case .iterm:
            body = """
            set agentWindow to create window with default profile
            tell current session of agentWindow
                write text \(appleScriptQuote(input))
            end tell
            activate
            """
        case .ghostty:
            body = """
            set cfg to new surface configuration
            set initial working directory of cfg to \(appleScriptQuote(folder.path))
            set initial input of cfg to \(appleScriptQuote(input + "\n"))
            set agentWindow to new window with configuration cfg
            activate window agentWindow
            """
        case .custom:
            throw AgentLaunchError.missingTerminal
        }
        return "tell application id \(appleScriptQuote(identifier))\n\(body)\nend tell"
    }

    @discardableResult
    static func execute(_ source: String) throws -> String {
        // Un proceso separado evita bloquear la UI y compartir el runtime de AppleScript entre hilos.
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if message.contains("(-1743)") { throw AgentLaunchError.automationDenied }
            throw AgentLaunchError.script(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return message
    }
}

/// El template se ejecuta en zsh. Los valores viajan como variables de entorno, nunca como código interpolado.
final class CustomTerminalLaunch: Sendable {
    private let process: Process
    private let output: Pipe

    init(template: String, folder: URL, command: String) throws {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentLaunchError.missingTerminalCommand
        }
        process = Process()
        output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", template]
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["WORK_BUDDY_FOLDER"] = folder.path
        environment["WORK_BUDDY_COMMAND"] = AgentTerminalLauncher.shellCommand(folder: folder, command: command)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
    }

    func start() throws { try process.run() }

    func finish() throws -> String {
        // Drenar toda la salida sin retener logs ilimitados de una terminal que siga ejecutándose.
        var captured = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            captured.append(chunk.prefix(max(0, 8192 - captured.count)))
        }
        process.waitUntilExit()
        let text = String(decoding: captured, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let details = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentLaunchError.script(details.isEmpty ? String(process.terminationStatus) : details)
        }
        return text
    }
}
