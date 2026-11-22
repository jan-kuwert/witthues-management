import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import WitthuesCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
}

@Suite struct TemplateTests {
    @Test func janFileNameAndFolders() {
        let f = InvoiceFields(seller: "Telekom Deutschland GmbH", invoiceNumber: "RE/2026/0815", invoiceDate: day(2026, 3, 7))
        #expect(PathTemplate.render("{yy}-{mm}-{dd} {company} {invoice}", fields: f) == "26-03-07 Telekom Deutschland RE-2026-0815")
        // Templates saved with the old name still work and are rewritten to {company}.
        #expect(PathTemplate.render("{customer}", fields: f) == "Telekom Deutschland")
        #expect(PathTemplate.migrated("{yy} {Customer} {seller}") == "{yy} {company} {company}")
        // The archive month comes from the payment date, not the invoice date.
        #expect(PathTemplate.render("{paid_yyyy}-{paid_mm}", fields: f, paidDate: day(2026, 5, 2)) == "2026-05")
        #expect(PathTemplate.unknownVariables(in: "{yyyy}-{month} {company} {customer}") == ["{month}"])
    }
}

@Suite struct EInvoiceTests {
    @Test func embeddedXMLWinsOverVisibleText() async throws {
        let x = await Extractor(useAppleIntelligence: false).extract(data: try fixture("zugferd.pdf"), fileName: "r.pdf", subject: "", sender: "")
        #expect(x.source == .eInvoiceXML)
        #expect(x.fields.invoiceNumber == "ZF-2026-4711")
        #expect(x.fields.seller == "Musterlieferant GmbH")
        #expect(x.fields.total == Decimal(string: "238.00"))
        #expect(x.fields.invoiceDate == day(2026, 3, 5))
    }

    @Test func ublXRechnung() throws {
        let f = try #require(EInvoice.parse(xml: try fixture("xrechnung-ubl.xml")))
        #expect(f.seller == "Stadtwerke Beispiel GmbH")
        #expect(f.invoiceNumber == "UBL-77/2026")
        #expect(f.total == Decimal(string: "119.00"))
    }
}

@Suite struct TextRuleTests {
    @Test func germanPDF() async throws {
        let x = await Extractor(useAppleIntelligence: false).extract(data: try fixture("german.pdf"), fileName: "Rechnung.pdf", subject: "", sender: "")
        #expect(x.isInvoice)
        #expect(x.fields.seller == "Beispiel Druckerei GmbH")
        #expect(x.fields.invoiceNumber == "RE-2026-00123")
        #expect(x.fields.invoiceDate == day(2026, 3, 7))
        // Gross, not the net 1.000,00 or the VAT line.
        #expect(x.fields.total == Decimal(string: "1190.00"))
        #expect(!x.reviewReasons.isEmpty)
    }

    @Test func englishPDF() async throws {
        let x = await Extractor(useAppleIntelligence: false).extract(data: try fixture("english.pdf"), fileName: "doc.pdf", subject: "", sender: "")
        #expect(x.fields.seller == "Acme Software Ltd.")
        #expect(x.fields.invoiceNumber == "INV-88412")
        #expect(x.fields.invoiceDate == day(2026, 3, 9))
        #expect(x.fields.total == Decimal(string: "300.00"))
        #expect(x.fields.currency == "GBP")
    }

    @Test func spacedNumberAndLetterheadSeparators() {
        // Layouts seen on real Telekom and Herder invoices.
        #expect(TextRules.invoiceNumber(in: "Datum 13.01.2026\nRechnungsnummer 19 5683 1701 2621\nCarmen") == "19 5683 1701 2621")
        #expect(TextRules.companyLine(in: "Adresse:\nRobert Herder GmbH & Co.KG * Ellerstr.16 * D-42697 Solingen") == "Robert Herder GmbH & Co.KG")
        #expect(PathTemplate.cleanName("Robert Herder GmbH & Co.KG") == "Robert Herder")
    }

    @Test func termsAreNotAnInvoice() async throws {
        let x = await Extractor(useAppleIntelligence: false).extract(data: try fixture("agb.pdf"), fileName: "Unterlagen.pdf", subject: "Ihre Rechnung", sender: "")
        #expect(!x.isInvoice)
    }

    @Test(arguments: [("1.234,56", "1234.56"), ("1,234.56", "1234.56"), ("1 234,56", "1234.56"), ("12,50", "12.50"), ("12.50", "12.50"),
                      // Typed by hand: either sign as decimal separator, one decimal is enough.
                      ("175,5", "175.5"), ("175.5", "175.5"), ("1.234,5", "1234.5"), ("1250", "1250"), ("1.250", "1250")])
    func amounts(raw: String, expected: String) {
        #expect(TextRules.parseAmount(raw) == Decimal(string: expected, locale: Locale(identifier: "en_US_POSIX")))
    }

    /// The Betrag field shows two decimals and reads back as the same amount, so saving another field keeps it.
    @Test func editableAmountReadsBack() {
        let d = Decimal(string: "1234.5", locale: Locale(identifier: "en_US_POSIX"))!
        #expect(InvoiceText.editableAmount(d) == "1234,50")
        #expect(InvoiceText.amount(InvoiceText.editableAmount(d)) == d)
    }
}

