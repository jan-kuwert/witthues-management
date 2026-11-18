import Foundation

public struct CheckSummary: Sendable, Equatable {
    public var messages = 0
    public var filed = 0
    public var skipped = 0
    public var duplicates = 0
    public var errors: [String] = []

    public var text: String {
        if messages == 0 { return "No new mail" }
        var parts = ["\(messages) new mail\(messages == 1 ? "" : "s")", "\(filed) invoice\(filed == 1 ? "" : "s") filed"]
        if skipped > 0 { parts.append("\(skipped) other PDF\(skipped == 1 ? "" : "s") skipped") }
        if !errors.isEmpty { parts.append("\(errors.count) error\(errors.count == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

/// Reads mail that arrived since the last check and files the invoices in it.
public enum MailChecker {
    @MainActor
    public static func check(library: Library, password: String, progress: @MainActor (String) -> Void = { _ in }) async throws -> CheckSummary {
        let s = library.settings
        guard s.isMailConfigured else { throw IMAPError(message: "Enter the mail account in Settings first") }
        guard s.isFolderConfigured else { throw IMAPError(message: "Choose the main folder in Settings first") }
        progress("Connecting to \(s.imapHost)…")
        let client = IMAPClient(host: s.imapHost, port: s.imapPort, useTLS: s.useTLS)
        defer { Task { await client.logout() } }
        try await client.connect(username: s.username, password: password)
        let validity = try await client.select(s.mailbox)
        // A changed UIDVALIDITY means the server renumbered the folder; start over from the date.
        let previous = library.cursor().flatMap { $0.uidValidity == validity ? $0 : nil }
        let uids = try await client.newUIDs(after: previous?.lastUID, since: s.importSince)
        var summary = CheckSummary()
        let extractor = Extractor(useAppleIntelligence: s.useAppleIntelligence)
        for (n, uid) in uids.enumerated() {
            progress("Reading mail \(n + 1) of \(uids.count)…")
            if let raw = try await client.fetch(uid: uid) {
                summary.messages += 1
                let mail = MIME.parse(raw)
                do {
                    for outcome in try await library.ingest(mail: mail, extractor: extractor) {
                        switch outcome {
                        case .filed: summary.filed += 1
                        case .skipped: summary.skipped += 1
                        case .duplicate: summary.duplicates += 1
                        }
                    }
                } catch {
                    summary.errors.append("“\(mail.subject)”: \(error.localizedDescription)")
                    // Stop here so this mail is tried again on the next check.
                    throw IMAPError(message: summary.errors.joined(separator: "\n"))
                }
            }
            library.setCursor(MailboxCursor(uidValidity: validity, lastUID: uid))
        }
        return summary
    }

    /// Logs in and lists folders, for the settings screen's "Test connection" button.
    public static func testConnection(settings s: AppSettings, password: String) async throws -> [String] {
        let client = IMAPClient(host: s.imapHost, port: s.imapPort, useTLS: s.useTLS)
        defer { Task { await client.logout() } }
        try await client.connect(username: s.username, password: password)
        return try await client.listMailboxes()
    }
}
