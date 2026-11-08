import SwiftUI

enum HostTest {
    /// `--hosttest <fixture-dir> [png-dir]`: runs sample questions against saved Beszel JSON (no network, no keychain).
    @MainActor static func run(fixtures: String, pngDir: String? = nil) {
        func load(_ key: String) throws -> Any {
            try JSONSerialization.jsonObject(with: Foundation.Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/beszel-\(key).json")))
        }
        var asked: [(String, String?)] = []
        /// Emulates PocketBase `filter=system='ID'`: only rows of that system come back.
        func loader(extraSystem: Bool, reverse: Bool = false) -> (String, String?) async throws -> Any {
            { key, sys in
                asked.append((key, sys))
                var o = try load(key) as! [String: Any]
                var items = o["items"] as! [[String: Any]]
                if key == "systems", extraSystem {
                    var other = items[0]; other["id"] = "otherid000000000"; other["name"] = "zz-vps"; other["info"] = ["cpu": 99.0, "mp": 10.0, "dp": 10.0]
                    items = reverse ? [other] + items : items + [other]
                }
                if key != "systems", let sys { items = items.filter { ($0["system"] as? String) == sys } }
                o["items"] = items
                return o
            }
        }
        Host.loader = loader(extraSystem: false)
        let questions = [
            "how much storage is left on my 8tb drive", "how much space is left on my eight terabyte hdd", "how full are my drives",
            "what's the CPU usage on my server", "how much ram is my server using", "is my homelab ok", "what's using the most cpu on my server",
            "what's using the most memory on my homelab", "how hot is my server", "how much space is left on my windows drive", "how much is left on my 4tb drive",
            "how much storage does my iphone have", "what's a cpu", "how much ram should I buy", "my mac is slow", "how much storage is on my laptop",
            "my server at work is down", "can you set up a web server", "is the minecraft server up", "is the discord server ok",
            "what is the server status for github", "how much space is left on the server at work",
        ]
        Task { @MainActor in
            var fails = 0
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                if !ok { fails += 1 }
                print("  \(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  \(detail)")")
            }
            if let pngDir { try? FileManager.default.createDirectory(atPath: pngDir, withIntermediateDirectories: true) }
            for (i, q) in questions.enumerated() {
                guard let intent = Host.detect(q) else { print("Q: \(q)\n  -> not host\n"); continue }
                let r = await Host.run(intent, question: q)
                print("Q: \(q)\n  -> \(intent)\n  A: \(r.answer)\n")
                guard let pngDir else { continue }
                let v = ImageRenderer(content: r.card.padding(20).frame(width: 520).background(Color(hex: 0x1C1D20)).environment(\.colorScheme, .dark))
                v.scale = 2
                if let t = v.nsImage?.tiffRepresentation, let d = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: "\(pngDir)/host-\(i + 1).png"))
                }
            }
            print("ASSERTIONS")
            let yes: [(String, Host.Intent)] = [
                ("how much storage is left on my 8tb drive", .disks(focus: "8tb")), ("how much space is left on my eight terabyte hdd", .disks(focus: "8tb")),
                ("how full are my drives", .disks(focus: nil)), ("what's the CPU usage on my homelab", .cpu), ("how much ram is my server using", .ram),
                ("is my homelab ok", .status), ("what's using the most cpu on my server", .top("cpu")), ("how hot is my server", .temp),
            ]
            for (q, want) in yes { check("detect \"\(q)\"", Host.detect(q) == want, "got \(String(describing: Host.detect(q)))") }
            let no = ["how much storage does my iphone have", "what's a cpu", "how much ram should I buy", "my mac is slow", "my server at work is down", "can you set up a web server",
                      "is the minecraft server up", "is the discord server ok", "what is the server status for github", "how much space is left on the server at work",
                      "how much storage is on my laptop", "is the server down"]
            for q in no { check("not host \"\(q)\"", Host.detect(q) == nil, "got \(String(describing: Host.detect(q)))") }

            // Multiple systems: the stats/containers calls carry the chosen system's id, whatever order the API lists them in.
            let sysId = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(fixtures)/beszel-systems.json"))) as? [String: Any])?["items"] as? [[String: Any]])?.first?["id"] as? String ?? ""
            for reverse in [false, true] {
                Host.loader = loader(extraSystem: true, reverse: reverse); asked = []
                let r = await Host.run(.top("cpu"), question: "what's using the most cpu on my server")
                check("multi-system pick is order-independent (reverse=\(reverse))", asked.filter { $0.0 != "systems" }.allSatisfy { $0.1 == sysId } && r.answer.contains("Top CPU"), r.answer)
                check("multi-system stats filtered by id (reverse=\(reverse))", asked.contains { $0.0 == "stats" && $0.1 == sysId } && asked.contains { $0.0 == "containers" && $0.1 == sysId }, "\(asked)")
            }
            let named = await Host.run(.cpu, question: "what's the cpu on my server zz-vps")
            check("spoken system name picks that system", named.answer.contains("99%"), named.answer)
            check("paths filter by system", Host.path("stats", system: "abc").contains("system%3D%27abc%27") && Host.path("containers", system: "abc").contains("system%3D%27abc%27"), Host.path("stats", system: "abc"))

            Host.token = "secret"; Host.tokenHost = "a.ts.net"
            Host.resetTokenIfHostChanged("a.ts.net"); check("token kept for same host", Host.token == "secret")
            Host.resetTokenIfHostChanged("b.ts.net"); check("token reset when host changes", Host.token == nil)

            Host.loader = { _, _ in throw Skills.Failure.unreachable }
            check("unreachable note", await Host.run(.cpu).answer == Skills.unreachable)
            Host.loader = { _, _ in throw Skills.Failure.missingKey("beszel-user") }
            check("missing key note", await Host.run(.cpu).answer.contains("beszel-user"))
            for q in ["how much did I spend on my 8TB drive", "how much did I spend on my 8 terabyte drive in October", "how much did my 8TB drive cost", "request a refund for my 8TB drive"] {
                check("money about a drive is not host \"\(q)\"", Host.detect(q) == nil, "\(String(describing: Host.detect(q)))")
            }
            print(fails == 0 ? "HOSTTEST ALL PASS" : "HOSTTEST \(fails) FAILED")
            exit(fails == 0 ? 0 : 1)
        }
    }
}