@Suite struct MIMETests {
    @Test func attachmentWithEncodedNames() throws {
        let pdf = try fixture("german.pdf")
        let raw = """
            From: =?UTF-8?Q?Beispiel_Druckerei_M=C3=BCller?= <rechnung@druckerei.de>\r
            Subject: =?ISO-8859-1?Q?Ihre_Rechnung_f=FCr_M=E4rz?=\r
            Message-ID: <abc@druckerei.de>\r
            Content-Type: multipart/mixed; boundary="XX"\r
            \r
            --XX\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            Hallo\r
            --XX\r
            Content-Type: application/pdf\r
            Content-Disposition: attachment; filename*=UTF-8''Rechnung%20M%C3%A4rz.pdf\r
            Content-Transfer-Encoding: base64\r
            \r
            \(pdf.base64EncodedString(options: .lineLength76Characters))\r
            --XX--\r

            """
        let mail = MIME.parse(Data(raw.utf8))
        #expect(mail.subject == "Ihre Rechnung für März")
        #expect(mail.from == "Beispiel Druckerei Müller <rechnung@druckerei.de>")
        #expect(mail.attachments.count == 1)
        #expect(mail.attachments.first?.fileName == "Rechnung März.pdf")
        #expect(mail.attachments.first?.data == pdf)
    }
}

