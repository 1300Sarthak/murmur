import AppKit
import SwiftUI

/// Turns an AI answer (Markdown plus optional ```card {json}``` blocks) into native views. Rendering is local,
/// so it costs no extra tokens.
enum Block: Hashable {
    case paragraph(String), heading(String), bullet(String), numbered(Int, String)
    case table([[String]]), code(String), stat(value: String, label: String, note: String)
    case facts(title: String, items: [[String]])

    static func parse(_ text: String, streaming: Bool) -> [Block] {
        var blocks: [Block] = []
        var lines = text.components(separatedBy: "\n")[...]
        var para: [String] = []
        func flush() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] } }

        while let line = lines.popFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                var body = String(t.dropFirst(3))
                var closed = false
                if body.hasSuffix("```"), body.count > 3 { body = String(body.dropLast(3)); closed = true }
                while !closed, let next = lines.popFirst() {
                    if next.trimmingCharacters(in: .whitespaces).hasSuffix("```") {
                        body += "\n" + next.trimmingCharacters(in: .whitespaces).dropLast(3); closed = true
                    } else { body += "\n" + next }
                }
                let isCard = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("card")
                if isCard {
                    // Half-streamed cards stay hidden until complete.
                    if closed, let card = card(from: String(body.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(4))) { blocks.append(card) }
                } else {
                    let code = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
                    blocks.append(.code(code.isEmpty ? body : code))
                }
            } else if t.hasPrefix("#") {
                flush(); blocks.append(.heading(t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                flush(); blocks.append(.bullet(String(t.dropFirst(2))))
            } else if let r = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                let n = Int(t[r].filter(\.isNumber)) ?? 1
                blocks.append(.numbered(n, String(t[r.upperBound...])))
            } else if t.hasPrefix("|") {
                flush()
                var rows = [t]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(lines.removeFirst().trimmingCharacters(in: .whitespaces)) }
                let cells = rows.filter { !$0.contains("---") }.map { r in
                    r.trimmingCharacters(in: CharacterSet(charactersIn: "| ")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                blocks.append(.table(cells))
            } else if t.isEmpty {
                flush()
            } else {
                para.append(t)
            }
        }
        flush()
        return blocks
    }

    private static func card(from json: String) -> Block? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        switch obj["type"] as? String {
        case "stat":
            return .stat(value: obj["value"].map { "\($0)" } ?? "", label: obj["label"] as? String ?? "", note: obj["note"] as? String ?? "")
        case "facts":
            let items = (obj["items"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
            return items.isEmpty ? nil : .facts(title: obj["title"] as? String ?? "", items: items)
        default: return nil
        }
    }
}

struct RichAnswer: View {
    let text: String
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Block.parse(text, streaming: streaming).enumerated()), id: \.offset) { _, b in view(for: b) }
            if streaming { Text("▍").foregroundStyle(Palette.bone.opacity(0.5)).font(.system(size: 13)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func md(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }

    @ViewBuilder private func view(for b: Block) -> some View {
        switch b {
        case .paragraph(let s):
            md(s).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(.white.opacity(0.92))
        case .heading(let s):
            md(s).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).padding(.top, 2)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Capsule().fill(Palette.bone.opacity(0.4)).frame(width: 6, height: 1.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                md(s).font(.system(size: 14.5)).foregroundStyle(.white.opacity(0.9))
            }
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n).").font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Palette.bone.opacity(0.45)).frame(minWidth: 14, alignment: .trailing)
                md(s).font(.system(size: 14.5)).foregroundStyle(.white.opacity(0.9))
            }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            md(cell).font(.system(size: 13, weight: i == 0 ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(i == 0 ? 0.95 : 0.8))
                        }
                    }
                    if i == 0 { Divider().overlay(Color.white.opacity(0.12)) }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .code(let c):
            ZStack(alignment: .topTrailing) {
                Text(c).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Button { Paster.copy(c) } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45)).padding(8)
            }
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .stat(let value, let label, let note):
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.bone.opacity(0.55))
                Text(value).font(.system(size: 32, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.bone)
                if !note.isEmpty { md(note).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)) }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .facts(let title, let items):
            VStack(alignment: .leading, spacing: 9) {
                if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, kv in
                        GridRow {
                            Text(kv.first ?? "").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5))
                            md(kv.dropFirst().joined(separator: " ")).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                        }
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Native weather card drawn from Open-Meteo data (no model tokens involved).
struct WeatherCard: View {
    let w: Weather.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: Weather.symbol(w.code, day: w.isDay))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(Palette.bone).font(.system(size: 40))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(w.temp)°").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                    Text(w.condition.capitalized).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(w.place.components(separatedBy: ",").first ?? w.place).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    if let d = w.days.first { Text("H \(d.high)°  L \(d.low)°").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
                    Text("Feels \(w.feels)° · \(w.wind) mph").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(w.hours.prefix(8).enumerated()), id: \.offset) { _, h in
                    VStack(spacing: 4) {
                        Text(h.label).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                        Text("\(h.temp)°").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        Text(h.rain > 0 ? "\(h.rain)%" : " ").font(.system(size: 10)).foregroundStyle(Palette.askSolid)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if w.days.count > 1 {
                HStack(spacing: 10) {
                    ForEach(Array(w.days.dropFirst().enumerated()), id: \.offset) { _, d in
                        HStack(spacing: 6) {
                            Image(systemName: Weather.symbol(d.code)).symbolRenderingMode(.hierarchical).foregroundStyle(Palette.bone).font(.system(size: 13))
                            Text("\(d.name) \(d.high)° / \(d.low)°").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                            if d.rain >= 20 { Text("\(d.rain)%").font(.system(size: 11)).foregroundStyle(Palette.askSolid) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
