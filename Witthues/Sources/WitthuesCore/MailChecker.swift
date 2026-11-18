import Foundation

public struct CheckSummary: Sendable, Equatable {
    public var messages = 0
    public var filed = 0
    public var skipped = 0
    public var duplicates = 0
    public var errors: [String] = []

    public var text: String {
        if messages == 0 { return "Keine neuen Mails" }
        var parts = [messages == 1 ? "1 neue Mail" : "\(messages) neue Mails",
                     filed == 1 ? "1 Rechnung abgelegt" : "\(filed) Rechnungen abgelegt"]
        if skipped > 0 { parts.append(skipped == 1 ? "1 anderes PDF übersprungen" : "\(skipped) andere PDFs übersprungen") }
        if !errors.isEmpty { parts.append(errors.count == 1 ? "1 Fehler" : "\(errors.count) Fehler") }
        return parts.joined(separator: ", ")
    }

    /// The result of reading existing folders.
    public var filesText: String {
        if messages == 0 { return "Keine PDFs gefunden" }
        var parts = [messages == 1 ? "1 PDF gelesen" : "\(messages) PDFs gelesen",
                     filed == 1 ? "1 Rechnung neu erfasst" : "\(filed) Rechnungen neu erfasst"]
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 war schon bekannt" : "\(duplicates) waren schon bekannt") }
        if skipped > 0 { parts.append(skipped == 1 ? "1 keine Rechnung" : "\(skipped) keine Rechnungen") }
        if !errors.isEmpty { parts.append(errors.count == 1 ? "1 Fehler" : "\(errors.count) Fehler") }
        return parts.joined(separator: ", ")
    }

    /// The result of reading past mail, where most invoices may already be filed.
    public var pastText: String {
        if messages == 0 { return "Keine Mails im Zeitraum" }
        var parts = [messages == 1 ? "1 Mail gelesen" : "\(messages) Mails gelesen",
                     filed == 1 ? "1 Rechnung neu abgelegt" : "\(filed) Rechnungen neu abgelegt"]
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 war schon vorhanden" : "\(duplicates) waren schon vorhanden") }
        if skipped > 0 { parts.append(skipped == 1 ? "1 anderes PDF übersprungen" : "\(skipped) andere PDFs übersprungen") }
        if !errors.isEmpty { parts.append(errors.count == 1 ? "1 Fehler" : "\(errors.count) Fehler") }
        return parts.joined(separator: ", ")
    }
}

/// Where a mail check stands: the folder, which mail of how many, the current subject and the results so far.
public struct MailProgress: Sendable, Equatable {
    public var step = ""
    public var folder = ""
    public var current = 0
    public var total = 0
    public var subject = ""
    public var summary = CheckSummary()
    /// What is counted: „Mail“, or „Datei“ when reading folders.
    public var unit = "Mail"

    public init(step: String = "") { self.step = step }

    public var fraction: Double? { total > 0 ? Double(current) / Double(total) : nil }

    /// One line, such as „INBOX: Mail 12 von 240“, or the current step before mails are read.
    public var text: String {
        guard total > 0 else { return step }
        return (folder.isEmpty ? "" : "\(folder): ") + "\(unit) \(current) von \(total)"
    }
}

/// Reads mail that arrived since the last check and files the invoices in it.
public enum MailChecker {
    @MainActor
    public static func check(library: Library, password: String,
                             progress: @MainActor (MailProgress) -> Void = { _ in }) async throws -> CheckSummary {
        let s = library.settings
        guard s.isMailConfigured else { throw IMAPError(message: "Bitte zuerst das Mailkonto in den Einstellungen eintragen") }
        guard s.isFolderConfigured else { throw IMAPError(message: "Bitte zuerst den Hauptordner in den Einstellungen wählen") }
        var p = MailProgress(step: "Verbinde mit \(s.imapHost) …")
        progress(p)
        let client = IMAPClient(host: s.imapHost, port: s.imapPort, useTLS: s.useTLS)
        defer { Task { await client.logout() } }
        try await client.connect(username: s.username, password: password)
        let validity = try await client.select(s.mailbox)
        // A changed UIDVALIDITY means the server renumbered the folder; start over from the date.
        let previous = library.cursor().flatMap { $0.uidValidity == validity ? $0 : nil }
        let uids = try await client.newUIDs(after: previous?.lastUID, since: s.importSince)
        let extractor = Extractor(useAppleIntelligence: s.useAppleIntelligence)
        p.folder = IMAPClient.displayName(s.mailbox)
        p.total = uids.count
        for (n, uid) in uids.enumerated() {
            p.current = n + 1
            if let error = try await read(uid: uid, client: client, library: library, extractor: extractor, into: &p, report: progress) {
                p.summary.errors.append(error)
                // Stop here so this mail is tried again on the next check.
                throw IMAPError(message: p.summary.errors.joined(separator: "\n"))
            }
            library.setCursor(MailboxCursor(uidValidity: validity, lastUID: uid))
        }
        return p.summary
    }

