import Foundation

/// The data the app needs from one invoice to name and file it.
public struct InvoiceFields: Codable, Equatable, Sendable {
    public var seller: String
    public var buyer: String
    public var invoiceNumber: String
    public var invoiceDate: Date?
    public var total: Decimal?
    public var currency: String

    public init(seller: String = "", buyer: String = "", invoiceNumber: String = "",
                invoiceDate: Date? = nil, total: Decimal? = nil, currency: String = "") {
        self.seller = seller
        self.buyer = buyer
        self.invoiceNumber = invoiceNumber
        self.invoiceDate = invoiceDate
        self.total = total
        self.currency = currency
    }
}

/// Where the fields came from, from most to least reliable.
public enum ExtractionSource: String, Codable, CaseIterable, Sendable {
    case eInvoiceXML = "E-invoice XML"
    case appleIntelligence = "Apple Intelligence"
    case textRules = "Text rules"
    case manual = "Edited by hand"

    /// German name shown in the app. The raw value stays English because it is stored in library.json.
    public var label: String {
        switch self {
        case .eInvoiceXML: return "E-Rechnung (XML)"
        case .appleIntelligence: return "Apple Intelligence"
        case .textRules: return "Textregeln"
        case .manual: return "Von Hand bearbeitet"
        }
    }
}

public enum InvoiceStatus: String, Codable, Sendable {
    case unpaid, paid
}

/// Where an attachment came from.
public struct MailOrigin: Codable, Equatable, Sendable {
    public var subject: String
    public var from: String
    public var date: Date?
    public var messageID: String
    public var attachmentName: String

    public init(subject: String = "", from: String = "", date: Date? = nil, messageID: String = "", attachmentName: String = "") {
        self.subject = subject
        self.from = from
        self.date = date
        self.messageID = messageID
        self.attachmentName = attachmentName
    }
}

public struct InvoiceRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var fields: InvoiceFields
    public var source: ExtractionSource
    /// Reasons a person should check the fields; empty when they look right.
    public var reviewReasons: [String]
    public var status: InvoiceStatus
    public var paidDate: Date?
    public var filePath: String
    public var origin: MailOrigin
    public var sha256: String
    public var importedAt: Date
    public var fileMissing: Bool = false

    public var needsReview: Bool { !reviewReasons.isEmpty }
    public var fileURL: URL { URL(fileURLWithPath: filePath) }

    public init(id: UUID = UUID(), fields: InvoiceFields, source: ExtractionSource, reviewReasons: [String],
                status: InvoiceStatus = .unpaid, paidDate: Date? = nil, filePath: String,
                origin: MailOrigin, sha256: String, importedAt: Date = Date()) {
        self.id = id
        self.fields = fields
        self.source = source
        self.reviewReasons = reviewReasons
        self.status = status
        self.paidDate = paidDate
        self.filePath = filePath
        self.origin = origin
        self.sha256 = sha256
        self.importedAt = importedAt
    }
}

/// An attachment the app decided is not an invoice. Kept so the user can import it anyway.
public struct SkippedAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var origin: MailOrigin
    public var reason: String
    public var storedPath: String
    public var skippedAt: Date

    public init(id: UUID = UUID(), origin: MailOrigin, reason: String, storedPath: String, skippedAt: Date = Date()) {
        self.id = id
        self.origin = origin
        self.reason = reason
        self.storedPath = storedPath
        self.skippedAt = skippedAt
    }
}

/// How far the mail checker got in one mailbox.
public struct MailboxCursor: Codable, Equatable, Sendable {
    public var uidValidity: UInt32
    public var lastUID: UInt32

    public init(uidValidity: UInt32, lastUID: UInt32) {
        self.uidValidity = uidValidity
        self.lastUID = lastUID
    }
}

