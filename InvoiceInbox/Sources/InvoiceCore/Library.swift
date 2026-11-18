import CryptoKit
import Foundation
import Observation

/// Everything the app remembers: filed invoices, skipped attachments and how far each mailbox was read.
@MainActor @Observable
public final class Library {
    public private(set) var records: [InvoiceRecord] = []
    public private(set) var skipped: [SkippedAttachment] = []
    public var settings: AppSettings { didSet { if settings != oldValue { saveSettings() } } }
    private var cursors: [String: MailboxCursor] = [:]

    public let directory: URL

    private struct Stored: Codable {
        var records: [InvoiceRecord]
        var skipped: [SkippedAttachment]
        var cursors: [String: MailboxCursor]
    }

    /// `INVOICE_INBOX_HOME` overrides the data folder, for tests and demos.
    public nonisolated static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["INVOICE_INBOX_HOME"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InvoiceInbox", isDirectory: true)
    }

    public init(directory: URL = Library.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("Skipped"), withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        settings = (try? decoder.decode(AppSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))) ?? AppSettings()
        if let stored = try? decoder.decode(Stored.self, from: Data(contentsOf: directory.appendingPathComponent("library.json"))) {
            records = stored.records
            skipped = stored.skipped
            cursors = stored.cursors
        }
        refreshFiles()
    }

    public var organizer: FileOrganizer { FileOrganizer(settings: settings) }

    // MARK: - Importing

    public enum Outcome: Equatable {
        case filed(InvoiceRecord)
        case skipped(SkippedAttachment)
        case duplicate
    }

    /// Files one mail's attachments: invoices go to the unpaid folder, other PDFs to the skipped list,
    /// and other file types are ignored.
    public func ingest(mail: ParsedMail, extractor: Extractor) async throws -> [Outcome] {
        let origin = MailOrigin(subject: mail.subject, from: mail.from, date: mail.date, messageID: mail.messageID)
        let xmls = mail.attachments.filter { $0.fileName.lowercased().hasSuffix(".xml") }
            .compactMap { a in EInvoice.parse(xml: a.data).map { (a, $0) } }
        let pdfs = mail.attachments.filter { $0.fileName.lowercased().hasSuffix(".pdf") || $0.mimeType == "application/pdf" }
        var outcomes: [Outcome] = []
        for pdf in pdfs {
            var o = origin
            o.attachmentName = pdf.fileName
            // A separate XRechnung in the same mail is the authoritative data for a single PDF.
            let companionXML = pdfs.count == 1 ? xmls.first : nil
            outcomes.append(try await ingest(data: pdf.data, fileName: pdf.fileName, origin: o, extractor: extractor, companionXML: companionXML))
        }
        if pdfs.isEmpty {
            for (xml, _) in xmls {
                var o = origin
                o.attachmentName = xml.fileName
                outcomes.append(try await ingest(data: xml.data, fileName: xml.fileName, origin: o, extractor: extractor))
            }
        }
        return outcomes
    }

    public func ingest(data: Data, fileName: String, origin: MailOrigin, extractor: Extractor,
                       companionXML: (MailAttachment, InvoiceFields)? = nil, force: Bool = false) async throws -> Outcome {
        let hash = Self.sha256(data)
        if records.contains(where: { $0.sha256 == hash }) { return .duplicate }
        if !force, skipped.contains(where: { $0.storedPath.hasSuffix(hash + "." + Self.ext(fileName)) }) { return .duplicate }

        var x = await extractor.extract(data: data, fileName: fileName, subject: origin.subject, sender: origin.from)
        if let (_, fields) = companionXML, x.source != .eInvoiceXML {
            x = Extraction(isInvoice: true, notInvoiceReason: "", fields: fields, source: .eInvoiceXML,
                           reviewReasons: Extractor.check(fields), xmlOnly: false)
        }
        if !x.isInvoice && !force {
            let stored = directory.appendingPathComponent("Skipped").appendingPathComponent(hash + "." + Self.ext(fileName))
            try data.write(to: stored, options: .atomic)
            let s = SkippedAttachment(origin: origin, reason: x.notInvoiceReason, storedPath: stored.path)
            skipped.insert(s, at: 0)
            save()
            return .skipped(s)
        }
        guard settings.isFolderConfigured else { throw IMAPError(message: "Choose the main folder in Settings first") }
        let url = try organizer.save(data, ext: Self.ext(fileName), fields: x.fields)
        if let (xml, _) = companionXML {
            try? xml.data.write(to: url.deletingPathExtension().appendingPathExtension("xml"), options: .withoutOverwriting)
        }
        let record = InvoiceRecord(fields: x.fields, source: x.source, reviewReasons: x.reviewReasons,
                                   filePath: url.path, origin: origin, sha256: hash)
        records.insert(record, at: 0)
        save()
        return .filed(record)
    }

    /// Files a skipped attachment as an invoice after all.
    public func importSkipped(_ id: SkippedAttachment.ID, extractor: Extractor) async throws {
        guard let s = skipped.first(where: { $0.id == id }) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: s.storedPath))
        let outcome = try await ingest(data: data, fileName: s.origin.attachmentName, origin: s.origin, extractor: extractor, force: true)
        if case .filed = outcome {
            skipped.removeAll { $0.id == id }
            try? FileManager.default.removeItem(atPath: s.storedPath)
            save()
        }
    }

    public func deleteSkipped(_ id: SkippedAttachment.ID) {
        guard let s = skipped.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(atPath: s.storedPath)
        skipped.removeAll { $0.id == id }
        save()
    }

    // MARK: - Changing invoices

    /// Saves edited fields and paid status, renaming and moving the file to match.
    public func update(_ id: InvoiceRecord.ID, fields: InvoiceFields, status: InvoiceStatus, paidDate: Date?) throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        var r = records[i]
        let newPaid = status == .paid ? (paidDate ?? Date()) : nil
        let url = try organizer.place(r.fileURL, fields: fields, status: status, paidDate: newPaid)
        if r.fields != fields {
            r.source = .manual
            r.reviewReasons = Extractor.check(fields)
        }
        r.fields = fields
        r.status = status
        r.paidDate = newPaid
        r.filePath = url.path
        r.fileMissing = false
        records[i] = r
        save()
    }

    public func setPaid(_ id: InvoiceRecord.ID, _ paid: Bool, on date: Date = Date()) throws {
        guard let r = records.first(where: { $0.id == id }) else { return }
        try update(id, fields: r.fields, status: paid ? .paid : .unpaid, paidDate: paid ? date : nil)
    }

    public func markReviewed(_ id: InvoiceRecord.ID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].reviewReasons = []
        save()
    }

    /// Forgets an invoice. The file itself stays where it is.
    public func remove(_ id: InvoiceRecord.ID) {
        records.removeAll { $0.id == id }
        save()
    }

    /// Notices files that were moved or deleted outside the app, e.g. in Finder or OneDrive.
    public func refreshFiles() {
        var changed = false
        for i in records.indices {
            let missing = !FileManager.default.fileExists(atPath: records[i].filePath)
            if records[i].fileMissing != missing { records[i].fileMissing = missing; changed = true }
        }
        if changed { save() }
    }

    // MARK: - Mailbox positions

    func cursorKey() -> String { "\(settings.username)@\(settings.imapHost)/\(settings.mailbox)" }
    func cursor() -> MailboxCursor? { cursors[cursorKey()] }
    func setCursor(_ c: MailboxCursor) { cursors[cursorKey()] = c; save() }

    /// Forgets how far the mailbox was read, so the next check starts again from the "import since" date.
    public func resetMailboxPosition() {
        cursors[cursorKey()] = nil
        save()
    }

    // MARK: - Storage

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Stored(records: records, skipped: skipped, cursors: cursors)) {
            try? data.write(to: directory.appendingPathComponent("library.json"), options: .atomic)
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func ext(_ fileName: String) -> String {
        let e = (fileName as NSString).pathExtension.lowercased()
        return e.isEmpty ? "pdf" : e
    }
}
