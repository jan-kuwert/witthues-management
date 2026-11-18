import Foundation
import WitthuesCore

// witthues-cli extract <file.pdf|file.xml|mail.eml>...   prints what the app would extract and the file name it would use
// witthues-cli import <files…>                            files them like mail attachments (set WITTHUES_HOME for a demo library)
// witthues-cli check                                      runs one mail check with the app's saved settings

let args = Array(CommandLine.arguments.dropFirst())
let organizer = FileOrganizer(settings: AppSettings())
let extractor = Extractor(useAppleIntelligence: ProcessInfo.processInfo.environment["NO_AI"] == nil)
print("Apple Intelligence: \(Extractor.appleIntelligenceStatus)")

func show(_ x: Extraction, name: String) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    print("\n== \(name)")
    guard x.isInvoice else { print("   not an invoice: \(x.notInvoiceReason)"); return }
    let f = x.fields
    print("   source:   \(x.source.rawValue)")
    print("   seller:   \(f.seller)")
    print("   buyer:    \(f.buyer)")
    print("   number:   \(f.invoiceNumber)")
    print("   date:     \(f.invoiceDate.map(df.string) ?? "-")")
    print("   total:    \(f.total.map { "\($0)" } ?? "-") \(f.currency)")
    print("   file:     \(organizer.relativePath(for: f, status: .unpaid, paidDate: nil))")
    if !x.reviewReasons.isEmpty { print("   check:    \(x.reviewReasons.joined(separator: "; "))") }
}

@MainActor func checkMail() async throws -> CheckSummary {
    let library = Library()
    return try await MailChecker.check(library: library, password: Keychain.password(for: library.settings.username) ?? "") { print($0.text) }
}

@MainActor func importFiles(_ paths: [String]) async throws {
    let library = Library()
    for path in paths {
        let url = URL(fileURLWithPath: path)
        let outcome = try await library.ingest(data: try Data(contentsOf: url), fileName: url.lastPathComponent,
                                               origin: MailOrigin(subject: "Imported", attachmentName: url.lastPathComponent),
                                               extractor: extractor)
        print(url.lastPathComponent, "→", outcome)
    }
}

switch args.first {
case "extract":
    for path in args.dropFirst() {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { print("cannot read \(path)"); continue }
        if url.pathExtension.lowercased() == "eml" {
            let mail = MIME.parse(data)
            for a in mail.attachments {
                show(await extractor.extract(data: a.data, fileName: a.fileName, subject: mail.subject, sender: mail.from),
                     name: "\(url.lastPathComponent) → \(a.fileName)")
            }
        } else {
            show(await extractor.extract(data: data, fileName: url.lastPathComponent, subject: "", sender: ""), name: url.lastPathComponent)
        }
    }
case "import":
    // Files PDFs or XMLs into the app's library, as if they arrived by mail.
    try await importFiles(Array(args.dropFirst()))
case "check":
    print(try await checkMail().text)
default:
    print("usage: witthues-cli extract <files…> | witthues-cli import <files…> | witthues-cli check")
}
