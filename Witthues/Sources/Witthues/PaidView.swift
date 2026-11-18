import AppKit
import PDFKit
import SwiftUI
import WitthuesCore

/// Paid invoices grouped by the month they were paid in, newest first. Each month can be printed in one go
/// (double-sided, each invoice on its own sheets) and then moved to the archive.
struct PaidList: View {
    @Environment(AppModel.self) private var model
    let records: [InvoiceRecord]
    @Binding var selection: InvoiceRecord.ID?
    /// The month just printed, to offer archiving it.
    @State private var printed: PaidMonth?

    struct PaidMonth: Identifiable, Equatable {
        /// Start of the payment month; nil for invoices without a payment date.
        var month: Date?
        var records: [InvoiceRecord]
        var id: Double { month?.timeIntervalSince1970 ?? -1 }
        var title: String { month?.formatted(.dateTime.month(.wide).year()) ?? "Ohne Zahlungsdatum" }
    }

    private var months: [PaidMonth] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: records) { r in r.paidDate.map { cal.dateInterval(of: .month, for: $0)!.start } }
        return groups.map { PaidMonth(month: $0.key, records: $0.value.sorted { ($0.paidDate ?? .distantPast) > ($1.paidDate ?? .distantPast) }) }
            .sorted { ($0.month ?? .distantPast) > ($1.month ?? .distantPast) }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(months) { m in
                Section {
                    ForEach(m.records) { r in
                        InvoiceRow(record: r, archived: model.library.isArchived(r))
                            .tag(r.id)
                            .contextMenu {
                                if !model.library.isArchived(r) {
                                    Button("Ins Archiv verschieben") { archive([r]) }
                                }
                                Button("Als offen markieren") {
                                    do { try model.library.setPaid(r.id, false) } catch { model.lastError = error.localizedDescription }
                                }
                                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([r.fileURL]) }
                            }
                    }
                } header: {
                    header(m)
                }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("Keine bezahlten Rechnungen", systemImage: "checkmark.circle",
                                       description: Text("Mit „Als bezahlt markieren“ erscheinen Rechnungen hier, nach Zahlungsmonat."))
            }
        }
        .alert("Gedruckte Rechnungen ins Archiv verschieben?", isPresented: Binding(get: { printed != nil }, set: { if !$0 { printed = nil } }),
               presenting: printed) { m in
            Button("Ins Archiv verschieben") { archive(m.records) }
            Button("Später", role: .cancel) {}
        } message: { m in
            let n = unarchived(m).count
            Text("\(n == 1 ? "1 Rechnung" : "\(n) Rechnungen") aus \(m.title) \(n == 1 ? "wird" : "werden") in den Archivordner verschoben. Das geht auch später über „Archivieren“.")
        }
    }

    private func unarchived(_ m: PaidMonth) -> [InvoiceRecord] { m.records.filter { !model.library.isArchived($0) } }

    private func header(_ m: PaidMonth) -> some View {
        let open = unarchived(m).count
        return VStack(alignment: .leading, spacing: 3) {
            Text(m.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
            Text("\(count(m.records.count)) · \(sum(m))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                Text(open == 0 ? "Alle im Archiv" : "\(open) nicht im Archiv")
                    .font(.caption).foregroundStyle(open == 0 ? .secondary : Color.blue).lineLimit(1)
                Spacer(minLength: 4)
                Button { print(m) } label: { Label("Drucken", systemImage: "printer") }
                    .help("Alle Rechnungen dieses Monats beidseitig drucken; jede Rechnung beginnt auf einem neuen Blatt")
                Button { archive(m.records) } label: { Label("Archivieren", systemImage: "archivebox") }
                    .disabled(open == 0)
                    .help("Rechnungen dieses Monats in den Archivordner verschieben")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(.vertical, 4)
    }

    private func count(_ n: Int) -> String { n == 1 ? "1 Rechnung" : "\(n) Rechnungen" }

    /// Total of the month in its most common currency.
    private func sum(_ m: PaidMonth) -> String {
        let withTotal = m.records.filter { $0.fields.total != nil }
        let currency = Dictionary(grouping: withTotal) { $0.fields.currency.isEmpty ? "EUR" : $0.fields.currency.uppercased() }
            .max { $0.value.count < $1.value.count }
        guard let (code, list) = currency else { return "" }
        return MenuBarView.money(list.reduce(Decimal(0)) { $0 + ($1.fields.total ?? 0) }, code)
    }

    private func archive(_ list: [InvoiceRecord]) {
        do { try model.library.archive(list.map(\.id)) } catch { model.lastError = error.localizedDescription }
    }

    /// Prints the month's PDFs as one double-sided job; afterwards the user decides whether to archive them.
    private func print(_ m: PaidMonth) {
        let files = m.records.map(\.fileURL).filter { $0.pathExtension.lowercased() == "pdf" }
        guard let doc = PrintBundle.document(files) else {
            model.lastError = "Keine druckbaren PDFs in \(m.title)."
            return
        }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595, height: 842) // A4
        PMSetDuplex(OpaquePointer(info.pmPrintSettings()), PMDuplexMode(kPMDuplexNoTumble))
        info.updateFromPMPrintSettings()
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        op.jobTitle = "Rechnungen \(m.title)"
        if op.run(), !unarchived(m).isEmpty { printed = m }
    }
}