    /// Reads mails from a date range in the chosen folders again, for invoices from before the first check
    /// or from other folders. Invoices already filed are recognized and skipped; the position of the regular
    /// check is not changed. Stops between mails when the task is cancelled; what is filed stays filed.
    @MainActor
    public static func readPast(library: Library, password: String, mailboxes: [String], from: Date, to: Date,
                                stage: Stage = .open, paidDate: Date? = nil,
                                progress: @MainActor (MailProgress) -> Void = { _ in }) async throws -> CheckSummary {
        let s = library.settings
        guard s.isMailConfigured else { throw IMAPError(message: "Bitte zuerst das Mailkonto in den Einstellungen eintragen") }
        guard s.isFolderConfigured else { throw IMAPError(message: "Bitte zuerst den Hauptordner in den Einstellungen wählen") }
        var p = MailProgress(step: "Verbinde mit \(s.imapHost) …")
        progress(p)
        let client = IMAPClient(host: s.imapHost, port: s.imapPort, useTLS: s.useTLS)
        defer { Task { await client.logout() } }
        try await client.connect(username: s.username, password: password)
        let extractor = Extractor(useAppleIntelligence: s.useAppleIntelligence)
        for mailbox in mailboxes {
            p.folder = IMAPClient.displayName(mailbox)
            p.step = "\(p.folder): Mails werden gesucht …"
            p.total = 0
            p.current = 0
            p.subject = ""
            progress(p)
            _ = try await client.select(mailbox)
            let uids = try await client.uids(from: from, to: to)
            p.total = uids.count
            for (n, uid) in uids.enumerated() {
                try Task.checkCancellation()
                p.current = n + 1
                // One unreadable mail should not stop a long import; it is listed in the result instead.
                if let error = try await read(uid: uid, client: client, library: library, extractor: extractor, stage: stage, paidDate: paidDate,
                                              into: &p, report: progress) {
                    p.summary.errors.append(error)
                    progress(p)
                }
            }
        }
        return p.summary
    }

    /// Fetches one mail and files its attachments, reporting progress as it goes; returns a message when filing failed.
    @MainActor
    private static func read(uid: UInt32, client: IMAPClient, library: Library, extractor: Extractor,
                             stage: Stage = .open, paidDate: Date? = nil, into p: inout MailProgress, report: @MainActor (MailProgress) -> Void) async throws -> String? {
        report(p)
        guard let raw = try await client.fetch(uid: uid) else { return nil }
        p.summary.messages += 1
        let mail = MIME.parse(raw)
        p.subject = mail.subject
        report(p)
        do {
            for outcome in try await library.ingest(mail: mail, extractor: extractor, stage: stage, paidDate: paidDate) {
                switch outcome {
                case .filed: p.summary.filed += 1
                case .skipped: p.summary.skipped += 1
                case .duplicate: p.summary.duplicates += 1
                }
            }
            report(p)
            return nil
        } catch {
            return "“\(mail.subject)”: \(error.localizedDescription)"
        }
    }

    /// Logs in and lists folders, for the settings screen's "Test connection" button.
    public static func testConnection(settings s: AppSettings, password: String) async throws -> [String] {
        let client = IMAPClient(host: s.imapHost, port: s.imapPort, useTLS: s.useTLS)
        defer { Task { await client.logout() } }
        try await client.connect(username: s.username, password: password)
        return try await client.listMailboxes()
    }
}
