import AppKit
import SwiftUI

enum PhotosTest {
    /// `--phototest <fixture-dir> [png-dir]`: asserts intents for sample questions against saved Immich JSON (never the network),
    /// optionally renders cards to PNG, prints PASS/FAIL per case and exits 1 on any failure.
    @MainActor static func run(fixtures dir: String) {
        let args = CommandLine.arguments
        let pngDir = args.firstIndex(of: "--phototest").flatMap { args[safe: $0 + 2] }
        func load(_ f: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/immich-\(f).json"))) }
        Photos.baseOverride = URL(string: "http://homelab:2283")
        Photos.loader = { _, path, body in
            if path.hasPrefix("/api/search/person") { return path.lowercased().contains("name=alex") || path.lowercased().contains("name=june") || path.lowercased().contains("name=may") ? try load("person-search") : [Any]() }
            if path.hasSuffix("/statistics"), path.hasPrefix("/api/people/") { return try load("person-stats") }
            if path == "/api/server/statistics" { return try load("server-stats") }
            // Only Oct 2026 has photos in the fixtures; every other date is empty.
            let after = body?["takenAfter"] as? String ?? ""
            let o = try load(after.hasPrefix("2026-10-0") && !after.hasPrefix("2026-10-07") || after.hasPrefix("2026-09-30") || after.hasPrefix("2026-10-25") ? "date-oct" : "date-oct7") as? [String: Any]
            if path == "/api/search/statistics" { return ["total": ((o?["assets"] as? [String: Any])?["count"] as? Int) ?? 0] }
            return o ?? [:]
        }
        Photos.thumbLoader = { path in
            let h = Double(abs(path.hashValue % 360)) / 360
            return NSImage(size: NSSize(width: 160, height: 160), flipped: false) { r in
                NSGradient(colors: [NSColor(hue: h, saturation: 0.35, brightness: 0.55, alpha: 1), NSColor(hue: h + 0.08, saturation: 0.5, brightness: 0.8, alpha: 1)])?.draw(in: r, angle: 45)
                return true
            }
        }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 12))!   // a Sunday
        // (question, expected kind): nil | library | person:<name> | date:<label> | date:<label>:<name>
        let cases: [(String, String)] = [
            ("how many photos of alex do I have", "person:alex"), ("how many photos of Alex do I have in total", "person:Alex"),
            ("how many photos of John do I have", "person:John"), ("how many photos of June do I have", "person:June"),
            ("photos of May from last friday", "date:Nov 6, 2026:May"), ("photos of alex from october", "date:October 2026:alex"),
            ("show me pictures of Paris", "person:Paris"), ("show me my photos of eiffel tower", "person:eiffel tower"),
            ("pull up what I did on oct 7th 2026", "date:Oct 7, 2026"), ("show me my photos from october 25", "date:Oct 25, 2026"),
            ("link me to what I did yesterday", "date:Nov 7, 2026"), ("what did I do last night", "date:Nov 7, 2026"),
            ("show me what I did last friday", "date:Nov 6, 2026"), ("what did I do last weekend", "date:Oct 31 – Nov 1, 2026"),
            ("pull up my photos from this day last year", "date:Nov 8, 2025"), ("show me my photos from October", "date:October 2026"),
            ("how many photos do I have in 2024", "date:2024"), ("show me my photos from this week", "date:Nov 2 – Nov 8, 2026"),
            ("how many photos did I take this month", "date:November 2026"), ("how many photos did I take this year", "date:2026"),
            ("show me my photos from feb 29 2025", "date:Feb 28, 2025"), ("show me my iphone photos from yesterday", "date:Nov 7, 2026"),
            ("how many photos do I have", "library"), ("how big is my photo library", "library"),
            ("how many pictures do I have in immich", "library"), ("how many videos do I have", "library"),
            ("how many photos should I post", "nil"), ("how many pictures do I need for a passport", "nil"),
            ("how many photos do I have from last summer", "nil"), ("what did I do last week at work", "nil"),
            ("take a photo", "nil"), ("photo editing tips", "nil"), ("what is a photon", "nil"),
            ("how many photos can iphone store", "nil"), ("how many photos can I store on my iphone", "nil"),
            ("show me a picture of a cat", "nil"), ("how do I take a picture of the moon", "nil"),
            ("photos of the sunset", "nil"), ("photos of me", "nil"), ("I took three hours on my homework", "nil"),
            ("How many photos of Ashmit do you have?", "person:Ashmit"), ("do you have pictures of alex", "person:alex"),
            ("can you take a photo", "nil"), ("do you have a picture of a cat", "nil"), ("how many photos can you store", "nil"),
        ]
        // Follow-ups after a photo turn about "alex": (question, expected)
        let follow: [(String, String)] = [
            ("what about Ashmit?", "person:Ashmit"), ("and Ashmit", "person:Ashmit"), ("Ashmit?", "person:Ashmit"),
            ("how about photos of Mom", "person:Mom"), ("what about october", "date:October 2026:alex"),
            ("and from last friday?", "date:Nov 6, 2026:alex"), ("Thanks!", "nil"), ("cool", "nil"),
            ("what about the weather", "nil"), ("why", "nil"), ("what's the capital of France", "nil"),
            ("tell me a joke about cats please", "nil"), ("what about it", "nil"),
        ]
        func kind(_ i: Photos.Intent?) -> String {
            switch i {
            case nil: "nil"
            case .library?: "library"
            case .person(let n, _, _)?: "person:\(n)"
            case .date(let s, let p, _)?: "date:\(s.label)" + (p.map { ":\($0)" } ?? "")
            }
        }
        Task { @MainActor in
            var fails = 0
            func check(_ ok: Bool, _ what: String, _ detail: String = "") {
                print("\(ok ? "PASS" : "FAIL")  \(what)\(ok ? "" : "  \(detail)")")
                if !ok { fails += 1 }
            }
            if let pngDir {
                try? FileManager.default.createDirectory(atPath: pngDir, withIntermediateDirectories: true)
                for f in (try? FileManager.default.contentsOfDirectory(atPath: pngDir)) ?? [] where f.hasPrefix("photos-") { try? FileManager.default.removeItem(atPath: "\(pngDir)/\(f)") }
            }
            var n = 0
            for (q, want) in cases {
                let intent = Photos.parse(q, now: now)
                let got = kind(intent)
                check(got == want, q, "want \(want), got \(got)")
                guard let intent, let pngDir else { continue }
                let r = await Photos.run(intent)
                n += 1
                let v = ImageRenderer(content: r.card.padding(20).frame(width: 520).background(Color(hex: 0x1C1D20)).environment(\.colorScheme, .dark))
                v.scale = 2
                if let t = v.nsImage?.tiffRepresentation, let d = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                    let slug = q.prefix(28).filter { $0.isLetter || $0 == " " }.replacingOccurrences(of: " ", with: "_")
                    try? d.write(to: URL(fileURLWithPath: "\(pngDir)/photos-\(n)-\(slug).png"))
                }
            }
            // Behaviour of run(): definite vs fall-through answers, and no URL in spoken text.
            var r = await Photos.run(Photos.parse("how many photos of John do I have", now: now)!)
            check(r.final && r.answer.contains("No one named John"), "unknown name + count question is a final note", r.answer)
            r = await Photos.run(Photos.parse("show me pictures of Paris", now: now)!)
            check(!r.final, "unknown name without count question falls through (final false)", r.answer)
            for (q, want) in follow {
                let got = kind(Photos.followUp(q, person: "alex", now: now))
                check(got == want, "follow-up \"\(q)\" -> \(want)", got)
            }
            r = await Photos.run(Photos.parse("photos of May from last friday", now: now)!)
            check(r.final && r.answer.hasPrefix("No photos of ") && r.answer.contains(" on Nov 6, 2026"), "person May + Nov 6 resolves person and date", r.answer)
            r = await Photos.run(Photos.parse("show me my photos from October", now: now)!)
            check(r.final && !r.answer.contains("http") && r.facts.contains("http://homelab:2283/search?query="), "answer has no URL, facts keep it", r.answer)
            r = await Photos.run(Photos.parse("how many photos of alex do I have", now: now)!)
            check(r.answer.contains("19,352") && !r.answer.contains("http") && r.facts.contains("/people/"), "person count and link only in facts", r.answer)
            Photos.loader = { _, _, _ in throw Skills.Failure.unreachable }
            check(await Photos.run(.library).answer == Skills.unreachable, "offline note")
            print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
            exit(fails == 0 ? 0 : 1)
        }
    }
}
