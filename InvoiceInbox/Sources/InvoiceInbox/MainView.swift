import InvoiceCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case unpaid, paid, review, all, skipped
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var sidebar: SidebarItem = .unpaid
    @State private var selection: InvoiceRecord.ID?
    @State private var search = ""
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebar) {
                Section("Invoices") {
                    row(.unpaid, "Unpaid", "tray.full", model.library.records.filter { $0.status == .unpaid }.count)
                    row(.paid, "Paid", "archivebox", model.library.records.filter { $0.status == .paid }.count)
                    row(.review, "Needs a look", "exclamationmark.bubble", model.library.records.filter(\.needsReview).count)
                    row(.all, "All", "doc.on.doc", model.library.records.count)
                }
                Section("Mail") {
                    row(.skipped, "Not invoices", "tray.and.arrow.down", model.library.skipped.count)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                StatusLine()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .padding(8)
            }
        } content: {
            Group {
                if sidebar == .skipped {
                    SkippedList()
                } else {
                    InvoiceList(records: filtered, selection: $selection)
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            .searchable(text: $search, placement: .toolbar, prompt: "Company, number, amount")
        } detail: {
            if let id = selection, sidebar != .skipped, model.library.records.contains(where: { $0.id == id }) {
                InvoiceDetail(id: id).id(id)
            } else {
                EmptyDetail()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.checkNow()
                } label: {
                    Label("Check mail", systemImage: "arrow.clockwise")
                }
                .disabled(model.isChecking)
                .help("Check for new invoices now (⌘R)")
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL { urls.append(url) }
                    else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                            let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                await model.importFiles(urls)
            }
            return true
        }
        .overlay {
            if dropTargeted {
                Label("Drop PDFs or e-invoice XML to file them", systemImage: "square.and.arrow.down")
                    .font(.title3)
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .onChange(of: sidebar) { selection = nil }
    }

    private func row(_ item: SidebarItem, _ title: String, _ icon: String, _ count: Int) -> some View {
        Label(title, systemImage: icon)
            .badge(count)
            .tag(item)
    }

    private var filtered: [InvoiceRecord] {
        var list = model.library.records
        switch sidebar {
        case .unpaid: list = list.filter { $0.status == .unpaid }
        case .paid: list = list.filter { $0.status == .paid }
        case .review: list = list.filter(\.needsReview)
        case .all, .skipped: break
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { r in
                [r.fields.seller, r.fields.buyer, r.fields.invoiceNumber, r.origin.subject, r.origin.from,
                 r.fields.total.map { "\($0)" } ?? ""].contains { $0.lowercased().contains(q) }
            }
        }
        return list.sorted { ($0.fields.invoiceDate ?? $0.importedAt) > ($1.fields.invoiceDate ?? $1.importedAt) }
    }
}

struct EmptyDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).foregroundStyle(.secondary)
            if !model.library.settings.isFolderConfigured || !model.library.settings.isMailConfigured {
                Text("Choose the main folder and enter the mail account to start.")
                    .foregroundStyle(.secondary)
                Button("Open Settings") { openSettings() }.buttonStyle(.glassProminent)
            } else {
                Text("Select an invoice, or drop PDFs here.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InvoiceList: View {
    @Environment(AppModel.self) private var model
    let records: [InvoiceRecord]
    @Binding var selection: InvoiceRecord.ID?

    var body: some View {
        List(records, selection: $selection) { r in
            InvoiceRow(record: r)
                .tag(r.id)
                .contextMenu {
                    Button(r.status == .paid ? "Mark as unpaid" : "Mark as paid") {
                        do { try model.library.setPaid(r.id, r.status != .paid) } catch { model.lastError = error.localizedDescription }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.fileURL]) }
                    Divider()
                    Button("Remove from list (keeps the file)", role: .destructive) { model.library.remove(r.id) }
                }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No invoices", systemImage: "tray", description: Text("New invoices from mail appear here."))
            }
        }
    }
}

struct InvoiceRow: View {
    let record: InvoiceRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(record.fields.seller.isEmpty ? "Unknown company" : record.fields.seller)
                        .fontWeight(.medium).lineLimit(1)
                    Spacer()
                    if let total = record.fields.total {
                        Text(MenuBarView.money(total, record.fields.currency)).monospacedDigit()
                    }
                }
                HStack {
                    Text(record.fields.invoiceNumber.isEmpty ? "No number" : record.fields.invoiceNumber)
                    Spacer()
                    Text(record.fields.invoiceDate?.formatted(date: .numeric, time: .omitted) ?? "No date")
                }
                .font(.caption).foregroundStyle(.secondary)
                if record.fileMissing {
                    Text("File was moved or deleted").font(.caption).foregroundStyle(.red)
                } else if record.needsReview {
                    Text(record.reviewReasons.first ?? "").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var icon: String {
        if record.fileMissing { return "questionmark.folder" }
        if record.needsReview { return "exclamationmark.circle.fill" }
        return record.status == .paid ? "checkmark.circle.fill" : "circle"
    }

    private var color: Color {
        if record.fileMissing { return .red }
        if record.needsReview { return .orange }
        return record.status == .paid ? .green : .secondary
    }
}

