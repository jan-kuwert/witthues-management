import Foundation

/// Public helpers for the app's edit form.
public enum InvoiceText {
    /// Parses "1.234,56", "1,234.56", "175,5" or "175.5".
    public static func amount(_ s: String) -> Decimal? { TextRules.parseAmount(s) }

    /// "175,50": two decimals with a comma and no grouping, so the text reads back as the same amount.
    public static func editableAmount(_ d: Decimal) -> String {
        d.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "de_DE")))
    }
}

/// Rule-based extraction from invoice text in German, English, French, Spanish, Italian and Dutch.
/// Used when there is no e-invoice XML: as the only extractor when Apple Intelligence is
/// unavailable, and as a cross-check of the model's answer when it is.
public enum TextRules {
    static let invoiceWords = ["rechnung", "invoice", "facture", "factura", "fattura", "factuur", "faktura",
                               "receipt", "quittung", "gutschrift", "credit note", "tax invoice", "bill"]
    static let notInvoiceWords = ["angebot", "quotation", "offer", "lieferschein", "delivery note", "agb",
                                  "terms and conditions", "allgemeine geschäftsbedingungen", "widerruf",
                                  "datenschutz", "privacy policy", "newsletter", "auftragsbestätigung",
                                  "order confirmation", "packing slip"]

    /// Whether a document looks like an invoice from its text, attachment name and mail subject.
    public static func looksLikeInvoice(text: String, fileName: String, subject: String) -> (Bool, String) {
        let name = fileName.lowercased()
        if let word = notInvoiceWords.first(where: { name.contains($0) }) {
            return (false, "Dateiname enthält „\(word)“")
        }
        let head = String(text.lowercased().prefix(1500))
        let haystack = name + " " + subject.lowercased() + " " + head
        guard invoiceWords.contains(where: { haystack.contains($0) }) else {
            return (false, "Kein Hinweis auf eine Rechnung in Dateiname, Betreff oder erster Seite")
        }
        if let word = notInvoiceWords.first(where: { head.prefix(300).contains($0) }),
           !invoiceWords.contains(where: { head.prefix(300).contains($0) }) {
            return (false, "Dokument beginnt mit „\(word)“")
        }
        let f = extract(text: text)
        guard !f.invoiceNumber.isEmpty || f.total != nil else {
            return (false, "Weder Rechnungsnummer noch Betrag gefunden")
        }
        return (true, "")
    }

    public static func extract(text: String) -> InvoiceFields {
        var f = InvoiceFields()
        f.invoiceNumber = invoiceNumber(in: text) ?? ""
        f.invoiceDate = invoiceDate(in: text)
        if let (amount, currency) = total(in: text) {
            f.total = amount
            f.currency = currency
        }
        if f.currency.isEmpty { f.currency = currencyCode(in: text) ?? "" }
        f.seller = companyLine(in: text) ?? ""
        f.sellerAddress = address(in: text)
        return f
    }

    /// The first postal address near the top that is not the own one: „Street 1, 12345 City“ on one line, or a
    /// street line followed by a postcode line.
    static func address(in text: String) -> String? {
        let lines = text.split(separator: "\n").prefix(30).map { $0.trimmingCharacters(in: .whitespaces) }
        let postcode = "(?:^|,\\s*|\\s)\\d{4,5}\\s+[A-ZÄÖÜ][a-zäöüß]+"
        for (i, line) in lines.enumerated() where line.count <= 90 && line.range(of: postcode, options: .regularExpression) != nil {
            let previous = i > 0 ? lines[i - 1] : ""
            if OwnCompany.isOwn(line) || OwnCompany.isOwn(previous) { continue }
            // „Firma GmbH, Hauptstr. 1, 20095 Hamburg“: the parts after the company name.
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count > 1 {
                let kept = parts.filter { p in !legalForms.contains { (" " + p.lowercased()).contains($0) } }
                if kept.count > 1 { return kept.joined(separator: ", ") }
            }
            // Street on the line before: it has a house number and is no company or label line.
            if previous.range(of: "\\d", options: .regularExpression) != nil, previous.count <= 60, !previous.contains(":") {
                return previous + ", " + line
            }
        }
        return nil
    }

    static let legalForms = ["gmbh", " ag", " se", " kg", " ug", "e.k.", " inc", " llc", " ltd", "limited", " b.v.", " bv",
                             " s.a.", " sas", " sarl", " s.r.l.", " srl", " s.l.", " ab", " aps", " a/s", " oy", "sp. z o.o.", " corp"]