@MainActor @Suite struct FilingTests {
    @Test func photoOfPaidInvoiceGoesStraightToArchiveAsPDF() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        lib.settings.rootFolder = tmp.appendingPathComponent("Rechnungen").path
        lib.settings.archiveFolder = "Archiv/{paid_yyyy}-{paid_mm}"
        // A portrait PNG, like a phone photo of a receipt.
        let ctx = try #require(CGContext(data: nil, width: 300, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 600))
        let png = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(png as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))

        let ex = Extractor(useAppleIntelligence: false)
        // A blank photo would not pass as an invoice from mail; imported by hand it is filed anyway.
        let r = try #require(try await lib.ingestFile(data: png as Data, fileName: "IMG_0001.png", stage: .archived, paidOn: day(2026, 4, 9),
                                                      origin: MailOrigin(), extractor: ex))
        #expect(r.stage == .archived)
        #expect(r.paidDate == day(2026, 4, 9))
        #expect(r.filePath.contains("/Rechnungen/Archiv/2026-04/26-04-09 "))
        // No date could be read from the blank photo, so the payment date stands in and it is flagged.
        #expect(r.needsReview)
        #expect(r.filePath.hasSuffix(".pdf"))
        let saved = try Data(contentsOf: r.fileURL)
        #expect(saved.prefix(4) == Data("%PDF".utf8))
        // Portrait stays portrait: A4 width, twice as high.
        let page = try #require(CGPDFDocument(CGDataProvider(data: saved as CFData)!)?.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).size == CGSize(width: 595, height: 1190))
        // Importing the same photo again files nothing.
        #expect(try await lib.ingestFile(data: png as Data, fileName: "IMG_0001.png", stage: .archived, paidOn: day(2026, 4, 9),
                                         origin: MailOrigin(), extractor: ex) == nil)
        #expect(lib.records.count == 1)
    }

    @Test func fileAlreadyInFoldersGetsAnEntryButNoCopy() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        let root = tmp.appendingPathComponent("Rechnungen")
        lib.settings.rootFolder = root.path
        let ex = Extractor(useAppleIntelligence: false)
        // Put into the unpaid folder by hand under another name, unknown to the app, then imported.
        let open = root.appendingPathComponent("00 Offen")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        let file = open.appendingPathComponent("alt.pdf")
        try fixture("german.pdf").write(to: file)
        let first = try await lib.ingest(data: try fixture("german.pdf"), fileName: "alt.pdf", origin: MailOrigin(), extractor: ex)
        guard case .filed(let r) = first else { Issue.record("an unknown file in the folders must get an entry: \(first)"); return }
        // The entry points at the file where it lies; no second copy, no rename.
        #expect(r.filePath == file.standardizedFileURL.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: open.path) == ["alt.pdf"])
        // Now it is known, so importing it again adds nothing.
        #expect(try await lib.ingest(data: try fixture("german.pdf"), fileName: "alt.pdf", origin: MailOrigin(), extractor: ex) == .duplicate)
        #expect(lib.records.count == 1)
        guard case .filed = try await lib.ingest(data: try fixture("english.pdf"), fileName: "e.pdf", origin: MailOrigin(), extractor: ex)
        else { Issue.record("a new invoice must still be filed"); return }
    }

    @Test func folderFileThatIsNoInvoiceCanBeDeclaredOne() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        let root = tmp.appendingPathComponent("Rechnungen")
        lib.settings.rootFolder = root.path
        let ex = Extractor(useAppleIntelligence: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2025-12"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("2025-12/agb.pdf")
        try fixture("agb.pdf").write(to: file)
        #expect(try await lib.indexExisting(file, stage: .archived, extractor: ex) == .notInvoice)
        let s = try #require(lib.skipped.first)
        #expect(s.inPlace == true && s.storedPath == file.standardizedFileURL.path)
        try await lib.importSkipped(s.id, stage: .archived, extractor: ex)
        // Added where it lies; the file is neither moved nor deleted.
        #expect(lib.skipped.isEmpty)
        #expect(lib.records.first?.filePath == file.standardizedFileURL.path && lib.records.first?.stage == .archived)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func fileThenArchiveByPaymentMonth() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        lib.settings.rootFolder = tmp.appendingPathComponent("OneDrive/Rechnungen").path
        let ex = Extractor(useAppleIntelligence: false)
        let pdf = try fixture("zugferd.pdf")

        let outcome = try await lib.ingest(data: pdf, fileName: "x.pdf", origin: MailOrigin(), extractor: ex)
        guard case .filed(let r) = outcome else { Issue.record("not filed: \(outcome)"); return }
        #expect(r.filePath.hasSuffix("OneDrive/Rechnungen/00 Offen/26-03-05 Musterlieferant ZF-2026-4711.pdf"))
        #expect(try Data(contentsOf: r.fileURL) == pdf)

        // The same attachment from a later mail is not filed twice.
        #expect(try await lib.ingest(data: pdf, fileName: "x.pdf", origin: MailOrigin(), extractor: ex) == .duplicate)

        // Paid in May: the file waits in the paid folder until it is archived, then goes to the invoice month by default.
        try lib.setPaid(r.id, true, on: day(2026, 5, 2))
        var paid = try #require(lib.records.first)
        #expect(paid.filePath.hasSuffix("OneDrive/Rechnungen/01 Bezahlt/26-03-05 Musterlieferant ZF-2026-4711.pdf"))
        #expect(paid.stage == .paid)
        try lib.archive([r.id])
        paid = try #require(lib.records.first)
        #expect(lib.isArchived(paid))
        #expect(paid.filePath.hasSuffix("OneDrive/Rechnungen/2026-03/26-03-05 Musterlieferant ZF-2026-4711.pdf"))
        #expect(!FileManager.default.fileExists(atPath: r.filePath))

        // With a payment-month template, marking unpaid and paid again moves it under the payment month.
        lib.settings.archiveFolder = "Archiv/{paid_yyyy}-{paid_mm}"
        try lib.setPaid(r.id, false)
        #expect(lib.records.first?.filePath == r.filePath)
        #expect(lib.records.first?.stage == .open)
        try lib.setPaid(r.id, true, on: day(2026, 5, 2))
        #expect(lib.records.first?.stage == .paid)
        try lib.archive([r.id])
        paid = try #require(lib.records.first)
        #expect(paid.filePath.hasSuffix("OneDrive/Rechnungen/Archiv/2026-05/26-03-05 Musterlieferant ZF-2026-4711.pdf"))
        #expect(FileManager.default.fileExists(atPath: paid.filePath))
        #expect(!FileManager.default.fileExists(atPath: r.filePath))

        // Records and saved views survive a restart.
        lib.views = [SavedView(name: "Paid 2026", folder: "Archiv", rules: [FilterRule(.status, .equals, "paid"), FilterRule(.invoiceDate, .equals, "2026")],
                               matchAny: true, icon: "eurosign.circle"),
                     SavedView(name: "2026-05", folder: "Archiv/2026-05", icon: "folder", isFolder: true)]
        // Templates saved with the old {customer} name come back as {company}.
        lib.settings.fileName = "{yy} {customer} {invoice}"
        let reopened = Library(directory: tmp.appendingPathComponent("data"))
        #expect(reopened.settings.fileName == "{yy} {company} {invoice}")
        #expect(reopened.views == lib.views)
        #expect(reopened.settings.archiveFolder == "Archiv/{paid_yyyy}-{paid_mm}")
        #expect(reopened.records.first?.stage == .archived)
        #expect(reopened.records.first?.filePath == paid.filePath)
    }

    /// Settings from before the paid folder existed: their "paidFolder" was the archive and must stay it.
    @Test func olderSettingsKeepTheirArchiveFolder() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data(#"{"rootFolder":"/x","unpaidFolder":"Offen","paidFolder":"Archiv/{yyyy}","fileName":"{invoice}","username":"a@b.de"}"#.utf8)
            .write(to: tmp.appendingPathComponent("settings.json"))
        let s = Library(directory: tmp).settings
        #expect(s.rootFolder == "/x" && s.unpaidFolder == "Offen" && s.username == "a@b.de")
        #expect(s.archiveFolder == "Archiv/{yyyy}")
        #expect(s.paidFolder == "01 Bezahlt")
        #expect(s.imapHost == "secureimap.t-online.de")
    }

    @Test func nonInvoiceIsSkippedNotFiled() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        lib.settings.rootFolder = tmp.appendingPathComponent("root").path
        let outcome = try await lib.ingest(data: try fixture("agb.pdf"), fileName: "AGB.pdf", origin: MailOrigin(), extractor: Extractor(useAppleIntelligence: false))
        guard case .skipped = outcome else { Issue.record("expected skipped, got \(outcome)"); return }
        #expect(lib.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("root/00 Offen").path))
    }
}

@Suite struct FilterRuleTests {
    private func record(_ seller: String, total: String?, status: InvoiceStatus, date: Date) -> InvoiceRecord {
        InvoiceRecord(fields: InvoiceFields(seller: seller, invoiceDate: date, total: total.flatMap { Decimal(string: $0) }),
                      source: .textRules, reviewReasons: [], status: status, filePath: "/x/\(seller).pdf", origin: MailOrigin(), sha256: seller)
    }

