import SwiftUI

private let up = Palette.agentSolid
private let down = Color(hex: 0xD98A82)

/// Native cards for finance answers (no model tokens involved).
struct FinanceCard: View {
    let r: Finance.Result

    var body: some View {
        switch r.card {
        case .holding(let h): HoldingCard(h: h)
        case .portfolio(let p): PortfolioCard(p: p)
        case .accounts(let a): AccountsCard(a: a)
        case .spending(let s): SpendingCard(s: s)
        case .txns(let t): TxnsCard(t: t)
        case .note(let t): FinanceShell { Text(t).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.8)) }
        case .offline:
            FinanceShell {
                HStack(spacing: 10) {
                    Image(systemName: "network.slash").foregroundStyle(Palette.bone.opacity(0.6)).font(.system(size: 18))
                    Text("Finance dashboard not reachable — is Tailscale on?").font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.8))
                }
            }
        case .none: EmptyView()
        }
    }
}

private struct FinanceShell<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private func label(_ s: String) -> some View { Text(s).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)) }
private func value(_ s: String) -> some View { Text(s).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.92)) }

private struct Gain: View {
    let cents: Int, pct: Double?, size: CGFloat
    var body: some View {
        let good = cents >= 0
        HStack(spacing: 4) {
            Image(systemName: good ? "arrow.up.right" : "arrow.down.right").font(.system(size: size - 1, weight: .semibold))
            Text(Finance.usd(abs(cents)) + (pct.map { " (\(Finance.pctText($0)))" } ?? "")).font(.system(size: size, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(good ? up : down)
    }
}

private func asOf(_ d: Date?) -> String { d.map { "as of " + $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "" }

struct HoldingCard: View {
    let h: Finance.Holding

    var body: some View {
        FinanceShell {
            HStack(alignment: .firstTextBaseline) {
                Text(h.symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Text(h.name).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer()
                Text(asOf(h.asOf)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(Finance.usd(h.value)).font(.system(size: 32, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
                if let g = h.gain { Gain(cents: g, pct: h.pct, size: 13) }
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 5) {
                GridRow { label("Shares"); value(Finance.shareText(h.shares)) }
                if let avg = h.avgCost { GridRow { label("Avg cost / share"); value(Finance.usd(avg)) } }
                if let c = h.cost { GridRow { label("Total cost"); value(Finance.usd(c)) } }
            }
            if h.uncosted > 1e-9 { label("Cost basis unavailable for \(Finance.shareText(h.uncosted)) shares") }
            if h.parts.count > 1 {
                Divider().overlay(Color.white.opacity(0.1))
                ForEach(Array(h.parts.enumerated()), id: \.offset) { _, p in
                    HStack {
                        Text(p.account).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        Spacer()
                        Text(Finance.shareText(p.shares)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        value(Finance.usd(p.value)).frame(minWidth: 80, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct PortfolioCard: View {
    let p: Finance.Portfolio

    var body: some View {
        FinanceShell {
            HStack(alignment: .firstTextBaseline) {
                label("Portfolio")
                Spacer()
                Text(asOf(p.asOf)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            Text(Finance.usd(p.total)).font(.system(size: 32, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
            GeometryReader { g in
                HStack(spacing: 2) {
                    Capsule().fill(Palette.askSolid).frame(width: max(4, g.size.width * CGFloat(p.invested) / CGFloat(max(1, p.total))))
                    Capsule().fill(Palette.bone.opacity(0.35))
                }
            }
            .frame(height: 6)
            HStack {
                legend(Palette.askSolid, "Invested \(Finance.usd(p.invested))")
                Spacer()
                legend(Palette.bone.opacity(0.35), "Cash \(Finance.usd(p.cash))")
            }
            Divider().overlay(Color.white.opacity(0.1))
            ForEach(Array(p.top.enumerated()), id: \.offset) { _, t in
                HStack {
                    Text(t.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    if let g = t.gain { Gain(cents: g, pct: t.pct, size: 11.5) }
                    value(Finance.usd(t.value)).frame(minWidth: 90, alignment: .trailing)
                }
            }
        }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 6) { Circle().fill(c).frame(width: 7, height: 7); Text(s).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)) }
    }
}

struct AccountsCard: View {
    let a: Finance.Accounts

    var body: some View {
        let ordered = a.list.filter { a.focus.contains($0.name) } + a.list.filter { !a.focus.contains($0.name) }
        let shown = Array(ordered.prefix(8))
        FinanceShell {
            label("Net worth")
            Text(Finance.usd(a.net)).font(.system(size: 32, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
            HStack(spacing: 18) {
                Text("Assets \(Finance.usd(a.assets))").foregroundStyle(up.opacity(0.9))
                Text("Liabilities \(Finance.usd(a.liabilities))").foregroundStyle(down.opacity(0.9))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            Divider().overlay(Color.white.opacity(0.1))
            ForEach(Array(shown.enumerated()), id: \.offset) { _, acc in
                let hit = a.focus.contains(acc.name)
                HStack {
                    Text(acc.name).font(.system(size: 12.5, weight: hit ? .semibold : .regular)).foregroundStyle(.white.opacity(hit ? 0.95 : 0.6)).lineLimit(1)
                    Spacer()
                    Text(Finance.usd(acc.isAsset ? acc.balance : -abs(acc.balance))).font(.system(size: 12.5, weight: hit ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(acc.isAsset ? .white.opacity(hit ? 1 : 0.8) : down)
                }
                .padding(.horizontal, hit ? 8 : 0).padding(.vertical, hit ? 4 : 0)
                .background(hit ? Palette.askSolid.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            if a.list.count > shown.count { label("+\(a.list.count - shown.count) more") }
        }
    }
}

struct SpendingCard: View {
    let s: Finance.Spending

    var body: some View {
        let q = s.match
        let rows = Array(s.rows.prefix(6)) + s.rows.dropFirst(6).filter { r in q.map { r.name.lowercased().contains($0) || ($0.contains(r.name.lowercased()) && r.name.count >= 4) } ?? false }
        let top = max(1, rows.first?.cents ?? 1)
        FinanceShell {
            HStack(alignment: .firstTextBaseline) {
                label("Spent in " + s.monthLabel)
                Spacer()
                if let b = s.burnPct { label(String(format: "%.0f%% burn", b)) }
            }
            Text(Finance.usd(s.spent)).font(.system(size: 32, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
            if let inc = s.income, inc > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    bar("Income", inc, max(inc, s.spent), up)
                    bar("Spending", s.spent, max(inc, s.spent), down)
                }
            }
            if !rows.isEmpty {
                Divider().overlay(Color.white.opacity(0.1))
                label("Gross by \(s.by)")
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    let hit = q.map { r.name.lowercased().contains($0) || $0.contains(r.name.lowercased()) } ?? false
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(r.name).font(.system(size: 12.5, weight: hit ? .semibold : .regular)).foregroundStyle(.white.opacity(hit ? 0.95 : 0.7)).lineLimit(1)
                            Spacer()
                            value(Finance.usd(r.cents))
                        }
                        GeometryReader { g in
                            Capsule().fill(hit ? Palette.askSolid : Palette.askSolid.opacity(0.45)).frame(width: max(3, g.size.width * CGFloat(r.cents) / CGFloat(top)))
                        }
                        .frame(height: 4)
                    }
                }
            }
            if let sv = s.saved, sv != 0 { label(s.current ? "Saved \(Finance.usd(sv)) so far" : "Saved \(Finance.usd(sv))") }
        }
    }

    private func bar(_ name: String, _ v: Int, _ full: Int, _ c: Color) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).frame(width: 64, alignment: .leading)
            GeometryReader { g in Capsule().fill(c.opacity(0.8)).frame(width: max(3, g.size.width * CGFloat(v) / CGFloat(max(1, full)))) }.frame(height: 6)
            value(Finance.usd(v)).frame(minWidth: 84, alignment: .trailing)
        }
    }
}

struct TxnsCard: View {
    let t: Finance.Txns
    /// ImageRenderer can't draw ScrollView, so --fintest turns this off to see every row.
    var scrollable = true

    var body: some View {
        FinanceShell {
            label("\(t.title) · \(t.monthLabel)")
            HStack(alignment: .firstTextBaseline) {
                Text(Finance.usd(t.total)).font(.system(size: 32, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
                Spacer()
                label("\(t.count) transaction\(t.count == 1 ? "" : "s")")
            }
            if !t.rows.isEmpty {
                Divider().overlay(Color.white.opacity(0.1))
                if scrollable, t.rows.count > 8 { ScrollView { list }.frame(height: 8 * 38) } else { list }
                if t.more > 0 { label("+\(t.more) more") }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(t.rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 10) {
                    Text(r.date).font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.45)).frame(width: 46, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        Text(r.category).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    value(Finance.usd(r.cents))
                }
            }
        }
    }
}