    /// The first line near the top that names a company by its legal form, usually the letterhead.
    static func companyLine(in text: String) -> String? {
        for raw in text.split(separator: "\n").prefix(25) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // The own name in the address block is the receiver, never the supplier.
            if OwnCompany.isOwn(line) { continue }
            let lower = " " + line.lowercased()
            guard line.count <= 70, line.rangeOfCharacter(from: .letters) != nil else { continue }
            if legalForms.contains(where: { form in
                lower.hasSuffix(form) || lower.hasSuffix(form + ".") || lower.contains(form + " ") || lower.contains(form + ",")
            }) {
                // "Firma GmbH, Hauptstr. 1, Hamburg" or "Firma GmbH * Hauptstr. 1" → "Firma GmbH"
                return line.split(whereSeparator: { ",*|•·".contains($0) }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? line
            }
        }
        return nil
    }

    static let numberLabels = [
        "rechnungsnummer", "rechnungs-nr\\.?", "rechnungsnr\\.?", "rechnung nr\\.?", "rechnung-nr\\.?", "rechnung",
        "belegnummer", "beleg-nr\\.?", "invoice number", "invoice no\\.?", "invoice #", "invoice id", "invoice",
        "facture n°", "facture no", "n° de facture", "numéro de facture", "facture",
        "número de factura", "nº factura", "factura n[º°o]\\.?", "factura",
        "numero fattura", "fattura n\\.?", "factuurnummer", "factuur nr\\.?", "fakturanummer", "bill number",
    ]

