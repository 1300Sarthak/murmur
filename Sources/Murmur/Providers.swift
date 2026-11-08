import Foundation
import Network

/// Where Ask AI answers come from. `auto` prefers frontier models when online and falls back to local Ollama.
enum AskProvider: String, CaseIterable, Identifiable {
    case auto, claude, codex, local
    var id: String { rawValue }
    var short: String {
        switch self {
        case .auto: "Auto"
        case .claude: "Claude \(Prefs.claudeModel)"
        case .codex: "Codex"
        case .local: Prefs.llmModel
        }
    }
    var title: String {
        switch self {
        case .auto: "Auto (best available)"
        case .claude: "Claude (Claude Code CLI)"
        case .codex: "Codex (Codex CLI)"
        case .local: "Local (Ollama)"
        }
    }
}

/// Tracks whether the Mac has a usable internet path, so Auto can switch to the local model offline.
final class Connectivity {
    static let shared = Connectivity()
    private let monitor = NWPathMonitor()
    private(set) var online = true
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.online = path.status == .satisfied }
        monitor.start(queue: DispatchQueue(label: "murmur.net"))
    }
}

/// Runs an agent CLI headlessly and streams its text output. No tools, no MCP servers, no hooks.
enum FrontierCLI {
    static func find(_ name: String) -> String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var claudePath: String? { find("claude") }
    static var codexPath: String? { find("codex") }

    /// Previous turns folded into one prompt, since each CLI call is a fresh, stateless session.
    static func prompt(for messages: [Ollama.Message]) -> String {
        let turns = messages.filter { $0.role != "system" && !$0.content.isEmpty }
        guard turns.count > 1 else { return turns.last?.content ?? "" }
        let history = turns.dropLast().map { "\($0.role == "user" ? "User" : "Assistant"): \($0.content)" }.joined(separator: "\n\n")
        return "Conversation so far:\n\(history)\n\nNew question: \(turns.last!.content)"
    }

    static func claude(system: String, messages: [Ollama.Message]) -> AsyncThrowingStream<String, Error> {
        guard let bin = claudePath else { return failing("Claude Code CLI not found") }
        var env = baseEnv()
        // Nothing beyond the request itself: no telemetry, error reports, or other non-essential traffic.
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        env["DISABLE_TELEMETRY"] = "1"
        env["DISABLE_ERROR_REPORTING"] = "1"
        let account = Prefs.agentAccount.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        if !account.isEmpty, account != "main" {
            env["CLAUDE_CONFIG_DIR"] = "\(NSHomeDirectory())/.claude-accounts/\(account)"
        }
        // Web search + page fetching only: enough for news, prices, scores, docs. Nothing touches your files.
        let args = ["-p", "--setting-sources", "", "--strict-mcp-config", "--tools", "WebSearch", "WebFetch",
                    "--allowedTools", "WebSearch", "WebFetch", "--no-session-persistence",
                    "--model", Prefs.claudeModel, "--system-prompt", system,
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--", prompt(for: messages)] // "--": a transcript starting with "-" is never read as a flag
        var wroteText = false
        var toolSince = false
        return run(bin, args, env: env) { obj in
            if obj["type"] as? String == "stream_event", let event = obj["event"] as? [String: Any] {
                if event["type"] as? String == "content_block_start", let block = event["content_block"] as? [String: Any],
                   (block["type"] as? String)?.contains("tool_use") == true {
                    toolSince = true
                    return .text(statusMarker + (block["name"] as? String == "WebFetch" ? "Reading a page" : "Searching the web"))
                }
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    // Keep text written before and after a search as separate paragraphs.
                    let sep = (toolSince && wroteText) ? "\n\n" : ""
                    toolSince = false
                    wroteText = true
                    return .text(sep + text)
                }
            }
            if obj["type"] as? String == "result", obj["is_error"] as? Bool == true {
                return .fail(obj["result"] as? String ?? "Claude returned an error")
            }
            return .skip
        }
    }

