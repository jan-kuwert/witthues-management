import CoreGraphics
import Foundation

/// Reads structured e-invoices: ZUGFeRD / Factur-X (CII XML embedded in a PDF), XRechnung and
/// Peppol UBL or CII sent as a separate XML file.
public enum EInvoice {
    /// Files embedded in a PDF (name and data), from the catalog's EmbeddedFiles name tree.
    public static func embeddedFiles(inPDF data: Data) -> [(name: String, data: Data)] {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider),
              let catalog = doc.catalog else { return [] }
        var names: CGPDFDictionaryRef?
        var embedded: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
              CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded else { return [] }
        var result: [(String, Data)] = []
        collect(nameTree: embedded, into: &result, depth: 0)
        return result
    }

    private static func collect(nameTree node: CGPDFDictionaryRef, into result: inout [(String, Data)], depth: Int) {
        guard depth < 16 else { return }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &array), let array {
            let count = CGPDFArrayGetCount(array)
            var i = 0
            while i + 1 < count {
                var nameRef: CGPDFStringRef?
                var spec: CGPDFDictionaryRef?
                var name = "attachment"
                if CGPDFArrayGetString(array, i, &nameRef), let nameRef,
                   let s = CGPDFStringCopyTextString(nameRef) { name = s as String }
                if CGPDFArrayGetDictionary(array, i + 1, &spec), let spec, let data = fileData(spec) {
                    var fileName: CGPDFStringRef?
                    if CGPDFDictionaryGetString(spec, "UF", &fileName) || CGPDFDictionaryGetString(spec, "F", &fileName),
                       let fileName, let s = CGPDFStringCopyTextString(fileName) { name = s as String }
                    result.append((name, data))
                }
                i += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for i in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, i, &kid), let kid { collect(nameTree: kid, into: &result, depth: depth + 1) }
            }
        }
    }

    private static func fileData(_ spec: CGPDFDictionaryRef) -> Data? {
        var ef: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(spec, "EF", &ef), let ef else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(ef, "F", &stream) || CGPDFDictionaryGetStream(ef, "UF", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
        return data as Data
    }

    /// The invoice XML embedded in a PDF, if any.
    public static func xml(inPDF data: Data) -> Data? {
        embeddedFiles(inPDF: data)
            .filter { $0.name.lowercased().hasSuffix(".xml") }
            .first { parse(xml: $0.data) != nil }?.data
    }

    /// Parses CII (ZUGFeRD, Factur-X, XRechnung CII) or UBL (XRechnung UBL, Peppol) invoice XML.
    public static func parse(xml data: Data) -> InvoiceFields? {
        guard let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement(), let rootName = root.localName else { return nil }
        func first(_ paths: [String]) -> String {
            for path in paths {
                let xpath = path.split(separator: "/").map { $0 == "" ? "" : "*[local-name()='\($0)']" }.joined(separator: "/")
                if let node = try? root.nodes(forXPath: xpath).first,
                   let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
            return ""
        }
        var f = InvoiceFields()
        switch rootName {
        case "CrossIndustryInvoice":
            f.invoiceNumber = first(["ExchangedDocument/ID"])
            f.invoiceDate = parseDate(first(["ExchangedDocument/IssueDateTime/DateTimeString"]))
            let agreement = "SupplyChainTradeTransaction/ApplicableHeaderTradeAgreement/"
            f.seller = first([agreement + "SellerTradeParty/Name", agreement + "SellerTradeParty/SpecifiedLegalOrganization/TradingBusinessName"])
            f.buyer = first([agreement + "BuyerTradeParty/Name"])
            let a = agreement + "SellerTradeParty/PostalTradeAddress/"
            f.sellerAddress = Self.joinAddress(first([a + "LineOne"]), first([a + "PostcodeCode"]), first([a + "CityName"]))
            let settlement = "SupplyChainTradeTransaction/ApplicableHeaderTradeSettlement/"
            f.currency = first([settlement + "InvoiceCurrencyCode"])
            let sum = settlement + "SpecifiedTradeSettlementHeaderMonetarySummation/"
            f.total = parseAmount(first([sum + "GrandTotalAmount", sum + "DuePayableAmount"]))
            let terms = settlement + "SpecifiedTradePaymentTerms/"
            var t = PaymentTerms.parse(first([terms + "Description"])) ?? PaymentTerms()
            t.dueDate = t.dueDate ?? parseDate(first([terms + "DueDateDateTime/DateTimeString"]))
            t.discountPercent = t.discountPercent ?? parseAmount(first([terms + "ApplicableTradePaymentDiscountTerms/CalculationPercent"]))
            t.discountDays = t.discountDays ?? Int(first([terms + "ApplicableTradePaymentDiscountTerms/BasisPeriodMeasure"])
                .components(separatedBy: ".")[0])
            // Payment means 59 is SEPA direct debit.
            t.directDebit = t.directDebit || first([settlement + "SpecifiedTradeSettlementPaymentMeans/TypeCode"]) == "59"
            f.terms = t.isEmpty ? nil : t
        case "Invoice", "CreditNote":
            f.invoiceNumber = first(["ID"])
            f.invoiceDate = parseDate(first(["IssueDate"]))
            f.seller = first(["AccountingSupplierParty/Party/PartyLegalEntity/RegistrationName",
                              "AccountingSupplierParty/Party/PartyName/Name"])
            f.buyer = first(["AccountingCustomerParty/Party/PartyLegalEntity/RegistrationName",
                             "AccountingCustomerParty/Party/PartyName/Name"])
            let a = "AccountingSupplierParty/Party/PostalAddress/"
            f.sellerAddress = Self.joinAddress(first([a + "StreetName"]), first([a + "PostalZone"]), first([a + "CityName"]))
            f.currency = first(["DocumentCurrencyCode"])
            f.total = parseAmount(first(["LegalMonetaryTotal/TaxInclusiveAmount", "LegalMonetaryTotal/PayableAmount"]))
            var t = PaymentTerms.parse(first(["PaymentTerms/Note"])) ?? PaymentTerms()
            t.dueDate = t.dueDate ?? parseDate(first(["DueDate", "PaymentMeans/PaymentDueDate"]))
            t.directDebit = t.directDebit || first(["PaymentMeans/PaymentMeansCode"]) == "59"
            f.terms = t.isEmpty ? nil : t
        default:
            return nil
        }
        return f.invoiceNumber.isEmpty && f.seller.isEmpty ? nil : f
    }

    /// „Hauptstr. 1, 20095 Hamburg“; nil when nothing is given.
    static func joinAddress(_ street: String, _ postcode: String, _ city: String) -> String? {
        let place = [postcode, city].filter { !$0.isEmpty }.joined(separator: " ")
        let s = [street, place].filter { !$0.isEmpty }.joined(separator: ", ")
        return s.isEmpty ? nil : s
    }

    static func parseDate(_ s: String) -> Date? {
        // DateFormatter reads "" as 1 Jan 2000.
        guard !s.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyyMMdd", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: String(s.prefix(format.count))) { return d }
        }
        return nil
    }

    static func parseAmount(_ s: String) -> Decimal? {
        s.isEmpty ? nil : Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }
}
