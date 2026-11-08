import SwiftUI

/// Seerr (Overseerr/Jellyseerr-compatible) media requests. Searching never requests anything: the card's Request
/// button is the only write, because a speech match can be wrong.
enum Media {
    /// Overridable so --mediatest can serve fixtures and record writes instead of touching the server.
    static var loader: ((_ method: String, _ path: String, _ query: [String: String], _ body: [String: Any]?) async throws -> Any)?

    private static func call(_ method: String = "GET", _ path: String, _ query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Any {
        if let loader { return try await loader(method, path, query, body) }
        let key = try Keychain.require("seerr")
        guard let base = Skills.base(5055) else { throw Skills.Failure.unreachable }
        // Seerr wants %20 for spaces and rejects loose punctuation, so encode everything but the unreserved set.
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let qs = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: ok) ?? "")" }.joined(separator: "&")
        guard let url = URL(string: base.absoluteString + "/api/v1" + path + (qs.isEmpty ? "" : "?" + qs)) else { throw Skills.Failure.unreachable }
        return try await Skills.json(url, method: method, headers: ["X-Api-Key": key], body: body)
    }

    // MARK: Detection

    struct Parsed: Equatable { var title: String; var year: Int?; var tv: Bool; var movie: Bool }

    private static func has(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    private static func normalize(_ q: String) -> String {
        q.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!,")))
    }

    private static let blockers = #"\b(refund|reminder|reminders|calendar|alarm|timer|e-?mail|text message|todo|to-do|task|appointment|contact|password|list|playlist|shopping|notes?|cart|document|file|spreadsheet)\b"#
    private static let target = #"\b(seerr|overseerr|jellyseerr|plex|jellyfin|watchlist)\b|\b(to|in|into|on) my (library|movies|shows)\b"#
    private static let nounRE = #"(tv show|tv series|movie|film|show|series)"#
    private static let stop: Set<String> = ["the", "a", "an", "it", "this", "that", "one", "some", "something", "please", "me"]

    /// `title` is empty when the user named a target but no title ("add the movie"): Ask answers "Which movie?".
    static func parse(_ raw: String) -> Parsed? {
        let s = normalize(raw)
        guard !has(s, blockers), !has(s, #"^(what|which|how|why|should|who|is|are|do|does|can i|could i)\b"#),
              let v = s.range(of: #"\b(request|add|download)\b"#, options: .regularExpression) else { return nil }
        let explicit = has(s, target)
        var t = String(s[v.upperBound...]).trimmingCharacters(in: .whitespaces)
        var tv = false, movie = false, anchored = explicit
        func note(_ n: String) { if n.contains("tv") || n == "show" || n == "series" { tv = true } else { movie = true } }
        t = t.replacingOccurrences(of: #"^me "#, with: "", options: .regularExpression)
        if let r = t.range(of: #"^(the |a |an )?\#(nounRE)( called| named)?( |$)"#, options: .regularExpression) {
            let head = String(t[r])
            if head.hasPrefix("the ") { anchored = true }
            if let n = head.range(of: nounRE, options: .regularExpression) { note(String(head[n])) }
            t.removeSubrange(r)
        }
        var year: Int?
        for _ in 0..<3 {
            t = t.replacingOccurrences(of: #" (please|for me)$"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"( |^)(on|to|in|into|onto|for) (my |the )?(seerr|overseerr|jellyseerr|plex|jellyfin|library|movies|shows|watchlist|media( library)?|collection)$"#, with: "", options: .regularExpression)
            if let r = t.range(of: #"( |^)(all )?seasons?( \d+)?$"#, options: .regularExpression) { tv = true; t.removeSubrange(r) }
            if let r = t.range(of: #" (the )?\#(nounRE)$"#, options: .regularExpression), t.distance(from: t.startIndex, to: r.lowerBound) > 0 {
                if let n = t[r].range(of: nounRE, options: .regularExpression) { note(String(t[r][n])) }
                t.removeSubrange(r)
                if !t.trimmingCharacters(in: .whitespaces).isEmpty && !stop.contains(t.trimmingCharacters(in: .whitespaces)) { anchored = true }
            }
            if let r = t.range(of: #"(^| )\(?((19|20)\d\d)\)?$"#, options: .regularExpression) {
                year = Int(t[r].filter(\.isNumber)); t.removeSubrange(r)
            }
            t = t.trimmingCharacters(in: .whitespaces)
        }
        let words = t.split(separator: " ").map(String.init)
        let bare = words.drop { stop.contains($0) }
        if bare.isEmpty { return anchored ? Parsed(title: "", year: nil, tv: tv, movie: movie) : nil }
        if bare.first == "of" || !anchored { return nil }
        return Parsed(title: t, year: year, tv: tv, movie: movie)
    }

    static func isStatusQuestion(_ raw: String) -> Bool {
        let s = normalize(raw)
        guard !has(s, blockers) else { return false }
        let media = has(s, #"\b(seerr|overseerr|jellyseerr|movie|movies|show|shows|media|download|downloads|plex|jellyfin)\b"#)
        return has(s, #"^(what|which)( movies| shows| things)? (have i|did i) request(ed)?( recently| lately| so far| today| this week)?$"#)
            || has(s, #"^((what are|what're|show|list|check) )?(my|the) (recent |latest )?requests$"#)
            || has(s, #"^(what('s| is) )?(the )?status of (my )?(recent )?requests$"#)
            || (media && has(s, #"\b(what|which)\b.*\b(have i|did i|i('ve| have)?)\b.*\brequest(ed)?\b|\b(status of|my|recent|latest) (media |movie |seerr |overseerr )?requests\b"#))
    }

    static func match(_ q: String) -> Skills.Job? {
        if isStatusQuestion(q) { return { await recent() } }
        guard let p = parse(q) else { return nil }
        if p.title.isEmpty { let n = p.tv ? "show" : "movie"; return { .note("Which \(n)?") } }
        return { await search(p) }
    }

    // MARK: Search

    struct Item: Identifiable, Equatable {
        let tmdb: Int, type: String, title: String, year: String, overview: String, poster: String?, status: Int
        var id: String { "\(type)-\(tmdb)" }
        var typeLabel: String { type == "tv" ? "show" : "movie" }
    }

    static func item(_ r: [String: Any]) -> Item? {
        guard let type = r["mediaType"] as? String, type == "movie" || type == "tv", let id = r["id"] as? Int else { return nil }
        let title = ((r[type == "tv" ? "name" : "title"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let date = (r[type == "tv" ? "firstAirDate" : "releaseDate"] as? String) ?? ""
        let status = ((r["mediaInfo"] as? [String: Any])?["status"] as? Int) ?? 1
        return Item(tmdb: id, type: type, title: title, year: String(date.prefix(4)), overview: (r["overview"] as? String) ?? "",
                    poster: r["posterPath"] as? String, status: status)
    }

    private static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Best first: exact title, spoken year, then the type the user implied; Seerr's own order (popularity) breaks ties.
    static func rank(_ results: [[String: Any]], _ p: Parsed) -> [Item] {
        let items = results.compactMap(item)
        let want = key(p.title), full = key(p.title + (p.year.map { " \($0)" } ?? ""))
        func score(_ i: Item) -> Int {
            var s = 0
            if key(i.title) == full && p.year != nil { s += 120 } else if key(i.title) == want { s += 100 }
            if let y = p.year, i.year == String(y), key(i.title) == want { s += 50 }
            if p.tv ? i.type == "tv" : i.type == "movie" { s += p.tv || p.movie ? 40 : 20 }
            return s
        }
        return items.enumerated().sorted { (score($0.element), -$0.offset) > (score($1.element), -$1.offset) }.map(\.element)
    }

    /// The server's default (non-4K) quality profile per media type; nil if the key can't read settings.
    static func profiles() async -> [String: (id: Int, name: String)] {
        async let radarr = defaultProfile("radarr"), sonarr = defaultProfile("sonarr")
        var out: [String: (id: Int, name: String)] = [:]
        out["movie"] = await radarr
        out["tv"] = await sonarr
        return out
    }

    private static func defaultProfile(_ service: String) async -> (id: Int, name: String)? {
        guard let arr = try? await call("GET", "/settings/\(service)") as? [[String: Any]],
              let d = arr.first(where: { ($0["isDefault"] as? Bool) == true && ($0["is4k"] as? Bool) != true }),
              let id = d["activeProfileId"] as? Int else { return nil }
        return (id, (d["activeProfileName"] as? String) ?? "default profile")
    }

    static func search(_ p: Parsed) async -> SkillResult {
        do {
            // A spoken year may be part of the title (Blade Runner 2049), so search both ways and let ranking decide.
            var results: [[String: Any]] = []
            for q in (p.year.map { ["\(p.title) \($0)", p.title] } ?? [p.title]) {
                let json = try await call("GET", "/search", ["query": q]) as? [String: Any]
                for r in (json?["results"] as? [[String: Any]]) ?? [] where !results.contains(where: { ($0["id"] as? Int) == (r["id"] as? Int) && ($0["mediaType"] as? String) == (r["mediaType"] as? String) }) { results.append(r) }
            }
            let ranked = rank(results, p)
            guard let top = ranked.first else { return .note("Seerr found nothing for \"\(p.title)\".") }
            let prof = await profiles()
            let model = await MediaCardModel(items: Array(ranked.prefix(4)), profiles: prof)
            let name = prof[top.type]?.name
            let head = "Found \(top.title) (\(top.year.isEmpty ? "" : top.year + ", ")\(top.typeLabel))."
            let tail: String
            switch top.status {
            case 5: tail = "It's already in your library."
            case 2, 3: tail = "It's already requested."
            default: tail = "Tap Request to add it" + (name.map { " in \($0)." } ?? ".")
            }
            let answer = "\(head) \(tail)"
            return SkillResult(card: AnyView(MediaCard(m: model)), facts: answer, answer: answer, final: true)
        } catch { return Skills.failed(error, service: "Seerr") }
    }

    /// The only write. Retries without a profile if the key isn't allowed to choose one.
    static func requestBody(_ i: Item, profile: Int?) -> [String: Any] {
        var b: [String: Any] = ["mediaType": i.type, "mediaId": i.tmdb]
        if let profile { b["profileId"] = profile }
        if i.type == "tv" { b["seasons"] = "all" }
        return b
    }

    static func send(_ i: Item, profile: Int?) async throws {
        do { _ = try await call("POST", "/request", body: requestBody(i, profile: profile)) }
        catch Skills.Failure.http(403, _) where profile != nil { _ = try await call("POST", "/request", body: requestBody(i, profile: nil)) }
    }

    // MARK: Recent requests

    struct Recent { let title: String, status: String, when: Date? }

    static func statusText(request: Int, media: Int) -> String {
        if request == 3 { return "Declined" }
        if request == 1 { return "Pending approval" }
        switch media {
        case 5: return "Available"
        case 4: return "Partially available"
        case 3: return "Downloading"
        default: return "Approved"
        }
    }

    static func recent() async -> SkillResult {
        do {
            let json = try await call("GET", "/request", ["take": "10", "sort": "added"]) as? [String: Any]
            let rows = Array(((json?["results"] as? [[String: Any]]) ?? []).prefix(10))
            if rows.isEmpty { return .note("You haven't requested anything in Seerr yet.") }
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let list: [Recent] = await withTaskGroup(of: (Int, Recent).self) { g in
                for (n, r) in rows.enumerated() {
                    g.addTask {
                        let m = r["media"] as? [String: Any]
                        let type = (m?["mediaType"] as? String) ?? (r["type"] as? String) ?? "movie"
                        let tmdb = m?["tmdbId"] as? Int
                        var title = tmdb.map { "TMDB \($0)" } ?? "Unknown"
                        if let tmdb, let d = try? await call("GET", "/\(type)/\(tmdb)") as? [String: Any],
                           let t = (d[type == "tv" ? "name" : "title"] as? String) {
                            let y = String(((d[type == "tv" ? "firstAirDate" : "releaseDate"] as? String) ?? "").prefix(4))
                            title = y.isEmpty ? t : "\(t) (\(y))"
                        }
                        let st = statusText(request: (r["status"] as? Int) ?? 2, media: (m?["status"] as? Int) ?? 1)
                        return (n, Recent(title: title, status: st, when: (r["createdAt"] as? String).flatMap { iso.date(from: $0) }))
                    }
                }
                var out: [(Int, Recent)] = []
                for await x in g { out.append(x) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let shown = list.prefix(5).map { "\($0.title): \($0.status)" }.joined(separator: "; ")
            let more = list.count > 5 ? " and \(list.count - 5) more." : "."
            let answer = "Your last \(list.count) requests: \(shown)\(more)"
            return SkillResult(card: AnyView(RecentRequestsCard(rows: list)), facts: answer, answer: answer, final: true)
        } catch { return Skills.failed(error, service: "Seerr") }
    }
}

// MARK: - Card

@MainActor final class MediaCardModel: ObservableObject {
    enum State: Equatable { case idle, sending, done, already, failed(String) }
    let items: [Media.Item]
    let profiles: [String: (id: Int, name: String)]
    @Published var state: [String: State] = [:]

    init(items: [Media.Item], profiles: [String: (id: Int, name: String)]) { self.items = items; self.profiles = profiles }

    func label(_ i: Media.Item, short: Bool = false) -> (text: String, enabled: Bool) {
        switch state[i.id] ?? .idle {
        case .sending: return ("Requesting…", false)
        case .done: return ("Requested ✓", false)
        case .already: return ("Already requested", false)
        case .failed: return (short ? "Retry" : "Retry request", true)
        case .idle:
            switch i.status {
            case 5: return ("Already in your library", false)
            case 2, 3: return ("Already requested", false)
            default:
                if short { return ("Request", true) }
                return (profiles[i.type].map { "Request in \($0.name)" } ?? "Request", true)
            }
        }
    }

    func request(_ i: Media.Item) async {
        guard label(i).enabled else { return }
        state[i.id] = .sending
        do {
            try await Media.send(i, profile: profiles[i.type]?.id)
            state[i.id] = .done
        } catch Skills.Failure.http(let code, let msg) {
            state[i.id] = code == 409 || msg.lowercased().contains("already") ? .already : .failed("Seerr error \(code): \(msg)")
        } catch { state[i.id] = .failed(Skills.unreachable) }
    }
}

struct MediaCard: View {
    @ObservedObject var m: MediaCardModel

    private func statusText(_ i: Media.Item) -> String? {
        switch i.status { case 2: "Pending"; case 3: "Processing"; case 4: "Partially available"; case 5: "Available"; default: nil }
    }

    var body: some View {
        let top = m.items[0]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Poster(path: top.poster, width: 66)
                VStack(alignment: .leading, spacing: 4) {
                    Text(top.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    Text([top.year, top.typeLabel.capitalized, statusText(top)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    Text(top.overview).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
            }
            let l = m.label(top)
            Button { Task { await m.request(top) } } label: {
                Text(l.text).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Palette.askSolid.opacity(l.enabled ? 1 : 0.25), in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(l.enabled ? Color(hex: 0x1C1D20) : .white.opacity(0.6))
            }.buttonStyle(.plain).disabled(!l.enabled)
            if case .failed(let e) = m.state[top.id] { Text(e).font(.system(size: 12)).foregroundStyle(Color(hex: 0xD98A82)) }
            if m.items.count > 1 {
                Divider().overlay(.white.opacity(0.08))
                Text("Not it?").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                ForEach(m.items.dropFirst()) { AltRow(m: m, i: $0) }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AltRow: View {
    @ObservedObject var m: MediaCardModel
    let i: Media.Item
    var body: some View {
        let l = m.label(i, short: true)
        HStack(spacing: 10) {
            Poster(path: i.poster, width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(i.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Text([i.year, i.typeLabel].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            Button { Task { await m.request(i) } } label: {
                Text(l.text).font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(l.enabled ? 0.14 : 0.06), in: Capsule())
                    .foregroundStyle(.white.opacity(l.enabled ? 0.9 : 0.5))
            }.buttonStyle(.plain).disabled(!l.enabled)
        }
    }
}

private struct Poster: View {
    let path: String?
    let width: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        AsyncImage(url: path.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") }) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            ZStack { Color.white.opacity(0.06); Image(systemName: "film").foregroundStyle(.white.opacity(0.3)) }
        }
        .frame(width: width, height: width * 1.5).clipShape(shape)
    }
}

struct RecentRequestsCard: View {
    let rows: [Media.Recent]
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Recent requests").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack {
                    Text(r.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(r.status).font(.system(size: 12)).foregroundStyle(r.status == "Available" ? Palette.agentSolid : .white.opacity(0.55))
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