    @Test func andOrAndExclusion() {
        let telekom = record("Telekom Deutschland", total: "72.96", status: .paid, date: day(2026, 1, 13))
        let herder = record("Herder", total: "250", status: .unpaid, date: day(2025, 3, 20))
        let noAmount = record("Hassler", total: nil, status: .unpaid, date: day(2026, 3, 1))
        let all = [telekom, herder, noAmount]
        func names(_ v: SavedView) -> [String] { all.filter { v.matches($0, folder: "") }.map(\.fields.seller) }

        let paidAnd2026 = SavedView(rules: [FilterRule(.status, .equals, "paid"), FilterRule(.invoiceDate, .equals, "2026")])
        #expect(names(paidAnd2026) == ["Telekom Deutschland"])
        var either = paidAnd2026
        either.matchAny = true
        #expect(names(either) == ["Telekom Deutschland", "Hassler"])
        // Exclusion is case-insensitive; a rule still being typed changes nothing.
        #expect(names(SavedView(rules: [FilterRule(.company, .notContains, "telekom"), FilterRule(.company, .contains, " ")])) == ["Herder", "Hassler"])
        // German amounts; an invoice without an amount is neither bigger nor smaller.
        #expect(names(SavedView(rules: [FilterRule(.amount, .greater, "72,95")])) == ["Telekom Deutschland", "Herder"])
        #expect(names(SavedView(rules: [FilterRule(.amount, .less, "100")])) == ["Telekom Deutschland"])
        #expect(names(SavedView(rules: [FilterRule(.invoiceDate, .before, "2026-01-13")])) == ["Herder"])
        #expect(names(SavedView(rules: [FilterRule(.invoiceDate, .equals, "2026-03")])) == ["Hassler"])
    }

    @Test func viewsFromBeforeRulesStillLoad() throws {
        let json = #"[{"id":"B8AD9A88-ED55-4AB3-900B-ED7A6385FE3C","name":"Bezahlt 2026","starred":true,"status":"Paid","year":2026,"onlyNeedsCheck":true,"search":""}]"#
        let v = try #require(try JSONDecoder().decode([SavedView].self, from: Data(json.utf8)).first)
        #expect(v.name == "Bezahlt 2026")
        #expect(v.rules.map(\.field) == [.status, .invoiceDate, .needsCheck])
        #expect(v.rules.map(\.value) == ["paid", "2026", "true"])
        #expect(!v.matchAny)
    }
}

@Suite struct DashboardPeriodTests {
    @Test func spansAcrossTheYearBoundary() throws {
        let now = day(2026, 1, 15)
        func span(_ p: DashboardPeriod) throws -> [Date] {
            let i = try #require(p.interval(now: now))
            return [i.start, i.end]
        }
        #expect(try span(.lastMonth) == [day(2025, 12, 1), day(2026, 1, 1)])
        #expect(try span(.thisQuarter) == [day(2026, 1, 1), day(2026, 4, 1)])
        #expect(try span(.lastQuarter) == [day(2025, 10, 1), day(2026, 1, 1)])
        #expect(try span(.last12Months) == [day(2025, 2, 1), day(2026, 2, 1)])
        #expect(try span(.lastYear) == [day(2025, 1, 1), day(2026, 1, 1)])
        // The last day of a quarter still belongs to it.
        #expect(DashboardPeriod.thisQuarter.interval(now: day(2026, 6, 30))?.start == day(2026, 4, 1))
        #expect(DashboardPeriod.all.interval(now: now) == nil)
    }
}

@Suite struct MailFolderTests {
    @Test func folderNamesAndMailLinks() {
        // IMAP sends non-ASCII folder names in modified UTF-7.
        #expect(IMAPClient.displayName("Entw&APw-rfe") == "Entwürfe")
        #expect(IMAPClient.displayName("INBOX/Gel&APY-scht") == "INBOX/Gelöscht")
        #expect(IMAPClient.displayName("A &- B") == "A & B")
        #expect(IMAPClient.displayName("INBOX") == "INBOX")
        #expect(MailOrigin(messageID: "abc.1@mail.de").mailURL?.absoluteString == "message://%3Cabc.1@mail.de%3E")
        #expect(MailOrigin().mailURL == nil)
    }
}

@Suite struct RenameTests {
    @MainActor @Test func customName() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        lib.settings.rootFolder = tmp.appendingPathComponent("Rechnungen").path
        let outcome = try await lib.ingest(data: try fixture("zugferd.pdf"), fileName: "x.pdf", origin: MailOrigin(),
                                           extractor: Extractor(useAppleIntelligence: false))
        guard case .filed(let r) = outcome else { Issue.record("not filed"); return }

        // A typed name is used in the template folder; "/" can't end up in a file name.
        try lib.update(r.id, fields: r.fields, status: .unpaid, paidDate: nil, name: "Strom März/April")
        var now = try #require(lib.records.first)
        #expect(now.filePath.hasSuffix("Rechnungen/00 Offen/Strom März-April.pdf"))
        #expect(!FileManager.default.fileExists(atPath: r.filePath))

