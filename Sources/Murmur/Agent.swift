import Foundation

/// Drives Claude Code through cmux's socket CLI: no Apple Events or Accessibility needed.
enum Cmux {
    static let cli = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    static var installed: Bool { FileManager.default.isExecutableFile(atPath: cli) }

    @discardableResult
    static func run(_ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        // A hung cmux must never leave Murmur stuck mid-pipeline.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    /// The focused cmux pane, but only if Claude Code is its foreground process. Spoken text must never be
    /// typed into a plain shell, where Enter would execute it.
    static func focusedClaude() -> (workspace: String, surface: String, tty: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(run(["identify", "--no-caller"]).out.utf8)) as? [String: Any],
              let focused = json["focused"] as? [String: Any],
              let ws = focused["workspace_ref"] as? String,
              let surface = focused["surface_ref"] as? String,
              focused["surface_type"] as? String == "terminal" else { return nil }
        return claudeTarget(workspace: ws, surface: surface)
    }


    /// The given surface (or the workspace's selected one) if Claude Code is its foreground process.
    static func claudeTarget(workspace ws: String, surface: String? = nil) -> (workspace: String, surface: String, tty: String)? {
        let tree = run(["tree", "--workspace", ws]).out
        let selected: String? = tree.split(separator: "\n")
            .first { $0.contains("[selected]") && $0.contains("surface:") }
            .flatMap { line in line.range(of: #"surface:\d+"#, options: .regularExpression).map { String(line[$0]) } }
        guard let surface = surface ?? selected else { return nil }
        guard let line = tree.split(separator: "\n").first(where: { $0.contains("surface \(surface) ") }),
              let range = line.range(of: #"tty=(\S+)"#, options: .regularExpression) else { return nil }
        let tty = String(line[range].dropFirst(4))
        return foregroundIsClaude(tty: tty) ? (ws, surface, tty) : nil
    }

    static func foregroundIsClaude(tty: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        // comm = the executable itself, never its arguments (so `vim ~/claude/notes.md` doesn't count).
        p.arguments = ["-t", tty, "-o", "stat=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        // '+' in STAT marks the terminal's foreground process group.
        return out.split(separator: "\n").contains { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].contains("+") else { return false }
            return (String(parts[1]) as NSString).lastPathComponent == "claude"
        }
    }

    /// Types the instruction into an existing Claude Code session and submits it.
    static func send(_ text: String, to target: (workspace: String, surface: String, tty: String)) -> Bool {
        let line = sanitize(text)
        guard !line.isEmpty,
              run(["send", "--workspace", target.workspace, "--surface", target.surface, "--", line]).ok else { return false }
        Thread.sleep(forTimeInterval: 0.08)
        // Re-check right before Enter: if Claude exited meanwhile, the text sits unsent in a shell instead of running.
        guard foregroundIsClaude(tty: target.tty) else { return false }
        return run(["send-key", "--workspace", target.workspace, "--surface", target.surface, "enter"]).ok
    }

    /// One line of plain text: no newlines (would submit early), no backslashes (cmux turns \n/\r into Enter),
    /// and no leading `!` (Claude's shell mode) or `-` (would read as a CLI flag).
    static func sanitize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\\s*\\n+\\s*", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\", with: " ")
            .trimmingCharacters(in: .whitespaces)
        while let c = t.first, c == "!" || c == "-" { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
        return t
    }

    /// Opens a new cmux workspace running `cca <account> <flags> "<prompt>"` in your login shell.
    static func newSession(prompt: String, account: String, cwd: String, flags: String, focus: Bool = true) -> Bool {
        let dir = Prefs.supportDir.appendingPathComponent("prompts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).txt")
        // The prompt goes through a file so no spoken text is ever parsed by the shell.
        // Old prompt files are only needed while the shell starts; keep the folder from growing.
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               d < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: old) }
        }
        var prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        while let c = prompt.first, c == "-" || c == "!" { prompt.removeFirst() } // never parsed as a claude flag
        guard !prompt.isEmpty, (try? prompt.write(to: file, atomically: true, encoding: .utf8)) != nil else { return false }
        let safeAccount = account.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        // Blank account = plain `claude`; otherwise the `cca <account>` multi-account wrapper.
        let launcher = safeAccount.isEmpty ? "claude" : "cca \(safeAccount)"
        let command = "\(launcher) \(flags) \"$(cat '\(file.path)')\""
        let words = prompt.split(separator: " ").prefix(6).joined(separator: " ")
        var dir2: ObjCBool = false
        let expanded = (cwd as NSString).expandingTildeInPath
        let workdir = FileManager.default.fileExists(atPath: expanded, isDirectory: &dir2) && dir2.boolValue ? expanded : NSHomeDirectory()
        return run(["new-workspace", "--name", "Voice: \(words)", "--cwd", workdir,
                    "--command", command, "--focus", focus ? "true" : "false"]).ok
    }
}
