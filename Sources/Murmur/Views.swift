import AppKit
import SwiftUI

// MARK: - Palette

enum Palette {
    // Quiet instrument palette: graphite glass, bone text, one solid muted color per mode, red only for recording.
    static let bone = Color(hex: 0xECE6DA)
    static let rec = Color(hex: 0xE5534B)
    static let surface = Color(hex: 0x2A2C30)
    static let dictateSolid = bone
    static let askSolid = Color(hex: 0x8EA2C6)
    static let agentSolid = Color(hex: 0x9DB89B)
    static func flat(_ c: Color) -> LinearGradient { LinearGradient(colors: [c, c], startPoint: .leading, endPoint: .trailing) }
    static let dictate = flat(dictateSolid)
    static let ask = flat(askSolid)
    static let agent = flat(agentSolid)
    static func gradient(_ m: AppModel.Mode) -> LinearGradient {
        switch m { case .dictate: dictate; case .ask: ask; case .agent: agent }
    }
    static func solid(_ m: AppModel.Mode) -> Color {
        switch m { case .dictate: dictateSolid; case .ask: askSolid; case .agent: agentSolid }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Dark glass surface used by the pill and the Ask card.
struct Glass<S: InsettableShape>: ViewModifier {
    var shape: S
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background(Color(hex: 0x1A1B1E).opacity(0.72), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Floating pill

@MainActor struct PillView: View {
    let model: AppModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.phase != .idle {
                content
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .modifier(Glass(shape: Capsule()))
                    .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
                                            removal: .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity)))
                    .padding(.bottom, 22)
            }
        }
        .frame(width: Panels.pillSize.width, height: Panels.pillSize.height)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: model.phase)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 12) {
                RecordingDot(color: Palette.rec, progress: model.silenceProgress)
                Waveform(levels: model.levels, gradient: Palette.gradient(model.mode))
                    .frame(width: 150, height: 26)
                TimelineView(.periodic(from: model.recordStart, by: 0.5)) { ctx in
                    Text(elapsed(ctx.date))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                if model.mode == .agent {
                    Image(systemName: "terminal.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.agent)
                }
            }
        case .transcribing: status(words: Quips.transcribing, tint: Palette.gradient(model.mode))
        case .polishing: status(words: model.mode == .agent ? Quips.agent : Quips.polishing, tint: Palette.gradient(model.mode))
        case .thinking: status(words: Quips.thinking, tint: Palette.ask)
        case .done(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white, Palette.agentSolid)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white, Color(hex: 0xFFB454))
                .lineLimit(1)
        case .idle: EmptyView()
        }
    }

    private func status(words: [String], tint: LinearGradient) -> some View {
        HStack(spacing: 10) {
            BouncingDots(gradient: tint)
            RotatingWord(words: words)
        }
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(model.recordStart)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Playful status words, Claude Code style. A new one fades in every ~1.4 s.
enum Quips {
    static let transcribing = ["Transcribing", "Unmumbling", "Deciphering", "Listening back", "Decoding vibes", "Parsing syllables"]
    static let polishing = ["Polishing", "De-umming", "Buffing", "Wordsmithing", "Sprinkling commas", "Herding words",
                            "Finessing", "Tidying", "Un-rambling", "Ironing sentences", "Fluffing prose"]
    static let thinking = ["Thinking", "Pondering", "Noodling", "Cogitating", "Ruminating", "Percolating", "Brewing",
                           "Conjuring", "Mulling", "Consulting the oracle", "Galaxy-braining"]
    static let agent = ["Briefing Claude", "Summoning Claude", "Sharpening the prompt", "Rolling up sleeves", "Waking the agent"]
}

struct RotatingWord: View {
    let words: [String]
    @State private var start = Date()
    @State private var offset = Int.random(in: 0..<100)

    var body: some View {
        TimelineView(.periodic(from: start, by: 1.4)) { ctx in
            let step = Int(ctx.date.timeIntervalSince(start) / 1.4)
            Text(words[(offset + step) % words.count] + "…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                .animation(.easeOut(duration: 0.25), value: step)
        }
        .frame(minWidth: 120, alignment: .leading)
        .clipped()
    }
}

struct Waveform: View {
    var levels: [Float]
    var gradient: LinearGradient

    var body: some View {
        GeometryReader { geo in
            let n = levels.count
            let gap: CGFloat = 2.5
            let w = max(1.5, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<n, id: \.self) { i in
                    // Taper the edges so the shape reads as a voice, not a bar chart.
                    let edge = sin(Double(i + 1) / Double(n + 1) * .pi)
                    let h = 3 + CGFloat(Double(levels[i]) * (0.35 + 0.65 * edge)) * (geo.size.height - 3)
                    Capsule().frame(width: w, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .foregroundStyle(gradient)
            .animation(.easeOut(duration: 0.09), value: levels)
        }
    }
}

struct PulsingDot: View {
    var color: Color
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .background(Circle().fill(color.opacity(0.45)).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// Pulses while you talk; when you pause, a ring fills up to show the auto-stop countdown.
struct RecordingDot: View {
    var color: Color
    var progress: Double
    var body: some View {
        ZStack {
            if progress > 0.05 {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle().trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle().fill(color.opacity(0.6)).frame(width: 5, height: 5)
            } else {
                PulsingDot(color: color)
            }
        }
        .frame(width: 14, height: 14)
        .animation(.linear(duration: 0.1), value: progress)
    }
}

struct BouncingDots: View {
    var gradient: LinearGradient
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().frame(width: 6, height: 6)
                        .offset(y: -4 * max(0, sin(t * 7 - Double(i) * 0.7)))
                        .opacity(0.5 + 0.5 * max(0, sin(t * 7 - Double(i) * 0.7)))
                }
            }
            .foregroundStyle(gradient)
            .frame(height: 16)
        }
    }
}

// MARK: - Ask AI panel

@MainActor struct AskView: View {
    let model: AppModel
    @State private var copied = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            card.padding(20)
        }
        .frame(width: Panels.askSize.width, height: Panels.askSize.height)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.06))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(model.conversation.enumerated()), id: \.offset) { i, msg in
                            if msg.role == "user" {
                                Text(msg.content)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .textSelection(.enabled)
                            } else {
                                if let w = model.weatherCards[i] { WeatherCard(w: w) }
                                if let f = model.financeCards[i] { FinanceCard(r: f) }
                                if let k = model.skillCards[i] { k.card }
                                answer(msg.content, streaming: model.askStreaming && i == model.conversation.count - 1)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: model.lastAnswer) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider().overlay(Color.white.opacity(0.06))
            footer
        }
        .modifier(Glass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
    }

    private var header: some View {
        HStack(spacing: 9) {
            AIOrb(active: model.askStreaming)
            Text("AI")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.bone)
            Spacer()
            Button { model.closeAsk() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private func answer(_ text: String, streaming: Bool) -> some View {
        if text.isEmpty && streaming {
            HStack(spacing: 10) {
                BouncingDots(gradient: Palette.ask)
                if !model.askStatus.isEmpty {
                    Text(model.askStatus + "…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.askStatus)
        } else {
            RichAnswer(text: text, streaming: streaming)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Press again to follow up, Esc to close")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                Paster.copy(model.lastAnswer)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .buttonStyle(ChipStyle(prominent: false))
            Button("Insert") { model.insertAnswer() }
                .buttonStyle(ChipStyle(prominent: true))
        }
        .disabled(model.askStreaming || model.lastAnswer.isEmpty)
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

/// A small glowing gradient orb; it slowly spins while an answer streams.
struct AIOrb: View {
    var active: Bool
    @State private var spin = false
    var body: some View {
        // A small solid dot that breathes only while an answer is arriving.
        Circle()
            .fill(Palette.askSolid)
            .frame(width: 8, height: 8)
            .opacity(spin ? 0.35 : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeOut(duration: 0.3), value: spin)
            .onAppear { spin = active }
            .onChange(of: active) { spin = active }
    }
}

struct ChipStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(prominent ? AnyShapeStyle(Palette.bone) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
            .foregroundStyle(prominent ? Color(hex: 0x1E1F22) : Palette.bone.opacity(0.85))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Menu bar

@MainActor struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("cleanup") private var cleanup = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Murmur").font(.system(size: 15, weight: .bold))
                Spacer()
                StatusDot(on: model.speechReady, label: "Parakeet")
                StatusDot(on: model.llmReady, label: "AI")
            }

            HStack(spacing: 10) {
                ActionTile(title: "Dictate", keys: "F18 · ⌥Space", icon: "mic.fill", gradient: Palette.dictate,
                           active: model.isRecording && model.mode == .dictate) { model.toggle(.dictate) }
                ActionTile(title: "Ask AI", keys: "F19 · ⌥/", icon: "sparkles", gradient: Palette.ask,
                           active: model.isRecording && model.mode == .ask) { model.toggle(.ask) }
            }

            ActionTile(title: "Claude Code", keys: "Pad 1+2 · ⌃⌥↩", icon: "terminal.fill", gradient: Palette.agent,
                       active: model.isRecording && model.mode == .agent, wide: true) { model.toggle(.agent) }

            Toggle(isOn: $cleanup) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI cleanup").font(.system(size: 12.5, weight: .medium))
                    Text("Remove fillers, apply corrections").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).controlSize(.small)

            if !Paster.canPaste {
                Button { Paster.promptForAccessibility() } label: {
                    Label("Grant Accessibility to auto-paste", systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
            }

            if !model.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(model.history.prefix(4)) { item in RecentRow(item: item) }
                }
            }

            Divider()
            HStack {
                Button("History") { open("history") }
                Button("Settings") { open("settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

struct StatusDot: View {
    var on: Bool
    var label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(on ? Palette.agentSolid : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .help(on ? "\(label) ready" : "\(label) not ready")
    }
}

struct ActionTile: View {
    var title: String, keys: String, icon: String
    var gradient: LinearGradient
    var active: Bool
    var wide = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            let layout = wide ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            layout {
                Image(systemName: active ? "stop.fill" : icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(active ? "Stop" : title).font(.system(size: 13, weight: .semibold))
                    Text(keys).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(Color.primary.opacity(hover ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RecentRow: View {
    let item: HistoryItem
    @State private var copied = false
    @State private var hover = false
    var body: some View {
        Button {
            Paster.copy(item.kind == .ask ? item.text : item.text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.kind == .ask ? "sparkles" : item.kind == .agent ? "terminal" : "text.quote")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12)
                Text(item.kind == .ask ? item.raw : item.text).lineLimit(1).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(copied ? "Copied" : item.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.primary.opacity(hover ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Click to copy")
    }
}

// MARK: - History window

@MainActor struct HistoryView: View {
    let model: AppModel
    @State private var query = ""
    @State private var selection: HistoryItem.ID?

    private var items: [HistoryItem] {
        query.isEmpty ? model.history : model.history.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.raw.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(items, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: item.kind == .ask ? "sparkles" : item.kind == .agent ? "terminal.fill" : "mic.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(item.kind == .ask ? Palette.askSolid : item.kind == .agent ? Palette.agentSolid : Palette.dictateSolid)
                        Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        if let app = item.app { Text("· \(app)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(item.kind == .ask ? item.raw : item.text).lineLimit(2)
                }
                .padding(.vertical, 3)
            }
            .searchable(text: $query)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .toolbar {
                ToolbarItem { Button("Clear", role: .destructive) { model.clearHistory() }.disabled(model.history.isEmpty) }
            }
        } detail: {
            if let item = model.history.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        block(item.kind == .ask ? "Question" : "Final text", item.kind == .ask ? item.raw : item.text)
                        if item.kind == .ask { block("Answer", item.text) }
                        else if item.raw != item.text { block("Raw transcript", item.raw).opacity(0.7) }
                        Text(String(format: "%.1fs of audio", item.seconds)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(model.history.isEmpty ? "Nothing yet. Press ⌥Space and start talking." : "Select an entry")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 680, minHeight: 420)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { Paster.copy(text) }.controlSize(.small)
            }
            Text(text).textSelection(.enabled).font(.system(size: 14))
        }
    }
}

// MARK: - Settings window

@MainActor struct SettingsView: View {
    let model: AppModel
    @AppStorage("cleanup") private var cleanup = true
    @AppStorage("sounds") private var sounds = true
    @AppStorage("llmModel") private var llmModel = "qwen3:4b-instruct"
    @AppStorage("vocabulary") private var vocabulary = ""
    @AppStorage("customInstructions") private var customInstructions = ""
    @AppStorage("autoStop") private var autoStop = true
    @AppStorage("speechModel") private var speechModel = "ggml-parakeet-tdt-0.6b-v2-q8_0.bin"
    @AppStorage("agentAccount") private var agentAccount = ""
    @AppStorage("agentCwd") private var agentCwd = "~/projects"
    @AppStorage("agentFlags") private var agentFlags = ""
    @AppStorage("askProvider") private var askProvider = "auto"
    @AppStorage("useContext") private var useContext = true
    @State private var contextInfo = SettingsView.describeContext()
    @AppStorage("claudeModel") private var claudeModel = "haiku"
    @AppStorage("weatherLocation") private var weatherLocation = ""
    @AppStorage("financeOn") private var financeOn = true
    @AppStorage("financeURL") private var financeURL = defaultFinanceURL
    @AppStorage("homelabHost") private var homelabHost = ""
    @State private var keys: [String: String] = [:]
    @AppStorage("financeCloud") private var financeCloud = false
    @State private var financeTest = ""
    @AppStorage("agentTerminal") private var agentTerminal = "terminal"
    @AppStorage("autoStopSeconds") private var autoStopSeconds = 1.2
    @State private var login = LoginItem.enabled
    @State private var tick = 0 // re-read permission state when the window regains focus

    var body: some View {
        Form {
            Section("Dictation") {
                Toggle("Clean up with local AI", isOn: $cleanup)
                Toggle("Stop automatically when I stop talking", isOn: $autoStop)
                if autoStop {
                    LabeledContent("Pause before stopping") {
                        HStack {
                            Slider(value: $autoStopSeconds, in: 0.6...3.0, step: 0.1).frame(width: 160)
                            Text(String(format: "%.1fs", autoStopSeconds)).monospacedDigit().frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                TextField("Vocabulary", text: $vocabulary, prompt: Text("Names and terms, e.g. Kubernetes, Supabase, your name"))
                TextField("Style instructions", text: $customInstructions, prompt: Text("e.g. Prefer lowercase in Slack"), axis: .vertical)
                    .lineLimit(2...4)
            }
            Section("Models") {
                LabeledContent("Speech") {
                    HStack {
                        Picker("", selection: $speechModel) {
                            ForEach(Prefs.availableSpeechModels, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 230)
                        .onChange(of: speechModel) { model.loadSpeech() }
                        StatusDot(on: model.speechReady, label: "")
                    }
                }
                LabeledContent("AI (Ollama)") {
                    HStack {
                        TextField("", text: $llmModel).frame(width: 180)
                        StatusDot(on: model.llmReady, label: "")
                        Button("Reconnect") { Task { await model.refreshLLM() } }.controlSize(.small)
                    }
                }
            }
            Section("Ask AI (pad 2)") {
                Picker("Answer with", selection: $askProvider) {
                    ForEach(AskProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if askProvider == "auto" || askProvider == "claude" {
                    Picker("Claude model", selection: $claudeModel) {
                        Text("Haiku · fastest").tag("haiku")
                        Text("Sonnet").tag("sonnet")
                        Text("Opus · smartest").tag("opus")
                    }
                }
                TextField("Your location (weather)", text: $weatherLocation, prompt: Text("e.g. Dublin, CA"))
                Text("Auto uses Claude (with web search), then Codex, when you're online, and the local model when you're offline or they fail. Weather comes live from Open-Meteo. Frontier answers use your Claude/Codex subscription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Finance (homelab)") {
                Toggle("Finance (homelab)", isOn: $financeOn)
                TextField("Dashboard URL", text: $financeURL)
                Toggle("Allow cloud models for finance and homelab questions", isOn: $financeCloud)
                LabeledContent("Connection") {
                    HStack {
                        if !financeTest.isEmpty { Text(financeTest).foregroundStyle(financeTest == "Reachable" ? .green : .red) }
                        Button("Test connection") {
                            financeTest = "Testing…"
                            Task { financeTest = await Finance.test() ? "Reachable" : "Unreachable" }
                        }.controlSize(.small)
                    }
                }
                Text("Money questions (\"how much NVIDIA do I have\") read live numbers from your dashboard over Tailscale and are answered by the local model only. Turn on cloud only if you accept sending those numbers to Claude/Codex.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Homelab") {
                TextField("Host", text: $homelabHost, prompt: Text("my-server.tailnet.ts.net"))
                ForEach(HomelabKeys.all, id: \.account) { k in
                    SecureField(k.label, text: Binding(get: { keys[k.account] ?? "" }, set: { keys[k.account] = $0 }),
                                prompt: Text(Keychain.get(k.account) == nil ? "not set" : "saved"))
                }
                Button("Save keys to Keychain") {
                    for (a, v) in keys where !v.isEmpty { Keychain.set(a, v) }
                    keys = [:]
                }.controlSize(.small)
                Text("Photos (Immich), media requests (Seerr) and server stats (Beszel) on your own server. Keys are stored in the macOS Keychain, never in preferences, and answers use the local model unless cloud is allowed above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Personal context (Ask AI)") {
                Toggle("Give Ask AI my context document", isOn: $useContext)
                LabeledContent("Document") {
                    HStack {
                        Text(contextInfo).foregroundStyle(.secondary)
                        Button("Choose…") { chooseContext() }.controlSize(.small)
                        if FileManager.default.fileExists(atPath: Prefs.contextURL.path) {
                            Button("Remove") { try? FileManager.default.removeItem(at: Prefs.contextURL); contextInfo = Self.describeContext() }
                                .controlSize(.small)
                        }
                    }
                }
                Text("Stored privately in Murmur's folder and used only for Ask AI, never dictation. Frontier calls run with telemetry off, no saved sessions, no plugins, hooks or memories; whether a provider trains on chats is your account's privacy setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code (pad 1+2)") {
                Picker("Open in", selection: $agentTerminal) {
                    Text("iTerm2").tag("iterm")
                    Text("Terminal").tag("terminal")
                    Text("cmux").tag("cmux")
                }
                TextField("cca account (optional)", text: $agentAccount, prompt: Text("blank = plain claude"))
                TextField("Start in folder", text: $agentCwd, prompt: Text("~/projects"))
                TextField("Extra claude flags", text: $agentFlags, prompt: Text("--permission-mode auto"))
                Text("Opens a new window running \(agentAccount.isEmpty ? "claude" : "cca " + agentAccount) with what you said. If you're looking at a Claude session in iTerm2, Terminal or cmux, it sends the instruction there instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                LabeledContent("Dictate", value: "Macro pad 1 (F18) · ⌥Space · ⌃⌥Space")
                LabeledContent("Ask AI", value: "Macro pad 2 (F19) · ⌥/ · ⌃⌥/")
                LabeledContent("Claude Code", value: "Pad 1 + 2 together · ⌃⌥Return")
                Text("Tap to start; it stops when you pause (or tap again). Hold for push-to-talk. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Sounds", isOn: $sounds)
                Toggle("Open at login", isOn: $login).onChange(of: login) { LoginItem.set(login) }
            }
            Section("Permissions") {
                let _ = tick
                LabeledContent("Microphone") {
                    perm(Permissions.micGranted) { Permissions.openPrivacyPane("Privacy_Microphone") }
                }
                LabeledContent("Accessibility (auto-paste)") {
                    perm(Paster.canPaste) { Paster.promptForAccessibility(); Permissions.openPrivacyPane("Privacy_Accessibility") }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in tick += 1 }
    }

    static func describeContext() -> String {
        guard let s = try? String(contentsOf: Prefs.contextURL, encoding: .utf8) else { return "None" }
        return "\(s.split(whereSeparator: \.isWhitespace).count) words"
    }

    private func chooseContext() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Copied in (owner-only permissions) so the original can move or be deleted.
        try? FileManager.default.removeItem(at: Prefs.contextURL)
        if (try? FileManager.default.copyItem(at: url, to: Prefs.contextURL)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Prefs.contextURL.path)
        }
        contextInfo = Self.describeContext()
    }

    static func label(for file: String) -> String {
        if file.contains("v2") { return "Parakeet v2 · English (most accurate)" }
        if file.contains("v3") { return "Parakeet v3 · multilingual" }
        return file.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")
    }

    private func perm(_ ok: Bool, fix: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .orange)
            if !ok { Button("Grant", action: fix).controlSize(.small) }
        }
    }
}
