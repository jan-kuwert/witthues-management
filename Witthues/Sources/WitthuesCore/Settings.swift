import Foundation
import Security

public struct AppSettings: Codable, Equatable, Sendable {
    /// Main folder, usually inside the OneDrive folder. Templates below are relative to it.
    public var rootFolder = ""
    public var unpaidFolder = "00 Offen"
    public var paidFolder = "{yyyy}-{mm}"
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

    /// Replaces earlier variable names such as {customer} with {company} in all templates.
    public mutating func migrateTemplates() {
        unpaidFolder = PathTemplate.migrated(unpaidFolder)
        paidFolder = PathTemplate.migrated(paidFolder)
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

    public static func password(for account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
