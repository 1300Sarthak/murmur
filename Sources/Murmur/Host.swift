import Foundation
import SwiftUI

/// Server stats from Beszel (PocketBase): CPU, RAM, temperature, disks, top containers.
enum Host {
    enum Intent: Equatable {
        case disks(focus: String?), cpu, ram, temp, status, top(String)
    }

    // MARK: Detection

    private static func has(_ q: String, _ p: String) -> Bool { q.range(of: p, options: .regularExpression) != nil }

    private static let digits = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    /// Lowercases and folds spoken sizes ("eight terabyte", "8 TB", "8-tb") into "8tb".
    static func normalize(_ q: String) -> String {
        var l = q.lowercased()
        for (w, d) in digits { l = l.replacingOccurrences(of: #"\b"# + w + #"(?=[\s-]*(tb|terabytes?|t b|tera ?bytes?)\b)"#, with: d, options: .regularExpression) }
        return l.replacingOccurrences(of: #"\b(\d+)[\s-]*(?:tb|terabytes?|t b|tera ?bytes?)\b"#, with: "$1tb", options: .regularExpression)
    }

    static func detect(_ q: String) -> Intent? {
        let l = normalize(q)
        if has(l, #"\b(should i|what is a|what's a|whats a|what are|how to|buy|upgrade|recommend|set up|setup|install)\b"#) { return nil }
        // Money about a drive ("how much did my 8TB drive cost") is a finance question.
        if has(l, #"\b(spen[dt]|spending|cost|costs|paid|pay|price|refund|bought|purchased?)\b"#) { return nil }
        // A server that isn't the user's own (work, Discord, GitHub, a game) is not the homelab.
        if has(l, #"\b(at work|work|office|school|company|discord|minecraft|github|aws|azure|gcp|game|web server|mail server)\b"#) { return nil }
        let drive = has(l, #"\bmy (\w+ ){0,2}\d+tb\b"#) || has(l, #"\b\d+tb (drive|hdd|disk|hard drive)\b"#) || has(l, #"\bmy windows (drive|disk|partition)\b"#)
        let cue = has(l, #"\b(my (home )?(server|homelab|home lab|nas)|homelab|home lab|beszel)\b"#) || has(l, #"\bmy (hard )?(drives|disks|hdds)\b"#) || drive
        guard cue else { return nil }
        if has(l, #"\b(most|hogging|eating|top|biggest|highest)\b|\bwhat('s| is) (is )?(using|eating|hogging)\b"#), has(l, #"\b(cpu|processor|ram|memory|resources)\b"#) {
            return .top(has(l, #"\b(ram|memory)\b"#) ? "mem" : "cpu")
        }
        if has(l, #"\b(storage|space|disks?|drives?|hdd|hdds|full|free|left|capacity|terabytes?)\b"#) || drive {
            let focus = l.range(of: #"\b\d+tb\b"#, options: .regularExpression).map { String(l[$0]) } ?? (has(l, #"\bwindows\b"#) ? "windows" : nil)
            return .disks(focus: focus)
        }
        if has(l, #"\b(cpu|processor|load)\b"#) { return .cpu }
        if has(l, #"\b(ram|memory)\b"#) { return .ram }
        if has(l, #"\b(hot|temperature|temp|temps|warm|overheating|heat)\b"#) { return .temp }
        if has(l, #"\b(status|ok|okay|healthy|health|doing|how's|how is|hows|alright|fine|uptime|up or down|down)\b|\b(is|are) (it|my \w+) up\b"#) { return .status }
        return nil
    }

    static func match(_ q: String) -> Skills.Job? {
        guard let intent = detect(q) else { return nil }
        return { await run(intent, question: q) }
    }

    // MARK: Data

    /// Overridable so --hosttest can read fixtures. Key is "systems", "stats" or "containers"; `system` is the chosen system's id.
    static var loader: ((String, String?) async throws -> Any)?
    static var token: String?
    static var tokenHost: String?

    /// A token minted for one host is useless (and a leak) for another.
    static func resetTokenIfHostChanged(_ host: String) {
        if tokenHost != host { token = nil; tokenHost = host }
    }

    private static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

    static func path(_ key: String, system: String?) -> String {
        let sys = system.map { " && system='\($0)'" } ?? ""
        switch key {
        case "systems": return "/api/collections/systems/records?perPage=100"
        case "stats": return "/api/collections/system_stats/records?sort=-created&perPage=1&filter=" + q("type='1m'" + sys)
        default: return "/api/collections/containers/records?perPage=200" + (system.map { "&filter=" + q("system='\($0)'") } ?? "")
        }
    }

    private static func login(_ base: URL) async throws -> String {
        let r = try await Skills.json(base.appendingPathComponent("api/collections/users/auth-with-password"), method: "POST",
                                      body: ["identity": try Keychain.require("beszel-user"), "password": try Keychain.require("beszel-pass")])
        guard let t = (r as? [String: Any])?["token"] as? String else { throw Skills.Failure.http(0, "no token from Beszel") }
        token = t
        return t
    }

    private static func fetch(_ key: String, system: String? = nil) async throws -> Any {
        if let loader { return try await loader(key, system) }
        resetTokenIfHostChanged(Prefs.homelabHost)
        guard let base = Skills.base(8090), let url = URL(string: base.absoluteString + path(key, system: system)) else { throw Skills.Failure.unreachable }
        let t: String
        if let cached = token { t = cached } else { t = try await login(base) }
        do { return try await Skills.json(url, headers: ["Authorization": t]) }
        catch Skills.Failure.http(let code, _) where code == 401 || code == 403 {
            token = nil
            return try await Skills.json(url, headers: ["Authorization": try await login(base)])
        }
    }

    /// The system to report on: the one named in the question, else the first by name (stable across API ordering).
    static func choose(_ systems: Any, question: String?) -> [String: Any]? {
        let list = items(systems).sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        let l = question?.lowercased() ?? ""
        return list.first { s in (s["name"] as? String).map { !$0.isEmpty && l.contains($0.lowercased()) } ?? false } ?? list.first
    }

    // MARK: Model

    struct Disk { let name: String, totalGB: Double, usedGB: Double, pct: Double
        var freeGB: Double { max(0, totalGB - usedGB) }
    }
    struct Box { let name: String, up: Bool, cpu: Double, mem: Double, temp: Double?, load: [Double], threads: Int?, uptime: Int?,
                 memTotal: Double?, memUsed: Double?, disks: [Disk] }
    struct Container { let name: String, cpu: Double, memMB: Double }
    struct Snapshot { var box: Box, containers: [Container], by: String, focus: String? }

    static func gb(_ v: Double) -> String { v >= 1024 ? String(format: "%.1f TB", v / 1024) : String(format: "%.0f GB", v) }
    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private static func items(_ any: Any) -> [[String: Any]] { ((any as? [String: Any])?["items"] as? [[String: Any]]) ?? [] }

    static func uptimeText(_ s: Int) -> String {
        s >= 86400 ? "\(s / 86400)d \(s % 86400 / 3600)h" : s >= 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : "\(s / 60)m"
    }

    static func parse(system sys: [String: Any], stats: Any?) -> Box? {
        guard let info = sys["info"] as? [String: Any] else { return nil }
        let st = stats.flatMap { items($0).first?["stats"] as? [String: Any] }
        var disks: [Disk] = []
        func add(_ name: String, _ d: Double?, _ du: Double?, _ pct: Double?) {
            if let d, let du, d > 0 { disks.append(Disk(name: name, totalGB: d, usedGB: du, pct: du / d * 100)) }
            else if let pct { disks.append(Disk(name: name, totalGB: 0, usedGB: 0, pct: pct)) }
        }
        add("Root", num(st?["d"]), num(st?["du"]), num(info["dp"]))
        let sefs = st?["efs"] as? [String: Any] ?? [:]
        let iefs = info["efs"] as? [String: Any] ?? [:]
        for name in Set(sefs.keys).union(iefs.keys).sorted() {
            let e = sefs[name] as? [String: Any]
            add(name, num(e?["d"]), num(e?["du"]), num(iefs[name]))
        }
        return Box(name: sys["name"] as? String ?? "server", up: (sys["status"] as? String ?? "up") == "up", cpu: num(info["cpu"]) ?? 0, mem: num(info["mp"]) ?? 0,
                   temp: num(info["dt"]), load: (info["la"] as? [NSNumber])?.map(\.doubleValue) ?? [], threads: (info["t"] as? NSNumber)?.intValue,
                   uptime: (info["u"] as? NSNumber)?.intValue, memTotal: num(st?["m"]), memUsed: num(st?["mu"]), disks: disks)
    }

    static func parseContainers(_ any: Any) -> [Container] {
        items(any).map { Container(name: $0["name"] as? String ?? "?", cpu: num($0["cpu"]) ?? 0, memMB: num($0["memory"]) ?? 0) }
    }

    // MARK: Run

    static func run(_ intent: Intent, question: String? = nil) async -> SkillResult {
        do {
            guard let sys = choose(try await fetch("systems"), question: question) else { return .note("Beszel has no systems yet.") }
            let id = sys["id"] as? String
            async let stats = try? fetch("stats", system: id)
            let wantTop: String? = { if case .top(let m) = intent { m } else { nil } }()
            async let cont: Any? = wantTop == nil ? nil : try? fetch("containers", system: id)
            let (st, c) = (await stats, await cont)
            guard let box = parse(system: sys, stats: st) else { return .note("Beszel has no data for this system yet.") }
            var d = Snapshot(box: box, containers: c.map(parseContainers) ?? [], by: wantTop ?? "", focus: nil)
            if case .disks(let f) = intent { d.focus = f }
            return result(intent, d)
        } catch { return Skills.failed(error, service: "Beszel") }
    }

    static func result(_ intent: Intent, _ d: Snapshot) -> SkillResult {
        let b = d.box
        func diskName(_ x: Disk) -> String { x.name }
        let pcts = { (v: Double) in String(format: "%.0f%%", v) }
        var answer: String
        switch intent {
        case .disks(let focus):
            let hit = focus.flatMap { f in b.disks.first { $0.name.lowercased() == f || $0.name.lowercased().contains(f) } }
            if let f = focus, hit == nil {
                answer = "I don't see a drive called \(f.uppercased()). Your drives are " + b.disks.map(\.name).joined(separator: ", ") + "."
            } else if let x = hit {
                let label = x.name.lowercased().hasSuffix("tb") ? "\(x.name) drive" : x.name == "Root" ? "root drive" : "\(x.name) drive"
                answer = x.totalGB > 0 ? "Your \(label) has \(gb(x.freeGB)) free of \(gb(x.totalGB)) (\(pcts(x.pct)) used)." : "Your \(label) is \(pcts(x.pct)) full."
            } else if let full = b.disks.max(by: { $0.pct < $1.pct }), let most = b.disks.max(by: { $0.freeGB < $1.freeGB }) {
                answer = "Your fullest drive is \(full.name) at \(pcts(full.pct)) used; \(most.name) has the most room with \(gb(most.freeGB)) free."
            } else { answer = "Beszel reports no disks." }
        case .cpu:
            answer = "Your server's CPU is at \(pcts(b.cpu))" + (b.load.first.map { ", load average \(String(format: "%.2f", $0))" } ?? "") + (b.threads.map { " across \($0) threads" } ?? "") + "."
        case .ram:
            if let t = b.memTotal, let u = b.memUsed { answer = "Your server is using \(String(format: "%.1f", u)) GB of \(String(format: "%.1f", t)) GB of RAM (\(pcts(b.mem)))." }
            else { answer = "Your server's RAM is \(pcts(b.mem)) used." }
        case .temp:
            answer = b.temp.map { "Your server is running at \(String(format: "%.0f", $0))°C." } ?? "Beszel doesn't report a temperature for your server."
        case .status:
            let full = b.disks.max(by: { $0.pct < $1.pct })
            answer = b.up ? "\(b.name) is up: CPU \(pcts(b.cpu)), RAM \(pcts(b.mem))" + (b.temp.map { ", \(String(format: "%.0f", $0))°C" } ?? "")
                + (full.map { ", fullest drive \($0.name) at \(pcts($0.pct))" } ?? "") + (b.uptime.map { ", up \(uptimeText($0))" } ?? "") + "."
                : "\(b.name) is down."
        case .top(let m):
            let sorted = d.containers.sorted { m == "mem" ? $0.memMB > $1.memMB : $0.cpu > $1.cpu }.prefix(3)
            func f(_ c: Container) -> String { m == "mem" ? String(format: "%.0f MB", c.memMB) : String(format: "%.1f%%", c.cpu) }
            answer = sorted.isEmpty ? "Beszel has no container data." : "Top \(m == "mem" ? "memory" : "CPU") use is " + sorted.map { "\($0.name) at \(f($0))" }.joined(separator: ", then ") + "."
        }
        var facts = "Server \(b.name) (\(b.up ? "up" : "down")): CPU \(pcts(b.cpu)), RAM \(pcts(b.mem))"
        if let t = b.temp { facts += ", temperature \(String(format: "%.0f", t))°C" }
        if let l = b.load.first { facts += ", load \(String(format: "%.2f", l))" }
        if let u = b.uptime { facts += ", uptime \(uptimeText(u))" }
        facts += "\nDisks:\n" + b.disks.map { "- \($0.name): \($0.totalGB > 0 ? "\(gb($0.freeGB)) free of \(gb($0.totalGB)), " : "")\(pcts($0.pct)) used" }.joined(separator: "\n")
        if !d.containers.isEmpty { facts += "\nTop containers by \(d.by):\n" + d.containers.sorted { d.by == "mem" ? $0.memMB > $1.memMB : $0.cpu > $1.cpu }.prefix(5).map { "- \($0.name): \(String(format: "%.1f", $0.cpu))% CPU, \(String(format: "%.0f", $0.memMB)) MB" }.joined(separator: "\n") }
        return SkillResult(card: AnyView(HostCard(d: d, focus: d.focus)), facts: facts, answer: answer, final: true)
    }
}

// MARK: Card

struct HostCard: View {
    let d: Host.Snapshot
    var focus: String?

    var body: some View {
        let b = d.box
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(b.name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Circle().fill(b.up ? Palette.agentSolid : Palette.rec).frame(width: 7, height: 7)
                Text(b.up ? "up" + (b.uptime.map { " " + Host.uptimeText($0) } ?? "") : "down").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 0) {
                gauge("CPU", b.cpu, "\(Int(b.cpu.rounded()))%")
                gauge("RAM", b.mem, "\(Int(b.mem.rounded()))%")
                if let t = b.temp { gauge("Temp", min(100, t), "\(Int(t.rounded()))°") }
            }
            if !b.load.isEmpty {
                Text("Load " + b.load.map { String(format: "%.2f", $0) }.joined(separator: "  ") + (b.threads.map { " · \($0) threads" } ?? ""))
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
            }
            if !b.disks.isEmpty {
                Divider().overlay(Color.white.opacity(0.1))
                ForEach(Array(b.disks.enumerated()), id: \.offset) { _, x in disk(x) }
            }
            if !d.containers.isEmpty {
                Divider().overlay(Color.white.opacity(0.1))
                Text("Top containers by \(d.by == "mem" ? "memory" : "CPU")").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                ForEach(Array(d.containers.sorted { d.by == "mem" ? $0.memMB > $1.memMB : $0.cpu > $1.cpu }.prefix(5).enumerated()), id: \.offset) { _, c in
                    HStack {
                        Text(c.name).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        Spacer()
                        Text(d.by == "mem" ? String(format: "%.0f MB", c.memMB) : String(format: "%.1f%%", c.cpu))
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tone(_ pct: Double) -> Color { pct >= 90 ? Palette.rec : pct >= 75 ? Color(hex: 0xD9B36A) : Palette.askSolid }

    private func gauge(_ name: String, _ pct: Double, _ text: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle().trim(from: 0, to: CGFloat(max(0.01, min(1, pct / 100)))).stroke(tone(pct), style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(text).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
            }
            .frame(width: 56, height: 56)
            Text(name).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private func disk(_ x: Host.Disk) -> some View {
        let hit = focus.map { x.name.lowercased().contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(x.name).font(.system(size: 12.5, weight: hit ? .semibold : .regular)).foregroundStyle(.white.opacity(hit ? 0.98 : 0.75))
                Spacer()
                Text(x.totalGB > 0 ? "\(Host.gb(x.freeGB)) free of \(Host.gb(x.totalGB))" : String(format: "%.0f%% used", x.pct))
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(hit ? 1 : 0.8))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(hit ? tone(x.pct) : tone(x.pct).opacity(0.5)).frame(width: max(3, g.size.width * CGFloat(min(100, x.pct) / 100)))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, hit ? 8 : 0).padding(.vertical, hit ? 5 : 0)
        .background(hit ? Palette.askSolid.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