        // Editing a field keeps the name; paying keeps it too and moves the file to the archive folder.
        var f = now.fields; f.buyer = "Witthüs"
        try lib.update(r.id, fields: f, status: .unpaid, paidDate: nil)
        #expect(try #require(lib.records.first).filePath == now.filePath)
        try lib.setPaid(r.id, true, on: day(2026, 5, 2))
        try lib.archive([r.id])
        now = try #require(lib.records.first)
        #expect(now.filePath.hasSuffix("Rechnungen/2026-03/Strom März-April.pdf"))

        // Typing exactly the template's name follows the template again, so a corrected date renames the file.
        try lib.update(r.id, fields: now.fields, status: .paid, paidDate: now.paidDate, name: "26-03-05 Musterlieferant ZF-2026-4711")
        #expect(try #require(lib.records.first).customName == nil)
        f = now.fields; f.invoiceDate = day(2026, 4, 1)
        try lib.update(r.id, fields: f, status: .paid, paidDate: now.paidDate)
        #expect(try #require(lib.records.first).filePath.hasSuffix("Rechnungen/2026-04/26-04-01 Musterlieferant ZF-2026-4711.pdf"))
    }
}

@Suite struct MailTextAndFolderTests {
    @Test func bodyFromPlainOrHTML() {
        let plain = "Subject: x\r\nContent-Type: multipart/mixed; boundary=\"B\"\r\n\r\n--B\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nGr=FC=DFe, anbei die Rechnung\r\n--B--\r\n"
        #expect(MIME.parse(Data(plain.utf8)).body == "Grüße, anbei die Rechnung")
        let html = "Subject: y\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><head><style>p{}</style></head><body><p>Hallo&nbsp;Team</p><p>Betrag: 5&euro;</p></body></html>\r\n"
        #expect(MIME.parse(Data(html.utf8)).body == "Hallo Team\nBetrag: 5€")
    }

    @MainActor @Test func existingFilesAreIndexedInPlace() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = tmp.appendingPathComponent("Rechnungen")
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        lib.settings.rootFolder = root.path
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("00 Offen"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("2025-01"), withIntermediateDirectories: true)
        let open = root.appendingPathComponent("00 Offen/alt.pdf"), paid = root.appendingPathComponent("2025-01/x.pdf")
        try fixture("zugferd.pdf").write(to: open)
        try fixture("german.pdf").write(to: paid)
        try fixture("agb.pdf").write(to: root.appendingPathComponent("2025-01/agb.pdf"))

        let ex = Extractor(useAppleIntelligence: false)
        #expect(lib.unknownFiles(in: root).count == 3)
        #expect(lib.suggestedStage(for: root.appendingPathComponent("00 Offen")) == .open)
        #expect(lib.suggestedStage(for: root.appendingPathComponent("2025-01")) == .archived)
        // The stage is the one the user picked, here "archived" for an old month folder.
        let s = try await lib.indexFolders([root.appendingPathComponent("2025-01")], stage: .archived, extractor: ex)
        #expect(s.messages == 2)
        #expect(s.filed == 1)
        #expect(s.skipped == 1)
        _ = try await lib.indexFolders([root.appendingPathComponent("00 Offen")], stage: .open, extractor: ex)
        // Not moved or renamed.
        #expect(lib.records.first { $0.filePath == open.standardizedFileURL.path }?.stage == .open)
        #expect(lib.records.first { $0.filePath == paid.standardizedFileURL.path }?.stage == .archived)
        #expect(fm.fileExists(atPath: open.path) && fm.fileExists(atPath: paid.path))
        // Correcting a field keeps the file where it is, under its own name.
        let old = try #require(lib.records.first { $0.filePath == paid.standardizedFileURL.path })
        var f = old.fields; f.total = 1200
        try lib.update(old.id, fields: f, status: old.status, paidDate: old.paidDate)
        let edited = try #require(lib.records.first { $0.id == old.id })
        #expect(edited.filePath == paid.standardizedFileURL.path && edited.fields.total == 1200 && edited.paidDate == nil)
        // Everything was read, including the file that is not an invoice; a second run adds nothing.
        #expect(lib.unknownFiles(in: root).isEmpty)
        #expect(try await lib.indexFolders([root], stage: .archived, extractor: ex).filed == 0)
        #expect(lib.records.count == 2)
    }
}

@Suite struct DeletedFileTests {
    @MainActor @Test func movedFilesAreFoundTrashedOnesRestored() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        lib.settings.rootFolder = tmp.appendingPathComponent("Rechnungen").path
        let outcome = try await lib.ingest(data: try fixture("zugferd.pdf"), fileName: "x.pdf", origin: MailOrigin(),
                                           extractor: Extractor(useAppleIntelligence: false))
        guard case .filed(let r) = outcome else { Issue.record("not filed"); return }
        let fm = FileManager.default

