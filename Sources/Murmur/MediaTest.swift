import SwiftUI

enum MediaTest {
    /// `--mediatest <fixture-dir>`: fixtures only; POSTs are recorded, never sent.
    @MainActor static func run(fixtures dir: String, pngDir: String? = nil) {
        if let pngDir { try? FileManager.default.createDirectory(atPath: pngDir, withIntermediateDirectories: true) }
        var posts: [String] = []
        var queries: [String] = []
        func file(_ n: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(n).json")))) ?? [:] }
        var failPost: Skills.Failure?
        Media.loader = { method, path, query, body in
            if method == "POST" {
                let d = try JSONSerialization.data(withJSONObject: body ?? [:], options: [.sortedKeys])
                posts.append("POST \(path) \(String(data: d, encoding: .utf8)!)")
                if let failPost { throw failPost }
                return [String: Any]()
            }
            switch path {
            case "/search":
                queries.append(query["query"] ?? "")
                let q = (query["query"] ?? "").lowercased()
                if q.contains("dune") { return file("seerr-search-dune") }
                if q.contains("office") { return file("seerr-search-office") }
                if q.contains("ocean") {
                    return ["results": [["id": 161, "mediaType": "movie", "title": "Ocean's Eleven", "releaseDate": "2001-12-07", "overview": "Danny Ocean assembles a crew to rob three casinos.", "mediaInfo": ["status": 5]],
                                        ["id": 163, "mediaType": "movie", "title": "Ocean's Twelve", "releaseDate": "2004-12-10", "overview": ""]]]
                }
                func m(_ id: Int, _ t: String, _ y: String) -> [String: Any] { ["id": id, "mediaType": "movie", "title": t, "releaseDate": y + "-01-01", "overview": ""] }
                if q.contains("blade runner") { return ["results": [m(335984, "Blade Runner 2049", "2017"), m(78, "Blade Runner", "1982")]] }
                if q.contains("wonder woman") { return ["results": [m(1, "Wonder Woman", "2017"), m(464052, "Wonder Woman 1984", "2020"), ["id": 9, "mediaType": "movie", "title": "", "releaseDate": ""]]] }
                return ["results": [Any]()]
            case "/settings/radarr", "/settings/sonarr":
                return [["isDefault": false, "is4k": true, "activeProfileId": 9, "activeProfileName": "4K"],
                        ["isDefault": true, "is4k": false, "activeProfileId": 7, "activeProfileName": "Best Available"]]
            case "/request": return file("seerr-requests")
            default:
                let id = Int(path.split(separator: "/").last ?? "") ?? 0
                return path.hasPrefix("/tv") ? ["name": "Show \(id)", "firstAirDate": "2019-01-01"] : ["title": "Movie \(id)", "releaseDate": "2010-05-05"]
            }
        }
        let qs = [
            "request dune on seerr", "add the movie dune 2021 to my library", "download the office show", "request ocean's eleven movie",
            "add dune part two to seerr", "can you request the series the office on overseerr", "what have I requested recently", "status of my requests",
            "request a refund", "add a reminder", "download this file", "add milk to my list", "what movie should I watch",
            "add a movie night reminder to my calendar", "request the movie zzzzqq on seerr",
        ]
        // (phrase, expected): nil = no match, "recent", "ask:<text>", or "found:<answer prefix>"
        let checks: [(String, String?)] = [
            ("add a show of hands", nil), ("add show tunes to my playlist", nil), ("add a series of tests to the file", nil),
            ("download the show notes", nil), ("add a tv to the shopping list", nil),
            ("what did I request from the landlord", nil), ("what are the latest requests for comment", nil),
            ("request a refund", nil), ("add a reminder", nil), ("download this file", nil), ("add milk to my list", nil), ("what movie should I watch", nil),
            ("what have I requested recently", "recent"), ("status of my requests", "recent"), ("what have I requested on seerr", "recent"),
            ("request the movie blade runner 2049", "found:Found Blade Runner 2049 (2017"), ("add wonder woman 1984 to my library", "found:Found Wonder Woman 1984 (2020"),
            ("add the movie dune 2021 to my library", "found:Found Dune (2021, movie)"), ("request dune on seerr", "found:Found Dune (2021"),
            ("download the office show", "found:Found The Office (2005, show)"), ("request ocean's eleven movie", "found:Found Ocean's Eleven"),
            ("add the movie", "ask:Which movie?"), ("add a movie to my library", "ask:Which movie?"), ("add the 2012 movie to my library", "ask:Which movie?"),
            ("request the show on seerr", "ask:Which show?"),
        ]
        Task { @MainActor in
            var fails = 0
            print("ASSERTIONS")
            for (q, want) in checks {
                let job = Media.match(q)
                var got = "none", ok = false
                if let job {
                    let a = await job().answer
                    got = a
                    switch want {
                    case "recent": ok = a.hasPrefix("Your last")
                    case let w? where w.hasPrefix("ask:"): ok = a == String(w.dropFirst(4))
                    case let w?: ok = a.hasPrefix(String(w.dropFirst(6)))
                    case nil: ok = false
                    }
                } else { ok = want == nil }
                if !ok { fails += 1 }
                print("  \(ok ? "PASS" : "FAIL") \(q) -> \(got.prefix(70))")
            }
            print("assertions failed: \(fails)\n")
            var n = 0
            var first: MediaCardModel?
            for q in qs {
                guard let job = Media.match(q) else { print("Q: \(q)\n  -> no match\n"); continue }
                let r = await job()
                print("Q: \(q)\n  parsed: \(Media.parse(q).map { "\($0)" } ?? "status/recent")\n  A: \(r.answer)\n")
                n += 1
                let slug = q.prefix(22).filter { $0.isLetter || $0 == " " }.replacingOccurrences(of: " ", with: "_")
                render(r.card, pngDir.map { "\($0)/media-\(n)-\(slug).png" })
                _ = first
            }
            print("search queries sent: \(queries)")
            // Simulate clicks on card state: request Dune, then a tv show, then a 409.
            let dune = await Media.match("request dune on seerr")!()
            _ = dune
            let items = Media.rank((file("seerr-search-dune") as! [String: Any])["results"] as! [[String: Any]], Media.parse("request dune on seerr")!)
            let model = MediaCardModel(items: Array(items.prefix(4)), profiles: ["movie": (7, "Best Available"), "tv": (7, "Best Available")])
            first = model
            render(AnyView(MediaCard(m: model)), pngDir.map { "\($0)/media-click-before.png" })
            await model.request(model.items[0])
            await model.request(model.items.first { $0.type == "tv" } ?? model.items[1])
            let off = Media.rank((file("seerr-search-office") as! [String: Any])["results"] as! [[String: Any]], Media.parse("download the office show")!)
            await MediaCardModel(items: Array(off.prefix(1)), profiles: ["tv": (7, "Best Available")]).request(off[0])
            failPost = .http(409, "Request for this media already exists.")
            if let alt = model.items.last { await model.request(alt) }
            print("click POSTs (never sent):"); posts.forEach { print("  \($0)") }
            print("states: \(model.state)")
            render(AnyView(MediaCard(m: model)), pngDir.map { "\($0)/media-click-after.png" })
            exit(fails > 0 ? 1 : 0)
        }
    }

    @MainActor static func render(_ card: AnyView, _ path: String?) {
        guard let path else { return }
        let v = ImageRenderer(content: card.padding(20).frame(width: 520).background(Color(hex: 0x1C1D20)).environment(\.colorScheme, .dark))
        v.scale = 2
        if let t = v.nsImage?.tiffRepresentation, let d = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }
}
