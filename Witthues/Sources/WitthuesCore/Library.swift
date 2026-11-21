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
    /// Known suppliers with the names the user wants, kept in suppliers.json.
    public var suppliers: [Supplier] = [] { didSet { if suppliers != oldValue { saveSuppliers() } } }
    private var cursors: [String: MailboxCursor] = [:]
    /// Files in the folders that were read and are not invoices (or copies of known ones), so they don't
    /// show up as unread again.
    private var ignoredFiles: Set<String> = []

    public let directory: URL

    private struct Stored: Codable {
        var records: [InvoiceRecord]
        var skipped: [SkippedAttachment]
        var cursors: [String: MailboxCursor]
        var ignoredFiles: Set<String>?
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
            ignoredFiles = stored.ignoredFiles ?? []
        }
        // Before stages existed, a paid invoice counted as archived once its file had left the unpaid folder.
        var migrated = false
        for i in records.indices where records[i].archived == nil {
            let r = records[i]
            let unpaid = organizer.folder(for: r.fields, stage: .open, paidDate: nil).standardizedFileURL.path
            records[i].archived = r.status == .paid && r.fileURL.deletingLastPathComponent().standardizedFileURL.path != unpaid
            migrated = true
        }
        if migrated { save() }
        if let list = try? decoder.decode([Supplier].self, from: Data(contentsOf: directory.appendingPathComponent("suppliers.json"))) {
            suppliers = list
        } else {
            // First start with suppliers: the companies of the invoices filed so far.
            for r in records.sorted(by: { $0.importedAt < $1.importedAt }) { register(r.fields.seller) }
            saveSuppliers()
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

    /// Files one mail's attachments: invoices go to the folder of the stage (new mail: the unpaid folder),
    /// other PDFs to the skipped list, and other file types are ignored.
    public func ingest(mail: ParsedMail, extractor: Extractor, stage: Stage = .open, paidDate: Date? = nil) async throws -> [Outcome] {
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
            outcomes.append(try await ingest(data: pdf.data, fileName: pdf.fileName, origin: o, extractor: extractor, companionXML: companionXML,
                                             stage: stage, paidDate: paidDate))
        }
        if pdfs.isEmpty {
            for (xml, _) in xmls {
                var o = origin
                o.attachmentName = xml.fileName
                outcomes.append(try await ingest(data: xml.data, fileName: xml.fileName, origin: o, extractor: extractor,
                                                 stage: stage, paidDate: paidDate))
            }
        }
        return outcomes
    }

    public func ingest(data: Data, fileName: String, origin: MailOrigin, extractor: Extractor,
                       companionXML: (MailAttachment, InvoiceFields)? = nil, force: Bool = false,
                       sourceHash: String? = nil, stage: Stage = .open, paidDate: Date? = nil) async throws -> Outcome {
        // A photo turned into a PDF is recognised by the photo, since each conversion gives a new PDF.
        let hash = sourceHash ?? Self.sha256(data)
        if records.contains(where: { $0.sha256 == hash && !$0.fileMissing }) { return .duplicate }
        // The same invoice again after it was deleted: forget the deleted entry and file it anew.
        records.removeAll { $0.sha256 == hash && $0.fileMissing }
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
        matchSupplier(&x.fields, &x.reviewReasons)
        // The same file may already lie in the folders, put there by hand or before the app existed.
        if copyInMainFolder(of: data) != nil { return .duplicate }
        let paid = stage == .open ? nil : paidDate
        // Without an invoice date the archive folder would be "YYYY-MM"; a known payment date stands in, to be checked.
        if x.fields.invoiceDate == nil, let paid {
            x.fields.invoiceDate = Calendar.current.startOfDay(for: paid)
            x.reviewReasons = x.reviewReasons.filter { $0 != "Kein Rechnungsdatum gefunden" } + ["Kein Rechnungsdatum gefunden, Zahlungsdatum verwendet"]
        }
        let url = try organizer.save(data, ext: Self.ext(fileName), fields: x.fields, stage: stage, paidDate: paid)
        if let (xml, _) = companionXML {
            try? xml.data.write(to: url.deletingPathExtension().appendingPathExtension("xml"), options: .withoutOverwriting)
        }
        var record = InvoiceRecord(fields: x.fields, source: x.source, reviewReasons: x.reviewReasons,
                                   status: stage == .open ? .unpaid : .paid, paidDate: paid,
                                   filePath: url.path, origin: origin, sha256: hash)
        record.archived = stage == .archived
        record.bookmark = Self.bookmark(url)
        record.termsRead = true
        records.insert(record, at: 0)
        save()
        return .filed(record)
    }

    /// A file anywhere in the main folder with exactly these bytes. Only files of the same size are read.
    public func copyInMainFolder(of data: Data) -> URL? {
        guard let e = FileManager.default.enumerator(at: organizer.rootURL, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == data.count,
                  let other = try? Data(contentsOf: url, options: .mappedIfSafe), other == data else { continue }
            return url
        }
        return nil
    }

    // MARK: - Existing folders

    public enum ExistingFile: Sendable, Equatable { case added, known, notInvoice }

    /// Adds an invoice PDF that already lies in a folder with the stage the user chose, without moving or
    /// renaming it, so invoices filed before the app count in the lists and statistics. The fields are read
    /// like a mail attachment; what the app is unsure about is marked for checking.
    /// `force` adds it even when the checks say it is no invoice (the user said it is one).
    public func indexExisting(_ url: URL, stage: Stage, paidDate: Date? = nil, extractor: Extractor,
                              force: Bool = false) async throws -> ExistingFile {
        let path = url.standardizedFileURL.path
        if records.contains(where: { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path == path }) { return .known }
        let data = try Data(contentsOf: url)
        let hash = Self.sha256(data)
        // A file moved in Finder comes back to its record instead of counting as deleted.
        if let i = records.firstIndex(where: { $0.sha256 == hash && $0.fileMissing }) {
            records[i].filePath = path
            records[i].fileMissing = false
            save()
            return .known
        }
        if records.contains(where: { $0.sha256 == hash }) {
            ignoredFiles.insert(path)
            save()
            return .known
        }
        var x = await extractor.extract(data: data, fileName: url.lastPathComponent, subject: "", sender: "")
        guard x.isInvoice || force else {
            ignoredFiles.insert(path)
            // Listed under „Keine Rechnungen“, where it can still be declared an invoice.
            if !skipped.contains(where: { $0.storedPath == path }) {
                var s = SkippedAttachment(origin: MailOrigin(subject: "Aus vorhandenem Ordner", attachmentName: url.lastPathComponent),
                                          reason: x.notInvoiceReason, storedPath: path)
                s.inPlace = true
                skipped.insert(s, at: 0)
            }
            save()
            return .notInvoice
        }
        matchSupplier(&x.fields, &x.reviewReasons)
        var record = InvoiceRecord(fields: x.fields, source: x.source, reviewReasons: x.reviewReasons,
                                   status: stage == .open ? .unpaid : .paid, paidDate: stage == .open ? nil : paidDate, filePath: path,
                                   origin: MailOrigin(subject: "Aus vorhandenem Ordner", attachmentName: url.lastPathComponent),
                                   sha256: hash)
        record.archived = stage == .archived
        record.inPlace = true
        record.customName = url.deletingPathExtension().lastPathComponent
        record.bookmark = Self.bookmark(url)
        record.termsRead = true
        records.insert(record, at: 0)
        save()
        return .added
    }

    /// The stage files in a folder most likely have: the unpaid or paid folder, otherwise archived.
    public func suggestedStage(for folder: URL) -> Stage {
        let path = folder.standardizedFileURL.path
        for stage in [Stage.open, .paid] {
            let f = organizer.folder(for: InvoiceFields(), stage: stage, paidDate: nil).standardizedFileURL.path
            if f != organizer.rootURL.standardizedFileURL.path, path == f || path.hasPrefix(f + "/") { return stage }
        }
        return .archived
    }

    /// PDFs in a folder and its subfolders that were never read.
    public func unknownFiles(in folder: URL) -> [URL] {
        let known = Set(records.map { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path }).union(ignoredFiles)
        return Self.pdfs(in: [folder]).filter { !known.contains($0.path) }
    }

    /// Reads every PDF in the folders and their subfolders with `indexExisting`. Stops between files when the
    /// task is cancelled; what is added stays added.
    public func indexFolders(_ folders: [URL], stage: Stage, paidDate: Date? = nil, extractor: Extractor,
                             progress: @MainActor (MailProgress) -> Void = { _ in }) async throws -> CheckSummary {
        try await indexFiles(Self.pdfs(in: folders), stage: stage, paidDate: paidDate, extractor: extractor, progress: progress)
    }

    /// Reads these PDFs with `indexExisting`.
    public func indexFiles(_ files: [URL], stage: Stage, paidDate: Date? = nil, extractor: Extractor,
                           progress: @MainActor (MailProgress) -> Void = { _ in }) async throws -> CheckSummary {
        var p = MailProgress(step: "Dateien werden gesucht …")
        p.unit = "Datei"
        progress(p)
        p.total = files.count
        for (n, url) in files.enumerated() {
            try Task.checkCancellation()
            p.current = n + 1
            p.folder = url.deletingLastPathComponent().lastPathComponent
            p.subject = url.lastPathComponent
            progress(p)
            p.summary.messages += 1
            do {
                switch try await indexExisting(url, stage: stage, paidDate: paidDate, extractor: extractor) {
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
    public nonisolated static func pdfs(in folders: [URL]) -> [URL] {
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

    /// Files an invoice the user added by hand (file, photo or scan) with the stage they chose.
    /// Photos and scans are saved as a one-page PDF. Returns nil when the same file was imported before.
    public func ingestFile(data: Data, fileName: String, stage: Stage, paidOn date: Date?, origin: MailOrigin,
                           extractor: Extractor) async throws -> InvoiceRecord? {
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
                                                     sourceHash: hash, stage: stage, paidDate: date)
        else { return nil }
        return record
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
    public func importSkipped(_ id: SkippedAttachment.ID, stage: Stage = .open, paidDate: Date? = nil, extractor: Extractor) async throws {
        guard let s = skipped.first(where: { $0.id == id }) else { return }
        // A file from the user's folders is added where it lies, never moved or deleted.
        if s.inPlace == true {
            ignoredFiles.remove(s.storedPath)
            _ = try await indexExisting(URL(fileURLWithPath: s.storedPath), stage: stage, paidDate: paidDate, extractor: extractor, force: true)
            skipped.removeAll { $0.id == id }
            save()
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: s.storedPath))
        let outcome = try await ingest(data: data, fileName: s.origin.attachmentName, origin: s.origin, extractor: extractor, force: true,
                                       stage: stage, paidDate: paidDate)
        if case .filed = outcome {
            skipped.removeAll { $0.id == id }
            try? FileManager.default.removeItem(atPath: s.storedPath)
            save()
        }
    }

    /// Forgets a skipped attachment. Its stored copy is deleted; a file in the user's folders stays.
    public func deleteSkipped(_ id: SkippedAttachment.ID) {
        guard let s = skipped.first(where: { $0.id == id }) else { return }
        if s.inPlace != true { try? FileManager.default.removeItem(atPath: s.storedPath) }
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
    /// template would give, follows the template. The file goes to the folder of its stage: open invoices to the
    /// unpaid folder, paid ones to the paid folder until they are archived (`archive`, or they already were).
    public func update(_ id: InvoiceRecord.ID, fields: InvoiceFields, status: InvoiceStatus, paidDate: Date?, name: String?,
                       archive: Bool = false) throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        var r = records[i]
        // A paid invoice without a known payment date keeps having none.
        let newPaid = status == .paid ? (paidDate ?? r.paidDate ?? (r.status == .paid ? nil : Date())) : nil
        let o = organizer
        let cleanName = name.map(FileOrganizer.cleanName).flatMap { $0.isEmpty || $0 == o.baseName(for: fields, paidDate: newPaid) ? nil : $0 }
        let inArchive = status == .paid && (archive || r.archived == true)
        let stage: Stage = status == .unpaid ? .open : inArchive ? .archived : .paid
        // Files read in place stay in their folder while only fields or the name change.
        let keep = r.inPlace == true && stage == r.stage
        let url = try o.place(r.fileURL, fields: fields, stage: stage, paidDate: newPaid, name: cleanName, keepFolder: keep)
        r.inPlace = keep ? true : nil
        // A company name the user typed or kept becomes a known supplier.
        if r.fields.seller != fields.seller { register(fields.seller) }
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
        r.archived = inArchive
        records[i] = r
        save()
    }

    /// Marks an invoice paid (it moves to the paid folder) or open. Only `archive` moves it on into the archive.
    public func setPaid(_ id: InvoiceRecord.ID, _ paid: Bool, on date: Date = Date()) throws {
        guard let r = records.first(where: { $0.id == id }) else { return }
        try update(id, fields: r.fields, status: paid ? .paid : .unpaid, paidDate: paid ? date : nil)
    }

    public func isArchived(_ r: InvoiceRecord) -> Bool { r.stage == .archived }

    /// Moves paid invoices into their archive folder. Open and already archived ones are left alone.
    public func archive(_ ids: [InvoiceRecord.ID]) throws {
        for id in ids {
            guard let r = records.first(where: { $0.id == id }), r.stage == .paid else { continue }
            try update(id, fields: r.fields, status: .paid, paidDate: r.paidDate, name: r.customName, archive: true)
        }
    }

    /// Looks for payment terms in invoices filed before the app read them, once per invoice.
    public func readMissingTerms() async {
        let todo = records.filter { $0.termsRead != true && !$0.fileMissing }.map { ($0.id, $0.fileURL) }
        guard !todo.isEmpty else { return }
        for (id, url) in todo {
            let terms = await Task.detached { Extractor.terms(ofFile: url) }.value
            guard let i = records.firstIndex(where: { $0.id == id }) else { continue }
            if records[i].fields.terms == nil { records[i].fields.terms = terms }
            records[i].termsRead = true
        }
        save()
    }

    /// Marks invoices as printed (on paper) or not.
    public func setPrinted(_ ids: [InvoiceRecord.ID], _ printed: Bool) {
        for i in records.indices where ids.contains(records[i].id) {
            records[i].printedAt = printed ? (records[i].printedAt ?? Date()) : nil
        }
        save()
    }

    public func markReviewed(_ id: InvoiceRecord.ID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].reviewReasons = []
        register(records[i].fields.seller)
        save()
    }

    // MARK: - Suppliers

    /// Gives a read company name the supplier's chosen name when it is known; a name much like a known one is
    /// marked for checking; a new one is added to the suppliers.
    func matchSupplier(_ fields: inout InvoiceFields, _ reasons: inout [String]) {
        let name = fields.seller.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch suppliers.match(name) {
        case .exact(let s):
            fields.seller = s.name
            // A known supplier confirms a name guessed from the letterhead or the sender.
            reasons.removeAll { $0.hasPrefix("Firmenname aus") }
        case .close(let s):
            reasons.append(Self.similarSupplierPrefix + s.name + "“")
        case .none:
            suppliers.append(Supplier(name: name))
        }
    }

    static let similarSupplierPrefix = "Lieferant ähnlich wie „"

    /// Adds the name as a supplier unless it, or a spelling of it, is known.
    func register(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if case .exact = suppliers.match(name) { return }
        suppliers.append(Supplier(name: name))
    }

    /// Invoices (also deleted ones) whose company is this supplier.
    public func records(of supplier: Supplier) -> [InvoiceRecord] {
        let keys = supplier.keys
        return records.filter { keys.contains(Supplier.key($0.fields.seller)) }
    }

    /// Renames a supplier. The old name stays as another spelling, and its invoices (and their files) get the new name.
    public func renameSupplier(_ id: Supplier.ID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = suppliers.firstIndex(where: { $0.id == id }), !name.isEmpty, name != suppliers[i].name else { return }
        var s = suppliers[i]
        s.aliases = Self.unique(s.aliases + [s.name]).filter { $0 != name }
        s.name = name
        // Another supplier with this name is the same company now.
        if case .exact(let other) = suppliers.filter({ $0.id != id }).match(name) {
            s.aliases = Self.unique(s.aliases + [other.name] + other.aliases).filter { $0 != name }
            suppliers.removeAll { $0.id == other.id }
        }
        if let j = suppliers.firstIndex(where: { $0.id == id }) { suppliers[j] = s }
        try relabel(s)
    }

    /// Merges suppliers into one: their names become its other spellings and their invoices get its name.
    public func mergeSuppliers(_ ids: Set<Supplier.ID>, into target: Supplier.ID) throws {
        guard var t = suppliers.first(where: { $0.id == target }) else { return }
        let merged = suppliers.filter { ids.contains($0.id) && $0.id != target }
        guard !merged.isEmpty else { return }
        t.aliases = Self.unique(t.aliases + merged.flatMap { [$0.name] + $0.aliases }).filter { $0 != t.name }
        suppliers.removeAll { ids.contains($0.id) && $0.id != target }
        if let j = suppliers.firstIndex(where: { $0.id == target }) { suppliers[j] = t }
        try relabel(t)
    }

    /// Gives the supplier's invoices its name, renaming their files like an edit would, but keeping how they were read.
    private func relabel(_ s: Supplier) throws {
        for r in records(of: s) {
            guard let i = records.firstIndex(where: { $0.id == r.id }) else { continue }
            let reasons = r.reviewReasons.filter { !$0.hasPrefix(Self.similarSupplierPrefix) && !$0.hasPrefix("Firmenname aus") }
            if r.fields.seller != s.name && !r.fileMissing {
                var f = r.fields
                f.seller = s.name
                try update(r.id, fields: f, status: r.status, paidDate: r.paidDate, name: r.customName)
            } else {
                records[i].fields.seller = s.name
            }
            records[i].source = r.source
            records[i].reviewReasons = reasons
        }
        save()
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Invoices whose file still exists. Deleted ones (in the app or in Finder) are only in `deleted`.
    public var liveRecords: [InvoiceRecord] { records.filter { !$0.fileMissing } }
    public var deleted: [InvoiceRecord] { records.filter(\.fileMissing) }

    /// Moves the invoices' files to the macOS trash; the invoices go to the deleted list.
    public func trash(_ ids: [InvoiceRecord.ID]) throws {
        for i in records.indices where ids.contains(records[i].id) {
            if FileManager.default.fileExists(atPath: records[i].filePath) {
                try FileManager.default.trashItem(at: records[i].fileURL, resultingItemURL: nil)
            }
            records[i].fileMissing = true
        }
        save()
    }

    /// Forgets every deleted invoice.
    public func clearDeleted() {
        records.removeAll(where: \.fileMissing)
        save()
    }

    /// Forgets an invoice. The file itself stays where it is.
    public func remove(_ id: InvoiceRecord.ID) {
        records.removeAll { $0.id == id }
        save()
    }

    /// Notices files that were moved or deleted outside the app, e.g. in Finder or OneDrive. A moved file is found
    /// again (by its bookmark, or by its content in the main folder) and keeps its invoice; only a file that is gone
    /// or lies in the Trash counts as deleted.
    public func refreshFiles() {
        var changed = false
        for i in records.indices {
            let url = records[i].fileURL
            if FileManager.default.fileExists(atPath: url.path) {
                if records[i].fileMissing { records[i].fileMissing = false; changed = true }
                if records[i].bookmark == nil, let b = Self.bookmark(url) { records[i].bookmark = b; changed = true }
                continue
            }
            if let found = Self.resolve(records[i].bookmark), !Self.isInTrash(found) {
                relocate(i, to: found)
                changed = true
            } else if !records[i].fileMissing {
                records[i].fileMissing = true
                changed = true
            }
        }
        // Without a bookmark (or when it broke), look for the same content among unknown PDFs in the main folder.
        if records.contains(where: \.fileMissing), settings.isFolderConfigured {
            var missing = Dictionary(records.indices.filter { records[$0].fileMissing }.map { (records[$0].sha256, $0) }) { a, _ in a }
            for url in unknownFiles(in: organizer.rootURL) where !missing.isEmpty {
                guard let data = try? Data(contentsOf: url), let i = missing.removeValue(forKey: Self.sha256(data)) else { continue }
                relocate(i, to: url)
                changed = true
            }
        }
        if changed { save() }
    }

    private func relocate(_ i: Int, to url: URL) {
        records[i].filePath = url.standardizedFileURL.path
        records[i].fileMissing = false
        records[i].bookmark = Self.bookmark(url)
        ignoredFiles.remove(records[i].filePath)
    }

    /// Brings a deleted invoice's file back: from the Trash or wherever its bookmark now points, to where it was.
    /// Returns false when the file can't be found; then the user picks it with `relink`.
    @discardableResult
    public func restore(_ id: InvoiceRecord.ID) throws -> Bool {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return false }
        refreshFiles()
        guard records[i].fileMissing else { return true }
        guard let found = Self.resolve(records[i].bookmark), FileManager.default.fileExists(atPath: found.path) else { return false }
        var target = records[i].fileURL
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Something else took the old name meanwhile: keep both.
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let base = records[i].fileURL.deletingPathExtension().lastPathComponent
            target = records[i].fileURL.deletingLastPathComponent().appendingPathComponent("\(base) (\(n))")
                .appendingPathExtension(records[i].fileURL.pathExtension)
            n += 1
        }
        try FileManager.default.moveItem(at: found, to: target)
        relocate(i, to: target)
        save()
        return true
    }

    /// Links a deleted invoice to a file the user picked. A file with other content is accepted but marked for a check.
    public func relink(_ id: InvoiceRecord.ID, to url: URL) throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let hash = Self.sha256(try Data(contentsOf: url))
        if hash != records[i].sha256 {
            if records.contains(where: { $0.id != id && $0.sha256 == hash && !$0.fileMissing }) {
                throw IMAPError(message: "Diese Datei gehört schon zu einer anderen Rechnung.")
            }
            records[i].sha256 = hash
            records[i].reviewReasons.append("Datei von Hand zugeordnet, Inhalt weicht ab")
        }
        relocate(i, to: url)
        save()
    }

    static func bookmark(_ url: URL) -> Data? { try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }

    static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
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
        if let data = try? encoder.encode(Stored(records: records, skipped: skipped, cursors: cursors, ignoredFiles: ignoredFiles)) {
            try? data.write(to: directory.appendingPathComponent("library.json"), options: .atomic)
        }
    }

    private func saveSuppliers() {
        if let data = try? JSONEncoder().encode(suppliers) {
            try? data.write(to: directory.appendingPathComponent("suppliers.json"), options: .atomic)
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
