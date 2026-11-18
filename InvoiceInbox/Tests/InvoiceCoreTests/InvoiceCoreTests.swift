import Foundation
import Testing
@testable import InvoiceCore

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
        #expect(PathTemplate.render("{yy}-{mm}-{dd} {customer} {invoice}", fields: f) == "26-03-07 Telekom Deutschland RE-2026-0815")
        // The archive month comes from the payment date, not the invoice date.
        #expect(PathTemplate.render("{paid_yyyy}-{paid_mm}", fields: f, paidDate: day(2026, 5, 2)) == "2026-05")
        #expect(PathTemplate.unknownVariables(in: "{yyyy}-{month} {customer}") == ["{month}"])
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

        // Paid in May: the default archive folder is the invoice month; the unpaid copy is gone.
        try lib.setPaid(r.id, true, on: day(2026, 5, 2))
        var paid = try #require(lib.records.first)
        #expect(paid.filePath.hasSuffix("OneDrive/Rechnungen/2026-03/26-03-05 Musterlieferant ZF-2026-4711.pdf"))
        #expect(!FileManager.default.fileExists(atPath: r.filePath))

        // With a payment-month template, marking unpaid and paid again moves it under the payment month.
        lib.settings.paidFolder = "Archiv/{paid_yyyy}-{paid_mm}"
        try lib.setPaid(r.id, false)
        #expect(lib.records.first?.filePath == r.filePath)
        try lib.setPaid(r.id, true, on: day(2026, 5, 2))
        paid = try #require(lib.records.first)
        #expect(paid.filePath.hasSuffix("OneDrive/Rechnungen/Archiv/2026-05/26-03-05 Musterlieferant ZF-2026-4711.pdf"))
        #expect(FileManager.default.fileExists(atPath: paid.filePath))
        #expect(!FileManager.default.fileExists(atPath: r.filePath))

        // Records and saved views survive a restart.
        lib.views = [SavedView(name: "Paid 2026", folder: "Archiv", status: .paid, year: 2026)]
        let reopened = Library(directory: tmp.appendingPathComponent("data"))
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
