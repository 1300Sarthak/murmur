#if DEBUG
import AppKit
import SwiftUI

/// `--cardtest [png-dir]`: parses sample model answers into blocks, checks each card type is recognised, that links are
/// limited to http(s), and that broken or half-streamed cards are dropped. With a png dir, renders each answer for a visual check.
enum CardTest {
    static let samples: [(String, String)] = [
        ("flights", #"```card {"type":"flights","title":"SFO → DEL","items":[{"airline":"Air India","flight":"AI 174","depart":"Nov 20 · 11:00 AM","arrive":"Nov 21 · 4:30 PM","duration":"16h 0m","stops":"Nonstop","price":"$1,050","from":"SFO","to":"DEL"},{"airline":"United","flight":"UA 1 + AI 121","depart":"Nov 20 · 1:15 PM","arrive":"Nov 22 · 12:10 AM","duration":"23h 25m","stops":"1 stop · FRA","price":"$880"}],"url":"https://www.google.com/travel/flights?q=Flights%20from%20SFO%20to%20DEL%20on%202026-11-20"}```"# + "\nAir India's nonstop is fastest; the United connection saves about $170."),
        ("route", #"```card {"type":"route","from":"Dublin, CA","to":"New Delhi","distance":"7,700 mi","time":"~17h nonstop","note":"Straight-line distance; Mumbai is about 8,400 mi."}```"#),
        ("list", #"```card {"type":"list","title":"Ramen near Dublin","items":[{"title":"Ramen Hiroshi","subtitle":"Japanese · 0.8 mi","meta":"4.6★ · $$","url":"https://maps.google.com/?q=Ramen+Hiroshi"},{"title":"Ippudo","subtitle":"Japanese · 12 mi","meta":"4.4★"}]}```"#),
        ("steps", #"```card {"type":"steps","title":"Renew a passport","items":["Fill in form DS-82","Attach a new photo","Mail it with the old passport and fee"]}```"#),
        ("quote", #"```card {"type":"quote","symbol":"NVDA","name":"NVIDIA","price":"$182.40","change":"-3.10","pct":"-1.7%"}```"#),
        ("score", #"```card {"type":"score","title":"NBA","status":"Final","teams":[["Warriors","112"],["Lakers","108"]]}```"#),
        ("event", #"```card {"type":"event","title":"Costco Dublin","when":"Today · 10 AM – 8:30 PM","where":"7200 Amador Plaza Rd","links":[["Directions","https://maps.apple.com/?q=Costco+Dublin"]]}```"#),
        ("compare", #"```card {"type":"compare","columns":["","iPhone 17","Pixel 10"],"rows":[["Price","$799","$799"],["Battery","22h","24h"]]}```"#),
        ("unknown", #"```card {"type":"recipe","title":"Chai","serves":"2","time":"10 min"}```"#),
        ("stat", #"```card {"type":"stat","value":"8,849 m","label":"Mount Everest","note":"29,032 ft"}```"#),
    ]

    @MainActor static func run(pngDir: String?) {
        Task { @MainActor in
            var fails = 0
            func check(_ ok: Bool, _ what: String, _ detail: String = "") {
                print("\(ok ? "PASS" : "FAIL")  \(what)\(ok ? "" : "  \(detail)")")
                if !ok { fails += 1 }
            }
            for (name, text) in samples {
                let blocks = Block.parse(text, streaming: false)
                let cards = blocks.filter { if case .card = $0 { true } else if case .stat = $0 { true } else { false } }
                check(cards.count == 1, "\(name) renders as one card", "\(blocks)")
                if let pngDir {
                    try? FileManager.default.createDirectory(atPath: pngDir, withIntermediateDirectories: true)
                    let v = ImageRenderer(content: RichAnswer(text: text, streaming: false).padding(20).frame(width: 520)
                        .background(Color(hex: 0x1C1D20)).environment(\.colorScheme, .dark))
                    v.scale = 2
                    if let t = v.nsImage?.tiffRepresentation, let d = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: "\(pngDir)/card-\(name).png"))
                    }
                }
            }
            check(Block.parse(#"```card {"type":"flights","items":[{"#, streaming: true).isEmpty, "half-streamed card stays hidden")
            let lead = Block.parse("I’ll check the latest Warriors game score.```card {\"type\":\"score\",\"teams\":[[\"A\",\"1\"]]}```\n\nThey won.", streaming: false)
            check(lead.count == 2 && { if case .card = lead[0] { true } else { false } }(), "inline card after a lead-in sentence renders, lead-in dropped", "\(lead)")
            let keep = Block.parse("Here are two options:```card {\"type\":\"steps\",\"items\":[\"a\"]}```", streaming: false)
            check(keep.count == 2, "a real sentence before a card is kept", "\(keep)")
            check(Block.parse("Use ```card``` blocks", streaming: false).count >= 1, "prose mentioning cards doesn't crash")
            let fenced = "```markdown\nWrite ```card {\"a\":1}``` here\n```"
            check(Block.normalized(fenced) == fenced, "code fence content is never rewritten")
            let prose = "Use ```card blocks for cards. More text after."
            check(Block.normalized(prose) == prose, "prose mentioning ```card is untouched")
            let looking = "Looking at it, Python is faster.\n```card {\"type\":\"stat\",\"value\":\"2x\"}```"
            check(Block.parse(looking, streaming: false).count == 2, "a real first sentence above a card is kept")
            let cardinal = Block.parse("```cardinal\nfoo\n```", streaming: false); check({ if case .code(let c)? = cardinal.first { c.contains("foo") } else { false } }(), "```cardinal stays a code block", "\(cardinal)")
            check(Block.parse("I'll search for flights.\n```card {\"type\":\"steps\",\"items\":[\"a\"]}```", streaming: false).count == 1, "progress line above a card is dropped")
            check(Block.parse(#"```card {not json}```"#, streaming: false).isEmpty, "broken JSON is dropped")
            check(Block.parse(#"```card {"type":"facts","items":[{"title":"a"}]}```"#, streaming: false).count == 1, "facts with object items falls back to a list")
            for bad in ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:", "https://", "ftp://a.com"] {
                check(ModelCard.link(bad) == nil, "link rejected: \(bad)")
            }
            check(ModelCard.link("https://www.google.com/travel/flights?q=x") != nil, "https link allowed")
            print(fails == 0 ? "CARDTEST ALL PASS" : "\(fails) FAILED")
            exit(fails == 0 ? 0 : 1)
        }

    }
}
#endif