        // Moved elsewhere in Finder (e.g. dragged to the desktop): the invoice follows the file and is not deleted.
        let elsewhere = tmp.appendingPathComponent("Schreibtisch/umbenannt.pdf")
        try fm.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: r.fileURL, to: elsewhere)
        lib.refreshFiles()
        var now = try #require(lib.records.first)
        #expect(!now.fileMissing)
        #expect(now.filePath == elsewhere.standardizedFileURL.path)
        #expect(lib.deleted.isEmpty)

        // In the Trash it counts as deleted, and restoring puts it back where it was.
        try fm.trashItem(at: elsewhere, resultingItemURL: nil)
        lib.refreshFiles()
        #expect(lib.deleted.count == 1)
        #expect(try lib.restore(r.id))
        now = try #require(lib.records.first)
        #expect(!now.fileMissing && now.filePath == elsewhere.standardizedFileURL.path)
        #expect(fm.fileExists(atPath: elsewhere.path))

        // Gone for good: the user picks a copy by hand.
        try fm.removeItem(at: elsewhere)
        lib.refreshFiles()
        #expect(try lib.restore(r.id) == false)
        let copy = tmp.appendingPathComponent("Kopie.pdf")
        try fixture("zugferd.pdf").write(to: copy)
        try lib.relink(r.id, to: copy)
        #expect(lib.deleted.isEmpty && lib.records.first?.filePath == copy.standardizedFileURL.path)
    }
}

@Suite struct PaymentTermsTests {
    private func parse(_ s: String) throws -> PaymentTerms { try #require(PaymentTerms.parse(s)) }

    @Test func skontoAndNetInOneLine() throws {
        let t = try parse("Zahlbar innerhalb von 10 Tagen mit 2 % Skonto oder 30 Tage netto.")
        #expect(t.discountPercent == 2 && t.discountDays == 10 && t.netDays == 30 && !t.directDebit)
        #expect(t.discountDeadline(invoiceDate: day(2026, 3, 7)) == day(2026, 3, 17))
        #expect(t.due(invoiceDate: day(2026, 3, 7)) == day(2026, 4, 6))
        #expect(t.discount(on: Decimal(string: "1190.00")) == Decimal(string: "23.80"))
        // The deadline day still counts, the day after does not.
        #expect(t.discountAvailable(invoiceDate: day(2026, 3, 7), on: day(2026, 3, 17)))
        #expect(!t.discountAvailable(invoiceDate: day(2026, 3, 7), on: day(2026, 3, 18)))
    }

    @Test func otherPhrasings() throws {
        let until = try parse("Bei Zahlung bis zum 15.03.2026 gewähren wir 3,5 % Skonto.")
        #expect(until.discountPercent == Decimal(string: "3.5") && until.discountUntil == day(2026, 3, 15))
        // From Jan's invoices: Telekom's debit date, Hassler's OCR'd „4o/o“, Herder's „sofort“.
        let telekom = try parse("Rechnungsbetrag 72,96 €\nDen Betrag von 72,96 € buchen wir am 26.01.2026 ab.")
        #expect(telekom.directDebit && telekom.dueDate == day(2026, 1, 26) && telekom.discountPercent == nil)
        let hassler = try parse("Gläubiger ID: DE49 Zahlungsbedingungen Bankeinzug mit 4o/o Skonto")
        #expect(hassler.directDebit && hassler.discountPercent == 4 && hassler.discountDeadline(invoiceDate: day(2025, 12, 27)) == nil)
        let herder = try parse("Lohnarbeit! Zahlbar sofort ohne Abzug.:Zahlungsbedingung")
        #expect(herder.netDays == 0 && herder.discountPercent == nil)
        let us = try parse("Terms: 2/10 net 30")
        #expect(us.discountPercent == 2 && us.discountDays == 10 && us.netDays == 30)
        let en = try parse("Payment terms: 2% discount if paid within 10 days, due within 30 days")
        #expect(en.discountPercent == 2 && en.discountDays == 10 && en.netDays == 30)
        let x = try parse("#SKONTO#TAGE=14#PROZENT=2.00#")
        #expect(x.discountPercent == 2 && x.discountDays == 14)
    }

    @Test func notPaymentTerms() {
        // A line-item discount, VAT and net amounts are not Skonto or terms.
        #expect(PaymentTerms.parse("Discount 10% on item 4711\nzzgl. 19 % USt.\nNettobetrag 1.000,00 EUR\nRabatt 5 %") == nil)
    }

    @Test func eInvoiceTermsAndTextAreCombined() async throws {
        // The ZUGFeRD fixture's XML has no terms; the visible text may still add them.
        let x = await Extractor(useAppleIntelligence: false).extract(data: try fixture("zugferd.pdf"), fileName: "r.pdf", subject: "", sender: "")
        #expect(x.fields.terms == nil)
        let cii = """
        <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100" xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100" xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
        <rsm:ExchangedDocument><ram:ID>R-1</ram:ID><ram:IssueDateTime><udt:DateTimeString format="102">20260301</udt:DateTimeString></ram:IssueDateTime></rsm:ExchangedDocument>
        <rsm:SupplyChainTradeTransaction><ram:ApplicableHeaderTradeSettlement>
        <ram:SpecifiedTradeSettlementPaymentMeans><ram:TypeCode>58</ram:TypeCode></ram:SpecifiedTradeSettlementPaymentMeans>
        <ram:SpecifiedTradePaymentTerms><ram:Description>#SKONTO#TAGE=7#PROZENT=3.00#</ram:Description>
        <ram:DueDateDateTime><udt:DateTimeString format="102">20260331</udt:DateTimeString></ram:DueDateDateTime></ram:SpecifiedTradePaymentTerms>
        </ram:ApplicableHeaderTradeSettlement></rsm:SupplyChainTradeTransaction></rsm:CrossIndustryInvoice>
        """
        let t = try #require(EInvoice.parse(xml: Data(cii.utf8))?.terms)
        #expect(t.discountPercent == 3 && t.discountDays == 7 && t.dueDate == day(2026, 3, 31) && !t.directDebit)
    }

    @Test func openInvoicesBySkontoDeadline() throws {
        func open(_ terms: String, invoiced: Date, total: String = "120") throws -> InvoiceRecord {
            InvoiceRecord(fields: InvoiceFields(invoiceDate: invoiced, total: Decimal(string: total), terms: try parse(terms)),
                          source: .textRules, reviewReasons: [], filePath: "/x.pdf", origin: MailOrigin(), sha256: terms)
        }
        let today = day(2026, 3, 10)
        // Invoiced earlier but a longer window: its deadline (20.03.) is later than the 14-day one (15.03.).
        let late = try open("14 Tage 3 % Skonto", invoiced: day(2026, 3, 6))
        let soon = try open("Zahlbar innerhalb 7 Tagen mit 2 % Skonto", invoiced: day(2026, 3, 8))
        let gone = try open("7 Tage 2 % Skonto", invoiced: day(2026, 2, 1))
        let debit = try open("Bankeinzug mit 4 % Skonto", invoiced: day(2026, 3, 9))
        #expect(try #require(soon.skontoOffer(on: today)).amount == Decimal(string: "2.4"))
        #expect(try #require(late.skontoOffer(on: today)).daysLeft(from: today) == 10)
        #expect(gone.skontoOffer(on: today) == nil && debit.skontoOffer(on: today) == nil)
        #expect(InvoiceRecord.bySkontoDeadline(soon, late, on: today) == true)
        #expect(InvoiceRecord.bySkontoDeadline(gone, late, on: today) == false)
        #expect(InvoiceRecord.bySkontoDeadline(gone, debit, on: today) == nil)
    }
}

@Suite struct PrintTests {
    @Test func everyInvoiceStartsOnAFreshSheet() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let one = tmp.appendingPathComponent("one.pdf"), three = tmp.appendingPathComponent("three.pdf")
        try fixture("german.pdf").write(to: one)
        let doc = try #require(PDFDocument(data: try fixture("english.pdf")))
        let page = try #require(doc.page(at: 0))
        doc.insert(page.copy() as! PDFPage, at: 1)
        doc.insert(page.copy() as! PDFPage, at: 2)
        #expect(doc.write(to: three))

