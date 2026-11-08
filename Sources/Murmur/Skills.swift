import Foundation
import Security
import SwiftUI

/// What a homelab skill hands back to Ask: a card, facts for the model, and an answer computed from the data.
struct SkillResult {
    var card: AnyView
    var facts: String
    var answer: String
    /// Show `answer` as-is and skip the model (errors, confirmations, links).
    var final = false

    static func note(_ text: String) -> SkillResult {
        SkillResult(card: AnyView(SkillNote(text: text)), facts: text, answer: text, final: true)
    }
}

/// Homelab integrations (photos, media requests, server stats). Each returns a job when it recognises the question.
enum Skills {
    typealias Job = () async -> SkillResult
    /// Tried in order; the first skill that recognises the question wins.
    static var matchers: [(String) -> Job?] = []

    static func match(_ question: String) -> Job? {
        guard !Prefs.homelabHost.isEmpty else { return nil }
        for m in matchers { if let job = m(question) { return job } }
        return nil
    }

    static func systemPrompt(_ r: SkillResult) -> String {
        """
        You are a fast assistant the user talks to by voice. Their question was transcribed from speech. Answer in 1-2 short \
        sentences using ONLY the data below; quote numbers exactly and never invent any. The user already sees a card with \
        the details, so give just the takeaway. If the data doesn't answer the question, say so. No Markdown.

        Data (just fetched from the user's homelab):
        \(r.facts)
        """
    }

    /// http://<homelab host>:<port>, from the host set in Settings (e.g. a Tailscale MagicDNS name).
    /// Only a bare hostname or IP is accepted, so a typo can't send keys somewhere else.
    static func base(_ port: Int) -> URL? {
        let h = Prefs.homelabHost
        guard h.range(of: #"^[A-Za-z0-9.-]{1,253}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "http://\(h):\(port)")
    }

    static let unreachable = "Homelab not reachable — is Tailscale on?"

    enum Failure: Error { case unreachable, http(Int, String), missingKey(String) }

    /// One JSON request with a hard deadline. Throws `Failure`.
    static func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Any? = nil,
                     timeout: TimeInterval = 6) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw Failure.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw Failure.http(code, msg ?? HTTPURLResponse.localizedString(forStatusCode: code))
        }
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    /// Turns any thrown error into a user-facing note.
    static func failed(_ error: Error, service: String) -> SkillResult {
        switch error {
        case Failure.missingKey(let k): .note("\(service) isn't set up — add the \(k) in Settings → Homelab.")
        case Failure.http(let code, let m): .note("\(service) error \(code): \(m)")
        default: .note(unreachable)
        }
    }
}

/// Service credentials live in the login Keychain (service "murmur.homelab"), never in preferences or source.
enum Keychain {
    static let service = "murmur.homelab"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Saves (or, for an empty value, removes) a key. Updates in place so a failed write never loses the old key.
    @discardableResult static func set(_ account: String, _ value: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        guard !value.isEmpty else { return [errSecSuccess, errSecItemNotFound].contains(SecItemDelete(q as CFDictionary)) }
        let data = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(q as CFDictionary, data as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(q.merging(data) { $1 }.merging([kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    /// The value, or throws so the skill can say which key is missing.
    static func require(_ account: String) throws -> String {
        guard let v = get(account), !v.isEmpty else { throw Skills.Failure.missingKey(account) }
        return v
    }
}

struct SkillNote: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The Keychain accounts the homelab skills read, with their Settings labels.
enum HomelabKeys {
    static let all: [(account: String, label: String)] = [
        ("immich", "Immich API key"), ("seerr", "Seerr API key"), ("beszel-user", "Beszel email"), ("beszel-pass", "Beszel password"),
    ]
}
