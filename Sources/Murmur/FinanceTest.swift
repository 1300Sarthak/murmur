import SwiftUI

extension Finance {
    /// `--fintest <fixture-dir> [png-dir]`: runs sample questions against saved JSON (never the network, never hotkeys).
    @MainActor static func selfTest(dir: String, pngDir: String?) {
        loader = { cmd, params in
            var file = cmd
            if cmd == "holdings", params["symbol"] == "NVDA" { file = "holdings-nvda" }
            if cmd == "spending" {
                if let by = params["by"] { file = "spending-\(by)-oct" }
                else if params["month"] == "2026-10" { file = "spending-category-oct" }
            }
            if cmd == "txns" { file = params["month"] == "2026-09" ? "txns-sep" : "txns-oct" }
            let month = params["month"] ?? DateFormatter.ym.string(from: Date())
            if cmd == "txns", month != "2026-10", month != "2026-09" { return [Any]() }
            if cmd == "spending", params["by"] != nil, month != "2026-10" { return [Any]() }
            var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(file).json")))
            if cmd == "holdings", let s = params["symbol"], var o = obj as? [String: Any] {
                o["holdings"] = (o["holdings"] as? [[String: Any]])?.filter { ($0["symbol"] as? String)?.uppercased() == s.uppercased() }
                obj = o
            }
            return obj
        }
        // (question, is a follow-up to the previous finance question)
        let questions: [(String, Bool)] = [
            ("how much nvidia stock do I have", false), ("how much am I up on voo", false), ("what's my net worth", false), ("and last month?", true),
            ("how much do I have in savings", false), ("how much is in my health savings account", false), ("how much did I spend this month", false),
            ("what did I spend on food", false), ("what did I spend last month", false), ("what did I spend at costco last month", false),
            ("how much did I spend on amazon this month", false), ("which merchants did I spend the most at last month", false),
            ("which card did I spend the most on last month", false), ("how much did I make this month", false), ("how much did I make last month", false),
            ("what did I spend in 2025", false), ("how much is in my checking account", false), ("how are my investments doing", false),
            ("how much bitcoin do I own", false), ("can I afford a new laptop", false), ("what about checking?", true),
            ("how much am I up on tsla", false), ("what's the weather", false), ("how much is nvidia stock", false), ("how tall is Everest", false),
            ("how do I save a file in vim", false), ("can you make me a list of movie ideas", false), ("what should I make for dinner", false),
            ("how many calories did I burn running", false), ("I spent three hours debugging", false), ("how do I spend a weekend in Paris", false),
            ("i want to shop for shoes", false), ("is my intel mac too slow", false), ("how do I check my balance in swift", false),
            ("tell me about my credit score", false), ("my savings plan for the trip", false), ("should I buy ether or bitcoin", false),
            ("how much is the stock market up", false),
            ("How much have I spent in October", false), ("Show me all the uncategorized?", true), ("show me those", true), ("what did I spend on food in october", false), ("show me those", true), ("show my amazon purchases in october", false), ("list my food & dining transactions in october", false),
            ("what did I buy at chipotle in october", false), ("show me the uncategorized transactions last month", false),
            ("show me the uncategorized", true), ("show me how to list transactions in sql", false),
            ("show me the bank statement", false), ("what did I buy at costco", false),
            ("list my food & dining transactions in september", false), ("show me my restaurant transactions in september", false), ("show me the uncategorized", true),
            ("how much did I spend on food in september", false), ("show me those", true),
        ]
        Task { @MainActor in
            var n = 0
            var prev: Intent?
            if let pngDir { try? FileManager.default.createDirectory(atPath: pngDir, withIntermediateDirectories: true) }
            @MainActor func png(_ r: Result, _ name: String) {
                guard let pngDir else { return }
                let card: AnyView = { if case .txns(let t) = r.card { return AnyView(TxnsCard(t: t, scrollable: false)) }; return AnyView(FinanceCard(r: r)) }()
                let v = ImageRenderer(content: card.padding(20).frame(width: 520).background(Color(hex: 0x1C1D20)).environment(\.colorScheme, .dark))
                v.scale = 2
                if let t = v.nsImage?.tiffRepresentation, let d = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: "\(pngDir)/\(name).png"))
                }
            }
            for (q, follow) in questions {
                guard let intent = detect(q, previous: follow ? prev : nil), let r = await run(intent) else { print("Q: \(q)\n  -> not finance\n"); continue }
                prev = intent
                print("Q: \(q)\n  -> \(intent)\n  A: \(r.answer)\n")
                if case .none = r.card { continue }
                n += 1
                png(r, "\(n)-\(String(String(describing: intent).prefix(9)).filter { $0.isLetter })-\(q.prefix(24).filter { $0.isLetter || $0 == " " }.replacingOccurrences(of: " ", with: "_"))")
            }
            print("numbersGrounded checks:")
            let nv = await run(.holding("NVDA"))!
            for t in ["You hold 0.023493 NVDA worth $4.39, down $0.61.", "You have about $5 of NVDA, down 12.2%.", "NVDA is up $0.61.", "You have $4.39 of NVDA, down 12 percent."] {
                print("  \(Finance.numbersGrounded(t, in: nv)) <- \(t)")
            }
            print("ASSERTIONS")
            var fails = 0
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                if !ok { fails += 1 }
                print("  \(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  \(detail)")")
            }
            // Same definition as `fin spending`: uncategorized txns total == the Uncategorized category's spentCents.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/spending-category-oct-recon.json")),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let cats = o["categories"] as? [[String: Any]],
               let unc = cats.first(where: { $0["name"] as? String == "Uncategorized" }) {
                let want = (unc["spentCents"] as? NSNumber)?.intValue ?? -1, count = (unc["count"] as? NSNumber)?.intValue ?? -1
                if let r = await run(.txns(Period(month: "2026-10", explicit: true), filter: "uncategorized")), case .txns(let t) = r.card {
                    check("uncategorized txns total == fin spending (\(usd(t.total)) vs \(usd(want)))", t.total == want, "\(t.total) vs \(want)")
                    check("uncategorized txns count == fin spending (\(t.count) vs \(count))", t.count == count, "\(t.count) vs \(count)")
                } else { check("uncategorized txns card", false) }
            } else { check("recon fixture present", false) }
            // Refunds net against the purchase they reverse; investment-account rows and income-kind categories are excluded.
            let synth: [[String: Any]] = [
                ["id": 1, "amountCents": -1000, "postedAt": "2026-10-02T00:00:00.000Z", "merchantRaw": "Shop", "account": ["type": "credit"], "category": NSNull()],
                ["id": 2, "amountCents": 400, "isRefund": true, "refundsTxnId": 1, "postedAt": "2026-10-03T00:00:00.000Z", "merchantRaw": "Shop", "account": ["type": "credit"]],
                ["id": 3, "amountCents": -5000, "postedAt": "2026-10-02T00:00:00.000Z", "merchantRaw": "Buy", "account": ["type": "brokerage"], "category": NSNull()],
                ["id": 4, "amountCents": -700, "postedAt": "2026-10-02T00:00:00.000Z", "merchantRaw": "Pay", "account": ["type": "checking"], "category": ["id": 1, "name": "Paycheck", "kind": "income"]],
                ["id": 5, "amountCents": -300, "postedAt": "2026-10-04T00:00:00.000Z", "merchantRaw": "Full", "account": ["type": "credit"], "category": NSNull()],
                ["id": 6, "amountCents": 300, "isRefund": true, "refundsTxnId": 5, "postedAt": "2026-10-04T00:00:00.000Z", "merchantRaw": "Full", "account": ["type": "credit"]],
            ]
            let saved = loader
            loader = { _, _ in synth }
            if let r = await run(.txns(Period(month: "2026-10", explicit: true), filter: nil)), case .txns(let t) = r.card {
                check("refund nets, brokerage/income-kind/fully-refunded dropped (total \(t.total), count \(t.count))", t.total == 600 && t.count == 1, "\(t.total) \(t.count)")
            } else { check("synthetic txns card", false) }
            loader = saved
            let oct = Period(month: "2026-10", explicit: true)
            func det(_ q: String, prev: Intent? = nil) -> Intent? { detect(q, previous: prev) }
            check("list purchases at costco in october keeps merchant", det("list purchases at costco in october") == .txns(oct, filter: "costco"), "\(String(describing: det("list purchases at costco in october")))")
            check("show my amazon purchases in october", det("show my amazon purchases in october") == .txns(oct, filter: "amazon"))
            check("what did I buy at chipotle in october", det("what did I buy at chipotle in october") == .txns(oct, filter: "chipotle"))
            check("bare 'show me the uncategorized' in finance context", det("show me the uncategorized", prev: .spending(oct, by: "category", query: nil)) == .txns(oct, filter: "uncategorized"))
            for q in ["show me the transactions table schema", "list expenses for a trip budget", "show me the uncategorized files on my desktop", "show me the uncategorized notes",
                      "list my charges for the phone", "what did I buy at the store", "show me the uncategorized"] {
                check("not finance \"\(q)\"", det(q) == nil, "\(String(describing: det(q)))")
            }
            // Cross-skill routing: photo questions mid finance conversation go to Photos (skills are tried first in ask()).
            let skillQs = ["what did I do on October 7th", "how many photos of Alex from last month", "what did I do yesterday",
                           "how many photos did I take this year", "show me my photos from this month", "how many photos do I have from the Costco trip",
                           "how many photos of Amazon boxes do I have", "how many pictures of my Tesla do I have"]
            for q in skillQs {
                let claimed = Photos.match(q) != nil || det(q, prev: .spending(oct, by: "category", query: nil)) == nil
                check("photos wins \"\(q)\"", claimed, "photos=\(Photos.match(q) != nil) finance=\(String(describing: det(q, prev: .spending(oct, by: "category", query: nil))))")
            }
            for q in ["how many photos of Amazon boxes do I have", "how many pictures of my Tesla do I have", "how many photos do I have from the Costco trip"] {
                check("ticker in photo question is not finance \"\(q)\"", det(q) == nil, "\(String(describing: det(q)))")
            }
            for q in ["and last month?", "show me those", "and those?", "break it down", "what about checking?"] { check("follow-up \"\(q)\"", Finance.isFollowUp(q)) }
            for q in ["what's the weather tomorrow in san jose", "is it going to rain", "will it snow tomorrow", "how cold is it outside", "what time is it in Tokyo", "tell me a joke"] {
                check("not follow-up \"\(q)\"", !Finance.isFollowUp(q))
            }
            print(fails == 0 ? "FINTEST ASSERTIONS ALL PASS" : "FINTEST \(fails) ASSERTIONS FAILED")
            if fails > 0 { exit(1) }
            loader = { _, _ in throw FetchError.unreachable }
            let off = (await run(.netWorth(Period(month: DateFormatter.ym.string(from: Date()))))!)
            print("Offline: \(off.answer)")
            png(off, "offline")
            loader = { _, _ in throw FetchError.server("db locked") }
            print("Server error: \((await run(.portfolio))!.answer)")
            loader = { _, _ in throw FetchError.slow }
            print("Slow: \((await run(.portfolio))!.answer)")
            exit(0)
        }
    }
}
