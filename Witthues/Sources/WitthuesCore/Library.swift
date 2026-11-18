import CryptoKit
import Foundation
import ImageIO
import Observation

/// Everything the app remembers: filed invoices, skipped attachments and how far each mailbox was read.
@MainActor @Observable
public final class Library {
    public private(set) var records: [InvoiceRecord] = []
    public private(set) var skipped: [SkippedAttachment] = []
    public var settings: AppSettings { didSet { if settings != oldValue { saveSettings() } } }
    /// Saved archive views, kept in views.json.
    public var views: [SavedView] { didSet { if views != oldValue { saveViews() } } }
    private var cursors: [String: MailboxCursor] = [:]

    public let directory: URL

    private struct Stored: Codable {
        var records: [InvoiceRecord]
        var skipped: [SkippedAttachment]
        var cursors: [String: MailboxCursor]
    }

    /// `WITTHUES_HOME` overrides the data folder, for tests and demos.
    public nonisolated static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["WITTHUES_HOME"] { return URL(fileURLWithPath: custom) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Witthues", isDirectory: true)
    }

    public init(directory: URL = Library.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("Skipped"), withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        var loaded = (try? decoder.decode(AppSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))) ?? AppSettings()
        loaded.migrateTemplates()
        settings = loaded
        views = (try? decoder.decode([SavedView].self, from: Data(contentsOf: directory.appendingPathComponent("views.json")))) ?? []
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
        let body = mail.body
        let origin = MailOrigin(subject: mail.subject, from: mail.from, date: mail.date, messageID: mail.messageID,
                                body: body.isEmpty ? nil : body)
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
                       companionXML: (MailAttachment, InvoiceFields)? = nil, force: Bool = false,
                       sourceHash: String? = nil) async throws -> Outcome {
        // A photo turned into a PDF is recognised by the photo, since each conversion gives a new PDF.
        let hash = sourceHash ?? Self.sha256(data)
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
        guard settings.isFolderConfigured else { throw IMAPError(message: "Bitte zuerst den Hauptordner in den Einstellungen wählen") }
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

    // MARK: - Existing folders

    public enum ExistingFile: Sendable, Equatable { case added, known, notInvoice }

    /// Adds an invoice PDF that already lies in a folder, without moving or renaming it, so invoices filed
    /// before the app count in the statistics. Files inside the unpaid folder count as open, all others as paid
    /// (without a payment date, which the file does not tell).
    public func indexExisting(_ url: URL, extractor: Extractor) async throws -> ExistingFile {
        let path = url.standardizedFileURL.path
        if records.contains(where: { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path == path }) { return .known }
        let data = try Data(contentsOf: url)
        let hash = Self.sha256(data)
        if records.contains(where: { $0.sha256 == hash }) { return .known }
        let x = await extractor.extract(data: data, fileName: url.lastPathComponent, subject: "", sender: "")
        guard x.isInvoice else { return .notInvoice }
        let unpaid = organizer.folder(for: x.fields, status: .unpaid, paidDate: nil).standardizedFileURL.path
        let record = InvoiceRecord(fields: x.fields, source: x.source, reviewReasons: x.reviewReasons,
                                   status: path.hasPrefix(unpaid + "/") ? .unpaid : .paid, filePath: path,
                                   origin: MailOrigin(subject: "Aus vorhandenem Ordner", attachmentName: url.lastPathComponent),
                                   sha256: hash)
        records.insert(record, at: 0)
        save()
        return .added
    }

    /// Reads every PDF in the folders and their subfolders with `indexExisting`. Stops between files when the
    /// task is cancelled; what is added stays added.
    public func indexFolders(_ folders: [URL], extractor: Extractor,
                             progress: @MainActor (MailProgress) -> Void = { _ in }) async throws -> CheckSummary {
        var p = MailProgress(step: "Dateien werden gesucht …")
        p.unit = "Datei"
        progress(p)
        let files = Self.pdfs(in: folders)
        p.total = files.count
        for (n, url) in files.enumerated() {
            try Task.checkCancellation()
            p.current = n + 1
            p.folder = url.deletingLastPathComponent().lastPathComponent
            p.subject = url.lastPathComponent
            progress(p)
            p.summary.messages += 1
            do {
                switch try await indexExisting(url, extractor: extractor) {
                case .added: p.summary.filed += 1
                case .known: p.summary.duplicates += 1
                case .notInvoice: p.summary.skipped += 1
                }
            } catch {
                p.summary.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progress(p)
        }
        return p.summary
    }

    /// PDFs in the folders and all subfolders, each once, sorted by path.
    nonisolated static func pdfs(in folders: [URL]) -> [URL] {
        var found = Set<URL>()
        for folder in folders {
            guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e where url.pathExtension.lowercased() == "pdf" { found.insert(url.standardizedFileURL) }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// File types a paid invoice can be imported from: PDFs, e-invoice XML and photos or scans.
    public static let importableExtensions: Set<String> = ["pdf", "xml", "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    /// Files an invoice the user says is already paid, straight into the archive folder.
    /// Photos and scans are saved as a one-page PDF. Returns nil when the same file was imported before.
    public func ingestPaid(data: Data, fileName: String, paidOn date: Date, origin: MailOrigin, extractor: Extractor) async throws -> InvoiceRecord? {
        let hash = Self.sha256(data)
        var data = data
        var name = fileName
        if !["pdf", "xml"].contains(Self.ext(fileName)) {
            guard let pdf = Self.pdf(fromImage: data) else { throw IMAPError(message: "\(fileName) ist kein lesbares Bild") }
            data = pdf
            name = (fileName as NSString).deletingPathExtension + ".pdf"
        }
        // The user says it is an invoice, so it is filed even if the checks would skip it.
        guard case .filed(let record) = try await ingest(data: data, fileName: name, origin: origin, extractor: extractor, force: true,
                                                     sourceHash: hash)
        else { return nil }
        // Without an invoice date the archive folder would be "YYYY-MM"; use the payment date and ask for a check.
        if record.fields.invoiceDate == nil, let i = records.firstIndex(where: { $0.id == record.id }) {
            records[i].fields.invoiceDate = Calendar.current.startOfDay(for: date)
            records[i].reviewReasons.append("Kein Rechnungsdatum gefunden, Zahlungsdatum verwendet")
        }
        // Added by hand as paid, typically a receipt already on paper: it goes straight to the archive.
        try setPaid(record.id, true, on: date)
        try archive([record.id])
        return records.first { $0.id == record.id }
    }

    /// A photo as a one-page PDF, A4 wide, upright, at most 3000 pixels on the long side.
    static func pdf(fromImage data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 3000,
              ] as CFDictionary)
        else { return nil }
        let width = 595.0
        var box = CGRect(x: 0, y: 0, width: width, height: width * Double(image.height) / Double(image.width))
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return out as Data
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

    /// Saves edited fields and paid status, renaming the file to match. A name the user typed is kept.
    public func update(_ id: InvoiceRecord.ID, fields: InvoiceFields, status: InvoiceStatus, paidDate: Date?) throws {
        guard let r = records.first(where: { $0.id == id }) else { return }
        try update(id, fields: fields, status: status, paidDate: paidDate, name: r.customName)
    }

    /// Saves fields and status with the file name (without extension) the user typed. nil, or the name the
    /// template would give, follows the template. A paid invoice stays in the unpaid folder until it is archived
    /// (`archive`, or it already was); open invoices always go to the unpaid folder.
    public func update(_ id: InvoiceRecord.ID, fields: InvoiceFields, status: InvoiceStatus, paidDate: Date?, name: String?,
                       archive: Bool = false) throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        var r = records[i]
        let newPaid = status == .paid ? (paidDate ?? r.paidDate ?? Date()) : nil
        let o = organizer
        let cleanName = name.map(FileOrganizer.cleanName).flatMap { $0.isEmpty || $0 == o.baseName(for: fields, paidDate: newPaid) ? nil : $0 }
        let inArchive = status == .paid && (archive || isArchived(r))
        let url = try o.place(r.fileURL, fields: fields, status: inArchive ? .paid : .unpaid, paidDate: newPaid, name: cleanName)
        if r.fields != fields {
            r.source = .manual
            r.reviewReasons = Extractor.check(fields)
        }
        r.fields = fields
        r.status = status
        r.paidDate = newPaid
        r.filePath = url.path
        r.fileMissing = false
        r.customName = cleanName
        records[i] = r
        save()
    }

    /// Marks an invoice paid or open. Paying does not move the file; `archive` does that, when the user says so.
    public func setPaid(_ id: InvoiceRecord.ID, _ paid: Bool, on date: Date = Date()) throws {
        guard let r = records.first(where: { $0.id == id }) else { return }
        try update(id, fields: r.fields, status: paid ? .paid : .unpaid, paidDate: paid ? date : nil)
    }

    /// A paid invoice whose file has left the unpaid folder, normally into the archive folder.
    public func isArchived(_ r: InvoiceRecord) -> Bool {
        guard r.status == .paid else { return false }
        let unpaid = organizer.folder(for: r.fields, status: .unpaid, paidDate: nil).standardizedFileURL.path
        return r.fileURL.deletingLastPathComponent().standardizedFileURL.path != unpaid
    }

    /// Moves paid invoices into their archive folder. Open and already archived ones are left alone.
    public func archive(_ ids: [InvoiceRecord.ID]) throws {
        for id in ids {
            guard let r = records.first(where: { $0.id == id }), r.status == .paid, !isArchived(r) else { continue }
            try update(id, fields: r.fields, status: .paid, paidDate: r.paidDate, name: r.customName, archive: true)
        }
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

    private func saveViews() {
        if let data = try? JSONEncoder().encode(views) {
            try? data.write(to: directory.appendingPathComponent("views.json"), options: .atomic)
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
