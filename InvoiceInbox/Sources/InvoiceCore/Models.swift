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
public enum ExtractionSource: String, Codable, Sendable {
    case eInvoiceXML = "E-invoice XML"
    case appleIntelligence = "Apple Intelligence"
    case textRules = "Text rules"
    case manual = "Edited by hand"
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
