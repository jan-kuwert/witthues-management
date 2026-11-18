import Foundation

/// Fills `{variable}` placeholders in folder and file name templates.
///
/// Variables: {yyyy} {yy} {mm} {dd} from the invoice date, {paid_yyyy} {paid_yy} {paid_mm} {paid_dd}
/// from the payment date, {company} (the company that sent the invoice), {buyer},
/// {invoice} (invoice number), {total}, {currency}. {customer} and {seller} are older names for {company}.
public enum PathTemplate {
    public static let variables: [(name: String, help: String)] = [
        ("{yyyy}", "Rechnungsjahr, 2026"),
        ("{yy}", "Rechnungsjahr, 26"),
        ("{mm}", "Rechnungsmonat, 03"),
        ("{dd}", "Rechnungstag, 07"),
        ("{paid_yyyy}", "Jahr, in dem bezahlt wurde"),
        ("{paid_mm}", "Monat, in dem bezahlt wurde"),
        ("{paid_dd}", "Tag, an dem bezahlt wurde"),
        ("{company}", "Firma, die die Rechnung geschickt hat, ohne „GmbH“ usw."),
        ("{buyer}", "Empfänger der Rechnung"),
        ("{invoice}", "Rechnungsnummer"),
        ("{total}", "Bruttobetrag, 119.00"),
        ("{currency}", "Währung, EUR"),
    ]

    /// Earlier names for {company}, still filled in so old templates keep working.
    static let legacyNames = ["{customer}": "{company}", "{seller}": "{company}"]

    /// The template with earlier variable names replaced by the current ones.
    public static func migrated(_ template: String) -> String {
        legacyNames.reduce(template) { $0.replacingOccurrences(of: $1.key, with: $1.value, options: .caseInsensitive) }
    }

    public static func render(_ template: String, fields: InvoiceFields, paidDate: Date? = nil,
                              calendar: Calendar = .current) -> String {
        var values: [String: String] = [:]
        func addDate(_ date: Date?, prefix: String) {
            guard let date else {
                for key in ["yyyy", "yy", "mm", "dd"] { values[prefix + key] = key.uppercased() }
                return
            }
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            values[prefix + "yyyy"] = String(format: "%04d", c.year ?? 0)
            values[prefix + "yy"] = String(format: "%02d", (c.year ?? 0) % 100)
            values[prefix + "mm"] = String(format: "%02d", c.month ?? 0)
            values[prefix + "dd"] = String(format: "%02d", c.day ?? 0)
        }
        addDate(fields.invoiceDate, prefix: "")
        addDate(paidDate, prefix: "paid_")
        let seller = cleanName(fields.seller)
        values["company"] = seller.isEmpty ? "Unbekannt" : seller
        values["customer"] = values["company"]
        values["seller"] = values["company"]
        values["buyer"] = cleanName(fields.buyer)
        values["invoice"] = fields.invoiceNumber.isEmpty ? "ohne-Nummer" : fields.invoiceNumber
        values["total"] = fields.total.map { String(format: "%.2f", NSDecimalNumber(decimal: $0).doubleValue) } ?? ""
        values["currency"] = fields.currency

        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            let key = rest[rest.index(after: open)..<close].lowercased()
            if let value = values[key] {
                out += sanitize(value)
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    /// Unknown `{names}` in a template, so the settings screen can warn about typos.
    public static func unknownVariables(in template: String) -> [String] {
        let known = Set(variables.map { $0.name.lowercased() }).union(legacyNames.keys)
        var unknown: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let name = String(rest[open...close]).lowercased()
            if !known.contains(name) { unknown.append(name) }
            rest = rest[rest.index(after: close)...]
        }
        return unknown
    }

    /// Removes legal suffixes so "Deutsche Telekom AG" becomes "Deutsche Telekom".
    static func cleanName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [" GmbH & Co. KG", " GmbH & Co KG", " GmbH & Co.KG", " GmbH", " AG", " SE", " KG", " UG (haftungsbeschränkt)", " UG",
                        " e.K.", " Inc.", " Inc", " LLC", " Ltd.", " Ltd", " Limited", " B.V.", " BV", " S.A.", " SAS",
                        " S.r.l.", " Srl", " AB", " ApS", " A/S", " Oy", " sp. z o.o.", " Corp.", " Corporation"]
        var changed = true
        while changed {
            changed = false
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
            for suffix in suffixes where s.lowercased().hasSuffix(suffix.lowercased()) && s.count > suffix.count {
                s = String(s.dropLast(suffix.count))
                changed = true
            }
        }
        return s
    }

    /// Characters that macOS or OneDrive reject in a file or folder name.
    static func sanitize(_ value: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#%").union(.controlCharacters).union(.newlines)
        let parts = value.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }
        return parts.joined().trimmingCharacters(in: .whitespaces)
    }
}