/// PDF on the left half, editable fields and actions on a glass panel on the right.
struct InvoiceDetail: View {
    @Environment(AppModel.self) private var model
    let id: InvoiceRecord.ID
    @State private var fields = InvoiceFields()
    @State private var totalText = ""
    @State private var hasDate = true
    @State private var paidDate = Date()

    private var record: InvoiceRecord? { model.library.records.first { $0.id == id } }

    var body: some View {
        if let record {
            HSplitView {
                PDFPreview(url: record.fileURL)
                    .frame(minWidth: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(record)
                        if !record.reviewReasons.isEmpty { reviewBox(record) }
                        form
                        filing(record)
                        origin(record)
                    }
                    .padding(16)
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
            .onAppear { load(record) }
        }
    }

    private func header(_ r: InvoiceRecord) -> some View {
        HStack {
            Label(r.source.rawValue, systemImage: r.source == .eInvoiceXML ? "checkmark.seal.fill" : r.source == .appleIntelligence ? "apple.intelligence" : "text.viewfinder")
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.tint(r.source == .eInvoiceXML ? .green.opacity(0.3) : .clear), in: .capsule)
            Spacer()
            Text(r.status == .paid ? "Paid" : "Unpaid")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.tint(r.status == .paid ? .green.opacity(0.35) : .orange.opacity(0.35)), in: .capsule)
        }
    }

    private func reviewBox(_ r: InvoiceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Please check", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            ForEach(r.reviewReasons, id: \.self) { Text("• \($0)").font(.callout) }
            Button("Looks right") { model.library.markReviewed(id) }.buttonStyle(.glass)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 14))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Company (sender)", text: $fields.seller)
            field("Invoice number", text: $fields.invoiceNumber)
            HStack {
                Toggle("Date", isOn: $hasDate).toggleStyle(.checkbox)
                Spacer()
                DatePicker("", selection: Binding(get: { fields.invoiceDate ?? Date() }, set: { fields.invoiceDate = $0 }),
                           displayedComponents: .date)
                    .labelsHidden().disabled(!hasDate)
            }
            HStack {
                field("Total", text: $totalText)
                field("Currency", text: $fields.currency).frame(width: 80)
            }
            field("Addressed to", text: $fields.buyer)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder).labelsHidden()
        }
    }

    private func filing(_ r: InvoiceRecord) -> some View {
        let edited = editedFields
        let newPath = model.library.organizer.relativePath(for: edited, status: r.status, paidDate: r.paidDate,
                                                           ext: r.fileURL.pathExtension.isEmpty ? "pdf" : r.fileURL.pathExtension)
        return VStack(alignment: .leading, spacing: 10) {
            Text("File").font(.caption).foregroundStyle(.secondary)
            Text(newPath).font(.callout.monospaced()).textSelection(.enabled)
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Save & rename") { apply(status: r.status, paidDate: r.paidDate) }
                            .buttonStyle(.glass)
                            .disabled(edited == r.fields)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.fileURL]) }
                            .buttonStyle(.glass)
                    }
                    if r.status == .unpaid {
                        HStack {
                            Text("Paid on").fixedSize()
                            DatePicker("Paid on", selection: $paidDate, displayedComponents: .date).labelsHidden()
                            Spacer()
                            Button("Mark as paid") { apply(status: .paid, paidDate: paidDate) }
                                .buttonStyle(.glassProminent)
                        }
                    } else {
                        HStack {
                            Text("Paid on \(r.paidDate?.formatted(date: .numeric, time: .omitted) ?? "–")")
                            Spacer()
                            Button("Mark as unpaid") { apply(status: .unpaid, paidDate: nil) }.buttonStyle(.glass)
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func origin(_ r: InvoiceRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("From mail").font(.caption).foregroundStyle(.secondary)
            Text(r.origin.subject).font(.callout)
            Text(r.origin.from).font(.caption).foregroundStyle(.secondary)
            Text(r.origin.attachmentName).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var editedFields: InvoiceFields {
        var f = fields
        f.total = TextRulesBridge.amount(totalText)
        if !hasDate { f.invoiceDate = nil }
        f.currency = f.currency.uppercased()
        return f
    }

    private func load(_ r: InvoiceRecord) {
        fields = r.fields
        totalText = r.fields.total.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        hasDate = r.fields.invoiceDate != nil
        paidDate = Date()
    }

    private func apply(status: InvoiceStatus, paidDate: Date?) {
        do {
            try model.library.update(id, fields: editedFields, status: status, paidDate: paidDate)
            if let r = record { load(r) }
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}

enum TextRulesBridge {
    static func amount(_ s: String) -> Decimal? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : InvoiceText.amount(t)
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .clear
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

struct SkippedList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.library.skipped) { s in
            VStack(alignment: .leading, spacing: 3) {
                Text(s.origin.attachmentName).fontWeight(.medium)
                Text(s.origin.subject).font(.caption)
                Text(s.reason).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("File as invoice") {
                        Task {
                            do { try await model.library.importSkipped(s.id, extractor: model.extractor) }
                            catch { model.lastError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.glass)
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: s.storedPath)) }.buttonStyle(.glass)
                    Button("Delete", role: .destructive) { model.library.deleteSkipped(s.id) }.buttonStyle(.glass)
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if model.library.skipped.isEmpty {
                ContentUnavailableView("Nothing skipped", systemImage: "tray",
                                       description: Text("PDFs from mail that don't look like invoices appear here."))
            }
        }
    }
}
