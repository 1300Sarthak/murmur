import AppKit
import SwiftUI

/// Cards the model asks for with a ```card {json}``` block (flights, distances, lists, steps, quotes, scores, events,
/// comparisons). The model sends a few compact fields; all layout happens here, so a rich answer costs no extra tokens.
/// Unknown types still render: an `items` list of objects becomes a list, anything else a key/value card.
enum CardSpec {
    static let types = ["flights", "route", "list", "steps", "quote", "score", "event", "compare"]

    /// The prompt section that teaches the model the card vocabulary. Kept short: it is sent with every question.
    static let prompt = """
    Cards: start EVERY answer with exactly ONE fenced card that fits it, then at most 2 short sentences (no repeating the card). \
    Skip the card only for chit-chat or a pure explanation. JSON on one line, values are short strings:
    ```card {"type":"stat","value":"8,849 m","label":"Mount Everest","note":"29,032 ft"}``` one key number or answer
    ```card {"type":"facts","title":"...","items":[["Key","Value"]]}``` 3-8 facts about one thing
    ```card {"type":"route","from":"Dublin, CA","to":"New Delhi","distance":"7,700 mi","time":"~17h flight","note":"..."}``` distance, travel time, directions
    ```card {"type":"flights","title":"SFO → DEL","items":[{"airline":"Air India","flight":"AI 174","depart":"Nov 20 · 11:00 AM","arrive":"Nov 21 · 4:30 PM","duration":"16h","stops":"Nonstop","price":"$1,050"}],"url":"https://www.google.com/travel/flights?q=Flights%20from%20SFO%20to%20DEL%20on%202026-11-20"}``` flights; omit fields you don't know; always include the Google Flights url
    ```card {"type":"list","title":"...","items":[{"title":"...","subtitle":"...","meta":"4.6★ · $$","url":"https://..."}]}``` places, products, shows, options, results
    ```card {"type":"steps","title":"...","items":["...","..."]}``` how-tos, recipes, itineraries
    ```card {"type":"quote","symbol":"AAPL","name":"Apple","price":"$231.40","change":"+2.10","pct":"+0.9%"}``` a stock, crypto or currency price
    ```card {"type":"score","title":"NBA","status":"Final","teams":[["Warriors","112"],["Lakers","108"]]}``` a game score
    ```card {"type":"event","title":"...","when":"Sat Nov 14 · 7 PM","where":"...","note":"...","url":"https://..."}``` an event, deadline, release or opening hours
    ```card {"type":"compare","columns":["","A","B"],"rows":[["Price","$1","$2"]]}``` comparing 2-4 options
    Any card may add "links":[["Label","https://..."]] for actions like booking, maps or tickets. Only real, working URLs.
    """
}

/// A ```card``` block whose type isn't stat/facts. Parses its JSON once and draws the matching layout.
struct ModelCard: View {
    let obj: [String: Any]

