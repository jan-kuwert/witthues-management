import Foundation

public struct IMAPError: LocalizedError {
    public enum Kind: Sendable { case login, connection, other }
    public var message: String
    public var kind: Kind = .other
    public var errorDescription: String? { message }
}

/// A small IMAP client for what the mail checker needs: log in, select a folder, find new
/// messages by UID and download them without marking them read.
public actor IMAPClient {
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private var tagCounter = 0
    private let timeout: TimeInterval = 60

    public init(host: String, port: Int, useTLS: Bool = true) {
        task = URLSession.shared.streamTask(withHostName: host, port: port)
        if useTLS { task.startSecureConnection() }
        task.resume()
    }

    /// One server response line, with any `{n}` literals it carried.
    struct Line {
        var text: String
        var literals: [Data]
    }

    public func connect(username: String, password: String) async throws {
        let greeting = try await readLogicalLine()
        guard greeting.text.hasPrefix("* OK") || greeting.text.hasPrefix("* PREAUTH") else {
            throw IMAPError(message: "Antwort des Mailservers: \(greeting.text)", kind: .connection)
        }
        do {
            _ = try await command("LOGIN \(quote(username)) \(quote(password))")
        } catch let e as IMAPError {
            throw IMAPError(message: "Anmeldung fehlgeschlagen. Bitte E-Mail-Adresse und Postfach-Passwort prüfen. (\(e.message))", kind: .login)
        }
    }

    /// Selects a folder read-only and returns its UIDVALIDITY.
    public func select(_ mailbox: String) async throws -> UInt32 {
        let lines = try await command("EXAMINE \(quote(mailbox))")
        for line in lines {
            if let r = line.text.range(of: "[UIDVALIDITY ") {
                let digits = line.text[r.upperBound...].prefix { $0.isNumber }
                if let v = UInt32(digits) { return v }
            }
        }
        return 0
    }

    public func listMailboxes() async throws -> [String] {
        let lines = try await command("LIST \"\" \"*\"")
        return lines.compactMap { line in
            guard line.text.hasPrefix("* LIST") else { return nil }
            if let literal = line.literals.last { return String(decoding: literal, as: UTF8.self) }
            let t = line.text
            if t.hasSuffix("\""), let open = t.dropLast().lastIndex(of: "\"") {
                return String(t[t.index(after: open)..<t.index(before: t.endIndex)])
            }
            return t.split(separator: " ").last.map(String.init)
        }
    }

    /// UIDs above `afterUID`, or received on or after `since` when there is no earlier position.
    public func newUIDs(after afterUID: UInt32?, since: Date) async throws -> [UInt32] {
        let criteria: String
        if let afterUID {
            criteria = "UID \(afterUID + 1):*"
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "d-MMM-yyyy"
            criteria = "SINCE \(f.string(from: since))"
        }
        let lines = try await command("UID SEARCH \(criteria)")
        let uids = lines.filter { $0.text.hasPrefix("* SEARCH") }
            .flatMap { $0.text.dropFirst(8).split(separator: " ").compactMap { UInt32($0) } }
        // "n:*" always matches the newest message, even when it is older than n.
        return uids.filter { afterUID == nil || $0 > afterUID! }.sorted()
    }

    /// UIDs of mails received from the start of `from` to the end of `to`, for reading past mail again.
    public func uids(from: Date, to: Date) async throws -> [UInt32] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy"
        let dayAfter = Calendar.current.date(byAdding: .day, value: 1, to: max(from, to))!
        let lines = try await command("UID SEARCH SINCE \(f.string(from: min(from, to))) BEFORE \(f.string(from: dayAfter))")
        return lines.filter { $0.text.hasPrefix("* SEARCH") }
            .flatMap { $0.text.dropFirst(8).split(separator: " ").compactMap { UInt32($0) } }
            .sorted()
    }

    /// A folder name as people read it: IMAP sends „Entwürfe“ as „Entw&APw-rfe“ (modified UTF-7).
    public nonisolated static func displayName(_ mailbox: String) -> String {
        var out = ""
        var rest = Substring(mailbox)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            guard let dash = rest[afterAmp...].firstIndex(of: "-") else { return out + rest[amp...] }
            let encoded = rest[afterAmp..<dash]
            if encoded.isEmpty {
                out += "&"
            } else {
                var b64 = encoded.replacingOccurrences(of: ",", with: "/")
                b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
                guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf16BigEndian) else {
                    return mailbox
                }
                out += text
            }
            rest = rest[rest.index(after: dash)...]
        }
        return out + rest
    }

    /// The full message, without setting the \Seen flag.
    public func fetch(uid: UInt32) async throws -> Data? {
        let lines = try await command("UID FETCH \(uid) (BODY.PEEK[])")
        return lines.first { $0.text.contains("FETCH") && !$0.literals.isEmpty }?.literals.first
    }

    public func logout() async {
        _ = try? await command("LOGOUT")
        task.cancel()
    }

    // MARK: - Protocol

    private func command(_ text: String) async throws -> [Line] {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        try await task.write(Data("\(tag) \(text)\r\n".utf8), timeout: timeout)
        var untagged: [Line] = []
        while true {
            let line = try await readLogicalLine()
            if line.text.hasPrefix(tag + " ") {
                let status = line.text.dropFirst(tag.count + 1)
                if status.hasPrefix("OK") { return untagged }
                throw IMAPError(message: String(status))
            }
            untagged.append(line)
        }
    }

    private func readLogicalLine() async throws -> Line {
        var line = Line(text: "", literals: [])
        while true {
            let raw = try await readRawLine()
            line.text += raw
            // A line ending in {n} is followed by n bytes of data, then the rest of the line.
            guard raw.hasSuffix("}"), let open = raw.lastIndex(of: "{"),
                  let n = Int(raw[raw.index(after: open)..<raw.index(before: raw.endIndex)].trimmingCharacters(in: CharacterSet(charactersIn: "+"))) else {
                return line
            }
            line.literals.append(try await readBytes(n))
        }
    }

    private func readRawLine() async throws -> String {
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var end = nl
                if end > buffer.startIndex, buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            try await fill()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let out = Data(buffer.prefix(n))
        buffer.removeFirst(n)
        return out
    }

    private func fill() async throws {
        let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: 1 << 20, timeout: timeout)
        if let data, !data.isEmpty { buffer.append(data); return }
        if eof { throw IMAPError(message: "Der Mailserver hat die Verbindung getrennt", kind: .connection) }
    }

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