/// One archive filter, such as "Firma enthält Telekom" or "Betrag größer als 100".
public struct FilterRule: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case text, number, date, status, source, flag }

    public enum Field: String, Codable, CaseIterable, Sendable {
        case status, needsCheck, source, company, invoiceNumber, fileName, folder, buyer, sender, subject, currency, amount, invoiceDate, paidDate

        public var label: String {
            switch self {
            case .status: return "Status"
            case .needsCheck: return "Zu prüfen"
            case .source: return "Gelesen aus"
            case .company: return "Firma"
            case .invoiceNumber: return "Rechnungsnummer"
            case .fileName: return "Dateiname"
            case .folder: return "Ordner"
            case .buyer: return "Empfänger"
            case .sender: return "Absender"
            case .subject: return "Mail-Betreff"
            case .currency: return "Währung"
            case .amount: return "Betrag"
            case .invoiceDate: return "Rechnungsdatum"
            case .paidDate: return "Bezahlt am"
            }
        }

        public var symbol: String {
            switch self {
            case .status: return "checkmark.circle"
            case .needsCheck: return "exclamationmark.bubble"
            case .source: return "doc.text.magnifyingglass"
            case .company: return "building.2"
            case .invoiceNumber: return "number"
            case .fileName: return "doc"
            case .folder: return "folder"
            case .buyer: return "person"
            case .sender: return "envelope"
            case .subject: return "text.bubble"
            case .currency: return "banknote"
            case .amount: return "eurosign.circle"
            case .invoiceDate: return "calendar"
            case .paidDate: return "calendar.badge.checkmark"
            }
        }

        public var kind: Kind {
            switch self {
            case .status: return .status
            case .needsCheck: return .flag
            case .source: return .source
            case .amount: return .number
            case .invoiceDate, .paidDate: return .date
            default: return .text
            }
        }

        /// Conditions offered for this field; the first is the default.
        public var ops: [Op] {
            switch kind {
            case .text: return [.contains, .notContains, .equals, .notEquals]
            case .number: return [.greater, .less, .equals, .notEquals]
            case .date: return [.equals, .notEquals, .before, .after]
            case .status, .source, .flag: return [.equals, .notEquals]
            }
        }
    }

    public enum Op: String, Codable, Sendable {
        case contains, notContains, equals, notEquals, greater, less, before, after

        /// Excludes what it names.
        public var isNegative: Bool { self == .notContains || self == .notEquals }

        /// The opposite condition, for "Ausschließen" / "Einschließen".
        public var negated: Op? {
            switch self {
            case .contains: return .notContains
            case .notContains: return .contains
            case .equals: return .notEquals
            case .notEquals: return .equals
            default: return nil
            }
        }

        public func label(for field: Field) -> String {
            switch (field.kind, self) {
            case (.flag, .equals): return "ja"
            case (.flag, _): return "nein"
            case (.date, .equals): return "liegt in"
            case (.date, .notEquals): return "liegt nicht in"
            case (_, .contains): return "enthält"
            case (_, .notContains): return "enthält nicht"
            case (_, .equals): return "ist"
            case (_, .notEquals): return "ist nicht"
            case (_, .greater): return "größer als"
            case (_, .less): return "kleiner als"
            case (_, .before): return "vor"
            case (_, .after): return "nach"
            }
        }
    }

    public var id: UUID
    public var field: Field
    public var op: Op
    /// Text, amount, "2026" / "2026-03" / "2026-03-07", or the raw status or source.
    public var value: String

    public init(id: UUID = UUID(), _ field: Field, _ op: Op? = nil, _ value: String? = nil) {
        self.id = id
        self.field = field
        self.op = op ?? field.ops[0]
        switch field.kind {
        case .status: self.value = value ?? InvoiceStatus.paid.rawValue
        case .source: self.value = value ?? ExtractionSource.eInvoiceXML.rawValue
        case .flag: self.value = value ?? "true"
        default: self.value = value ?? ""
        }
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespaces) }

    /// Has a value to filter by. Rules still being typed are ignored, so they never hide or add rows.
    public var isComplete: Bool {
        switch field.kind {
        case .status, .source, .flag: return true
        case .number: return Self.number(trimmed) != nil
        case .text, .date: return !trimmed.isEmpty
        }
    }

    /// The condition and value in words, such as "enthält „Telekom“".
    public var summary: String {
        let opText = op.label(for: field)
        guard isComplete else { return opText + " …" }
        switch field.kind {
        case .flag: return opText
        case .status: return opText + " " + (value == InvoiceStatus.paid.rawValue ? "Bezahlt" : "Offen")
        case .source: return opText + " " + (ExtractionSource(rawValue: value)?.label ?? value)
        case .text: return "\(opText) „\(trimmed)“"
        case .date where op == .before || op == .after:
            return opText + " " + (Self.date(from: trimmed)?.formatted(date: .numeric, time: .omitted) ?? trimmed)
        case .number, .date: return opText + " " + trimmed
        }
    }

    /// Whether an invoice passes this rule. `folder` is the invoice's folder relative to the main folder.
    public func matches(_ r: InvoiceRecord, folder: String) -> Bool {
        let v = trimmed
        switch field.kind {
        case .flag:
            let flagged = r.needsReview || r.fileMissing
            return op == .equals ? flagged : !flagged
        case .status: return (r.status.rawValue == v) != op.isNegative
        case .source: return (r.source.rawValue == v) != op.isNegative
        case .text:
            let t = text(of: r, folder: folder)
            switch op {
            case .contains, .notContains: return t.localizedCaseInsensitiveContains(v) != op.isNegative
            default: return (t.trimmingCharacters(in: .whitespaces).compare(v, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame) != op.isNegative
            }
        case .number:
            guard let n = Self.number(v) else { return true }
            // An invoice without an amount is neither bigger nor smaller; only exclusions keep it.
            guard let total = r.fields.total else { return op.isNegative }
            let a = NSDecimalNumber(decimal: total).doubleValue
            switch op {
            case .greater: return a > n
            case .less: return a < n
            default: return (abs(a - n) < 0.005) != op.isNegative
            }
        case .date:
            guard let d = field == .invoiceDate ? r.fields.invoiceDate : r.paidDate else { return op.isNegative }
            let day = Self.dayString(d)
            switch op {
            case .before: return day < v
            case .after: return day > v
            default: return day.hasPrefix(v) != op.isNegative
            }
        }
    }

    private func text(of r: InvoiceRecord, folder: String) -> String {
        switch field {
        case .company: return r.fields.seller
        case .invoiceNumber: return r.fields.invoiceNumber
        case .fileName: return r.fileURL.lastPathComponent
        case .folder: return folder
        case .buyer: return r.fields.buyer
        case .sender: return r.origin.from
        case .subject: return r.origin.subject
        case .currency: return r.fields.currency.isEmpty ? "EUR" : r.fields.currency.uppercased()
        default: return ""
        }
    }

    /// "1.234,56", "1234.56" or "50 €" as a number.
    static func number(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: " ", with: "")
        if t.contains(",") { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        return Double(t)
    }

    /// "2026-03-07", the form date rules store and compare.
    public static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(from s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// A named set of archive filters the user saved. Starred views appear in the sidebar.
public struct SavedView: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var starred: Bool
    /// Folder relative to the main folder; nil means every folder.
    public var folder: String?
    /// Filter rules. All must match, or with matchAny at least one.
    public var rules: [FilterRule]
    public var matchAny: Bool
    public var search: String
    /// SF Symbol shown in the sidebar; nil for views saved before icons existed.
    public var icon: String?
    /// A starred folder from the folder browser rather than a named filter; listed under "Archiv".
    public var isFolder: Bool?

    public init(id: UUID = UUID(), name: String = "", starred: Bool = true, folder: String? = nil, rules: [FilterRule] = [],
                matchAny: Bool = false, search: String = "", icon: String? = nil, isFolder: Bool? = nil) {
        self.id = id
        self.name = name
        self.starred = starred
        self.folder = folder
        self.rules = rules
        self.matchAny = matchAny
        self.search = search
        self.icon = icon
        self.isFolder = isFolder
    }

    private enum CodingKeys: String, CodingKey { case id, name, starred, folder, rules, matchAny, search, icon, isFolder }
    /// Filters of the first version, before rules existed; turned into rules when read.
    private enum LegacyKeys: String, CodingKey { case status, year, onlyNeedsCheck }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? true
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        matchAny = try c.decodeIfPresent(Bool.self, forKey: .matchAny) ?? false
        search = try c.decodeIfPresent(String.self, forKey: .search) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder)
        if let rules = try c.decodeIfPresent([FilterRule].self, forKey: .rules) {
            self.rules = rules
        } else {
            let old = try decoder.container(keyedBy: LegacyKeys.self)
            var r: [FilterRule] = []
            switch try old.decodeIfPresent(String.self, forKey: .status) {
            case "Paid": r.append(FilterRule(.status, .equals, InvoiceStatus.paid.rawValue))
            case "Unpaid": r.append(FilterRule(.status, .equals, InvoiceStatus.unpaid.rawValue))
            default: break
            }
            if let y = try old.decodeIfPresent(Int.self, forKey: .year), y != 0 { r.append(FilterRule(.invoiceDate, .equals, String(y))) }
            if try old.decodeIfPresent(Bool.self, forKey: .onlyNeedsCheck) == true { r.append(FilterRule(.needsCheck, .equals)) }
            rules = r
        }
    }

    /// Whether an invoice passes the rules (not the folder or search, which the archive applies itself).
    public func matches(_ r: InvoiceRecord, folder: String) -> Bool {
        let active = rules.filter(\.isComplete)
        guard !active.isEmpty else { return true }
        return matchAny ? active.contains { $0.matches(r, folder: folder) } : active.allSatisfy { $0.matches(r, folder: folder) }
    }

    /// The sidebar icon.
    public var symbol: String { icon ?? (isFolder == true ? "folder" : "star.fill") }

    /// True when both views filter the same way, whatever their name or star.
    public func sameFilters(as other: SavedView) -> Bool {
        folder == other.folder && rules == other.rules && matchAny == other.matchAny && search == other.search
    }
}
