import Foundation
import Security

public struct AppSettings: Codable, Equatable, Sendable {
    /// Main folder, usually inside the OneDrive folder. Templates below are relative to it.
    public var rootFolder = ""
    /// Open invoices.
    public var unpaidFolder = "00 Offen"
    /// Paid invoices waiting to be printed and archived.
    public var paidFolder = "01 Bezahlt"
    /// Archived invoices, by default one folder per invoice month.
    public var archiveFolder = "{yyyy}-{mm}"
    public var fileName = "{yy}-{mm}-{dd} {company} {invoice}"

    public var imapHost = "secureimap.t-online.de"
    public var imapPort = 993
    public var useTLS = true
    public var username = ""
    public var mailbox = "INBOX"
    /// On the first check, mails received since this date are read.
    public var importSince = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

    public var checkOnLaunch = true
    public var checkIntervalMinutes = 5
    public var useAppleIntelligence = true

    public init() {}

    // "paidFolder" in older settings files was the archive folder; it keeps that key.
    enum CodingKeys: String, CodingKey {
        case rootFolder, unpaidFolder, paidFolder = "paidWaitingFolder", archiveFolder = "paidFolder", fileName
        case imapHost, imapPort, useTLS, username, mailbox, importSince, checkOnLaunch, checkIntervalMinutes, useAppleIntelligence
    }

    /// Missing keys keep their defaults, so settings from older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ value: inout T) throws {
            if let v = try c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        try get(.rootFolder, &rootFolder)
        try get(.unpaidFolder, &unpaidFolder)
        try get(.paidFolder, &paidFolder)
        try get(.archiveFolder, &archiveFolder)
        try get(.fileName, &fileName)
        try get(.imapHost, &imapHost)
        try get(.imapPort, &imapPort)
        try get(.useTLS, &useTLS)
        try get(.username, &username)
        try get(.mailbox, &mailbox)
        try get(.importSince, &importSince)
        try get(.checkOnLaunch, &checkOnLaunch)
        try get(.checkIntervalMinutes, &checkIntervalMinutes)
        try get(.useAppleIntelligence, &useAppleIntelligence)
    }

    /// The folder template for a stage.
    public func folderTemplate(_ stage: Stage) -> String {
        switch stage {
        case .open: return unpaidFolder
        case .paid: return paidFolder
        case .archived: return archiveFolder
        }
    }

    /// Replaces earlier variable names such as {customer} with {company} in all templates.
    public mutating func migrateTemplates() {
        unpaidFolder = PathTemplate.migrated(unpaidFolder)
        paidFolder = PathTemplate.migrated(paidFolder)
        archiveFolder = PathTemplate.migrated(archiveFolder)
        fileName = PathTemplate.migrated(fileName)
    }

    public var isMailConfigured: Bool { !imapHost.isEmpty && !username.isEmpty }
    public var isFolderConfigured: Bool { !rootFolder.isEmpty }

    /// Example fields for previews in the settings screen.
    public static let sampleFields = InvoiceFields(
        seller: "Telekom Deutschland GmbH", buyer: "Witthüs", invoiceNumber: "RE-2026-0815",
        invoiceDate: Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7)),
        total: Decimal(string: "119.00"), currency: "EUR")
}

/// The mailbox password, kept in the login keychain.
public enum Keychain {
    static let service = "Witthues IMAP"

    /// What reading the password found. `denied` means it is stored but macOS did not hand it out, for example
    /// because the access prompt was declined after an update; asking again shows the prompt again.
    public enum Lookup: Equatable, Sendable {
        case found(String)
        case missing
        case denied
    }

    /// Reads the password; macOS may ask the user to allow access first.
    public static func lookup(for account: String) -> Lookup {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let p = String(data: data, encoding: .utf8), !p.isEmpty else { return .missing }
            return .found(p)
        case errSecItemNotFound: return .missing
        default: return .denied
        }
    }

    public static func password(for account: String) -> String? {
        if case .found(let p) = lookup(for: account) { return p }
        return nil
    }

    /// Stores the password (an empty one removes it). Returns false when macOS refused.
    @discardableResult
    public static func setPassword(_ password: String, for account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        guard !password.isEmpty else {
            let s = SecItemDelete(base as CFDictionary)
            return s == errSecSuccess || s == errSecItemNotFound
        }
        let data = Data(password.utf8)
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        // Not stored yet, or stored by an older build this one may not change: replace it.
        if updated != errSecItemNotFound { SecItemDelete(base as CFDictionary) }
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