    init?(json: String) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        obj = o
    }

    private func s(_ k: String, in o: [String: Any]? = nil) -> String {
        guard let v = (o ?? obj)[k], !(v is NSNull) else { return "" }
        if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: " · ") }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "Yes" : "No" }
        return "\(v)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var type: String { s("type") }
    private var dicts: [[String: Any]] { (obj["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
    private var strings: [String] { (obj["items"] as? [Any] ?? []).compactMap { $0 is [String: Any] ? nil : "\($0)" } }

    /// http(s) only, so a card can't open file:// or app URLs.
    static func link(_ raw: String) -> URL? {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", u.host?.isEmpty == false else { return nil }
        return u
    }

    private var links: [(String, URL)] {
        var out: [(String, URL)] = []
        if let u = Self.link(s("url")) { out.append((type == "flights" ? "Open in Google Flights" : "Open", u)) }
        for l in obj["links"] as? [Any] ?? [] {
            if let p = l as? [Any], p.count >= 2, let u = Self.link("\(p[1])") { out.append(("\(p[0])", u)) }
            else if let d = l as? [String: Any], let u = Self.link(s("url", in: d)) { out.append((s("label", in: d).isEmpty ? "Open" : s("label", in: d), u)) }
        }
        return Array(out.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            let ls = links
            if !ls.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(ls.enumerated()), id: \.offset) { _, l in
                        Button { NSWorkspace.shared.open(l.1) } label: {
                            HStack(spacing: 5) {
                                Text(l.0).lineLimit(1)
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                            }
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.bone)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Palette.bone.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        switch type {
        case "flights": flights
        case "route": route
        case "steps": steps
        case "quote": quote
        case "score": score
        case "event": event
        case "compare": compare
        default: if dicts.isEmpty { keyValues } else { list }
        }
    }

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
    }
    private func dim(_ t: String, _ size: CGFloat = 12) -> some View {
        Text(t).font(.system(size: size)).foregroundStyle(.white.opacity(0.55))
    }

    private var flights: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "airplane").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.bone)
                title(s("title").isEmpty ? "Flights" : s("title"))
            }
            ForEach(Array(dicts.prefix(5).enumerated()), id: \.offset) { i, f in
                if i > 0 { Divider().overlay(Color.white.opacity(0.08)) }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text([s("airline", in: f), s("flight", in: f)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                        Spacer()
                        Text(s("price", in: f)).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
                    }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s("depart", in: f)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                            if !s("from", in: f).isEmpty { dim(s("from", in: f), 11) }
                        }
                        VStack(spacing: 2) {
                            dim(s("duration", in: f), 10.5)
                            HStack(spacing: 3) {
                                Circle().frame(width: 4, height: 4)
                                Rectangle().frame(height: 1)
                                Image(systemName: "airplane").font(.system(size: 8))
                            }
                            .foregroundStyle(.white.opacity(0.3)).frame(minWidth: 50)
                            dim(s("stops", in: f), 10.5)
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(s("arrive", in: f)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                            if !s("to", in: f).isEmpty { dim(s("to", in: f), 11) }
                        }
                    }
                    if !s("note", in: f).isEmpty { dim(s("note", in: f), 11.5) }
                }
            }
            if dicts.isEmpty, !s("note").isEmpty { dim(s("note"), 12.5) }
        }
    }

    private var route: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                endpoint(s("from"), icon: "location.fill")
                VStack(spacing: 3) {
                    Text(s("distance")).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
                    HStack(spacing: 3) {
                        Circle().frame(width: 5, height: 5)
                        Rectangle().frame(height: 1)
                        Circle().frame(width: 5, height: 5)
                    }
                    .foregroundStyle(Palette.bone.opacity(0.35))
                    if !s("time").isEmpty { dim(s("time"), 11.5) }
                }
                .frame(maxWidth: .infinity)
                endpoint(s("to"), icon: "mappin")
            }
            if !s("note").isEmpty { dim(s("note"), 12) }
        }
    }

    private func endpoint(_ name: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Palette.bone.opacity(0.8))
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(width: 96)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !s("title").isEmpty { title(s("title")) }
            let items = strings.isEmpty ? dicts.map { s("title", in: $0) } : strings
            ForEach(Array(items.prefix(12).enumerated()), id: \.offset) { i, t in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Palette.surface)
                        .frame(width: 18, height: 18).background(Palette.bone.opacity(0.75), in: Circle())
                    Text(t).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var quote: some View {
        let change = s("change") + s("pct")
        let down = [s("change"), s("pct")].contains { $0.hasPrefix("-") || $0.hasPrefix("−") }
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s("symbol")).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.bone.opacity(0.6))
                if !s("name").isEmpty { Text(s("name")).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85)) }
                Text(s("price")).font(.system(size: 30, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
            }
            Spacer()
            if !change.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: down ? "arrow.down.right" : "arrow.up.right").font(.system(size: 11, weight: .bold))
                    Text([s("change"), s("pct").isEmpty ? "" : "(\(s("pct")))"].filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(down ? Palette.rec : Palette.agentSolid)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background((down ? Palette.rec : Palette.agentSolid).opacity(0.12), in: Capsule())
            }
        }
    }

    private var score: some View {
        let teams = (obj["teams"] as? [Any] ?? []).compactMap { t -> (String, String)? in
            if let p = t as? [Any], let n = p.first { return ("\(n)", p.count > 1 ? "\(p[1])" : "") }
            if let d = t as? [String: Any] { return (s("name", in: d), s("score", in: d)) }
            return nil
        }
        let best = teams.compactMap { Int($0.1) }.max()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !s("title").isEmpty { dim(s("title"), 11.5) }
                Spacer()
                if !s("status").isEmpty { Text(s("status")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.bone.opacity(0.7)) }
            }
            ForEach(Array(teams.prefix(4).enumerated()), id: \.offset) { _, t in
                let lead = best != nil && Int(t.1) == best
                HStack {
                    Text(t.0).font(.system(size: 15, weight: lead ? .semibold : .regular)).foregroundStyle(.white.opacity(lead ? 0.95 : 0.7))
                    Spacer()
                    Text(t.1).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(lead ? Palette.bone : .white.opacity(0.55))
                }
            }
            if !s("note").isEmpty { dim(s("note"), 11.5) }
        }
    }

    private var event: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar").font(.system(size: 18)).foregroundStyle(Palette.bone.opacity(0.8))
                .frame(width: 36, height: 36).background(Palette.bone.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                title(s("title"))
                if !s("when").isEmpty { Text(s("when")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.bone) }
                if !s("where").isEmpty { dim(s("where"), 12) }
                if !s("note").isEmpty { dim(s("note"), 12) }
            }
        }
    }

    private var compare: some View {
        let cols = (obj["columns"] as? [Any] ?? []).map { "\($0)" }
        let rows = (obj["rows"] as? [Any] ?? []).compactMap { $0 as? [Any] }.map { $0.map { "\($0)" } }
        return VStack(alignment: .leading, spacing: 8) {
            if !s("title").isEmpty { title(s("title")) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                if !cols.isEmpty {
                    GridRow { ForEach(Array(cols.enumerated()), id: \.offset) { _, c in Text(c).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.bone.opacity(0.8)) } }
                    Divider().overlay(Color.white.opacity(0.1))
                }
                ForEach(Array(rows.prefix(10).enumerated()), id: \.offset) { _, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { j, c in
                            Text(c).font(.system(size: 12.5, weight: j == 0 ? .regular : .medium))
                                .foregroundStyle(.white.opacity(j == 0 ? 0.5 : 0.9))
                        }
                    }
                }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !s("title").isEmpty { title(s("title")) }
            ForEach(Array(dicts.prefix(8).enumerated()), id: \.offset) { i, d in
                if i > 0 { Divider().overlay(Color.white.opacity(0.07)) }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s("title", in: d).isEmpty ? s("name", in: d) : s("title", in: d))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                        if !s("subtitle", in: d).isEmpty { dim(s("subtitle", in: d), 12) }
                    }
                    Spacer(minLength: 8)
                    if !s("meta", in: d).isEmpty { Text(s("meta", in: d)).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.bone.opacity(0.75)) }
                    if let u = Self.link(s("url", in: d)) {
                        Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 13)) }
                            .buttonStyle(.plain).foregroundStyle(Palette.bone.opacity(0.6))
                    }
                }
            }
        }
    }

    /// Fallback for a type this build doesn't know: every scalar field as a row.
    private var keyValues: some View {
        let skip: Set<String> = ["type", "title", "url", "links"]
        let rows = obj.keys.sorted().filter { !skip.contains($0) && !(obj[$0] is [String: Any]) }.map { ($0.capitalized, s($0)) }.filter { !$0.1.isEmpty }
        return VStack(alignment: .leading, spacing: 8) {
            if !s("title").isEmpty { title(s("title")) }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, kv in
                    GridRow {
                        dim(kv.0, 12.5)
                        Text(kv.1).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                    }
                }
            }
        }
    }
}