    static func codex(system: String, messages: [Ollama.Message]) -> AsyncThrowingStream<String, Error> {
        guard let bin = codexPath else { return failing("Codex CLI not found") }
        let scratch = Prefs.supportDir.appendingPathComponent("codex-scratch").path
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let args = ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-C", scratch,
                    "\(system)\n\n\(prompt(for: messages))"]
        var env = baseEnv()
        let home = isolatedCodexHome()
        if let home { env["CODEX_HOME"] = home }
        return run(bin, args, env: env, onExit: { if let home { wipe(home) } }) { obj in
            if obj["type"] as? String == "item.completed", let item = obj["item"] as? [String: Any],
               item["type"] as? String == "agent_message", let text = item["text"] as? String { return .text(text) }
            if obj["type"] as? String == "turn.failed" || obj["type"] as? String == "error" {
                return .fail((obj["message"] as? String) ?? "Codex returned an error")
            }
            return .skip
        }
    }

    /// A private CODEX_HOME holding only your login (symlinked) and a minimal config, so Ask questions never
    /// touch Codex's history, memories, logs, plugins, hooks, or global AGENTS.md.
    private static func isolatedCodexHome() -> String? {
        let fm = FileManager.default
        let real = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
        guard fm.fileExists(atPath: "\(real)/auth.json") else { return nil }
        let home = Prefs.supportDir.appendingPathComponent("codex-home")
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        wipe(home.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        let auth = home.appendingPathComponent("auth.json")
        if (try? fm.destinationOfSymbolicLink(atPath: auth.path)) == nil {
            try? fm.removeItem(at: auth)
            try? fm.createSymbolicLink(atPath: auth.path, withDestinationPath: "\(real)/auth.json")
        }
        // Keep your chosen model, nothing else.
        let model = (try? String(contentsOfFile: "\(real)/config.toml", encoding: .utf8))?
            .split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model =") }
        let config = (model.map { "\($0)\n" } ?? "") + "[history]\npersistence = \"none\"\n"
        try? config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        return home.path
    }

    /// Deletes everything Codex wrote (logs, state, memories, caches) except the login link and config.
    private static func wipe(_ home: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] where name != "auth.json" && name != "config.toml" {
            try? FileManager.default.removeItem(atPath: "\(home)/\(name)")
        }
    }

    /// Prefix for status updates (e.g. "Searching the web") mixed into the text stream.
    static let statusMarker = "\u{1}"

    // MARK: Plumbing

    enum Parsed { case text(String), fail(String), skip }

    private static func baseEnv() -> [String: String] {
        let p = ProcessInfo.processInfo.environment
        return ["HOME": NSHomeDirectory(), "USER": p["USER"] ?? NSUserName(), "LOGNAME": p["LOGNAME"] ?? NSUserName(),
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(NSHomeDirectory())/.local/bin", "LANG": "en_US.UTF-8"]
    }

    private static func failing(_ msg: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: MurmurError.message(msg)) }
    }

    private static func run(_ bin: String, _ args: [String], env: [String: String], onExit: (@Sendable () -> Void)? = nil,
                            parse: @escaping ([String: Any]) -> Parsed) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.environment = env
            p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            p.standardInput = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let task = Task.detached {
                var failed: String?
                var produced = false
                do {
                    try p.run()
                    // Lines are read in order on one task, so nothing is lost when the process exits.
                    for try await line in out.fileHandleForReading.bytes.lines {
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        switch parse(obj) {
                        case .text(let t): produced = true; continuation.yield(t)
                        case .fail(let m): failed = m
                        case .skip: break
                        }
                    }
                    p.waitUntilExit()
                    onExit?()
                    if let failed { continuation.finish(throwing: MurmurError.message(failed)) }
                    else if !produced { continuation.finish(throwing: MurmurError.message("No answer (exit \(p.terminationStatus))")) }
                    else { continuation.finish() }
                } catch {
                    onExit?()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel(); if p.isRunning { p.terminate() } }
        }
    }
}
