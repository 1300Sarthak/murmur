import Foundation

/// Personal finance from the self-hosted dashboard on the tailnet (`fin <cmd> --json` over HTTP). Money questions
/// get live numbers drawn as a native card; the model only phrases an answer from a compact fact summary.
enum Finance {
    // MARK: Detection

    struct Period: Equatable {
        var month: String
        var unsupported = false
        var explicit = false
    }
    enum Intent: Equatable {
        case holding(String), portfolio, netWorth(Period), accounts(String), spending(Period, by: String, query: String?), income(Period), brief
        /// A list of expense transactions in one month. `filter`: "uncategorized", a category name, or merchant text.
        case txns(Period, filter: String?)

        var period: Period? {
            switch self {
            case .spending(let p, _, _), .income(let p), .netWorth(let p), .txns(let p, _): p
            default: nil
            }
        }
    }

    private static let names: [(String, String)] = [
        ("nvidia", "NVDA"), ("apple", "AAPL"), ("google", "GOOGL"), ("alphabet", "GOOGL"), ("amazon", "AMZN"), ("costco", "COST"),
        ("intel", "INTC"), ("qualcomm", "QCOM"), ("asml", "ASML"), ("sofi", "SOFI"), ("rivian", "RIVN"), ("shopify", "SHOP"),
        ("bitcoin", "BTC"), ("ethereum", "ETH"), ("ether", "ETH"), ("solana", "SOL"), ("ripple", "XRP"), ("tesla", "TSLA"),
        ("microsoft", "MSFT"), ("s&p", "VOO"), ("s and p", "VOO"), ("sp500", "VOO"), ("vanguard 500", "VOO"), ("nasdaq", "QQQ"),
    ]
    private static let spoken: Set<String> = ["nvda", "aapl", "googl", "amzn", "intc", "qcom", "sofi", "rivn", "btc", "voo",
                                              "qqq", "qqqm", "schd", "vxus", "vxf", "tsla", "msft", "xrp", "asml"]
    private static let notTickers: Set<String> = ["my", "the", "any", "this", "that", "of", "in", "our", "your", "a", "an", "much", "many",
                                                  "all", "stock", "stocks", "some", "what", "how", "bank", "total"]
    private static let accountKinds: [(String, [String])] = [
        ("hsa", ["hsa", "health savings"]), ("savings", ["savings"]), ("checking", ["checking"]),
        ("credit", ["credit card", "credit cards", "card balance"]), ("ira", ["roth", "ira"]), ("401k", ["401k", "401(k)", "four oh one"]),
        ("crypto", ["crypto account", "crypto wallet", "my crypto"]), ("brokerage", ["brokerage"]),
    ]
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    private static let numberWords = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]

    private static func has(_ q: String, _ pattern: String) -> Bool { q.range(of: pattern, options: .regularExpression) != nil }

    /// Capture groups (index 0 = whole match) of the first match, or nil.
    private static func rx(_ l: String, _ p: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: p), let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: l).map { String(l[$0]) } ?? "" }
    }

    /// Which ticker the question is about, from company names, spoken tickers, or "<word> stock".
    static func symbol(in q: String) -> String? {
        let l = q.lowercased()
        if let n = names.first(where: { has(l, #"\b"# + NSRegularExpression.escapedPattern(for: $0.0) + #"\b"#) }) { return n.1 }
        let words = l.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if let s = words.first(where: spoken.contains) { return s.uppercased() }
        if let g = rx(l, #"\b([a-z]{2,5})\s+(?:stock|shares|share|etf|coin)\b"#) ?? rx(l, #"\b(?:up|down|position|invested|stake)\s+(?:on|in)\s+([a-z]{2,5})\b"#),
           !notTickers.contains(g[1]) { return g[1].uppercased() }
        return nil
    }

    static func accountKind(in l: String) -> String? {
        accountKinds.first { $0.1.contains { has(l, #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#) } }?.0
    }

    /// The calendar month a question refers to. Ranges ("last year", "in 2025", "last week") are flagged unsupported
    /// rather than silently answered with the current month.
    static func period(in q: String, now: Date = Date()) -> Period {
        let l = q.lowercased()
        let cal = Calendar.current
        func ym(_ d: Date) -> String { DateFormatter.ym.string(from: d) }
        let year = rx(l, #"\b((?:19|20)\d{2})\b"#)?[1]
        if let m = months.firstIndex(where: { has(l, #"\b"# + $0 + #"\b"#) && !($0 == "may" && has(l, #"\bmay i\b|\bmay be\b"#)) }) {
            var c = cal.dateComponents([.year, .month], from: now)
            if let y = year.flatMap(Int.init) { c.year = y } else if m + 1 > c.month! { c.year! -= 1 }
            c.month = m + 1
            return Period(month: ym(cal.date(from: c)!), explicit: true)
        }
        if has(l, #"\blast month\b"#) { return Period(month: ym(cal.date(byAdding: .month, value: -1, to: now)!), explicit: true) }
        if let g = rx(l, #"\b(a|an|one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+months?\s+ago\b"#),
           let n = numberWords[g[1]] ?? Int(g[1]) { return Period(month: ym(cal.date(byAdding: .month, value: -n, to: now)!), explicit: true) }
        if has(l, #"\b(this month|so far|currently)\b"#) { return Period(month: ym(now), explicit: true) }
        if year != nil || has(l, #"\b(today|yesterday|tonight|this week|last week|this year|last year|ytd|year to date|quarter|weekly|annual|annually|all time|(last|past)\s+(\d+\s+)?(days?|weeks?|years?))\b"#) {
            return Period(month: ym(now), unsupported: true, explicit: true)
        }
        return Period(month: ym(now))
    }

    private static let slowText = "Finance dashboard is taking too long — try again."
    private static let unsupportedText = "I can only look up one calendar month at a time, like \"last month\" or \"in March\"."

    /// True for questions that lean on what was just shown ("and last month?", "show me those", "why is it so high").
    static func isFollowUp(_ q: String) -> Bool {
        let l = q.lowercased()
        if Weather.isWeatherQuestion(q) { return false }
        if has(l, #"\b(weather|forecast|news|score|recipe|translate|define|joke|time is it|who is|who was|what is a|how do i|how to)\b"#) { return false }
        // It must point back at the data: a leading "and/what about…", or a reference to what was shown.
        return has(l, #"^\s*(and|what about|how about|why|which one|then)\b|\b(those|them|these|that one|the rest|more detail|break (it|that|them) down|show me (it|that|those))\b"#)
    }

    static func detect(_ q: String, previous: Intent? = nil, now: Date = Date()) -> Intent? {
        // Photo/video questions belong to Photos, even when they mention a company ("photos of my Tesla").
        if has(q.lowercased(), #"\b(photos?|pictures?|pics|videos?|immich|selfies?)\b"#) { return nil }
        if let i = fresh(q, now: now, ctx: previous != nil) {
            // "show me the uncategorized" right after an October spending card means October.
            if case .txns(let p, let f) = i, !p.explicit, let pp = previous?.period, !pp.unsupported { return .txns(pp, filter: f) }
            return i
        }
        return followUp(q, previous: previous, now: now)
    }

    private static let periodWords = #"\b(this|last|past) (month|year)\b|\b(\#(months.joined(separator: "|")))\b|\b(19|20)\d{2}\b"#

    private static let techWords = #"\b(sql|code|python|swift|api|database|table|schema|columns?|spreadsheet|excel|csv|files?|folders?|desktop|notes?|documents?|docs|emails?|photos?|tasks?|bank statement|how to|show me how)\b"#
    private static let genericPlaces: Set<String> = ["store", "stores", "shop", "shops", "place", "places", "there", "somewhere", "online", "something", "anything", "stuff", "things", "mall", "market", "the", "a", "an", "that", "this"]

    private static func cleanFilter(_ f: String) -> String? {
        let t = f.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
        let words = t.split(separator: " ").map { $0.lowercased() }
        return words.isEmpty || words.allSatisfy(genericPlaces.contains) ? nil : t
    }

    /// "show me the uncategorized", "list my food & dining transactions", "what did I buy at costco".
    /// `ctx`: the conversation is already about finance, so a bare "the uncategorized" is about transactions.
    private static func txnsIntent(_ l: String, _ p: Period, ctx: Bool) -> Intent? {
        if has(l, techWords) { return nil }
        let personal = has(l, #"\b(i|i've|my|we|our)\b"#)
        if has(l, #"\buncategori[sz]ed\b"#), has(l, #"\b(show|list|see|display|what|which|find|pull|any|how many|are there)\b|\b(transactions?|purchases?|charges?|spending|spent|expenses?)\b"#),
           ctx || personal || p.explicit || has(l, #"\b(transactions?|purchases?|charges?|spending|spent|expenses?)\b"#) {
            return .txns(p, filter: "uncategorized")
        }
        let noun = #"(?:transactions?|purchases?|charges?|expenses?|txns?)"#
        if let g = rx(l, #"\bwhat (?:did|have) (?:i|we) (?:buy|bought|purchase|purchased)\s+(?:at|from)\s+(.+?)(?=\s+(?:this|last|in|during|so far)\b|[?.!]*$)"#) {
            return cleanFilter(g[1]).map { .txns(p, filter: $0) }
        }
        if let g = rx(l, #"^(?:please\s+|can you\s+|could you\s+)*(?:show|list|display|see|pull up|give)(?:\s+me)?\s+(?:all\s+)?(?:of\s+)?(?:(.+?)\s+)?"# + noun + #"\b(.*)$"#) {
            guard personal || p.explicit || ctx else { return nil }
            var sub = g[1].replacingOccurrences(of: periodWords, with: " ", options: .regularExpression)
            sub = sub.replacingOccurrences(of: #"\b(all|my|the|your|our|of|in|from|recent|latest|every|for|at|on)\b"#, with: " ", options: .regularExpression)
                .split(separator: " ").joined(separator: " ")
            if sub.count > 40 { return nil }
            var rest = g[2].replacingOccurrences(of: periodWords, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,"))
            rest = rest.split(separator: " ").joined(separator: " ")
            if has(rest, #"^(in|during|so far)?$"#) || rest == "in" { rest = "" }
            var merchant: String?
            if let m = rx(rest, #"^(?:at|from)\s+(.+)$"#) { merchant = cleanFilter(m[1].replacingOccurrences(of: #"\s+(in|during)$"#, with: "", options: .regularExpression)); if merchant == nil { return nil } }
            else if !rest.isEmpty, !has(rest, #"^(in|during)$"#) { return nil }
            return .txns(p, filter: merchant ?? (sub.isEmpty ? nil : sub))
        }
        return nil
    }

    private static func fresh(_ q: String, now: Date, ctx: Bool = false) -> Intent? {
        let l = q.lowercased()
        let personal = has(l, #"\b(i|i'm|i've|my|me|mine|am i|we|our)\b"#)
        if has(l, #"\b(how (do|can|should|would) i|how to|tell me about|what should|should i|can you (make|write|tell))\b"#) { return nil }
        let p = period(in: q, now: now)
        if has(l, #"\bnet worth\b"#) { return .netWorth(p) }
        if let t = txnsIntent(l, p, ctx: ctx) { return t }
        if has(l, #"\b(spend|spent|spending)\b"#), !has(l, #"\b(spen[dt]|spending)\s+(\w+\s+){0,2}(hours?|minutes?|days?|weeks?|weekends?|time|years?|nights?)\b"#) {
            var query: String?
            var at = false
            if let g = rx(l, #"\b(?:spend|spent|spending)\s+(?:the\s+)?(?:most\s+|more\s+)?(?:money\s+|so much\s+|a lot\s+)?(on|at|for)\s+(.+?)(?=\s+(?:this|last|in|during|so far|over|\d+ months?)\b|[?.!]*$)"#) {
                var o = g[2].replacingOccurrences(of: #"^(the|my|all|any)\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
                if has(o, #"^(this|last|in|during|so far|most|\d+ months?)\b"#) || o.isEmpty { o = "" }
                query = o.isEmpty ? nil : o
                at = g[1] == "at"
            }
            if personal || p.explicit || query != nil, query != nil || p.explicit || has(l, #"\b(money|how much|total|most|biggest|top|\$)"#) {
                let by = at || has(l, #"\b(merchants?|stores?|vendors?|where)\b"#) ? "merchant" : has(l, #"\bcards?\b"#) ? "card" : "category"
                return .spending(p, by: by, query: query)
            }
        }
        if has(l, #"\b(income|paycheck|salary|take.?home|savings rate|burn rate)\b"#) && (personal || p.explicit)
            || has(l, #"\bhow much\b.*\b(i|we)\s+(make|made|earn|earned|save|saved|take home)\b"#) { return .income(p) }
        if personal, let s = symbol(in: q),
           has(l, #"\b(own|have|hold|holding|holdings|shares?|stock|stocks|position|up|down|worth|invested|invest|gain|gained|loss|lost|stake|return)\b"#) { return .holding(s) }
        if let k = accountKind(in: l), !has(l, #"\b(plan|goal|rate|score|tips?|apy)\b"#),
           has(l, #"\b(accounts?|balances?|how much|in my|in the)\b"#) { return .accounts(k) }
        if personal, has(l, #"\b(portfolio|investments|holdings|my stocks|invested)\b"#) { return .portfolio }
        if has(l, #"\b(account balances?|my accounts|bank balance|how much money|my balances?)\b"#) { return .accounts("") }
        if personal, has(l, #"\b(my (money|finances|budget|debt)|afford|financial(ly)?)\b"#) { return .brief }
        return nil
    }

    /// "and last month?" / "what about checking?" after a finance question: keep the intent kind, swap the detail.
    private static func followUp(_ q: String, previous: Intent?, now: Date) -> Intent? {
        guard let prev = previous, q.split(separator: " ").count <= 9 else { return nil }
        let l = q.lowercased()
        let p = period(in: q, now: now)
        // "show me those" after a spending card: the underlying transactions.
        if has(l, #"\b(show|list|see|display)\b.*\b(those|them|these|all of them|everything|the transactions)\b"#), let pp = prev.period, !pp.unsupported {
            if case .spending(_, _, let query) = prev { return .txns(p.explicit ? p : pp, filter: query) }
            if case .txns(_, let f) = prev { return .txns(p.explicit ? p : pp, filter: f) }
        }
        let kind = accountKind(in: l)
        switch prev {
        case .txns(_, let f): return p.explicit ? .txns(p, filter: f) : nil
        case .spending(_, let by, let query): return p.explicit ? .spending(p, by: by, query: query) : nil
        case .income: return p.explicit ? .income(p) : nil
        case .holding, .portfolio: return symbol(in: q).map { .holding($0) }
        case .netWorth, .accounts, .brief:
            if let k = kind { return .accounts(k) }
            return p.explicit ? .netWorth(p) : nil
        }
    }

    // MARK: Results

    struct Position { let symbol: String, value: Int, gain: Int?, pct: Double? }
    struct Holding {
        struct Part { let account: String, shares: Double, value: Int, gain: Int? }
        let symbol: String, name: String, shares: Double, value: Int, cost: Int?, gain: Int?, pct: Double?, parts: [Part], asOf: Date?
        /// Shares that have a cost basis; gain and average cost cover only these.
        let costedShares: Double
        var uncosted: Double { max(0, shares - costedShares) }
        var avgCost: Int? { cost.flatMap { costedShares > 0 ? Int((Double($0) / costedShares).rounded()) : nil } }
    }
    struct Portfolio { let total: Int, invested: Int, cash: Int, positions: Int, top: [Position], asOf: Date? }
    struct Account { let name: String, type: String, balance: Int, isAsset: Bool }
    struct Accounts { let net: Int, assets: Int, liabilities: Int, list: [Account], focus: Set<String>, kind: String }
    struct Spending {
        let month: String, monthLabel: String, current: Bool, spent: Int, income: Int?, by: String, rows: [(name: String, cents: Int)], match: String?, burnPct: Double?, saved: Int?
    }
    struct Txn { let date: String, name: String, cents: Int, category: String }
    struct Txns { let title: String, monthLabel: String, count: Int, total: Int, rows: [Txn], more: Int }
    enum Card { case holding(Holding), portfolio(Portfolio), accounts(Accounts), spending(Spending), txns(Txns), note(String), offline, none }

    struct Result {
        var card: Card
        var facts: String
        /// Deterministic one-line answer built straight from the data; also the fallback if the model is down.
        var answer: String
        /// No model call: the answer is already complete (errors, unsupported periods, history lookups).
        var final = false
        var offline = false
        /// Sign of the headline gain (1 up, -1 down), so a model can't flip it.
        var direction: Int?
    }

    private static func note(_ text: String) -> Result { Result(card: .note(text), facts: text, answer: text, final: true) }

    static func systemPrompt(_ r: Result) -> String {
        """
        You are a fast assistant the user talks to by voice. Their question was transcribed from speech. Answer in 1-2 short \
        sentences using ONLY the figures below. Quote dollar amounts and percentages exactly as written; never compute new \
        numbers, round, or invent any. The user already sees a card with the details, so give just the takeaway. If the data \
        doesn't answer the question, say so. No Markdown. It is now \(Date().formatted(date: .complete, time: .shortened)).

        Finance data (just fetched):
        \(r.facts)
        """
    }

    /// For follow-ups in a conversation that already showed data: answer only from what was shown, or say it isn't there.
    static func followUpPrompt(_ facts: String) -> String {
        """
        You are a fast assistant the user talks to by voice, continuing a conversation about their own data. Answer in 1-3 \
        short sentences using ONLY the data below and the conversation so far. Never guess or invent figures, transactions, \
        or categories. If the data below doesn't contain the answer, say exactly what you can't see and suggest a question \
        that would fetch it (for example "show my uncategorized transactions in October"). No Markdown. \
        It is now \(Date().formatted(date: .complete, time: .shortened)).

        Data shown so far:
        \(facts.isEmpty ? "(none)" : facts)
        """
    }

    /// Facts-only variant for homelab skills (no direction info).
    static func numbersGrounded(_ text: String, facts: String) -> Bool {
        let known = numbers(facts)
        let year = Double(Calendar.current.component(.year, from: Date()))
        return numbers(text).allSatisfy { n in
            n == year || known.contains { abs(n - $0) <= max(0.0051, $0 * 0.01) || abs(n - $0.rounded()) < 0.001 }
        }
    }

    private static func numbers(_ s: String) -> [Double] {
        let t = s.replacingOccurrences(of: ",", with: "")
        return (try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#))?.matches(in: t, range: NSRange(t.startIndex..., in: t))
            .compactMap { Range($0.range, in: t).flatMap { Double(t[$0]) } } ?? []
    }

    /// True when every number in `text` is in the data (exact, within 1%, or rounded to a whole number) and any
    /// up/down wording agrees with the data, so a model can't slip in an invented figure.
    static func numbersGrounded(_ text: String, in r: Result) -> Bool {
        let known = numbers(r.facts) + numbers(r.answer)
        let year = Double(Calendar.current.component(.year, from: Date()))
        let ok = numbers(text).allSatisfy { n in
            n == year || known.contains { abs(n - $0) <= max(0.0051, $0 * 0.01) || abs(n - $0.rounded()) < 0.001 }
        }
        let l = text.lowercased()
        let upWord = has(l, #"\b(up|gained|gain|higher|profit)\b"#), downWord = has(l, #"\b(down|lost|loss|lower|dropped)\b"#)
        if r.direction == 1, downWord, !upWord { return false }
        if r.direction == -1, upWord, !downWord { return false }
        return ok
    }

    // MARK: Fetch

    enum FetchError: Error { case unreachable, slow, server(String) }

    /// Overridable so --fintest can read fixtures instead of the network.
    static var loader: ((String, [String: String]) async throws -> Any)?

    static var baseURL: String {
        let s = Prefs.financeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private static func get(_ cmd: String, _ params: [String: String] = [:]) async throws -> Any {
        if let loader { return try await loader(cmd, params) }
        guard var c = URLComponents(string: "\(baseURL)/api/fin/\(cmd)") else { throw FetchError.server("bad dashboard URL") }
        c.queryItems = params.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        guard let url = c.url else { throw FetchError.server("bad dashboard URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as URLError where e.code == .timedOut { throw FetchError.slow }
        catch { throw FetchError.unreachable }
        let obj = try? JSONSerialization.jsonObject(with: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj else {
            throw FetchError.server((obj as? [String: Any])?["error"] as? String ?? (code == 200 ? "unexpected response" : "HTTP \(code)"))
        }
        return obj
    }

    static func test() async -> Bool { (try? await get("overview")) != nil }

    /// Races `op` against a deadline so one slow call can't hang the Ask flow.
    private static func withDeadline<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask(operation: op)
            g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); throw FetchError.slow }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    /// nil when the ask was cancelled (never an "offline" card for a cancelled fetch).
    static func run(_ intent: Intent) async -> Result? {
        if loader == nil, baseURL.isEmpty { return note("Set your finance dashboard URL in Settings → Finance.") }
        do {
            let r = try await withDeadline(10) { try await execute(intent) }
            return Task.isCancelled ? nil : r
        } catch {
            if error is CancellationError || Task.isCancelled { return nil }
            if case FetchError.server(let m) = error { return Result(card: .note("Finance dashboard error: \(m)"), facts: "", answer: "Finance dashboard error: \(m)", final: true) }
            if case FetchError.slow = error { return Result(card: .note(slowText), facts: "", answer: slowText, final: true) }
            return Result(card: .offline, facts: "", answer: "Finance dashboard not reachable — is Tailscale on?", final: true, offline: true)
        }
    }

    private static func execute(_ intent: Intent) async throws -> Result {
        switch intent {
        case .holding(let s): return holding(try await get("holdings", ["symbol": s]), s)
        case .portfolio: return portfolio(try await get("holdings"))
        case .netWorth(let p) where p.unsupported: return note(unsupportedText)
        case .netWorth(let p) where p.month != DateFormatter.ym.string(from: Date()): return pastNetWorth(try await get("brief"), month: p.month)
        case .netWorth:
            async let a = get("accounts"), o = try? get("overview")
            return accounts(try await a, overview: await o, kind: "")
        case .accounts(let k):
            async let a = get("accounts"), o = try? get("overview")
            return accounts(try await a, overview: await o, kind: k)
        case .spending(let p, _, _) where p.unsupported, .income(let p) where p.unsupported: return note(unsupportedText)
        case .spending(let p, let by, let q):
            let m = p.month
            async let fl = flow(m)
            if by == "category" {
                let cat = try await get("spending", ["month": m])
                if let q, !hasMatch(rows(cat), q), let mer = try? await get("spending", ["month": m, "by": "merchant", "limit": "200"]), hasMatch(rows(mer), q) {
                    return spending(mer, cash: cat, month: m, by: "merchant", query: q, flow: await fl)
                }
                return spending(cat, cash: cat, month: m, by: by, query: q, flow: await fl)
            }
            async let r = get("spending", ["month": m, "by": by, "limit": q == nil ? "10" : "200"]), cat = try? get("spending", ["month": m])
            return spending(try await r, cash: await cat, month: m, by: by, query: q, flow: await fl)
        case .income(let p):
            async let cat = try? get("spending", ["month": p.month]), fl = flow(p.month)
            guard let f = await fl else { throw FetchError.server("no income data for \(monthName(p.month))") }
            let c = await cat
            return spending(c ?? [String: Any](), cash: c, month: p.month, by: "category", query: nil, flow: f, income: true)
        case .brief: return brief(try await get("brief"))
        case .txns(let p, _) where p.unsupported: return note(unsupportedText)
        case .txns(let p, let f): return txns(try await get("txns", ["month": p.month, "limit": "1000"]), month: p.month, filter: f)
        }
    }


    /// THE month definition for every answer: overview's `flow` (take-home, net spend, saved), else the brief's row for that month.
    private static func flow(_ m: String) async -> [String: Any]? {
        if let ov = try? await get("overview", ["month": m]), let f = (ov as? [String: Any])?["flow"] as? [String: Any], f["month"] as? String == m { return f }
        return ((try? await get("brief")).flatMap { ($0 as? [String: Any])?["flow"] as? [[String: Any]] })?.first { $0["month"] as? String == m }
    }

    // MARK: Parsing

    private static func cents(_ v: Any?) -> Int { (v as? NSNumber).map { Int($0.doubleValue.rounded()) } ?? 0 }
    private static func opt(_ v: Any?) -> Int? { (v as? NSNumber).map { Int($0.doubleValue.rounded()) } }
    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func usd(_ c: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return (c < 0 ? "-$" : "$") + (f.string(from: NSNumber(value: Double(abs(c)) / 100)) ?? "0.00")
    }

    static func shareText(_ s: Double) -> String {
        func trim(_ x: String) -> String { var t = x; while t.contains("."), t.hasSuffix("0") || t.hasSuffix(".") { t.removeLast() }; return t }
        let t = trim(String(format: s >= 100 ? "%.2f" : s >= 1 ? "%.4f" : "%.8f", s))
        return t == "0" && s > 0 ? String(format: "%g", s) : t
    }

    static func pctText(_ p: Double) -> String { String(format: "%+.1f%%", p) }

    private static func gainPhrase(_ gain: Int, _ pct: Double?) -> String {
        let p = pct.map { " (\(pctText($0)))" } ?? ""
        return gain == 0 ? "flat" : "\(gain > 0 ? "up" : "down") \(usd(abs(gain)))\(p)"
    }

    /// "Example Credit Card **1234 (1234)" -> "Example Credit Card".
    private static func clean(_ n: String) -> String {
        n.replacingOccurrences(of: #"\s*\(\d{3,}\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*(\*+|-)\s*\d{3,}$"#, with: "", options: .regularExpression)
    }

    private static func holding(_ any: Any, _ symbol: String) -> Result {
        let rows = ((any as? [String: Any])?["holdings"] as? [[String: Any]] ?? []).filter { ($0["symbol"] as? String)?.uppercased() == symbol }
        guard !rows.isEmpty else {
            return Result(card: .note("No \(symbol) in your accounts."), facts: "The user holds no \(symbol).", answer: "You don't hold any \(symbol).", final: true)
        }
        func sh(_ r: [String: Any]) -> Double { (r["shares"] as? NSNumber)?.doubleValue ?? 0 }
        let parts = rows.map { Holding.Part(account: $0["accountName"] as? String ?? "", shares: sh($0), value: cents($0["marketValueCents"]), gain: opt($0["gainCents"])) }
        let costed = rows.filter { opt($0["gainCents"]) != nil && cents($0["costBasisCents"]) > 0 }
        let cost = costed.isEmpty ? nil : costed.reduce(0) { $0 + cents($1["costBasisCents"]) }
        let gain = costed.isEmpty ? nil : costed.reduce(0) { $0 + cents($1["gainCents"]) }
        let h = Holding(symbol: symbol, name: rows[0]["description"] as? String ?? symbol, shares: parts.reduce(0) { $0 + $1.shares },
                        value: parts.reduce(0) { $0 + $1.value }, cost: cost, gain: gain,
                        pct: gain.flatMap { g in cost.map { Double(g) / Double($0) * 100 } }, parts: parts, asOf: rows.compactMap { date($0["asOf"]) }.max(),
                        costedShares: costed.reduce(0) { $0 + sh($1) })
        var a = "You have \(shareText(h.shares)) \(symbol) worth \(usd(h.value))"
        if let g = h.gain { a += ", \(gainPhrase(g, h.pct))" }
        if parts.count > 1 { a += " across \(parts.count) accounts" }
        a += "."
        if h.uncosted > 1e-9 { a += " Cost basis is unavailable for \(shareText(h.uncosted)) shares." }
        var facts = "\(h.name) (\(symbol)): \(shareText(h.shares)) shares, current value \(usd(h.value))"
        if let c = h.cost, let g = h.gain, let avg = h.avgCost {
            facts += ", average cost \(usd(avg)) per share, total cost \(usd(c)), \(g >= 0 ? "gain" : "loss") \(usd(abs(g))) (\(pctText(h.pct ?? 0)))"
        }
        if h.uncosted > 1e-9 { facts += ". Cost basis unavailable for \(shareText(h.uncosted)) shares" }
        if parts.count > 1 { facts += "\n" + parts.map { "- \($0.account): \(shareText($0.shares)) shares, \(usd($0.value))" }.joined(separator: "\n") }
        return Result(card: .holding(h), facts: facts, answer: a, direction: h.gain.map { $0 == 0 ? 0 : $0 > 0 ? 1 : -1 })
    }

    private static let cashLike: Set<String> = ["SPAXX", "FDRXX", "USD", "CASH"]

    private static func portfolio(_ any: Any) -> Result {
        let obj = any as? [String: Any] ?? [:]
        let sum = obj["summary"] as? [String: Any] ?? [:]
        var by: [String: (value: Int, gain: Int, cost: Int)] = [:]
        for r in obj["holdings"] as? [[String: Any]] ?? [] {
            guard let s = r["symbol"] as? String, !cashLike.contains(s.uppercased()) else { continue }
            var e = by[s] ?? (0, 0, 0)
            e.value += cents(r["marketValueCents"])
            if opt(r["gainCents"]) != nil, cents(r["costBasisCents"]) > 0 { e.gain += cents(r["gainCents"]); e.cost += cents(r["costBasisCents"]) }
            by[s] = e
        }
        let top = by.sorted { $0.value.value > $1.value.value }.prefix(6).map {
            Position(symbol: $0.key, value: $0.value.value, gain: $0.value.cost > 0 ? $0.value.gain : nil,
                     pct: $0.value.cost > 0 ? Double($0.value.gain) / Double($0.value.cost) * 100 : nil)
        }
        let p = Portfolio(total: cents(sum["totalCents"]), invested: cents(sum["investedCents"]), cash: cents(sum["cashCents"]),
                          positions: cents(sum["positions"]), top: Array(top), asOf: date(sum["asOf"]))
        var a = "Your portfolio is worth \(usd(p.total)): \(usd(p.invested)) invested and \(usd(p.cash)) in cash."
        if let t = top.first { a += " Your biggest position is \(t.symbol) at \(usd(t.value))." }
        let facts = "Portfolio total \(usd(p.total)), invested \(usd(p.invested)), cash \(usd(p.cash)), \(p.positions) positions\nTop positions:\n" +
            top.map { "- \($0.symbol): \(usd($0.value))" + ($0.gain.map { ", \($0 >= 0 ? "gain" : "loss") \(usd(abs($0)))" } ?? "") + ($0.pct.map { " (\(pctText($0)))" } ?? "") }.joined(separator: "\n")
        return Result(card: .portfolio(p), facts: facts, answer: a)
    }

    private static func accounts(_ any: Any, overview: Any?, kind: String) -> Result {
        let list = (any as? [[String: Any]] ?? []).filter { $0["isActive"] as? Bool != false }.map {
            Account(name: $0["name"] as? String ?? "Account", type: $0["type"] as? String ?? "", balance: cents($0["currentBalanceCents"]), isAsset: $0["isAsset"] as? Bool ?? true)
        }.sorted { $0.balance > $1.balance }
        let ov = overview as? [String: Any]
        let assets = ov.map { cents($0["assets"]) } ?? list.filter(\.isAsset).reduce(0) { $0 + $1.balance }
        let liabilities = ov.map { cents($0["liabilities"]) } ?? list.filter { !$0.isAsset }.reduce(0) { $0 + abs($1.balance) }
        let net = ov.map { cents($0["netWorth"]) } ?? assets - liabilities
        func match(_ a: Account) -> Bool {
            switch kind {
            case "": return false
            case "401k": return a.name.lowercased().contains("401")
            case "credit": return a.type == "credit"
            default: return a.type == kind
            }
        }
        let focus = list.filter(match)
        var a = "Your net worth is \(usd(net)): \(usd(assets)) in assets and \(usd(liabilities)) in liabilities."
        var facts = "Net worth \(usd(net)), assets \(usd(assets)), liabilities \(usd(liabilities))\nAccounts:\n" +
            list.map { "- \($0.name) (\($0.type)): \(usd($0.balance))" }.joined(separator: "\n")
        if !kind.isEmpty {
            let label = kind == "credit" ? "credit card" : kind == "401k" ? "401(k)" : kind == "hsa" ? "HSA" : kind
            let total = focus.reduce(0) { $0 + $1.balance }
            if focus.isEmpty { a = "I couldn't find a \(label) account." }
            else if focus.count == 1 { a = "Your \(label) account has \(usd(abs(total)))." }
            else { a = "Your \(label) accounts total \(usd(abs(total))) across \(focus.count) accounts." }
            facts += "\nAsked about \(label) accounts: \(focus.isEmpty ? "none found" : "total \(usd(total))")"
        }
        return Result(card: .accounts(Accounts(net: net, assets: assets, liabilities: liabilities, list: list, focus: Set(focus.map(\.name)), kind: kind)), facts: facts, answer: a)
    }

    /// Net worth at the end of a past month, from the brief's daily series.
    private static func pastNetWorth(_ any: Any, month: String) -> Result {
        let series = ((any as? [String: Any])?["netWorth"] as? [String: Any])?["series"] as? [[String: Any]] ?? []
        guard let last = series.last(where: { ($0["date"] as? String)?.hasPrefix(month) == true }) else {
            return note("I only have net worth history for roughly the last month, so I can't see \(monthName(month)).")
        }
        let a = "Your net worth was \(usd(cents(last["net"]))) on \(last["date"] as? String ?? month)."
        return Result(card: .note(a), facts: a, answer: a, final: true)
    }

    private static func monthName(_ m: String) -> String {
        guard let d = DateFormatter.ym.date(from: m) else { return m }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMMM" : "MMMM yyyy"
        return f.string(from: d)
    }

    /// Spending rows from either shape: by=category is `{cashflow, categories}`, by=merchant/card is a top-level array.
    private static func rows(_ any: Any) -> [(name: String, cents: Int)] {
        let list = (any as? [[String: Any]]) ?? (any as? [String: Any]).flatMap { o in ["categories", "merchants", "cards", "rows", "items"].lazy.compactMap { o[$0] as? [[String: Any]] }.first } ?? []
        return list.map { (clean($0["merchant"] as? String ?? $0["name"] as? String ?? $0["card"] as? String ?? $0["category"] as? String ?? "Other"), cents($0["spentCents"] ?? $0["totalCents"] ?? $0["amountCents"])) }
            .filter { $0.cents > 0 }.sorted { $0.cents > $1.cents }
    }

    private static func isMatch(_ name: String, _ q: String) -> Bool {
        let n = name.lowercased()
        return n.contains(q) || (n.count >= 4 && q.contains(n))
    }
    private static func hasMatch(_ r: [(name: String, cents: Int)], _ q: String) -> Bool { r.contains { isMatch($0.name, q) } }

    private static func spending(_ any: Any, cash: Any?, month m: String, by: String, query: String?, flow: [String: Any]?, income inc: Bool = false) -> Result {
        let rs = rows(any)
        let cf = (cash as? [String: Any])?["cashflow"] as? [String: Any]
        let total = flow.map { cents($0["netSpendCents"]) } ?? cf.map { cents($0["spendingCents"]) } ?? rs.reduce(0) { $0 + $1.cents }
        let income = flow.map { cents($0["takeHomeCents"]) } ?? cf.flatMap { opt($0["incomeCents"]) }
        let mn = monthName(m)
        let isNow = m == DateFormatter.ym.string(from: Date())
        let s = Spending(month: m, monthLabel: mn, current: isNow, spent: total, income: income, by: by, rows: rs, match: query,
                         burnPct: (flow?["burnPct"] as? NSNumber)?.doubleValue, saved: flow.map { cents($0["savedCents"]) })
        var a = isNow ? "You've spent \(usd(total)) so far in \(mn)" : "You spent \(usd(total)) in \(mn)"
        if let i = income, i > 0 { a += ", against \(usd(i)) of income" }
        a += "."
        if inc, let b = s.burnPct, let sv = s.saved {
            a = "In \(mn) you took home \(usd(income ?? 0)) and spent \(usd(total)) (\(String(format: "%.0f", b))% burn), saving \(usd(sv))."
        } else if query == nil, by != "category", let t = rs.first {
            a = "Your top \(by) in \(mn) was \(t.name) at \(usd(t.cents)), out of \(usd(total)) spent in total."
        }
        if let q = query {
            let hit = rs.filter { isMatch($0.name, q) }
            if hit.isEmpty { a = "I didn't find any spending on \(q) in \(mn). " + (rs.first.map { "Your biggest \(by) is \($0.name) at \(usd($0.cents))." } ?? "") }
            else { a = "You spent \(usd(hit.reduce(0) { $0 + $1.cents })) on \(hit.map(\.name).joined(separator: " and ")) in \(mn)." }
        }
        var facts = "Month \(mn): total spending \(usd(total))" + (income.map { ", income \(usd($0))" } ?? "")
        if let b = s.burnPct, let sv = s.saved { facts += ", burn \(String(format: "%.0f", b))%, saved \(usd(sv))" }
        facts += "\nBy \(by):\n" + rs.prefix(10).map { "- \($0.name): \(usd($0.cents))" }.joined(separator: "\n")
        if let q = query { facts += "\nThe user asked about spending on \"\(q)\"." }
        return Result(card: .spending(s), facts: facts, answer: a.trimmingCharacters(in: .whitespaces))
    }

    private static func normName(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "&", with: "and").split(separator: " ").joined(separator: " ")
    }

    /// Expense rows for one month, narrowed client-side by category (own or parent name) or merchant text.
    private static func txns(_ any: Any, month m: String, filter: String?) -> Result {
        let all = (any as? [[String: Any]]) ?? ((any as? [String: Any])?["txns"] as? [[String: Any]]) ?? []
        var byId: [Int: String] = [:]
        for t in all { if let c = t["category"] as? [String: Any], let id = (c["id"] as? NSNumber)?.intValue, let n = c["name"] as? String { byId[id] = n } }
        func names(_ t: [String: Any]) -> [String] {
            guard let c = t["category"] as? [String: Any], let n = c["name"] as? String else { return [] }
            return [n] + ((c["parentId"] as? NSNumber).flatMap { byId[$0.intValue] }.map { [$0] } ?? [])
        }
        func isUncat(_ t: [String: Any]) -> Bool { names(t).first.map { normName($0) == "uncategorized" } ?? true }
        // Same definition as `fin spending`: real expenses only, refunds netted against the purchase they reverse.
        var refunded: [Int: Int] = [:]
        for t in all where cents(t["amountCents"]) > 0 && (t["isRefund"] as? Bool) == true {
            if let id = (t["refundsTxnId"] as? NSNumber)?.intValue { refunded[id, default: 0] += cents(t["amountCents"]) }
        }
        let skipAccounts: Set<String> = ["brokerage", "ira", "crypto"], skipKinds: Set<String> = ["income", "transfer", "investment"]
        var rows: [[String: Any]] = []
        for var t in all {
            let amt = cents(t["amountCents"])
            guard amt < 0, (t["isTransfer"] as? Bool) != true, (t["isExcluded"] as? Bool) != true else { continue }
            if let ty = (t["account"] as? [String: Any])?["type"] as? String, skipAccounts.contains(ty) { continue }
            if let k = (t["category"] as? [String: Any])?["kind"] as? String, skipKinds.contains(k) { continue }
            let net = max(-amt - (refunded[(t["id"] as? NSNumber)?.intValue ?? -1] ?? 0), 0)
            guard net > 0 else { continue }
            t["amountCents"] = -net
            rows.append(t)
        }
        var title = "Transactions"
        var phrase = "transactions"
        if let f = filter {
            let nf = normName(f)
            if nf == "uncategorized" { rows = rows.filter(isUncat); title = "Uncategorized"; phrase = "uncategorized transactions" }
            else {
                func hit(_ n: String) -> Bool { let x = normName(n); return x == nf || x.contains(nf) || (nf.contains(x) && x.count >= 4) }
                if let match = rows.lazy.compactMap({ t in names(t).first(where: hit) }).first {
                    rows = rows.filter { names($0).contains(where: hit) }; title = match; phrase = "\(match) transactions"
                } else {
                    rows = rows.filter { t in [t["merchantRaw"], t["payeeNormalized"], t["memo"]].contains { ($0 as? String)?.lowercased().contains(f.lowercased()) == true } }
                    title = f.capitalized; phrase = "transactions at \(f.capitalized)"
                }
            }
        }
        rows.sort { ($0["postedAt"] as? String ?? "") > ($1["postedAt"] as? String ?? "") }
        let mn = monthName(m)
        let total = rows.reduce(0) { $0 - cents($1["amountCents"]) }
        let list = rows.prefix(50).map { t -> Txn in
            let d = String((t["postedAt"] as? String ?? "").prefix(10)).split(separator: "-")
            let day = d.count == 3 ? "\(months[(Int(d[1]) ?? 1) - 1].prefix(3).capitalized) \(Int(d[2]) ?? 0)" : ""
            let name = (t["merchantRaw"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (t["payeeNormalized"] as? String) ?? "Unknown"
            return Txn(date: day, name: name, cents: -cents(t["amountCents"]), category: names(t).first ?? "Uncategorized")
        }
        let answer = rows.isEmpty ? "I found no \(phrase) in \(mn)."
            : "You have \(rows.count) \(rows.count == 1 ? phrase.replacingOccurrences(of: "transactions", with: "transaction") : phrase) in \(mn) totalling \(usd(total))."
        var facts = answer
        if !list.isEmpty { facts += "\nTransactions (date, merchant, amount, category):\n" + list.map { "- \($0.date) \($0.name) \(usd($0.cents)) \($0.category)" }.joined(separator: "\n") }
        if rows.count > list.count { facts += "\n(+\(rows.count - list.count) more not listed)" }
        let t = Txns(title: title, monthLabel: mn, count: rows.count, total: total, rows: list, more: rows.count - list.count)
        return Result(card: .txns(t), facts: facts, answer: answer, final: true)
    }

    private static func brief(_ any: Any) -> Result {
        let obj = any as? [String: Any] ?? [:]
        let nw = obj["netWorth"] as? [String: Any] ?? [:]
        var facts = "Net worth \(usd(cents(nw["net"]))), assets \(usd(cents(nw["assets"]))), liabilities \(usd(cents(nw["liabilities"])))"
        var a = "Your net worth is \(usd(cents(nw["net"])))"
        let last = (obj["flow"] as? [[String: Any]])?.last
        let mn = last.flatMap { $0["month"] as? String }.map(monthName) ?? "this month"
        for f in (obj["flow"] as? [[String: Any]] ?? []).suffix(3) {
            facts += "\n\(f["month"] as? String ?? ""): income \(usd(cents(f["takeHomeCents"]))), spending \(usd(cents(f["netSpendCents"]))), saved \(usd(cents(f["savedCents"])))"
        }
        if let f = (obj["flow"] as? [[String: Any]])?.last {
            a += ", and in \(mn) you've spent \(usd(cents(f["netSpendCents"]))) against \(usd(cents(f["takeHomeCents"]))) of income"
        }
        let cats = (obj["topCategories"] as? [[String: Any]] ?? []).prefix(5)
        if !cats.isEmpty { facts += "\nTop categories: " + cats.map { "\($0["name"] as? String ?? ""): \(usd(cents($0["spentCents"])))" }.joined(separator: ", ") }
        return Result(card: .none, facts: facts, answer: a + ".")
    }
}

extension DateFormatter {
    static let ym: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f }()
}
