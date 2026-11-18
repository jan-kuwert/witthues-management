import Foundation

public struct MailAttachment: Sendable {
    public var fileName: String
    public var mimeType: String
    public var data: Data
}

public struct ParsedMail: Sendable {
    public var subject = ""
    public var from = ""
    public var messageID = ""
    public var date: Date?
    public var attachments: [MailAttachment] = []
}

/// Minimal MIME reader: headers, multipart bodies, base64 and quoted-printable, RFC 2047 encoded
/// headers and RFC 2231 file names. Forwarded mails (message/rfc822) are read too.
public enum MIME {
    public static func parse(_ raw: Data) -> ParsedMail {
        let (headers, _) = splitHeaders(raw)
        var mail = ParsedMail()
        mail.subject = decodeWords(headers["subject"] ?? "")
        mail.from = decodeWords(headers["from"] ?? "")
        mail.messageID = (headers["message-id"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
        mail.date = parseDate(headers["date"] ?? "")
        collect(raw, into: &mail.attachments, depth: 0)
        return mail
    }

    private static func collect(_ part: Data, into out: inout [MailAttachment], depth: Int) {
        guard depth < 12 else { return }
        let (headers, body) = splitHeaders(part)
        let (type, typeParams) = parseHeaderValue(headers["content-type"] ?? "text/plain")
        let (_, dispParams) = parseHeaderValue(headers["content-disposition"] ?? "")
        if type.hasPrefix("multipart/"), let boundary = typeParams["boundary"] {
            for sub in splitMultipart(body, boundary: boundary) { collect(sub, into: &out, depth: depth + 1) }
            return
        }
        let decoded = decode(body, encoding: (headers["content-transfer-encoding"] ?? "").lowercased())
        if type == "message/rfc822" {
            collect(decoded, into: &out, depth: depth + 1)
            return
        }
        var name = dispParams["filename"] ?? typeParams["name"] ?? ""
        name = decodeWords(name)
        if name.isEmpty, type == "application/pdf" { name = "attachment.pdf" }
        guard !name.isEmpty else { return }
        out.append(MailAttachment(fileName: name, mimeType: type, data: decoded))
    }

    static func splitHeaders(_ data: Data) -> ([String: String], Data) {
        let crlf = Data("\r\n\r\n".utf8), lf = Data("\n\n".utf8)
        let r1 = data.range(of: crlf), r2 = data.range(of: lf)
        let sep: Range<Data.Index>?
        switch (r1, r2) {
        case let (a?, b?): sep = a.lowerBound <= b.lowerBound ? a : b
        case let (a?, nil): sep = a
        case let (nil, b?): sep = b
        default: sep = nil
        }
        let headerData = sep.map { data[data.startIndex..<$0.lowerBound] } ?? data
        let body = sep.map { data[$0.upperBound...] } ?? Data()
        let text = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .isoLatin1) ?? ""
        var headers: [String: String] = [:]
        var current: (String, String)?
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                current?.1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                if let (k, v) = current, headers[k] == nil { headers[k] = v }
                current = (line[..<colon].lowercased().trimmingCharacters(in: .whitespaces),
                           line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        if let (k, v) = current, headers[k] == nil { headers[k] = v }
        return (headers, Data(body))
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var positions: [Range<Data.Index>] = []
        var start = body.startIndex
        while let r = body.range(of: delimiter, in: start..<body.endIndex) {
            // A delimiter must start a line.
            if r.lowerBound == body.startIndex || body[r.lowerBound - 1] == UInt8(ascii: "\n") { positions.append(r) }
            start = r.upperBound
        }
        for (i, r) in positions.enumerated() {
            let afterDelimiter = body[r.upperBound...]
            if afterDelimiter.starts(with: Data("--".utf8)) { break }
            guard let lineEnd = afterDelimiter.firstIndex(of: UInt8(ascii: "\n")) else { break }
            let partStart = lineEnd + 1
            var partEnd = i + 1 < positions.count ? positions[i + 1].lowerBound : body.endIndex
            if partEnd > partStart, body[partEnd - 1] == UInt8(ascii: "\n") { partEnd -= 1 }
            if partEnd > partStart, body[partEnd - 1] == UInt8(ascii: "\r") { partEnd -= 1 }
            if partEnd >= partStart { parts.append(Data(body[partStart..<partEnd])) }
        }
        return parts
    }

    static func decode(_ body: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return quotedPrintable(body, underscoreIsSpace: false)
        default:
            return body
        }
    }

    static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 2 < bytes.count || i + 2 == bytes.count {
                    if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\r") { i += 3; continue }
                    if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\n") { i += 2; continue }
                    if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                        out.append(h << 4 | l); i += 3; continue
                    }
                }
                out.append(b)
            } else if underscoreIsSpace, b == UInt8(ascii: "_") {
                out.append(UInt8(ascii: " "))
            } else {
                out.append(b)
            }
            i += 1
        }
        return out
    }

    /// `type/subtype; a=b; c="d"` → ("type/subtype", [a: b, c: d]), including RFC 2231 `name*0*=` parts.
    static func parseHeaderValue(_ value: String) -> (String, [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for ch in value {
            if ch == "\"" { inQuotes.toggle(); current.append(ch) } else if ch == ";", !inQuotes { pieces.append(current); current = "" } else { current.append(ch) }
        }
        pieces.append(current)
        let main = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        var extended: [String: [(Int, String, Bool)]] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            if let star = key.firstIndex(of: "*") {
                let base = String(key[..<star])
                let rest = key[key.index(after: star)...]
                let encoded = rest.hasSuffix("*") || rest.isEmpty
                let index = Int(rest.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
                extended[base, default: []].append((index, val, encoded))
                continue
            }
            key = key.trimmingCharacters(in: .whitespaces)
            params[key] = val
        }
        for (base, segments) in extended {
            var charset = "utf-8"
            var bytes = Data()
            for (n, (_, raw, encoded)) in segments.sorted(by: { $0.0 < $1.0 }).enumerated() {
                var s = raw
                if encoded, n == 0, let q1 = s.firstIndex(of: "'"), let q2 = s[s.index(after: q1)...].firstIndex(of: "'") {
                    charset = String(s[..<q1]).isEmpty ? "utf-8" : String(s[..<q1])
                    s = String(s[s.index(after: q2)...])
                }
                bytes.append(encoded ? percentDecode(s) : Data(s.utf8))
            }
            params[base] = String(data: bytes, encoding: encoding(charset)) ?? String(decoding: bytes, as: UTF8.self)
        }
        return (main, params)
    }

    static func percentDecode(_ s: String) -> Data {
        var out = Data()
        var it = Array(s.utf8)[...]
        while let b = it.popFirst() {
            if b == UInt8(ascii: "%"), it.count >= 2, let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) {
                out.append(v); it = it.dropFirst(2)
            } else { out.append(b) }
        }
        return out
    }

    static func encoding(_ charset: String) -> String.Encoding {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cf != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// RFC 2047: `=?UTF-8?B?...?=` and `=?iso-8859-1?Q?...?=`, joining adjacent encoded words.
    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let re = try! NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=")
        var out = ""
        var last = s.startIndex
        var previousWasEncoded = false
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s), let cs = Range(m.range(at: 1), in: s),
                  let kind = Range(m.range(at: 2), in: s), let text = Range(m.range(at: 3), in: s) else { continue }
            let between = String(s[last..<r.lowerBound])
            if !(previousWasEncoded && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { out += between }
            let charset = String(s[cs]).split(separator: "*").first.map(String.init) ?? "utf-8"
            let payload = Data(s[text].utf8)
            let bytes = s[kind].lowercased() == "b"
                ? (Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data())
                : quotedPrintable(payload, underscoreIsSpace: true)
            out += String(data: bytes, encoding: encoding(charset)) ?? String(decoding: bytes, as: UTF8.self)
            last = r.upperBound
            previousWasEncoded = true
        }
        out += s[last...]
        return out
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let cleaned = s.replacingOccurrences(of: "\\s*\\(.*\\)$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = format
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }
}
