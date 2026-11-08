import AppKit
import SwiftUI

/// Immich photo questions: person counts, "what I did on <date>" with thumbnails + a link, library size.
enum Photos {
    // MARK: Intent

    struct Span: Equatable { var start: Date; var end: Date; var label: String }   // end is exclusive

    enum Intent {
        case library
        /// `loud`: a "how many ... do I have" question, so an unknown name gets a definite answer. `fallback`: the name was also a date ("June").
        case person(String, loud: Bool, fallback: Span?)
        case date(Span, person: String?, loud: Bool)
    }

    /// Overridable so --phototest can read fixtures instead of the network: (method, path with query, body) -> JSON.
    static var loader: ((String, String, [String: Any]?) async throws -> Any)?
    /// Overridable thumbnail fetch (path -> image).
    static var thumbLoader: ((String) async -> NSImage?)?
    static var baseOverride: URL?

    static var base: URL? { baseOverride ?? Skills.base(2283) }

    static func match(_ q: String) -> Skills.Job? {
        guard let intent = parse(q) else { return nil }
        return claim(intent)
    }

    /// Runs the intent and lets the next turn be a short follow-up ("what about Ashmit?", "and from October?").
    private static func claim(_ intent: Intent) -> Skills.Job {
        let person: String? = switch intent { case .person(let n, _, _): n; case .date(_, let n, _): n; case .library: nil }
        Skills.followUp = { followUp($0, person: person).map(claim) }
        return { await run(intent) }
    }

