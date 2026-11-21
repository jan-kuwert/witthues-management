import CoreGraphics
import Foundation
import PDFKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct Extraction: Sendable {
    public var isInvoice: Bool
    public var notInvoiceReason: String
    public var fields: InvoiceFields
    public var source: ExtractionSource
    public var reviewReasons: [String]
    /// Set when the attachment was XML: the app files it next to a PDF of the same name if one exists.
    public var xmlOnly: Bool
}

/// Turns one attachment into invoice fields: e-invoice XML first, then PDF text or OCR,
/// read by Apple Intelligence when available and by text rules otherwise.
public struct Extractor: Sendable {
    public var useAppleIntelligence: Bool

    public init(useAppleIntelligence: Bool = true) {
        self.useAppleIntelligence = useAppleIntelligence
    }

    public static var appleIntelligenceStatus: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return "Verfügbar"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence in den Systemeinstellungen einschalten"
        case .unavailable(.modelNotReady): return "Modell wird noch geladen"
        case .unavailable(.deviceNotEligible): return "Dieser Mac unterstützt Apple Intelligence nicht"
        case .unavailable(let other): return "Nicht verfügbar (\(other))"
        }
        #else
        return "Von diesem macOS nicht unterstützt"
        #endif
    }

    public func extract(data: Data, fileName: String, subject: String, sender: String) async -> Extraction {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".xml") {
            if let f = EInvoice.parse(xml: data) {
                return Extraction(isInvoice: true, notInvoiceReason: "", fields: f, source: .eInvoiceXML,
                                  reviewReasons: Self.check(f), xmlOnly: true)
            }
            return notInvoice("XML-Datei ist keine E-Rechnung")
        }
        guard lower.hasSuffix(".pdf") || data.starts(with: Array("%PDF".utf8)) else {
            return notInvoice("Kein PDF")
        }
        if let xml = EInvoice.xml(inPDF: data), var f = EInvoice.parse(xml: xml) {
            // Skonto is often only in the printed text, not in the XML.
            f.terms = Self.terms(xml: f.terms, text: Self.pdfText(data))
            return Extraction(isInvoice: true, notInvoiceReason: "", fields: f, source: .eInvoiceXML,
                              reviewReasons: Self.check(f), xmlOnly: false)
        }

        var text = Self.pdfText(data)
        var reasons: [String] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
            text = await Self.ocr(data)
            reasons.append("Gescanntes PDF, per Texterkennung gelesen")
        }
        var (looksLike, why) = TextRules.looksLikeInvoice(text: text, fileName: fileName, subject: subject)
        // Phone photos of receipts often carry a poor text layer from the scanning app; Apple's OCR reads them better.
        if !looksLike, reasons.isEmpty {
            let ocrText = await Self.ocr(data)
            let retry = TextRules.looksLikeInvoice(text: ocrText, fileName: fileName, subject: subject)
            if retry.0 {
                text = ocrText
                (looksLike, why) = retry
                reasons.append("Textebene unlesbar, per Texterkennung gelesen")
            }
        }
        let rules = TextRules.extract(text: text)

        var fields = rules
        var source = ExtractionSource.textRules
        var modelSaysInvoice: Bool?
        #if canImport(FoundationModels)
        if useAppleIntelligence, SystemLanguageModel.default.isAvailable {
            do {
                let m = try await Self.askModel(text: text, fileName: fileName, subject: subject, sender: sender)
                modelSaysInvoice = m.isInvoice
                fields = Self.merge(model: m, rules: rules, text: text, reasons: &reasons)
                source = .appleIntelligence
            } catch {
                reasons.append("Apple Intelligence fehlgeschlagen: \(error.localizedDescription)")
            }
        }
        #endif
        // The model decides only when both agree it's unclear; keyword rules catch the model's misses.
        let isInvoice = looksLike || modelSaysInvoice == true
        if !isInvoice { return notInvoice(modelSaysInvoice == false ? "Apple Intelligence: keine Rechnung. \(why)" : why) }
        // The model sometimes names the receiver; the rules skip the own name.
        if OwnCompany.isOwn(fields.seller) { fields.seller = rules.seller }
        fields.sellerAddress = fields.sellerAddress ?? rules.sellerAddress

        if fields.seller.isEmpty, !Self.senderName(sender).isEmpty {
            fields.seller = Self.senderName(sender)
            reasons.append("Firmenname aus dem Absender der Mail übernommen")
        } else if source == .textRules, !fields.seller.isEmpty {
            reasons.append("Firmenname aus dem Briefkopf geraten")
        }
        reasons += Self.check(fields)
        fields.terms = PaymentTerms.parse(text)
        return Extraction(isInvoice: true, notInvoiceReason: "", fields: fields, source: source,
                          reviewReasons: reasons, xmlOnly: false)
    }

    static func terms(xml: PaymentTerms?, text: String) -> PaymentTerms? {
        let fromText = PaymentTerms.parse(text)
        return xml.map { $0.merged(with: fromText) } ?? fromText
    }

    /// The supplier's address in a filed file (embedded XML first, then the PDF text; no OCR).
    public static func sellerAddress(ofFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "xml" { return EInvoice.parse(xml: data)?.sellerAddress }
        return EInvoice.xml(inPDF: data).flatMap(EInvoice.parse)?.sellerAddress ?? TextRules.address(in: pdfText(data))
    }

    /// Payment terms of a filed file (PDF text and embedded XML, no OCR), for invoices read before terms existed.
    public static func terms(ofFile url: URL) -> PaymentTerms? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "xml" { return EInvoice.parse(xml: data)?.terms }
        return terms(xml: EInvoice.xml(inPDF: data).flatMap(EInvoice.parse)?.terms, text: pdfText(data))
    }

    private func notInvoice(_ reason: String) -> Extraction {
        Extraction(isInvoice: false, notInvoiceReason: reason, fields: InvoiceFields(), source: .textRules, reviewReasons: [], xmlOnly: false)
    }

    /// Reasons a person should look at the fields.
    static func check(_ f: InvoiceFields) -> [String] {
        var r: [String] = []
        if f.invoiceNumber.isEmpty { r.append("Keine Rechnungsnummer gefunden") }
        if f.invoiceDate == nil { r.append("Kein Rechnungsdatum gefunden") }
        if f.seller.isEmpty { r.append("Kein Firmenname gefunden") }
        if f.total == nil { r.append("Kein Betrag gefunden") }
        if let d = f.invoiceDate, d > Date().addingTimeInterval(86400 * 2) { r.append("Rechnungsdatum liegt in der Zukunft") }
        if let d = f.invoiceDate, d < Date().addingTimeInterval(-86400 * 365 * 3) { r.append("Rechnungsdatum ist älter als 3 Jahre") }
        return r
    }

    /// "Telekom Deutschland GmbH <rechnung@telekom.de>" → "Telekom Deutschland GmbH"; a bare address → "telekom".
    static func senderName(_ from: String) -> String {
        if let lt = from.firstIndex(of: "<") {
            let name = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
        }
        let address = from.trimmingCharacters(in: CharacterSet(charactersIn: " <>\""))
        guard let at = address.firstIndex(of: "@") else { return address }
        let parts = address[address.index(after: at)...].split(separator: ".")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : String(address[address.index(after: at)...])
    }

    public static func pdfText(_ data: Data) -> String {
        guard let doc = PDFDocument(data: data) else { return "" }
        var pages: [String] = []
        for i in 0..<min(doc.pageCount, 4) { pages.append(doc.page(at: i)?.string ?? "") }
        return pages.joined(separator: "\n")
    }

    /// OCR of the first pages with Apple Vision, for scanned invoices without a text layer.
    public static func ocr(_ data: Data) async -> String {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else { return "" }
        var out: [String] = []
        for n in 1...min(doc.numberOfPages, 3) {
            guard let page = doc.page(at: n), let image = render(page) else { continue }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US"),
                                            Locale.Language(identifier: "fr-FR"), Locale.Language(identifier: "es-ES"),
                                            Locale.Language(identifier: "it-IT"), Locale.Language(identifier: "nl-NL")]
            request.usesLanguageCorrection = true
            if let lines = try? await request.perform(on: image) {
                out.append(lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2.5
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    #if canImport(FoundationModels)
    static func askModel(text: String, fileName: String, subject: String, sender: String) async throws -> ModelInvoice {
        let session = LanguageModelSession(instructions: """
            You read business documents received by email and extract invoice data. \
            Copy names and numbers exactly as printed. Leave a field empty if it is not in the document.
            """)
        // The on-device model has a 4,096-token window shared by instructions, schema, document and answer.
        let document = String(text.prefix(5000))
        let prompt = """
            Email from: \(sender)
            Email subject: \(subject)
            File name: \(fileName)

            Document text:
            \(document)
            """
        return try await session.respond(to: prompt, generating: ModelInvoice.self,
                                         options: GenerationOptions(sampling: .greedy)).content
    }

    static func merge(model m: ModelInvoice, rules: InvoiceFields, text: String, reasons: inout [String]) -> InvoiceFields {
        var f = InvoiceFields()
        f.seller = m.seller.trimmingCharacters(in: .whitespacesAndNewlines)
        if f.seller.isEmpty { f.seller = rules.seller }
        f.buyer = m.buyer.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = m.invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactText = text.replacingOccurrences(of: " ", with: "")
        // A number the model wrote that isn't in the text is likely made up; prefer the rules' answer then.
        if !number.isEmpty, compactText.contains(number.replacingOccurrences(of: " ", with: "")) {
            f.invoiceNumber = number
        } else {
            f.invoiceNumber = rules.invoiceNumber
            if !number.isEmpty { reasons.append("Rechnungsnummer „\(number)“ von Apple Intelligence steht nicht im Dokument") }
        }
        if !rules.invoiceNumber.isEmpty, f.invoiceNumber != rules.invoiceNumber {
            reasons.append("Rechnungsnummer unklar: „\(f.invoiceNumber)“ oder „\(rules.invoiceNumber)“")
        }
        f.invoiceDate = EInvoice.parseDate(m.invoiceDate) ?? rules.invoiceDate
        if let a = f.invoiceDate, let b = rules.invoiceDate, !Calendar.current.isDate(a, inSameDayAs: b) {
            reasons.append("Rechnungsdatum unklar")
        }
        f.total = TextRules.parseAmount(m.total) ?? rules.total
        if let a = f.total, let b = rules.total, a != b { reasons.append("Betrag unklar") }
        f.currency = m.currency.count == 3 ? m.currency.uppercased() : rules.currency
        return f
    }
    #endif
}

#if canImport(FoundationModels)
@Generable
struct ModelInvoice {
    @Guide(description: "Is this document an invoice, bill, receipt or credit note? False for offers, terms, delivery notes, order confirmations, newsletters.")
    var isInvoice: Bool
    @Guide(description: "Company that issued the invoice and wants to be paid")
    var seller: String
    @Guide(description: "Company or person the invoice is addressed to")
    var buyer: String
    @Guide(description: "Invoice number exactly as printed")
    var invoiceNumber: String
    @Guide(description: "Invoice date as YYYY-MM-DD")
    var invoiceDate: String
    @Guide(description: "Gross total to pay, like 1234.56")
    var total: String
    @Guide(description: "ISO currency code like EUR")
    var currency: String
}
#endif