    static func invoiceNumber(in text: String) -> String? {
        for label in numberLabels {
            // Label, optional "number"/":"/"#", then a token with at least one digit.
            // Digit groups split by single spaces, as Telekom prints "19 5683 1701 2621", count as one number.
            let pattern = "(?i)\\b\(label)\\s*(?:nummer|number|no\\.?|nr\\.?|n°|#)?\\s*[:#.]?\\s*((?:\\d{1,6} ){1,5}\\d{1,6}(?![\\d.,])|[A-Z0-9][A-Z0-9/._-]{2,30})"
            for match in matches(pattern, in: text) {
                let candidate = match.trimmingCharacters(in: CharacterSet(charactersIn: ".-_/"))
                if candidate.rangeOfCharacter(from: .decimalDigits) != nil, !looksLikeDate(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    static let dateLabels = ["rechnungsdatum", "invoice date", "date of issue", "issue date", "issued on", "date de facture",
                             "fecha de factura", "fecha", "data fattura", "factuurdatum", "belegdatum", "datum", "date"]

    static func invoiceDate(in text: String) -> Date? {
        for label in dateLabels {
            guard let range = text.range(of: label, options: [.caseInsensitive]) else { continue }
            let window = String(text[range.upperBound...].prefix(60))
            if let d = firstDate(in: window) { return d }
        }
        return firstDate(in: String(text.prefix(2000)))
    }

    static let months: [String: Int] = {
        var m: [String: Int] = [:]
        let lists = [
            ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"],
            ["januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember"],
            ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
            ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
            ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"],
            ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"],
        ]
        for list in lists { for (i, name) in list.enumerated() { m[name] = i + 1; m[String(name.prefix(3))] = m[String(name.prefix(3))] ?? i + 1 } }
        m["jän"] = 1; m["mär"] = 3; m["sept"] = 9
        return m
    }()

    static func firstDate(in s: String) -> Date? {
        var best: (String.Index, Date)?
        func consider(_ r: Range<String.Index>, _ y: Int, _ m: Int, _ d: Int) {
            var year = y
            if year < 100 { year += 2000 }
            guard (1...12).contains(m), (1...31).contains(d), (2000...2100).contains(year),
                  let date = Calendar.current.date(from: DateComponents(year: year, month: m, day: d)) else { return }
            if best == nil || r.lowerBound < best!.0 { best = (r.lowerBound, date) }
        }
        // 2026-03-07
        for (r, g) in groups("\\b(20\\d{2})-(\\d{1,2})-(\\d{1,2})\\b", in: s) { consider(r, Int(g[0])!, Int(g[1])!, Int(g[2])!) }
        // 07.03.2026, 07/03/2026, 07-03-26 (day first, as in Europe)
        for (r, g) in groups("\\b(\\d{1,2})[./-](\\d{1,2})[./-](\\d{2,4})\\b", in: s) {
            var d = Int(g[0])!, m = Int(g[1])!
            // US style 03/27/2026: only when the first number can't be a day-first month.
            if m > 12 && d <= 12 { swap(&d, &m) }
            consider(r, Int(g[2])!, m, d)
        }
        // 7. März 2026, 7 March 2026
        for (r, g) in groups("(?i)\\b(\\d{1,2})\\.?\\s+([a-zäéûè]{3,10})\\.?\\s+(20\\d{2})\\b", in: s) {
            if let m = months[g[1].lowercased()] { consider(r, Int(g[2])!, m, Int(g[0])!) }
        }
        // March 7, 2026
        for (r, g) in groups("(?i)\\b([a-z]{3,9})\\.?\\s+(\\d{1,2}),?\\s+(20\\d{2})\\b", in: s) {
            if let m = months[g[0].lowercased()] { consider(r, Int(g[2])!, m, Int(g[1])!) }
        }
        return best?.1
    }

    static let totalLabels = ["gesamtbetrag", "rechnungsbetrag", "zu zahlender betrag", "zahlbetrag", "endbetrag",
                              "bruttobetrag", "summe brutto", "gesamtsumme", "gesamt brutto", "amount due", "total due",
                              "balance due", "grand total", "total amount", "invoice total", "total incl", "total (incl",
                              "montant ttc", "total ttc", "importe total", "totale fattura", "totale", "totaalbedrag",
                              "te betalen", "summe", "gesamt", "total", "betrag"]

    static func total(in text: String) -> (Decimal, String)? {
        let lower = text.lowercased()
        for label in totalLabels {
            // Several lines can carry the label ("Total" for net and gross); the last one is usually the gross amount.
            var found: (Decimal, String)?
            var searchStart = lower.startIndex
            while let r = lower.range(of: label, range: searchStart..<lower.endIndex) {
                let window = String(text[r.upperBound...].prefix(80))
                if let amount = firstAmount(in: window) { found = amount }
                searchStart = r.upperBound
            }
            if let found { return found }
        }
        return nil
    }

    static func firstAmount(in s: String) -> (Decimal, String)? {
        let pattern = "(€|EUR|USD|\\$|£|GBP|CHF)?\\s*(-?\\d{1,3}(?:[.,' ]\\d{3})*(?:[.,]\\d{2})|-?\\d+[.,]\\d{2})\\s*(€|EUR|USD|\\$|£|GBP|CHF)?"
        guard let (_, g) = groups(pattern, in: s, allowEmpty: true).first else { return nil }
        let symbol = !g[0].isEmpty ? g[0] : g[2]
        let currency = ["€": "EUR", "$": "USD", "£": "GBP"][symbol] ?? symbol
        return parseAmount(g[1]).map { ($0, currency) }
    }

    /// "1.234,56", "1,234.56", "1 234,56", "175,5" or "175.5": `.` and `,` both work as decimal separator. The last one is
    /// the decimal separator when one or two digits follow it, or when the other sign comes before it
    /// ("1.234,567"); otherwise ("1.250") all of them group thousands.
    static func parseAmount(_ raw: String) -> Decimal? {
        var s = raw.filter { !$0.isWhitespace && $0 != "'" && $0 != "€" }
        if let last = s.lastIndex(where: { $0 == "," || $0 == "." }) {
            let decimals = String(s[s.index(after: last)...])
            let head = String(s[..<last])
            let otherSign: Character = s[last] == "," ? "." : ","
            if (1...2).contains(decimals.count) || head.contains(otherSign) {
                s = head.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "") + "." + decimals
            } else {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
            }
        }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func currencyCode(in text: String) -> String? {
        if text.contains("€") || text.contains("EUR") { return "EUR" }
        for code in ["USD", "GBP", "CHF", "SEK", "DKK", "PLN"] where text.contains(code) { return code }
        if text.contains("£") { return "GBP" }
        if text.contains("$") { return "USD" }
        return nil
    }

    static func looksLikeDate(_ s: String) -> Bool {
        s.range(of: "^\\d{1,4}[./-]\\d{1,2}[./-]\\d{1,4}$", options: .regularExpression) != nil
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        groups(pattern, in: s).compactMap { $0.1.first }
    }

    private static func groups(_ pattern: String, in s: String, allowEmpty: Bool = false) -> [(Range<String.Index>, [String])] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let r = Range(m.range, in: s) else { return nil }
            var out: [String] = []
            for i in 1..<m.numberOfRanges {
                if let gr = Range(m.range(at: i), in: s) { out.append(String(s[gr])) } else if allowEmpty { out.append("") } else { return nil }
            }
            return (r, out)
        }
    }
}