        // 1 page + blank back, 3 pages + blank, 1 page + blank: each invoice begins on an odd page (a front side).
        let bundle = try #require(PrintBundle.document([one, three, one]))
        #expect(bundle.pageCount == 2 + 4 + 2)
        #expect(bundle.page(at: 1)?.string?.isEmpty ?? true)
        #expect(bundle.page(at: 5)?.string?.isEmpty ?? true)
        #expect(bundle.page(at: 6)?.string?.isEmpty == false)
        #expect(PrintBundle.document([]) == nil)
    }
}

@MainActor @Suite struct SupplierTests {
    @Test func matching() {
        let list = [Supplier(name: "Telekom", aliases: ["Telekom Deutschland GmbH"]), Supplier(name: "Verlag Herder")]
        #expect(list.match("TELEKOM DEUTSCHLAND GmbH") == .exact(list[0]))
        #expect(list.match("Herder GmbH") == .close(list[1]))
        // An OCR slip is close; a different company is not.
        #expect(list.match("Te1ekom") == .close(list[0]))
        #expect(list.match("Papierwerk Lahr") == .none)
    }

    @Test func correctionsAreLearnt() async throws {
        func setup(_ suppliers: [Supplier]) async throws -> (Library, InvoiceRecord) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let lib = Library(directory: tmp.appendingPathComponent("data"))
            lib.settings.rootFolder = tmp.appendingPathComponent("Rechnungen").path
            lib.suppliers = suppliers
            let out = try await lib.ingest(data: try fixture("german.pdf"), fileName: "r.pdf", origin: MailOrigin(),
                                           extractor: Extractor(useAppleIntelligence: false))
            guard case .filed(let r) = out else { throw CancellationError() }
            return (lib, r)
        }
        func setSeller(_ lib: Library, _ r: InvoiceRecord, _ name: String) throws {
            var f = r.fields
            f.seller = name
            try lib.update(r.id, fields: f, status: r.status, paidDate: r.paidDate)
        }

        // A close match taken over: the read spelling now matches by itself.
        var (lib, r) = try await setup([Supplier(name: "Beispiel Druckerej")])
        #expect(r.reviewReasons.contains { $0.hasPrefix("Lieferant ähnlich") })
        try setSeller(lib, r, "Beispiel Druckerej")
        #expect(lib.suppliers.count == 1 && lib.suppliers[0].aliases == ["Beispiel Druckerei GmbH"])
        #expect(lib.suppliers.match("Beispiel Druckerei GmbH") == .exact(lib.suppliers[0]))

