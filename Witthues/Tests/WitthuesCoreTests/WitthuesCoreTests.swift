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

    @Test(arguments: [("1.234,56", "1234.56"), ("1,234.56", "1234.56"), ("1 234,56", "1234.56"), ("12,50", "12.50"), ("12.50", "12.50")])
    func amounts(raw: String, expected: String) {
        #expect(TextRules.parseAmount(raw) == Decimal(string: expected, locale: Locale(identifier: "en_US_POSIX")))
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
        lib.settings.paidFolder = "Archiv/{paid_yyyy}-{paid_mm}"
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
        let r = try #require(try await lib.ingestPaid(data: png as Data, fileName: "IMG_0001.png", paidOn: day(2026, 4, 9), origin: MailOrigin(), extractor: ex))
        #expect(r.status == .paid)
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
        #expect(try await lib.ingestPaid(data: png as Data, fileName: "IMG_0001.png", paidOn: day(2026, 4, 9), origin: MailOrigin(), extractor: ex) == nil)
        #expect(lib.records.count == 1)
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

        // Paid in May: the file stays until it is archived, then goes to the invoice month by default.
        try lib.setPaid(r.id, true, on: day(2026, 5, 2))
        var paid = try #require(lib.records.first)
        #expect(paid.filePath == r.filePath && paid.status == .paid && !lib.isArchived(paid))
        try lib.archive([r.id])
        paid = try #require(lib.records.first)
        #expect(lib.isArchived(paid))
        #expect(paid.filePath.hasSuffix("OneDrive/Rechnungen/2026-03/26-03-05 Musterlieferant ZF-2026-4711.pdf"))
        #expect(!FileManager.default.fileExists(atPath: r.filePath))

        // With a payment-month template, marking unpaid and paid again moves it under the payment month.
        lib.settings.paidFolder = "Archiv/{paid_yyyy}-{paid_mm}"
        try lib.setPaid(r.id, false)
        #expect(lib.records.first?.filePath == r.filePath)
        try lib.setPaid(r.id, true, on: day(2026, 5, 2))
        #expect(lib.records.first?.filePath == r.filePath)
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
        #expect(reopened.settings.paidFolder == "Archiv/{paid_yyyy}-{paid_mm}")
        #expect(reopened.records.first?.status == .paid)
        #expect(reopened.records.first?.filePath == paid.filePath)
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
        let s = try await lib.indexFolders([root], extractor: ex)
        #expect(s.messages == 3)
        #expect(s.filed == 2)
        #expect(s.skipped == 1)
        // Not moved or renamed; status from the folder it lies in.
        #expect(lib.records.first { $0.filePath == open.standardizedFileURL.path }?.status == .unpaid)
        #expect(lib.records.first { $0.filePath == paid.standardizedFileURL.path }?.status == .paid)
        #expect(fm.fileExists(atPath: open.path) && fm.fileExists(atPath: paid.path))
        // A second run adds nothing.
        #expect(try await lib.indexFolders([root], extractor: ex).filed == 0)
        #expect(lib.records.count == 2)
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
