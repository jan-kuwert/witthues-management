import Foundation

/// Names and places invoice files according to the settings' templates.
public struct FileOrganizer: Sendable {
    public var settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public var rootURL: URL { URL(fileURLWithPath: settings.rootFolder, isDirectory: true) }

    public func folder(for fields: InvoiceFields, status: InvoiceStatus, paidDate: Date?) -> URL {
        let template = status == .paid ? settings.paidFolder : settings.unpaidFolder
        let relative = PathTemplate.render(template, fields: fields, paidDate: paidDate)
        // Templates may use "/" for subfolders, such as "{yyyy}/{yyyy}-{mm}".
        return relative.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != ".." }
            .reduce(rootURL) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    public func baseName(for fields: InvoiceFields, paidDate: Date?) -> String {
        let name = PathTemplate.render(settings.fileName, fields: fields, paidDate: paidDate)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((name.isEmpty ? "Invoice" : name).prefix(180))
    }

    /// Where a file with these fields belongs, relative to the main folder, for previews.
    public func relativePath(for fields: InvoiceFields, status: InvoiceStatus, paidDate: Date?, ext: String = "pdf") -> String {
        let folder = folder(for: fields, status: status, paidDate: paidDate).path
        let rel = folder.hasPrefix(rootURL.path) ? String(folder.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : folder
        return (rel.isEmpty ? "" : rel + "/") + baseName(for: fields, paidDate: paidDate) + "." + ext
    }

    /// Writes new data into its folder, creating folders as needed. Never overwrites another file.
    public func save(_ data: Data, ext: String, fields: InvoiceFields, status: InvoiceStatus = .unpaid, paidDate: Date? = nil) throws -> URL {
        let target = try uniqueURL(fields: fields, status: status, paidDate: paidDate, ext: ext, current: nil)
        try data.write(to: target, options: .withoutOverwriting)
        return target
    }

    /// Moves an existing file to where its fields and status say it belongs. Returns the new location.
    public func place(_ current: URL, fields: InvoiceFields, status: InvoiceStatus, paidDate: Date?) throws -> URL {
        let ext = current.pathExtension.isEmpty ? "pdf" : current.pathExtension
        let target = try uniqueURL(fields: fields, status: status, paidDate: paidDate, ext: ext, current: current)
        guard target.standardizedFileURL != current.standardizedFileURL else { return current }
        try FileManager.default.moveItem(at: current, to: target)
        // A matching e-invoice XML filed next to the PDF moves with it.
        let xml = current.deletingPathExtension().appendingPathExtension("xml")
        if ext.lowercased() == "pdf", FileManager.default.fileExists(atPath: xml.path) {
            try? FileManager.default.moveItem(at: xml, to: target.deletingPathExtension().appendingPathExtension("xml"))
        }
        return target
    }

    private func uniqueURL(fields: InvoiceFields, status: InvoiceStatus, paidDate: Date?, ext: String, current: URL?) throws -> URL {
        let dir = folder(for: fields, status: status, paidDate: paidDate)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = baseName(for: fields, paidDate: paidDate)
        for n in 1...999 {
            let name = n == 1 ? base : "\(base) (\(n))"
            let url = dir.appendingPathComponent(name).appendingPathExtension(ext)
            if url.standardizedFileURL == current?.standardizedFileURL { return url }
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