        // A supplier the app created for the read name goes away when the invoice moves to an existing one.
        (lib, r) = try await setup([Supplier(name: "Druckhaus Nord")])
        #expect(lib.suppliers.map(\.name).sorted() == ["Beispiel Druckerei GmbH", "Druckhaus Nord"])
        try setSeller(lib, r, "Druckhaus Nord")
        #expect(lib.suppliers.map(\.name) == ["Druckhaus Nord"] && lib.suppliers[0].aliases == ["Beispiel Druckerei GmbH"])

        // A rejected match: its own supplier, and never suggested again.
        (lib, r) = try await setup([Supplier(name: "Beispiel Druckerej")])
        let other = lib.suppliers[0]
        lib.rejectMatch(r.id, supplier: other.id)
        #expect(lib.suppliers.count == 2 && lib.records[0].reviewReasons.allSatisfy { !$0.hasPrefix("Lieferant ähnlich") })
        #expect(lib.suppliers.filter { $0.id == other.id }.match("Beispiel Druckerei GmbH") == .none)
        #expect(lib.suppliers.similarPairs().isEmpty)
    }

    @Test func ownCompanyIsNeverTheSupplier() throws {
        // The receiver's block comes first, as on many invoices; the supplier and its address come after it.
        let text = """
        Witthüs
        Carmen Booz-Kuwert
        Untere Wallbrunnstraße 9
        79539 Lörrach
        Musterbau GmbH
        Industriestr. 12
        77933 Lahr
        Rechnung Nr. MB-2026-7
        Rechnungsdatum: 02.03.2026
        Gesamtbetrag 120,00 EUR
        """
        let f = TextRules.extract(text: text)
        #expect(f.seller == "Musterbau GmbH")
        #expect(f.sellerAddress == "Industriestr. 12, 77933 Lahr")
        #expect(TextRules.address(in: "Beispiel Druckerei GmbH, Hauptstr. 1, 20095 Hamburg") == "Hauptstr. 1, 20095 Hamburg")

        // A name the model or a person gives that is the own company never becomes a supplier.
        let lib = Library(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var own = InvoiceFields(seller: "Witthüs, Carmen Booz-Kuwert")
        var reasons: [String] = []
        lib.matchSupplier(&own, &reasons)
        #expect(own.seller.isEmpty && reasons == [OwnCompany.reviewReason] && lib.suppliers.isEmpty)
        lib.register("WITTHUES")
        #expect(lib.suppliers.isEmpty)
    }

    @Test func renameAndMergeRelabelInvoicesAndFiles() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let lib = Library(directory: tmp.appendingPathComponent("data"))
        lib.settings.rootFolder = tmp.appendingPathComponent("Rechnungen").path
        let ex = Extractor(useAppleIntelligence: false)
        guard case .filed(let a) = try await lib.ingest(data: try fixture("german.pdf"), fileName: "a.pdf", origin: MailOrigin(), extractor: ex)
        else { Issue.record("not filed"); return }
        let first = try #require(lib.suppliers.first { $0.name == a.fields.seller })

        try lib.renameSupplier(first.id, to: "Druckerei Beispiel")
        let renamed = try #require(lib.records.first)
        #expect(renamed.fields.seller == "Druckerei Beispiel")
        #expect(renamed.fileURL.lastPathComponent.contains("Druckerei Beispiel"))
        #expect(FileManager.default.fileExists(atPath: renamed.filePath))
        #expect(renamed.source == a.source)

        // The old spelling on a new invoice now gets the chosen name.
        var f = InvoiceFields(seller: a.fields.seller)
        var reasons: [String] = []
        lib.matchSupplier(&f, &reasons)
        #expect(f.seller == "Druckerei Beispiel")

        let other = Supplier(name: "Druckerei Bspl.")
        lib.suppliers.append(other)
        try lib.mergeSuppliers([first.id, other.id], into: other.id)
        #expect(lib.suppliers.count == 1 && lib.suppliers[0].aliases.contains("Druckerei Beispiel"))
        #expect(lib.records.first?.fields.seller == "Druckerei Bspl.")
    }
}

@Suite struct UpdateTests {
    /// The updater reads the version from the tag and picks the zipped app, not the .dmg next to it.
    @Test func readsLatestRelease() throws {
        let json = """
            {"tag_name": "v12", "body": "- Skonto", "published_at": "2026-11-21T10:00:00Z",
             "html_url": "https://github.com/jan-kuwert/witthues-management/releases/tag/v12",
             "assets": [{"name": "Witthues.dmg", "browser_download_url": "https://example.com/Witthues.dmg"},
                        {"name": "Witthues.zip", "browser_download_url": "https://example.com/Witthues.zip"}]}
            """
        let r = try Updates.parse(Data(json.utf8))
        #expect(r.version == 12 && r.download.lastPathComponent == "Witthues.zip" && r.notes == "- Skonto")
        #expect(Updates.version(tag: "v3") == 3 && Updates.version(tag: "0.1") == nil)
        let noZip = json.replacingOccurrences(of: "Witthues.zip", with: "other.zip")
        #expect(throws: UpdateError.self) { try Updates.parse(Data(noZip.utf8)) }
    }
}
