import Foundation

/// When and how an invoice is to be paid, read from its text or e-invoice data: an early-payment discount
/// (Skonto), the due date and whether the amount is taken by direct debit.
public struct PaymentTerms: Codable, Equatable, Sendable {
    /// Skonto in percent, such as 2 for „2 % Skonto“.
    public var discountPercent: Decimal?
    /// Skonto applies when paid within this many days of the invoice date …
    public var discountDays: Int?
    /// … or until this day (wins over `discountDays`).
    public var discountUntil: Date?
    /// Due this many days after the invoice date; 0 for „zahlbar sofort“ …
    public var netDays: Int?
    /// … or on this day (wins over `netDays`); for direct debit the day it is taken.
    public var dueDate: Date?
    /// The amount is taken from the account (SEPA direct debit, Bankeinzug); nothing to transfer.
    public var directDebit: Bool
    /// The lines the terms were read from, so a person can check them.
    public var text: String

    public init(discountPercent: Decimal? = nil, discountDays: Int? = nil, discountUntil: Date? = nil, netDays: Int? = nil,
                dueDate: Date? = nil, directDebit: Bool = false, text: String = "") {
        self.discountPercent = discountPercent
        self.discountDays = discountDays
        self.discountUntil = discountUntil
        self.netDays = netDays
        self.dueDate = dueDate
        self.directDebit = directDebit
        self.text = text
    }

    public var isEmpty: Bool {
        discountPercent == nil && discountDays == nil && discountUntil == nil && netDays == nil && dueDate == nil && !directDebit
    }

    /// Last day the Skonto may be deducted; nil when the invoice names no deadline.
    public func discountDeadline(invoiceDate: Date?) -> Date? {
        if let discountUntil { return discountUntil }
        guard let discountDays, let invoiceDate else { return nil }
        return Calendar.current.date(byAdding: .day, value: discountDays, to: Calendar.current.startOfDay(for: invoiceDate))
    }

    /// Day the full amount is due.
    public func due(invoiceDate: Date?) -> Date? {
        if let dueDate { return dueDate }
        guard let netDays, let invoiceDate else { return nil }
        return Calendar.current.date(byAdding: .day, value: netDays, to: Calendar.current.startOfDay(for: invoiceDate))
    }

    /// The Skonto in money, rounded to cents.
    public func discount(on total: Decimal?) -> Decimal? {
        guard let total, let discountPercent, discountPercent > 0 else { return nil }
        var value = total * discountPercent / 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }

    /// Whether the Skonto can still be used on `day` (the deadline day itself counts); true without a deadline.
    public func discountAvailable(invoiceDate: Date?, on day: Date = Date()) -> Bool {
        guard discountPercent != nil else { return false }
        guard let deadline = discountDeadline(invoiceDate: invoiceDate) else { return true }
        return Calendar.current.startOfDay(for: day) <= Calendar.current.startOfDay(for: deadline)
    }

    // MARK: - Reading terms from text

    /// „Discount“ alone is often a line-item discount; it counts only next to words about paying early.
    private static func isDiscount(_ clause: String) -> Bool {
        ["skonto", "escompte", "sconto"].contains(where: clause.contains)
            || (clause.contains("discount") && ["pay", "within", "days", "early"].contains(where: clause.contains))
    }
    private static let netWords = ["netto", "ohne abzug", "rein netto", "net ", "net,", "net.", "sans escompte"]
    private static let debitPattern = "lastschrift|bankeinzug|abbuchung|abgebucht|buchen wir .{0,40} ab\\b|wird .{0,40} eingezogen|direct debit|prélèvement"
    private static let duePattern = "\\b(?:zahlbar|fällig|zahlungsziel|zahlungsfrist|zahlung bis|bitte (?:überweisen|zahlen)|buchen wir am|abgebucht am|eingezogen am|due|payable|payment by|à payer|échéance)"

