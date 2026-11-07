import AppKit
import AVFoundation
import Carbon.HIToolbox
import Observation

@MainActor
@Observable
final class AppModel {
    enum Mode { case dictate, ask, agent }
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case polishing
        case thinking
        case done(String)
        case error(String)
    }

    // UI state
    var phase: Phase = .idle
    var mode: Mode = .dictate
    var levels: [Float] = Array(repeating: 0, count: 30)
    var recordStart = Date()
    /// 0...1 while you're pausing after speech; reaching 1 auto-stops the recording.
    var silenceProgress: Double = 0
    var speechReady = false
    var llmReady = false
    var history: [HistoryItem] = HistoryStore.load()

    // Ask AI conversation (kept until the panel is closed, so follow-ups have context)
    var askVisible = false
    var askStreaming = false
    var conversation: [Ollama.Message] = []

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { [.recording, .transcribing, .polishing, .thinking].contains(phase) }

    private let recorder = Recorder()
    private var parakeet: Parakeet?
    private let ollama = Ollama()
    private var targetApp: NSRunningApplication?
    private var pressedAt: [Mode: Date] = [:]
    private var keyDown: Set<Mode> = []
    private var dismissWork: DispatchWorkItem?
    private var askTask: Task<Void, Never>?
    private var pipeline: Task<Void, Never>?
    /// Bumped on every start/cancel; async work checks it so stale results never paste or reopen panels.
    private var session = 0
    private var askGeneration = 0
    private var escapeRegistered = false
    private static let maxRecordingSeconds: Double = 300
    @ObservationIgnored private var vad: VoiceDetector?
    @ObservationIgnored private var vadFrames = 0
    @ObservationIgnored private var vadGeneration = 0
    @ObservationIgnored private var speechLoadGeneration = 0
    @ObservationIgnored private var speechFrames = 0
    @ObservationIgnored private var silentFrames = 0
    let panels = Panels()

    // Hotkey IDs
    private enum HK: UInt32 { case padDictate = 1, padAsk, kbDictate, kbAsk, escape, kbAgent }

    func start() {
        Prefs.register()
        panels.attach(self)
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.push(level: level) }
        }
        recorder.onInterrupted = { [weak self] in
            // Audio route changed (e.g. AirPods connected): keep what we have instead of hanging.
            DispatchQueue.main.async { if self?.isRecording == true { self?.stopRecording() } }
        }

        // Macro pad sends F18 / F19. Keyboard fallbacks: ⌃⌥Space (dictate), ⌃⌥/ (ask). Hold or tap.
        HotKeys.shared.register(id: HK.padDictate.rawValue, keyCode: kVK_F18) { [weak self] in self?.key(.dictate, pressed: $0) }
        HotKeys.shared.register(id: HK.padAsk.rawValue, keyCode: kVK_F19) { [weak self] in self?.key(.ask, pressed: $0) }
        HotKeys.shared.register(id: HK.kbDictate.rawValue, keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in self?.key(.dictate, pressed: $0) }
        HotKeys.shared.register(id: HK.kbAsk.rawValue, keyCode: kVK_ANSI_Slash, modifiers: controlKey | optionKey) { [weak self] in self?.key(.ask, pressed: $0) }
        HotKeys.shared.register(id: HK.kbAgent.rawValue, keyCode: kVK_Return, modifiers: controlKey | optionKey) { [weak self] in self?.key(.agent, pressed: $0) }

        if CommandLine.arguments.contains("--demo") { return runDemo() }
        if let i = CommandLine.arguments.firstIndex(of: "--agenttest"), i + 1 < CommandLine.arguments.count {
            // Opens a background (unfocused) Claude Code workspace with the given prompt, exactly as agent mode would.
            let prompt = CommandLine.arguments[i + 1]
            DispatchQueue.global().async {
                let ok = Cmux.newSession(prompt: prompt, account: Prefs.agentAccount, cwd: Prefs.agentCwd, flags: Prefs.agentFlags, focus: false)
                print("AGENTTEST newSession=\(ok)")
                exit(ok ? 0 : 1)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--sendtest"), i + 2 < CommandLine.arguments.count {
            let (ws, text) = (CommandLine.arguments[i + 1], CommandLine.arguments[i + 2])
            DispatchQueue.global().async {
                guard let target = Cmux.claudeTarget(workspace: ws) else { print("SENDTEST no-claude-in-foreground"); exit(2) }
                print("SENDTEST target=\(target) sent=\(Cmux.send(text, to: target))")
                exit(0)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--vadtest"), i + 1 < CommandLine.arguments.count {
            return runVadTest(wav: CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            return runSelfTest(wav: CommandLine.arguments[i + 1])
        }

        Task { _ = await Permissions.requestMic() }
        if !Paster.canPaste { Paster.promptForAccessibility() }

        loadSpeech()
        Task.detached(priority: .utility) { [vadPath = Prefs.vadModelPath] in
            guard let v = try? VoiceDetector(modelPath: vadPath) else { return } // auto-stop just stays off
            await MainActor.run {
                self.vad = v
                self.recorder.onSamples = { [weak self] chunk in
                    v.feed(chunk) { probs, gen in DispatchQueue.main.async { self?.handleVoice(probs, generation: gen) } }
                }
            }
        }
        Task { await refreshLLM() }
    }

    /// (Re)loads the selected Parakeet model; called at launch and when the model is changed in Settings.
    func loadSpeech() {
        speechReady = false
        speechLoadGeneration += 1
        let gen = speechLoadGeneration
        let old = parakeet
        Task.detached(priority: .userInitiated) { [modelPath = Prefs.modelPath] in
            do {
                let p = try Parakeet(modelPath: modelPath)
                await p.warmUp()
                await MainActor.run {
                    guard gen == self.speechLoadGeneration else { return } // a newer selection won
                    self.parakeet = p; self.speechReady = true
                }
            } catch {
                await MainActor.run {
                    guard gen == self.speechLoadGeneration else { return }
                    self.parakeet = old; self.speechReady = old != nil; self.flash(.error(error.localizedDescription))
                }
            }
        }
    }

    func refreshLLM() async {
        llmReady = await ollama.isUp()
        if llmReady { await ollama.warm(model: Prefs.llmModel) }
    }

    // MARK: Hotkey handling — a quick tap toggles, a long hold is push-to-talk.

    private func key(_ m: Mode, pressed: Bool) {
        if pressed {
            guard !keyDown.contains(m) else { return } // ignore auto-repeat
            keyDown.insert(m)
            if isRecording, m != .agent, mode != m, mode != .agent,
               Date().timeIntervalSince(recordStart) < 0.4 {
                // Pad buttons 1 + 2 pressed together: this recording becomes a Claude Code instruction.
                mode = .agent
                pressedAt = [:]
                Sound.play("Purr")
                refresh()
            } else if isRecording {
                if mode == m || mode == .agent { stopRecording() }
                pressedAt[m] = nil
            } else if !isBusy || phase == .thinking {
                startRecording(m)
                // Measured after the engine is running, so slow mic start-up doesn't look like a hold.
                pressedAt[m] = isRecording ? Date() : nil
            }
        } else {
            keyDown.remove(m)
            if isRecording, mode == m, let t = pressedAt[m], Date().timeIntervalSince(t) > 0.45 {
                stopRecording()
            }
            pressedAt[m] = nil
        }
    }

    func toggle(_ m: Mode) {
        if isRecording { if mode == m { stopRecording() } } else if !isBusy || phase == .thinking { startRecording(m) }
    }

    // MARK: Recording

    func startRecording(_ m: Mode) {
        guard speechReady else { return flash(.error("Speech model still loading…")) }
        guard Permissions.micGranted else {
            Task { _ = await Permissions.requestMic() }
            return flash(.error("Microphone access needed"))
        }
        if askTask != nil { askTask?.cancel(); askGeneration += 1; askStreaming = false }
        pipeline?.cancel()
        dismissWork?.cancel()
        session += 1
        let front = NSWorkspace.shared.frontmostApplication
        // Started from Murmur's own menu or windows: there is no app to paste into, so copy instead.
        targetApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        mode = m
        do {
            try recorder.start()
        } catch {
            return flash(.error(error.localizedDescription))
        }
        levels = Array(repeating: 0, count: levels.count)
        vad?.reset()
        vadGeneration += 1
        vadFrames = 0; speechFrames = 0; silentFrames = 0
        silenceProgress = 0
        recordStart = Date()
        phase = .recording
        Sound.play("Tink")
        refresh()
        let mySession = session
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordingSeconds) { [weak self] in
            if let self, self.session == mySession, self.isRecording { self.stopRecording() }
        }
    }

    /// Esc: cancels whatever is in progress; with nothing in progress, closes the Ask panel.
    func cancel() {
        if isBusy && phase != .thinking {
            if isRecording { _ = recorder.stop() }
            session += 1
            pipeline?.cancel()
            phase = .idle
            refresh()
        } else if askVisible {
            closeAsk()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        let samples = recorder.stop()
        silenceProgress = 0
        let seconds = Double(samples.count) / 16_000
        Sound.play("Pop")
        guard seconds > 0.35, let parakeet else { phase = .idle; refresh(); return }
        phase = .transcribing
        refresh()

        let mySession = session
        let mode = self.mode
        pipeline = Task {
            let raw = await parakeet.transcribe(samples)
            guard session == mySession, !Task.isCancelled else { return }
            guard !raw.isEmpty else { return flash(.error("Didn't catch that")) }
            switch mode {
            case .dictate: await finishDictation(raw: raw, seconds: seconds, session: mySession)
            case .ask: ask(raw, seconds: seconds)
            case .agent: await runAgent(raw: raw, seconds: seconds, session: mySession)
            }
        }
    }

    /// Endpointing: after you've spoken, a long enough pause stops the recording. Off while a key is held
    /// (push-to-talk ends on release) and when disabled in Settings.
    private func handleVoice(_ probs: [Float], generation: Int) {
        guard isRecording, generation == vadGeneration else { return } // drop results from a previous recording
        let frameSeconds = Double(VoiceDetector.frame) / 16_000
        for p in probs {
            vadFrames += 1
            if p >= 0.5 { speechFrames += 1; silentFrames = 0 }
            else if p < 0.35 { silentFrames += 1 }
        }
        guard Prefs.autoStop, keyDown.isEmpty else { silenceProgress = 0; return } // a held key means push-to-talk
        let spoke = Double(speechFrames) * frameSeconds >= 0.25
        if spoke {
            silenceProgress = min(1, Double(silentFrames) * frameSeconds / Prefs.autoStopSeconds)
            if silenceProgress >= 1 { stopRecording() }
        } else if Double(vadFrames) * frameSeconds > 8 {
            _ = recorder.stop()
            session += 1
            Sound.play("Pop")
            flash(.error("Didn't hear anything"))
        }
    }

    private func push(level: Float) {
        guard isRecording else { return }
        levels.removeFirst()
        levels.append(level)
    }

    // MARK: Dictation

    private func finishDictation(raw: String, seconds: Double, session mySession: Int) async {
        var text = raw
        if Prefs.cleanup, raw.split(separator: " ").count >= 4 {
            phase = .polishing
            refresh()
            text = await polish(raw)
            guard session == mySession, !Task.isCancelled else { return }
        }
        let target = targetApp
        let item = HistoryItem(kind: .dictation, raw: raw, text: text, app: target?.localizedName, seconds: seconds)
        guard let target, !target.isTerminated else {
            record(item)
            Paster.copy(text)
            return flash(.done("Copied"))
        }
        if !target.isActive { target.activate(); try? await Task.sleep(for: .milliseconds(120)) }
        guard session == mySession else { return }
        record(item)
        let pasted = Paster.paste(text)
        flash(.done(pasted ? "Pasted" : "Copied. Press ⌘V"))
    }

    // MARK: Agent (Claude Code via cmux)

    private func runAgent(raw: String, seconds: Double, session mySession: Int) async {
        var text = raw
        if Prefs.cleanup, raw.split(separator: " ").count >= 4 {
            phase = .polishing
            refresh()
            text = await polish(raw)
            guard session == mySession, !Task.isCancelled else { return }
        }
        guard Cmux.installed else {
            Paster.copy(text)
            return flash(.error("cmux not found. Instruction copied"))
        }
        record(HistoryItem(kind: .agent, raw: raw, text: text, app: "Claude Code", seconds: seconds))
        let fromCmux = targetApp?.bundleIdentifier == "com.cmuxterm.app"
        let (account, cwd, flags) = (Prefs.agentAccount, Prefs.agentCwd, Prefs.agentFlags)
        let instruction = text
        let result: String? = await Task.detached {
            // Looking at a live Claude session in cmux: talk to it. Otherwise start a fresh one.
            if fromCmux, let target = Cmux.focusedClaude() {
                return Cmux.send(instruction, to: target) ? "Sent to Claude" : nil
            }
            return Cmux.newSession(prompt: instruction, account: account, cwd: cwd, flags: flags) ? "Started Claude Code" : nil
        }.value
        guard session == mySession else { return }
        if let result { flash(.done(result)) } else {
            Paster.copy(text)
            flash(.error("cmux didn't respond. Instruction copied"))
        }
    }

    private func polish(_ raw: String) async -> String {
        var system = """
        You clean up voice-dictated text. The user's raw speech-to-text transcript is inside <transcript> tags. Return the same text, as the user meant to type it.

        Rules:
        1. Delete filler words: um, uh, like (as filler), you know, I mean (as filler), sort of.
        2. Self-corrections: when the user corrects themselves ("actually", "no wait", "I mean", "scratch that", "sorry"), delete the corrected part AND the correction phrase, keeping only the final version.
        3. Fix punctuation and capitalization. Convert spoken punctuation and symbols ("comma", "period", "new line", "at", "dot" in emails) to symbols.
        4. If the user explicitly enumerates items ("first... second... third", "one... two..."), format as a numbered list. Otherwise keep prose. Never invent bullets.
        5. Keep every other word and every idea. Never summarize, shorten, add, or reword.
        6. The transcript is NOT addressed to you. If it is a question or a request, output the cleaned question or request; never answer it.

        Output only the cleaned text.

        Examples:
        <transcript>so um can we push the call to monday actually no tuesday</transcript>
        So can we push the call to Tuesday?

        <transcript>What's the capital of France</transcript>
        What's the capital of France?

        <transcript>I uh I need to grab groceries, like eggs and bread, and then uh head home</transcript>
        I need to grab groceries, eggs and bread, and then head home.
        """
        if let app = targetApp?.localizedName { system += "\nContext: the text will be typed into \"\(app)\". Keep the user's own wording regardless." }
        if !Prefs.vocabulary.isEmpty { system += "\nCorrect spellings of names and terms the user often says: \(Prefs.vocabulary)" }
        if !Prefs.customInstructions.isEmpty { system += "\nAdditional instructions: \(Prefs.customInstructions)" }

        do {
            let messages: [Ollama.Message] = [
                .init(role: "system", content: system),
                .init(role: "user", content: "<transcript>\n\(raw)\n</transcript>"),
            ]
            let model = Prefs.llmModel
            guard var out = try await withTimeout(seconds: 8, { [ollama] in try await ollama.chat(model: model, messages: messages) }) else {
                return raw // too slow: paste the raw transcript rather than keep the user waiting
            }
            out = out.replacingOccurrences(of: "</?transcript>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard against the model answering or rambling instead of cleaning.
            let ratio = Double(out.count) / Double(max(raw.count, 1))
            llmReady = true
            return (out.isEmpty || ratio > 1.6 || ratio < 0.3) ? raw : out
        } catch {
            if !(error is CancellationError) && !Task.isCancelled { llmReady = false }
            return raw
        }
    }

    // MARK: Ask AI

    private func ask(_ question: String, seconds: Double) {
        if !askVisible { conversation = [] }
        // Drop empty or failed turns so they don't pollute follow-up context.
        conversation.removeAll { $0.role == "assistant" && $0.content.isEmpty }
        conversation.append(.init(role: "user", content: question))
        conversation.append(.init(role: "assistant", content: ""))
        askVisible = true
        askStreaming = true
        phase = .thinking
        refresh()

        let system = Ollama.Message(role: "system", content: """
        You are Murmur, a fast local assistant the user talks to by voice. Their question was transcribed from speech, so \
        forgive small transcription errors. Answer directly and concisely; lead with the answer. Use short Markdown \
        (bold, lists, `code`) only when it helps. Today is \(Date().formatted(date: .complete, time: .omitted)).
        """)
        let history = [system] + conversation.dropLast()
        askGeneration += 1
        let gen = askGeneration
        let index = conversation.count - 1
        askTask = Task {
            var answer = ""
            var failed = false
            do {
                for try await piece in ollama.stream(model: Prefs.llmModel, messages: history) {
                    guard !Task.isCancelled, gen == askGeneration else { break }
                    answer += piece
                    conversation[index].content = answer
                    if phase == .thinking { phase = .idle; refresh() }
                }
                llmReady = true
            } catch {
                failed = true
                if !Task.isCancelled, gen == askGeneration {
                    conversation[index].content = "**Couldn't reach the local model.** Make sure Ollama is running and `\(Prefs.llmModel)` is pulled.\n\n`\(error.localizedDescription)`"
                    llmReady = false
                }
            }
            // A newer ask or a close owns the UI now; leave it alone.
            guard gen == askGeneration else { return }
            askStreaming = false
            if phase == .thinking { phase = .idle }
            refresh()
            if !failed, !answer.isEmpty { record(HistoryItem(kind: .ask, raw: question, text: answer, app: nil, seconds: seconds)) }
        }
    }

    func closeAsk() {
        askTask?.cancel()
        askGeneration += 1
        askVisible = false
        askStreaming = false
        if phase == .thinking { phase = .idle }
        refresh()
    }

    var lastAnswer: String { conversation.last(where: { $0.role == "assistant" })?.content ?? "" }

    func insertAnswer() {
        let text = lastAnswer
        let target = targetApp
        closeAsk()
        guard let target, !target.isTerminated else { return Paster.copy(text) }
        Task {
            target.activate()
            try? await Task.sleep(for: .milliseconds(150))
            Paster.paste(text)
        }
    }

    /// Headless check of the real pipeline: WAV -> Parakeet (in-process) -> AI cleanup. Prints, never pastes.
    private func runSelfTest(wav: String) {
        Task.detached {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav), commonFormat: .pcmFormatFloat32, interleaved: false)
                let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buf)
                let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
                let t0 = Date()
                let p = try Parakeet(modelPath: Prefs.modelPath)
                let tLoad = Date().timeIntervalSince(t0)
                await p.warmUp()
                let t1 = Date()
                let raw = await p.transcribe(samples)
                let tAsr = Date().timeIntervalSince(t1)
                let t2 = Date()
                let clean = await self.polish(raw)
                let tLlm = Date().timeIntervalSince(t2)
                print(String(format: "SELFTEST load=%.2fs asr=%.3fs llm=%.3fs audio=%.1fs", tLoad, tAsr, tLlm, Double(samples.count) / 16000))
                print("RAW:   \(raw)")
                print("CLEAN: \(clean)")
            } catch {
                print("SELFTEST ERROR: \(error)")
            }
            exit(0)
        }
    }

    /// Headless endpointing check: streams a WAV through Silero in 64 ms blocks, same rules as handleVoice().
    private func runVadTest(wav: String) {
        DispatchQueue.global().async {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: wav), commonFormat: .pcmFormatFloat32, interleaved: false)
                let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buf)
                let samples = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
                let v = try VoiceDetector(modelPath: Prefs.vadModelPath)
                let frameSeconds = Double(VoiceDetector.frame) / 16_000
                var all: [Float] = []
                let done = DispatchSemaphore(value: 0)
                var blocks = 0
                for start in stride(from: 0, to: samples.count, by: 1024) {
                    blocks += 1
                    v.feed(Array(samples[start..<min(start + 1024, samples.count)])) { probs, _ in all += probs; done.signal() }
                }
                for _ in 0..<blocks { done.wait() }
                var speech = 0, silent = 0, frames = 0
                var firstSpeech: Double?
                for p in all {
                    frames += 1
                    if p >= 0.5 { speech += 1; silent = 0; if firstSpeech == nil { firstSpeech = Double(frames) * frameSeconds } }
                    else if p < 0.35 { silent += 1 }
                    if Double(speech) * frameSeconds >= 0.25, Double(silent) * frameSeconds >= Prefs.autoStopSeconds {
                        print(String(format: "VADTEST first_speech=%.2fs auto_stop_at=%.2fs audio=%.2fs frames=%d", firstSpeech ?? -1, Double(frames) * frameSeconds, Double(samples.count) / 16000, all.count))
                        exit(0)
                    }
                }
                print(String(format: "VADTEST first_speech=%.2fs auto_stop_at=never audio=%.2fs frames=%d", firstSpeech ?? -1, Double(samples.count) / 16000, all.count))
            } catch { print("VADTEST ERROR: \(error)") }
            exit(0)
        }
    }

    /// Visual check only: cycles the pill and Ask panel through their states with fake data. Never records or pastes.
    private func runDemo() {
        let steps: [(Double, () -> Void)] = [
            (0.5, { self.mode = .dictate; self.recordStart = Date(); self.phase = .recording }),
            (1.8, { self.silenceProgress = 0.3 }),
            (2.2, { self.silenceProgress = 0.65 }),
            (3.0, { self.silenceProgress = 0; self.phase = .transcribing }),
            (4.5, { self.phase = .polishing }),
            (6.0, { self.phase = .done("Pasted") }),
            (7.5, { self.mode = .ask; self.recordStart = Date(); self.phase = .recording }),
            (10.0, {
                self.phase = .idle
                self.conversation = [
                    .init(role: "user", content: "What's the difference between a process and a thread?"),
                    .init(role: "assistant", content: "A **process** has its own memory space; a **thread** runs inside a process and shares its memory.\n\n- Processes are isolated, so a crash stays contained.\n- Threads are cheaper to create and switch, but need locks for shared data.\n\nUse `fork()` for isolation, threads for parallel work on shared state."),
                ]
                self.askVisible = true
            }),
            (14.0, { self.askVisible = false; self.phase = .error("Microphone access needed") }),
            (16.0, { self.phase = .idle }),
        ]
        for (t, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { step(); self.panels.update() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in
                guard self.phase == .recording else { return }
                let t = Date().timeIntervalSinceReferenceDate
                self.levels.removeFirst()
                self.levels.append(Float(0.35 + 0.35 * sin(t * 5) * sin(t * 1.7) + Double.random(in: 0...0.3)))
            }
        }
    }

    // MARK: Helpers

    /// Runs `op`, returning nil if it doesn't finish within `seconds`.
    private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await op() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func record(_ item: HistoryItem) {
        history.insert(item, at: 0)
        HistoryStore.save(history)
    }

    func clearHistory() {
        history = []
        HistoryStore.save([])
    }

    /// Re-renders panels and holds the Esc hotkey only while something is cancellable or the Ask panel is open,
    /// so Esc is never stolen from other apps otherwise.
    func refresh() {
        panels.update()
        let wantEscape = isBusy || askVisible
        if wantEscape && !escapeRegistered {
            HotKeys.shared.register(id: HK.escape.rawValue, keyCode: kVK_Escape) { [weak self] pressed in
                if pressed { self?.cancel() }
            }
            escapeRegistered = true
        } else if !wantEscape && escapeRegistered {
            HotKeys.shared.unregister(id: HK.escape.rawValue)
            escapeRegistered = false
        }
    }

    func flash(_ p: Phase) {
        phase = p
        refresh()
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == p else { return }
            self.phase = .idle
            self.refresh()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (p == .done("Pasted") ? 0.9 : 2.2), execute: work)
    }
}
