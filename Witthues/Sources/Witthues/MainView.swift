import WitthuesCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case dashboard, unpaid, paid, review, all, skipped
    /// A folder in the archive table; nil is every file.
    case archive(String?)
    /// A saved archive view.
    case view(SavedView.ID)
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var sidebar: SidebarItem = .unpaid
    @State private var selection: InvoiceRecord.ID?
    @State private var search = ""
    @State private var dropTargeted = false
    /// An invoice the dashboard asked to open; selected once the list has switched.
    @State private var pendingOpen: InvoiceRecord.ID?
    /// The saved view being renamed from the sidebar.
    @State private var renaming: SavedView?
    @State private var drag = CommandDragOut()
    /// Shown when a folder from outside the main folder is dropped on the sidebar.
    @State private var dropProblem: String?
    @State private var importingPaid = false

    var body: some View {
        Group {
            if sidebar == .dashboard {
                // Two columns, so the charts get the full width.
                NavigationSplitView {
                    sidebarList
                } detail: {
                    DashboardView(open: { id in openInvoice(id) }, show: { sidebar = $0 })
                }
            } else if let (start, viewID) = archiveStart {
                // Two columns, so the table gets the full width.
                NavigationSplitView {
                    sidebarList
                } detail: {
                    ArchiveView(start: start, viewID: viewID, open: openInvoice, showView: { sidebar = .view($0) },
                                openFolder: { sidebar = .archive($0) })
                        .id(sidebar)
                }
            } else {
                invoiceSplitView
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    importingPaid = true
                } label: {
                    Label("Bezahlte Rechnung hinzufügen", systemImage: "doc.badge.plus")
                }
                .help("Bezahlte Rechnung aus Fotos, per iPhone-Scan oder aus einer Datei hinzufügen (⇧⌘N)")
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button {
                    model.checkNow()
                } label: {
                    Label("Mails abrufen", systemImage: "arrow.clockwise")
                }
                .disabled(model.isChecking)
                .help("Jetzt nach neuen Rechnungen suchen (⌘R)")
                Button {
                    openSettings()
                } label: {
                    Label("Einstellungen", systemImage: "gearshape")
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
                Label("PDFs oder E-Rechnungen (XML) hier ablegen", systemImage: "square.and.arrow.down")
                    .font(.title3)
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .sheet(isPresented: $importingPaid) { PaidImportSheet() }
        .sheet(isPresented: Binding(get: { model.showingPastMail }, set: { model.showingPastMail = $0 })) { PastMailSheet() }
        .sheet(item: $renaming) { v in
            ViewEditor(title: v.isFolder == true ? "Ordner bearbeiten" : "Ansicht bearbeiten", name: v.name, icon: v.symbol) { name, icon in
                guard let i = model.library.views.firstIndex(where: { $0.id == v.id }) else { return }
                model.library.views[i].name = name
                model.library.views[i].icon = icon
            }
        }
        // Installed here, not on the sidebar: the sidebar is rebuilt when switching between list, archive and dashboard.
        .onAppear {
            drag.remove = { id in
                // Folders lose their entry; views keep existing and only lose the star.
                if model.library.views.first(where: { $0.id == id })?.isFolder == true { deleteView(id) } else { setStar(id, false) }
            }
            drag.install()
        }
        .onDisappear { drag.uninstall() }
        .onChange(of: sidebar) {
            selection = pendingOpen
            pendingOpen = nil
        }
    }

    private var sidebarList: some View {
        List(selection: $sidebar) {
            Section {
                Label("Übersicht", systemImage: "chart.bar.xaxis").tag(SidebarItem.dashboard)
            }
            Section("Rechnungen") {
                row(.unpaid, "Offen", "tray.full", model.library.records.filter { $0.status == .unpaid }.count)
                row(.paid, "Bezahlt", "archivebox", model.library.records.filter { $0.status == .paid }.count)
                row(.review, "Zu prüfen", "exclamationmark.bubble", model.library.records.filter(\.needsReview).count)
                row(.all, "Alle", "doc.on.doc", model.library.records.count)
            }
            Section("Archiv") {
                row(.archive(nil), "Alle Dateien", "tablecells", model.library.records.count)
                if !model.library.settings.rootFolder.isEmpty {
                    Label(ArchiveFolders.rootName(model.library), systemImage: "folder.fill")
                        .tag(SidebarItem.archive(""))
                        .help("Hauptordner mit allen Unterordnern")
                }
                // Starred folders, with the name and icon they were given.
                ForEach(model.library.views.filter { $0.isFolder == true && $0.starred }) { v in
                    Label(v.name, systemImage: v.symbol)
                        .removableByCommandDrag(v.id, drag)
                        // The tag must come after the drag modifiers, or the row can no longer be selected.
                        .tag(SidebarItem.view(v.id))
                        .help((v.folder ?? "") + "\n⌘ und aus der Seitenleiste ziehen zum Entfernen")
                        .contextMenu {
                            Button("Bearbeiten …") { renaming = v }
                            Button("Im Finder zeigen") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.library.settings.rootFolder).appendingPathComponent(v.folder ?? "")])
                            }
                            Divider()
                            Button("Stern entfernen") { deleteView(v.id) }
                        }
                }
            }
            let starred = model.library.views.filter { $0.starred && $0.isFolder != true }
            if !starred.isEmpty {
                Section("Ansichten") {
                    ForEach(starred) { v in
                        Label(v.name, systemImage: v.symbol)
                            .removableByCommandDrag(v.id, drag)
                            .tag(SidebarItem.view(v.id))
                            .help("⌘ und aus der Seitenleiste ziehen zum Entfernen")
                            .contextMenu {
                                Button("Bearbeiten …") { renaming = v }
                                Button("Stern entfernen") { setStar(v.id, false) }
                                Divider()
                                Button("Ansicht löschen", role: .destructive) { deleteView(v.id) }
                            }
                    }
                }
            }
            Section("Mail") {
                row(.skipped, "Keine Rechnungen", "tray.and.arrow.down", model.library.skipped.count)
                Button { model.showingPastMail = true } label: {
                    Label("Einlesen …", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .help("Ältere Mails oder vorhandene Rechnungsordner einlesen, etwa für die Statistik (⇧⌘R)")
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.area = $0 }
        // Folders dropped here are added under "Archiv"; other files are imported as invoices.
        .dropDestination(for: URL.self) { urls, _ in
            dropOnSidebar(urls)
            return true
        }
        .alert("Ordner nicht im Hauptordner", isPresented: Binding(get: { dropProblem != nil }, set: { if !$0 { dropProblem = nil } })) {
            Button("OK") { dropProblem = nil }
        } message: {
            Text(dropProblem ?? "")
        }
        .safeAreaInset(edge: .bottom) {
            StatusLine()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(8)
        }
    }

    private var invoiceSplitView: some View {
        NavigationSplitView {
            sidebarList
        } content: {
            Group {
                if sidebar == .skipped {
                    SkippedList()
                } else {
                    InvoiceList(records: filtered, selection: $selection)
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            .searchable(text: $search, placement: .toolbar, prompt: "Firma, Nummer, Betrag")
        } detail: {
            if let id = selection, sidebar != .skipped, model.library.records.contains(where: { $0.id == id }) {
                InvoiceDetail(id: id).id(id)
            } else {
                EmptyDetail()
            }
        }
    }

    /// The archive filters to start from for the selected sidebar item, if it is an archive folder or view.
    private var archiveStart: (SavedView, SavedView.ID?)? {
        switch sidebar {
        case .archive(let folder): return (SavedView(folder: folder), nil)
        case .view(let id):
            guard let v = model.library.views.first(where: { $0.id == id }) else { return (SavedView(), nil) }
            return (v, id)
        default: return nil
        }
    }

    private func setStar(_ id: SavedView.ID, _ starred: Bool) {
        guard let i = model.library.views.firstIndex(where: { $0.id == id }) else { return }
        model.library.views[i].starred = starred
        if !starred, sidebar == .view(id) { sidebar = .archive(nil) }
    }

    /// Adds dropped folders inside the main folder to the sidebar; imports anything else.
    private func dropOnSidebar(_ urls: [URL]) {
        let root = URL(fileURLWithPath: model.library.settings.rootFolder).resolvingSymlinksInPath().path
        var files: [URL] = []
        var outside: [String] = []
        var added: SavedView.ID?
        for url in urls {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { files.append(url); continue }
            let path = url.resolvingSymlinksInPath().path
            if path == root { sidebar = .archive(""); continue }
            guard !model.library.settings.rootFolder.isEmpty, path.hasPrefix(root + "/") else { outside.append(url.lastPathComponent); continue }
            let folder = String(path.dropFirst(root.count + 1))
            if let existing = model.library.views.first(where: { $0.isFolder == true && $0.folder == folder }) {
                added = existing.id
            } else {
                let v = SavedView(name: url.lastPathComponent, folder: folder, icon: "folder", isFolder: true)
                model.library.views.append(v)
                added = v.id
            }
        }
        if let added { sidebar = .view(added) }
        if !outside.isEmpty {
            dropProblem = "„\(outside.joined(separator: "“, „"))“ liegt nicht im Hauptordner „\(ArchiveFolders.rootName(model.library))“. Nur Ordner darin können in die Seitenleiste."
        }
        if !files.isEmpty { Task { await model.importFiles(files) } }
    }

    private func deleteView(_ id: SavedView.ID) {
        if sidebar == .view(id) { sidebar = .archive(nil) }
        model.library.views.removeAll { $0.id == id }
    }

    /// Shows an invoice in the "All" list with its detail open.
    private func openInvoice(_ id: InvoiceRecord.ID) {
        pendingOpen = id
        sidebar = .all
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
        case .all, .skipped, .dashboard, .archive, .view: break
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
                Text("Zum Start den Hauptordner wählen und das Mailkonto eintragen.")
                    .foregroundStyle(.secondary)
                Button("Einstellungen öffnen") { openSettings() }.buttonStyle(.glassProminent)
            } else {
                Text("Rechnung auswählen oder PDFs hier ablegen.").foregroundStyle(.secondary)
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
                    Button(r.status == .paid ? "Als offen markieren" : "Als bezahlt markieren") {
                        do { try model.library.setPaid(r.id, r.status != .paid) } catch { model.lastError = error.localizedDescription }
                    }
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([r.fileURL]) }
                    Divider()
                    Button("Aus der Liste entfernen (Datei bleibt)", role: .destructive) { model.library.remove(r.id) }
                }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("Keine Rechnungen", systemImage: "tray", description: Text("Neue Rechnungen aus den Mails erscheinen hier."))
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
                    Text(record.fields.seller.isEmpty ? "Unbekannte Firma" : record.fields.seller)
                        .fontWeight(.medium).lineLimit(1)
                    Spacer()
                    if let total = record.fields.total {
                        Text(MenuBarView.money(total, record.fields.currency)).monospacedDigit()
                    }
                }
                HStack {
                    Text(record.fields.invoiceNumber.isEmpty ? "Ohne Nummer" : record.fields.invoiceNumber)
                    Spacer()
                    Text(record.fields.invoiceDate?.formatted(date: .numeric, time: .omitted) ?? "Ohne Datum")
                }
                .font(.caption).foregroundStyle(.secondary)
                if record.fileMissing {
                    Text("Datei wurde verschoben oder gelöscht").font(.caption).foregroundStyle(.red)
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
    /// The file name without extension, as shown in the field.
    @State private var fileName = ""

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
            Label(r.source.label, systemImage: r.source == .eInvoiceXML ? "checkmark.seal.fill" : r.source == .appleIntelligence ? "apple.intelligence" : "text.viewfinder")
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.tint(r.source == .eInvoiceXML ? .green.opacity(0.3) : .clear), in: .capsule)
            Spacer()
            Text(r.status == .paid ? "Bezahlt" : "Offen")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.tint(r.status == .paid ? .green.opacity(0.35) : .orange.opacity(0.35)), in: .capsule)
        }
    }

    private func reviewBox(_ r: InvoiceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Bitte prüfen", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            ForEach(r.reviewReasons, id: \.self) { Text("• \($0)").font(.callout) }
            Button("Passt so") { model.library.markReviewed(id) }.buttonStyle(.glass)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 14))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Firma (Absender)", text: $fields.seller)
            field("Rechnungsnummer", text: $fields.invoiceNumber)
            HStack {
                Toggle("Datum", isOn: $hasDate).toggleStyle(.checkbox)
                Spacer()
                DatePicker("", selection: Binding(get: { fields.invoiceDate ?? Date() }, set: { fields.invoiceDate = $0 }),
                           displayedComponents: .date)
                    .labelsHidden().disabled(!hasDate)
            }
            HStack {
                field("Betrag", text: $totalText)
                field("Währung", text: $fields.currency).frame(width: 80)
            }
            field("Empfänger", text: $fields.buyer)
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
        let o = model.library.organizer
        let ext = r.fileURL.pathExtension.isEmpty ? "pdf" : r.fileURL.pathExtension
        let templateName = o.baseName(for: edited, paidDate: r.paidDate)
        let changed = edited != r.fields || fileName != currentName(r)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dateiname").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("Dateiname", text: $fileName).textFieldStyle(.roundedBorder)
                    Text(".\(ext)").foregroundStyle(.secondary)
                }
                templateHint(templateName, matches: fileName == templateName) { fileName = templateName }
            }
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Speichern & umbenennen") { save(r) }
                            .buttonStyle(.glass)
                            .disabled(!changed || fileName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([r.fileURL]) }
                            .buttonStyle(.glass)
                    }
                    if r.status == .unpaid {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bezahlt am").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                DatePicker("Bezahlt am", selection: $paidDate, displayedComponents: .date).labelsHidden()
                                Spacer(minLength: 8)
                                Button("Als bezahlt markieren") { apply(status: .paid, paidDate: paidDate) }
                                    .buttonStyle(.glassProminent)
                                    .fixedSize()
                            }
                        }
                    } else {
                        HStack {
                            Text("Bezahlt am \(r.paidDate?.formatted(date: .numeric, time: .omitted) ?? "–")")
                            Spacer()
                            Button("Als offen markieren") { apply(status: .unpaid, paidDate: nil) }.buttonStyle(.glass)
                        }
                    }
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    /// The name or folder the settings' template gives, with a button that puts it into the field.
    private func templateHint(_ value: String, matches: Bool, use: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars").foregroundStyle(.secondary)
            Text("Vorlage: \(value)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help("Aus dem Namensformat in den Einstellungen")
            Spacer(minLength: 4)
            if matches {
                Image(systemName: "checkmark").foregroundStyle(.green).help("Entspricht der Vorlage")
            } else {
                Button("Übernehmen", action: use).buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    private func currentName(_ r: InvoiceRecord) -> String { r.fileURL.deletingPathExtension().lastPathComponent }
    /// Saves fields and the file name. A name left as it was keeps following the template when the record did.
    private func save(_ r: InvoiceRecord) {
        do {
            try model.library.update(id, fields: editedFields, status: r.status, paidDate: r.paidDate,
                                     name: fileName == currentName(r) ? r.customName : fileName)
            if let r = record { load(r) }
        } catch {
            model.lastError = error.localizedDescription
        }
    }

    private func origin(_ r: InvoiceRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Aus Mail").font(.caption).foregroundStyle(.secondary)
            Text(r.origin.subject).font(.callout)
            Text(r.origin.from).font(.caption).foregroundStyle(.secondary)
            Text(r.origin.attachmentName).font(.caption).foregroundStyle(.secondary)
            if let url = r.origin.mailURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("In Mail öffnen", systemImage: "envelope")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.top, 4)
                .help("Zeigt die Mail mit dieser Rechnung in Apple Mail, um die Quelle zu prüfen")
            }
            if let body = r.origin.body, !body.isEmpty {
                Text("Mailtext").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                ScrollView {
                    Text(body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5) }
            }
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
        fileName = currentName(r)
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
                    Button("Als Rechnung ablegen") {
                        Task {
                            do { try await model.library.importSkipped(s.id, extractor: model.extractor) }
                            catch { model.lastError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.glass)
                    Button("Öffnen") { NSWorkspace.shared.open(URL(fileURLWithPath: s.storedPath)) }.buttonStyle(.glass)
                    Button("Löschen", role: .destructive) { model.library.deleteSkipped(s.id) }.buttonStyle(.glass)
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if model.library.skipped.isEmpty {
                ContentUnavailableView("Nichts übersprungen", systemImage: "tray",
                                       description: Text("PDFs aus Mails, die keine Rechnungen sind, erscheinen hier."))
            }
        }
    }
}

/// ⌘-dragging a starred folder or view out of the sidebar removes it, like Finder's sidebar.
/// Uses an AppKit event monitor because the sidebar's table view keeps the mouse-up from SwiftUI gestures.
@MainActor @Observable final class CommandDragOut {
    /// Frames of the removable sidebar entries, in window coordinates (top-left origin).
    var frames: [SavedView.ID: CGRect] = [:]
    /// The sidebar's frame; releasing outside it removes the entry.
    var area: CGRect = .zero
    private(set) var dragging: SavedView.ID?
    private(set) var offset: CGSize = .zero
    private(set) var outside = false
    var remove: (SavedView.ID) -> Void = { _ in }
    @ObservationIgnored private var start: CGPoint = .zero
    @ObservationIgnored private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let height = event.window?.contentView?.bounds.height else { return event }
            let p = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            let (type, command) = (event.type, event.modifierFlags.contains(.command))
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { self?.handle(type, at: p, command: command) ?? false }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the event belongs to a ⌘-drag and should not reach the sidebar.
    private func handle(_ type: NSEvent.EventType, at p: CGPoint, command: Bool) -> Bool {
        switch type {
        case .leftMouseDown:
            // Anywhere on the row counts, not only on its label.
            guard command, area.contains(p),
                  let id = frames.first(where: { $0.value.insetBy(dx: 0, dy: -4).minY...$0.value.insetBy(dx: 0, dy: -4).maxY ~= p.y })?.key
            else { return false }
            dragging = id
            start = p
            return true
        case .leftMouseDragged:
            guard dragging != nil else { return false }
            offset = CGSize(width: p.x - start.x, height: p.y - start.y)
            outside = !area.contains(p)
            (outside ? NSCursor.disappearingItem : NSCursor.arrow).set()
            return true
        default:
            guard let id = dragging else { return false }
            dragging = nil
            NSCursor.arrow.set()
            if !area.contains(p) {
                frames[id] = nil
                remove(id)
            }
            withAnimation(.snappy) { offset = .zero; outside = false }
            return true
        }
    }
}

extension View {
    /// Lets the entry be ⌘-dragged out of the sidebar to remove it.
    func removableByCommandDrag(_ id: SavedView.ID, _ drag: CommandDragOut) -> some View {
        self
            .offset(drag.dragging == id ? drag.offset : .zero)
            .opacity(drag.dragging == id && drag.outside ? 0.4 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.frames[id] = $0 }
    }
}