    /// Reads payment terms from invoice text (German, English and French phrasings), including the XRechnung
    /// form „#SKONTO#TAGE=14#PROZENT=2.00#“. Returns nil when the text names none.
    public static func parse(_ text: String) -> PaymentTerms? {
        var t = PaymentTerms()
        var used: [String] = []
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for raw in lines {
            // OCR often reads „%“ as „o/o“ or „°/o“.
            let line = raw.lowercased().replacingOccurrences(of: "°/o", with: "%").replacingOccurrences(of: "o/o", with: "%")
            var hit = false

            // XRechnung: #SKONTO#TAGE=14#PROZENT=2.00#
            if let g = groups("#skonto#tage=(\\d{1,3})#prozent=(\\d{1,2}(?:\\.\\d{1,2})?)", in: line).first {
                t.discountDays = Int(g[0])
                t.discountPercent = Decimal(string: g[1], locale: Locale(identifier: "en_US_POSIX"))
                hit = true
            }
            // US style: 2/10 net 30
            if let g = groups("\\b(\\d{1,2})\\s?/\\s?(\\d{1,3}),?\\s*net\\s*(\\d{1,3})\\b", in: line).first {
                t.discountPercent = Decimal(string: g[0]); t.discountDays = Int(g[1]); t.netDays = Int(g[2])
                hit = true
            }
            if line.range(of: debitPattern, options: .regularExpression) != nil {
                t.directDebit = true
                hit = true
            }
            // One line often holds both: „10 Tage 2 % Skonto, 30 Tage netto“.
            // Split on „,“ only where it is no decimal comma („3,5 %“).
            let clauses = line.replacingOccurrences(of: ",(?!\\d)|;", with: "\u{1F}", options: .regularExpression)
            for clause in clauses.components(separatedBy: "\u{1F}").flatMap({ $0.components(separatedBy: " oder ") })
                .flatMap({ $0.components(separatedBy: " or ") }) {
                if isDiscount(clause) {
                    if t.discountPercent == nil, let p = percent(in: clause) { t.discountPercent = p; hit = true }
                    if t.discountDays == nil, let d = days(in: clause) { t.discountDays = d; hit = true }
                    if t.discountUntil == nil, let d = TextRules.firstDate(in: clause) { t.discountUntil = d; hit = true }
                } else if netWords.contains(where: { (clause + " ").contains($0) })
                            || clause.range(of: duePattern, options: .regularExpression) != nil {
                    if clause.range(of: "sofort|immediately|upon receipt|on receipt|à réception", options: .regularExpression) != nil,
                       t.netDays == nil {
                        t.netDays = 0; hit = true
                    }
                    if t.netDays == nil, let d = days(in: clause) { t.netDays = d; hit = true }
                    if let r = clause.range(of: duePattern, options: .regularExpression),
                       t.dueDate == nil, let d = TextRules.firstDate(in: String(clause[r.lowerBound...])) {
                        t.dueDate = d; hit = true
                    }
                }
            }
            if hit { used.append(raw) }
        }
        guard !t.isEmpty else { return nil }
        t.text = used.prefix(4).joined(separator: "\n")
        return t
    }

    /// Fills in what `other` knows and this one doesn't, such as terms from the PDF text next to e-invoice data.
    public func merged(with other: PaymentTerms?) -> PaymentTerms {
        guard let other else { return self }
        var t = self
        t.discountPercent = t.discountPercent ?? other.discountPercent
        t.discountDays = t.discountDays ?? other.discountDays
        t.discountUntil = t.discountUntil ?? other.discountUntil
        t.netDays = t.netDays ?? other.netDays
        t.dueDate = t.dueDate ?? other.dueDate
        t.directDebit = t.directDebit || other.directDebit
        t.text = [t.text, other.text].filter { !$0.isEmpty }.joined(separator: "\n")
        return t
    }

    private static func percent(in s: String) -> Decimal? {
        guard let g = groups("(\\d{1,2}(?:[.,]\\d{1,2})?)\\s?%", in: s).first,
              let p = Decimal(string: g[0].replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
              p > 0, p < 20 else { return nil }
        return p
    }

    private static func days(in s: String) -> Int? {
        groups("\\b(\\d{1,3})\\s?(?:kalendertage|werktage|tagen|tage|tg\\.?|days|jours)\\b", in: s).first.flatMap { Int($0[0]) }
    }

    private static func groups(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
        }
    }
}

/// Skonto an open invoice still offers: what it saves and the last day to pay (nil when no deadline is named).
public struct SkontoOffer: Equatable, Sendable {
    public var percent: Decimal
    public var amount: Decimal?
    public var deadline: Date?

    /// Days from `day` to the deadline; 0 on the deadline day itself.
    public func daysLeft(from day: Date = Date()) -> Int? {
        deadline.flatMap { Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: day), to: Calendar.current.startOfDay(for: $0)).day }
    }
}

extension InvoiceRecord {
    /// The Skonto this invoice can still save by paying in time. Nil once it is paid, deleted, past the deadline,
    /// or taken by direct debit, where nothing is left to do.
    public func skontoOffer(on day: Date = Date()) -> SkontoOffer? {
        guard stage == .open, !fileMissing, let t = fields.terms, !t.directDebit, let p = t.discountPercent,
              t.discountAvailable(invoiceDate: fields.invoiceDate, on: day) else { return nil }
        return SkontoOffer(percent: p, amount: t.discount(on: fields.total), deadline: t.discountDeadline(invoiceDate: fields.invoiceDate))
    }

    /// Open invoices by Skonto deadline, earliest first, then those with a Skonto but no deadline; the rest keep their order.
    public static func bySkontoDeadline(_ a: InvoiceRecord, _ b: InvoiceRecord, on day: Date = Date()) -> Bool? {
        let x = a.skontoOffer(on: day), y = b.skontoOffer(on: day)
        switch (x, y) {
        case (nil, nil): return nil
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(x), .some(y)):
            switch (x.deadline, y.deadline) {
            case let (.some(dx), .some(dy)): return dx == dy ? nil : dx < dy
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return nil
            }
        }
    }
}