    private static let leadRx = rx(#"^\s*(?:(?:and|ok(?:ay)?|now|so|then)\s+)*(?:(?:what|how) about|same for|what of|how many (?:of|for))?\s*(?:(?:photos?|pictures?|pics?) (?:of|with|from|on)\s+|for\s+|of\s+|from\s+|on\s+)?(.*?)[\s?.!]*$"#)

    private static let acks: Set<String> = ["thanks", "thank you", "cool", "nice", "great", "ok", "okay", "wow", "yes", "no", "yeah", "nope", "sure", "awesome", "perfect", "got it", "never mind"]

    /// A short follow-up to the previous photo turn: a new person, or a new date for the same person.
    static func followUp(_ q: String, person: String?, now: Date = Date()) -> Intent? {
        guard q.split(separator: " ").count <= 7,
              let m = leadRx.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let r = Range(m.range(at: 1), in: q) else { return nil }
        let rest = String(q[r]).trimmingCharacters(in: .whitespaces)
        let led = r.lowerBound != q.drop(while: \.isWhitespace).startIndex   // "what about …", "and …", "of …"
        guard !rest.isEmpty, led || !acks.contains(rest.lowercased()) else { return nil }
        if let span = parseSpan(rest.lowercased(), now: now) { return .date(span, person: person, loud: true) }
        // A name: 1-3 words, capitalised as transcription writes names, or introduced by "what about"/"and".
        let words = rest.split(separator: " ")
        guard words.count <= 3, let first = words.first, !notNames.contains(first.lowercased()),
              rest.range(of: #"^[A-Za-z][\w'’.-]*( [A-Za-z][\w'’.-]*){0,2}$"#, options: .regularExpression) != nil,
              led || first.first?.isUppercase == true,
              timeRx.firstMatch(in: rest.lowercased(), range: NSRange(rest.startIndex..., in: rest)) == nil,
              !["it", "them", "him", "her", "that", "those", "weather", "you", "why", "how", "what"].contains(first.lowercased())
        else { return nil }
        return .person(rest, loud: true, fallback: nil)
    }

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let nounRx = rx(#"\b(photos?|pictures?|pics?|immich)\b"#)
    private static let cueRx = rx(#"\b(i|i'm|i've|i'd|my|me|mine|we|our|you|your)\b"#)   // "do you have" means the user's library
    private static let didRx = rx(#"\b(what (did )?(i|we) (do|did|were doing|was doing)|where (was|were) (i|we))\b"#)
    private static let negRx = rx(#"\b(take|taking|snap)\s+(a\s+|some\s+|the\s+)?(photos?|pictures?|pics?)\b|\b(edit|editing|crop|resize|compress|print|store|storage|fit|hold|megapixels?|need|have to|software|apps?|tips?|tutorial|filters?)\b"#)
    private static let libRx = rx(#"how many (photos?|pictures?|pics?|videos?)\b.*\b(do i have|have i (taken|got)|did i take|in (my )?(library|immich)|in total|total|do i own)\b|how (big|large) is my (photo |picture |immich )?library|\b(photo|picture|immich) library\b"#)
    private static let countRx = rx(#"\bhow (many|much)\b"#)
    private static let ctxRx = rx(#"\b(work|school|homework|class|office|job|shift|meeting|college|university)\b"#)
    private static let timeRx = rx(#"\b(yesterday|today|tonight|last|this|next|ago|week|weekend|month|year|morning|evening|night|since|between|before|after|summer|winter|spring|fall|autumn)\b"#)
    private static let nameRx = rx(#"\b(?:of|with)\s+([A-Za-z][\w'’.-]*(?:\s+[A-Za-z][\w'’.-]*){0,2}?)(?=\s+(?:do|did|that|i|in|from|on|during|taken|over|last|this|yesterday|today|since|are|there|have|and|is|was)\b|[?.!,]*$)"#)
    private static let notNames: Set<String> = ["my", "the", "a", "an", "our", "mine", "me", "us", "this", "that", "these", "those", "all", "everything", "any", "some"]

    static func parse(_ q: String, now: Date = Date()) -> Intent? {
        let l = q.lowercased(), full = NSRange(l.startIndex..., in: l)
        let immich = l.contains("immich")
        let cue = immich || cueRx.firstMatch(in: l, range: full) != nil
        if !immich, negRx.firstMatch(in: l, range: full) != nil { return nil }
        let noun = nounRx.firstMatch(in: l, range: full) != nil
        let lib = libRx.firstMatch(in: l, range: full) != nil

        // Name first, so a name that is also a month ("June", "May") isn't read as a date.
        var name: String?
        var l2 = l
        if noun, let m = nameRx.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), let r = Range(m.range(at: 1), in: q) {
            let n = String(q[r]).trimmingCharacters(in: .punctuationCharacters)
            if notNames.contains(n.lowercased().split(separator: " ").first.map(String.init) ?? "") { return nil }
            if !n.isEmpty {
                name = n
                if let whole = Range(m.range(at: 0), in: q) {
                    l2 = String(q[q.startIndex..<whole.lowerBound]).lowercased() + " " + String(q[whole.upperBound...]).lowercased()
                }
            }
        }
        let span = parseSpan(l2, now: now)
        let loud = cue && countRx.firstMatch(in: l, range: full) != nil
        if span == nil, timeRx.firstMatch(in: l2, range: NSRange(l2.startIndex..., in: l2)) != nil { return nil }
        if span != nil, !noun, !lib {
            // "what did I do <when>" questions, but not about work/school.
            guard cue, didRx.firstMatch(in: l, range: full) != nil, ctxRx.firstMatch(in: l, range: full) == nil else { return nil }
        } else if !noun, !lib { return nil }
        // Without I/my/me, only "photos of <person> from <date>" is specific enough to claim.
        guard cue || (noun && span != nil && name != nil) else { return nil }
        if let span { return .date(span, person: name, loud: loud) }
        if let name { return .person(name, loud: loud, fallback: parseSpan(name.lowercased(), now: now)) }
        return lib && cue ? .library : nil
    }

    // MARK: Dates

    private static let monthPat = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static func monthNumber(_ s: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        return names.firstIndex(of: String(s.lowercased().prefix(3))).map { $0 + 1 }
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : Range(r, in: s).map { String(s[$0]) }
    }

    static func parseSpan(_ s: String, now: Date) -> Span? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let ny = cal.component(.year, from: now)
        func day(_ y: Int, _ m: Int, _ d: Int) -> Span? {
            var d = d
            if m == 2, d == 29, cal.date(from: DateComponents(year: y, month: 2, day: 29)).map({ cal.component(.month, from: $0) != 2 }) ?? true { d = 28 }
            guard let st = cal.date(from: DateComponents(year: y, month: m, day: d)),
                  cal.component(.day, from: st) == d, cal.component(.month, from: st) == m else { return nil }
            return Span(start: st, end: cal.date(byAdding: .day, value: 1, to: st)!, label: "")
        }
        func dated(_ sp: Span?) -> Span? { sp.map { Span(start: $0.start, end: $0.end, label: label($0)) } }
        func dayNoYear(_ m: Int, _ d: Int, _ y: Int?) -> Span? {
            if let y { return dated(day(y, m, d)) }
            guard let sp = day(ny, m, d) else { return nil }
            return dated(sp.start >= cal.date(byAdding: .day, value: 1, to: today)! ? day(ny - 1, m, d) : sp)
        }
        let r = NSRange(s.startIndex..., in: s)
        let year4 = { (str: String?) in str.flatMap(Int.init) }

        if s.contains("this day last year") || s.contains("year ago today") || s.contains("year ago to the day") {
            let c = cal.dateComponents([.month, .day], from: now)
            return dayNoYear(c.month!, c.day!, ny - 1)
        }
        if let m = rx(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#).firstMatch(in: s, range: r),
           let y = Int(group(m, 1, s)!), let mo = Int(group(m, 2, s)!), let d = Int(group(m, 3, s)!) { return dayNoYear(mo, d, y) }
        if let m = rx(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#).firstMatch(in: s, range: r),
           let mo = Int(group(m, 1, s)!), let d = Int(group(m, 2, s)!) {
            var y = year4(group(m, 3, s)); if let yy = y, yy < 100 { y = 2000 + yy }
            return dayNoYear(mo, d, y)
        }
        if let m = rx(#"\b"# + monthPat + #"\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4}))?"#).firstMatch(in: s, range: r),
           let mo = monthNumber(group(m, 1, s)!), let d = Int(group(m, 2, s)!) { return dayNoYear(mo, d, year4(group(m, 3, s))) }
        if let m = rx(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + monthPat + #"\b(?:,?\s+(\d{4}))?"#).firstMatch(in: s, range: r),
           let d = Int(group(m, 1, s)!), let mo = monthNumber(group(m, 2, s)!) { return dayNoYear(mo, d, year4(group(m, 3, s))) }
        if let m = rx(#"(?:\b(in|from|during|of|for)\s+)?\b"# + monthPat + #"\b(?:\s+(\d{4}))?"#).firstMatch(in: s, range: r),
           let mo = monthNumber(group(m, 2, s)!) {
            let y = year4(group(m, 3, s))
            // "may"/"mar" are ordinary words, so they need a preposition or a year to count as a month.
            if group(m, 1, s) != nil || y != nil || !["may", "mar"].contains(String(group(m, 2, s)!.lowercased().prefix(3))) {
                return month(y ?? (mo > cal.component(.month, from: now) ? ny - 1 : ny), mo)
            }
        }
        let monday = cal.date(byAdding: .day, value: -((cal.component(.weekday, from: now) + 5) % 7), to: today)!
        func span(_ a: Date, _ b: Date) -> Span { let sp = Span(start: a, end: b, label: ""); return Span(start: a, end: b, label: label(sp)) }
        if s.contains("last weekend") { return span(cal.date(byAdding: .day, value: -2, to: monday)!, monday) }
        if s.contains("yesterday") || s.contains("last night") { return span(cal.date(byAdding: .day, value: -1, to: today)!, today) }
        if rx(#"\btoday\b"#).firstMatch(in: s, range: r) != nil { return span(today, cal.date(byAdding: .day, value: 1, to: today)!) }
        if s.contains("this week") { return span(monday, cal.date(byAdding: .day, value: 7, to: monday)!) }
        if s.contains("this month") { return month(ny, cal.component(.month, from: now)) }
        if s.contains("this year") { return yearSpan(ny) }
        if s.contains("last week") { return span(cal.date(byAdding: .day, value: -7, to: monday)!, monday) }
        if s.contains("last month") {
            let c = cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: -1, to: today)!)
            return month(c.year!, c.month!)
        }
        if s.contains("last year") {
            return yearSpan(ny - 1)
        }
        if let m = rx(#"\b(?:last|on|this past)\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#).firstMatch(in: s, range: r),
           let target = weekdays.firstIndex(of: group(m, 1, s)!) {
            var d = (cal.component(.weekday, from: now) - 1 - target + 7) % 7
            if d == 0 { d = 7 }
            let st = cal.date(byAdding: .day, value: -d, to: today)!
            return span(st, cal.date(byAdding: .day, value: 1, to: st)!)
        }
        if let m = rx(#"\b((?:19|20)\d{2})\b"#).firstMatch(in: s, range: r), let y = Int(group(m, 1, s)!) { return yearSpan(y) }
        return nil

        func yearSpan(_ y: Int) -> Span {
            Span(start: cal.date(from: DateComponents(year: y))!, end: cal.date(from: DateComponents(year: y + 1))!, label: String(y))
        }
        func month(_ y: Int, _ m: Int) -> Span? {
            guard let st = cal.date(from: DateComponents(year: y, month: m, day: 1)) else { return nil }
            let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
            return Span(start: st, end: cal.date(byAdding: .month, value: 1, to: st)!, label: f.string(from: st))
        }
    }

    private static func label(_ s: Span) -> String {
        let cal = Calendar.current
        let last = cal.date(byAdding: .day, value: -1, to: s.end)!
        let f = DateFormatter()
        if cal.isDate(s.start, inSameDayAs: last) { f.dateFormat = "MMM d, yyyy"; return f.string(from: s.start) }
        f.dateFormat = "MMM d"
        let g = DateFormatter(); g.dateFormat = "MMM d, yyyy"
        return "\(f.string(from: s.start)) – \(g.string(from: last))"
    }

    // MARK: Fetch

    private static func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Any {
        if let loader { return try await loader(method, path, body) }
        guard let base, let url = URL(string: base.absoluteString + path) else { throw Skills.Failure.unreachable }
        return try await Skills.json(url, method: method, headers: ["x-api-key": try Keychain.require("immich"), "Accept": "application/json"], body: body)
    }

    private static func thumb(_ path: String) async -> NSImage? {
        if let thumbLoader { return await thumbLoader(path) }
        guard let base, let key = Keychain.get("immich"), let url = URL(string: base.absoluteString + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }

    private static func isoUTC(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }

    private struct Person { var id: String; var name: String }

    private static func findPerson(_ name: String) async throws -> Person? {
        let arr = try await call("GET", "/api/search/person?name=\(enc(name))") as? [[String: Any]] ?? []
        let hit = arr.first { ($0["name"] as? String)?.lowercased() == name.lowercased() } ?? arr.first
        guard let id = hit?["id"] as? String else { return nil }
        return Person(id: id, name: hit?["name"] as? String ?? name)
    }

    private static func n(_ v: Any?) -> Int { (v as? Int) ?? Int((v as? Double) ?? 0) }
    private static func num(_ i: Int) -> String { i.formatted(.number) }
    private static func plural(_ i: Int, _ w: String) -> String { "\(num(i)) \(w)\(i == 1 ? "" : "s")" }

    // MARK: Run

    static func run(_ intent: Intent) async -> SkillResult {
        do {
            switch intent {
            case .library: return try await library()
            case .person(let name, let loud, let fb):
                if let r = try await person(name, loud: loud) { return r }
                if let fb { return try await date(fb, nil, loud: loud) ?? .note("") }
                return missing(name, loud)
            case .date(let span, let name, let loud): return try await date(span, name, loud: loud) ?? missing(name ?? "", loud)
            }
        } catch { return Skills.failed(error, service: "Immich") }
    }

    private static func library() async throws -> SkillResult {
        let o = try await call("GET", "/api/server/statistics") as? [String: Any] ?? [:]
        let photos = n(o["photos"]), videos = n(o["videos"]), bytes = Int64(n(o["usage"]))
        let size = bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
        var a = "You have \(plural(photos, "photo")) and \(plural(videos, "video")) in Immich"
        if let size { a += ", using \(size)" }
        a += "."
        let link = base?.appendingPathComponent("photos")
        return SkillResult(card: AnyView(LibraryCard(photos: photos, videos: videos, size: size, link: link)), facts: a, answer: a)
    }

    /// Not a definite answer unless the user asked "how many photos of X do I have": "photos of Paris" is probably not a person.
    private static func missing(_ name: String, _ loud: Bool) -> SkillResult {
        loud ? .note("No one named \(name) in Immich.")
             : SkillResult(card: AnyView(EmptyView()), facts: "No person named \(name) in Immich.", answer: "No person named \(name) in Immich.", final: false)
    }

    private static func person(_ name: String, loud: Bool) async throws -> SkillResult? {
        guard let p = try await findPerson(name) else { return nil }
        let count = n((try await call("GET", "/api/people/\(p.id)/statistics") as? [String: Any])?["assets"])
        let link = base?.appendingPathComponent("people/\(p.id)")
        let face = await thumb("/api/people/\(p.id)/thumbnail")
        let a = "\(p.name) appears in \(plural(count, "photo")). Open the card link to view them in Immich."
        return SkillResult(card: AnyView(PersonCard(name: p.name, count: count, face: face, link: link)),
                           facts: a + (link.map { " \($0.absoluteString)" } ?? ""), answer: a, final: true)
    }

    private static func date(_ span: Span, _ name: String?, loud: Bool) async throws -> SkillResult? {
        var person: Person?
        if let name {
            guard let p = try await findPerson(name) else { return nil }
            person = p
        }
        var filter: [String: Any] = ["takenAfter": isoUTC(span.start), "takenBefore": isoUTC(span.end.addingTimeInterval(-0.001))]
        if let person { filter["personIds"] = [person.id] }
        let count = n((try await call("POST", "/api/search/statistics", filter) as? [String: Any])?["total"])
        var items: [String] = []
        if count > 0 {
            var body = filter; body["size"] = 8; body["order"] = "asc"; body["page"] = 1
            let o = (try await call("POST", "/api/search/metadata", body) as? [String: Any])?["assets"] as? [String: Any]
            items = (o?["items"] as? [[String: Any]] ?? []).prefix(8).compactMap { $0["id"] as? String }
        }
        let images: [NSImage?] = await withTaskGroup(of: (Int, NSImage?).self) { g in
            for (i, id) in items.enumerated() { g.addTask { (i, await thumb("/api/assets/\(id)/thumbnail?size=thumbnail")) } }
            var out = [NSImage?](repeating: nil, count: items.count)
            for await (i, img) in g { out[i] = img }
            return out
        }
        // Immich web: /search?query=<JSON of a MetadataSearchDto> (web/src/lib/route.ts, Route.search).
        let web = base.flatMap { b -> URL? in
            guard let d = try? JSONSerialization.data(withJSONObject: filter, options: [.sortedKeys]),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return URL(string: b.absoluteString + "/search?query=" + enc(s))
        }
        let on = span.label.range(of: #"^[A-Za-z]+ \d{4}$|^\d{4}$"#, options: .regularExpression) != nil ? "in" : "on"
        let who = person.map { " of \($0.name)" } ?? ""
        let a = (count == 0 ? "No photos\(who) \(on) \(span.label)." : "\(plural(count, "photo"))\(who) \(on) \(span.label).")
            + " Open the card link to view them in Immich."
        return SkillResult(card: AnyView(DateCard(label: span.label, who: person?.name, count: count, images: images, link: web)),
                           facts: a + (web.map { " \($0.absoluteString)" } ?? ""), answer: a, final: true)
    }
}

// MARK: Cards

private struct PhotoShell<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ImmichLink: View {
    let title: String
    let url: URL?
    var body: some View {
        if let url {
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 5) {
                    Text(title)
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.askSolid)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Palette.askSolid.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct LibraryCard: View {
    let photos: Int, videos: Int, size: String?, link: URL?
    var body: some View {
        PhotoShell {
            Text("Immich library").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                stat(photos.formatted(.number), "photos")
                stat(videos.formatted(.number), "videos")
                if let size { stat(size, "used") }
            }
            ImmichLink(title: "Open in Immich", url: link)
        }
    }
    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
            Text(l).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct PersonCard: View {
    let name: String, count: Int, face: NSImage?, link: URL?
    var body: some View {
        PhotoShell {
            HStack(spacing: 10) {
                Group {
                    if let face { Image(nsImage: face).resizable().scaledToFill() } else { Color.white.opacity(0.1) }
                }
                .frame(width: 34, height: 34).clipShape(Circle())
                Text(name).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(count.formatted(.number)).font(.system(size: 32, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
                Text(count == 1 ? "photo" : "photos").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            ImmichLink(title: "Open in Immich", url: link)
        }
    }
}

private struct DateCard: View {
    let label: String, who: String?, count: Int, images: [NSImage?], link: URL?
    var body: some View {
        PhotoShell {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                if let who { Text(who).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5)) }
            }
            if count == 0 {
                Text("No photos").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.bone)
            } else {
                Text("\(count.formatted(.number)) \(count == 1 ? "photo" : "photos")")
                    .font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(images.indices, id: \.self) { i in
                        Color.white.opacity(0.08).aspectRatio(1, contentMode: .fit)
                            .overlay { if let img = images[i] { Image(nsImage: img).resizable().scaledToFill() } }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                if count > images.count, !images.isEmpty {
                    Text("+\((count - images.count).formatted(.number)) more").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
            ImmichLink(title: "Open in Immich", url: link)
        }
    }
}
