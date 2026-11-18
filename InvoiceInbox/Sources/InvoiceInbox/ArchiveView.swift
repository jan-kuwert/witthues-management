import InvoiceCore
import SwiftUI

/// One table row: an invoice flattened into sortable values.
struct ArchiveRow: Identifiable {
    let id: InvoiceRecord.ID
    let fileName: String
    let folder: String
    let invoiceDate: Date
    let status: String
    let paidDate: Date
    let invoiceNumber: String
    let company: String
    let buyer: String
    let amount: Double
    let currency: String
    let source: String
    let check: String
    let subject: String
    let importedAt: Date
    let record: InvoiceRecord

    /// Stands in for a missing date so rows still sort; shown as "–".
    static let noDate = Date.distantPast

    init(_ r: InvoiceRecord, folder: String) {
        id = r.id
        record = r
        fileName = r.fileURL.lastPathComponent
        self.folder = folder
        invoiceDate = r.fields.invoiceDate ?? Self.noDate
        status = r.status == .paid ? "Bezahlt" : "Offen"
        paidDate = r.paidDate ?? Self.noDate
        invoiceNumber = r.fields.invoiceNumber
        company = r.fields.seller
        buyer = r.fields.buyer
        amount = r.fields.total.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        currency = r.fields.currency
        source = r.source.label
        check = r.fileMissing ? "Datei fehlt" : (r.reviewReasons.first ?? "")
        subject = r.origin.subject
        importedAt = r.importedAt
    }
}

/// The main folder's subfolders, for the sidebar's Archive section.
enum ArchiveFolders {
    /// Folder of a filed invoice, relative to the main folder ("" when it sits directly in it).
    static func relative(_ path: String, root: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let base = root.hasSuffix("/") ? root : root + "/"
        if dir == root || dir + "/" == base { return "" }
        return dir.hasPrefix(base) ? String(dir.dropFirst(base.count)) : dir
    }

    /// Folders that hold invoices plus folders that exist on disk (two levels deep), with invoice counts.
    /// The unpaid folder comes first, then newest archive folders first.
    @MainActor static func list(_ library: Library) -> [(path: String, count: Int)] {
        let root = library.settings.rootFolder
        guard !root.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for r in library.records { counts[relative(r.filePath, root: root), default: 0] += 1 }
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        for level1 in (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [] {
            guard (try? level1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            counts[level1.lastPathComponent, default: 0] += 0
            for level2 in (try? fm.contentsOfDirectory(at: level1, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            where (try? level2.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                counts[level1.lastPathComponent + "/" + level2.lastPathComponent, default: 0] += 0
            }
        }
        counts[""] = nil
        let unpaid = library.settings.unpaidFolder
        return counts.map { (path: $0.key, count: $0.value) }.sorted { a, b in
            if (a.path == unpaid) != (b.path == unpaid) { return a.path == unpaid }
            return a.path.localizedStandardCompare(b.path) == .orderedDescending
        }
    }
}

/// Finder/Excel-like table of filed invoices: sortable, filterable, with columns the user picks.
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    /// The saved view shown, or nil for a folder or "All files".
    let viewID: SavedView.ID?
    /// Opens an invoice in the invoice list.
    var open: (InvoiceRecord.ID) -> Void
    /// Shows a saved view in the archive.
    var showView: (SavedView.ID) -> Void

    /// The filters in use. Starts from the saved view or the sidebar folder, and is saved as a view on request.
    @State private var filter: SavedView
    @State private var selection = Set<InvoiceRecord.ID>()
    @State private var sortOrder = [KeyPathComparator(\ArchiveRow.invoiceDate, order: .reverse)]
    @State private var columns: TableColumnCustomization<ArchiveRow> = ArchiveView.loadColumns()
    @State private var naming = false
    @State private var newName = ""

    init(start: SavedView, viewID: SavedView.ID?, open: @escaping (InvoiceRecord.ID) -> Void,
         showView: @escaping (SavedView.ID) -> Void) {
        self.viewID = viewID
        self.open = open
        self.showView = showView
        _filter = State(initialValue: start)
    }

    private var savedView: SavedView? { viewID.flatMap { id in model.library.views.first { $0.id == id } } }
    /// The saved view's filters were changed here and not saved yet.
    private var isModified: Bool { savedView.map { !$0.sameFilters(as: filter) } ?? false }

    private var title: String {
        if let savedView { return savedView.name }
        return filter.folder.map { $0.isEmpty ? "Hauptordner" : $0 } ?? "Alle Dateien"
    }

    /// Column IDs and titles, for the Columns menu.
    static let columnTitles: [(id: String, title: String)] = [
        ("file", "Dateiname"), ("folder", "Ordner"), ("date", "Rechnungsdatum"), ("status", "Status"), ("paid", "Bezahlt am"),
        ("number", "Rechnungsnummer"), ("company", "Firma"), ("buyer", "Empfänger"), ("amount", "Betrag"),
        ("currency", "Währung"), ("source", "Gelesen aus"), ("check", "Prüfen"), ("subject", "Mail-Betreff"), ("imported", "Importiert"),
    ]
    /// Shown until the user changes the columns.
    static let defaultHidden: Set<String> = ["buyer", "currency", "source", "check", "subject", "imported"]

    var body: some View {
        let rows = filteredRows
        VStack(spacing: 0) {
            filterBar
            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
                mainColumns
                moreColumns
            }
            .contextMenu(forSelectionType: InvoiceRecord.ID.self) { ids in
                contextMenu(ids)
            } primaryAction: { ids in
                // Double-click or Return opens the PDF, like Finder.
                for r in records(ids) { NSWorkspace.shared.open(r.fileURL) }
            }
            .safeAreaInset(edge: .bottom) {
                Text(footer(rows))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(model.library.records.isEmpty ? "Noch keine Rechnungen" : "Keine passenden Rechnungen",
                                           systemImage: "magnifyingglass",
                                           description: Text(model.library.records.isEmpty ? "Abgelegte Rechnungen erscheinen hier." : "Filter oder Suche ändern."))
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                viewsMenu
                columnsMenu
            }
        }
        .alert("Ansicht speichern", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Speichern") { saveNewView() }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Speichert den aktuellen Ordner und die Filter. Die Ansicht bekommt einen Stern und erscheint in der Seitenleiste unter „Ansichten“.")
        }
        .onChange(of: columns) { saveColumns() }
    }

    // MARK: - Columns

    typealias Columns = TableColumnBuilder<ArchiveRow, KeyPathComparator<ArchiveRow>>

    @Columns private var mainColumns: some TableColumnContent<ArchiveRow, KeyPathComparator<ArchiveRow>> {
        TableColumn("Dateiname", value: \.fileName) { r in
            Label(r.fileName, systemImage: r.record.fileURL.pathExtension.lowercased() == "xml" ? "chevron.left.forwardslash.chevron.right" : "doc.richtext")
                .foregroundStyle(r.record.fileMissing ? .red : .primary)
                .help(r.record.filePath)
        }
        .width(min: 140, ideal: 250)
        .customizationID("file")
        TableColumn("Ordner", value: \.folder) { r in Text(r.folder.isEmpty ? "–" : r.folder) }
            .width(min: 60, ideal: 75)
            .customizationID("folder")
        TableColumn("Rechnungsdatum", value: \.invoiceDate) { r in Text(dateText(r.invoiceDate)).monospacedDigit() }
            .width(min: 70, ideal: 80)
            .customizationID("date")
        TableColumn("Status", value: \.status) { r in
            Text(r.status)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background((r.record.status == .paid ? Color.green : Color.orange).opacity(0.18), in: .capsule)
        }
        .width(min: 60, ideal: 70)
        .customizationID("status")
        TableColumn("Bezahlt am", value: \.paidDate) { r in Text(dateText(r.paidDate)).monospacedDigit() }
            .width(min: 70, ideal: 80)
            .customizationID("paid")
        TableColumn("Rechnungsnummer", value: \.invoiceNumber) { r in Text(r.invoiceNumber.isEmpty ? "–" : r.invoiceNumber).textSelection(.enabled) }
            .width(min: 80, ideal: 120)
            .customizationID("number")
        TableColumn("Firma", value: \.company) { r in Text(r.company.isEmpty ? "Unbekannt" : r.company) }
            .width(min: 90, ideal: 150)
            .customizationID("company")
    }

    @Columns private var moreColumns: some TableColumnContent<ArchiveRow, KeyPathComparator<ArchiveRow>> {
        TableColumn("Empfänger", value: \.buyer)
            .width(min: 90, ideal: 140)
            .customizationID("buyer")
        TableColumn("Betrag", value: \.amount) { r in
            Text(r.record.fields.total.map { MenuBarView.money($0, r.currency) } ?? "–")
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .width(min: 70, ideal: 90)
        .customizationID("amount")
        TableColumn("Währung", value: \.currency)
            .width(min: 50, ideal: 60)
            .customizationID("currency")
        TableColumn("Gelesen aus", value: \.source)
            .width(min: 80, ideal: 110)
            .customizationID("source")
        TableColumn("Prüfen", value: \.check) { r in Text(r.check).foregroundStyle(r.record.fileMissing ? .red : .orange).help(r.record.reviewReasons.joined(separator: "\n")) }
            .width(min: 70, ideal: 130)
            .customizationID("check")
        TableColumn("Mail-Betreff", value: \.subject)
            .width(min: 100, ideal: 200)
            .customizationID("subject")
        TableColumn("Importiert", value: \.importedAt) { r in Text(dateText(r.importedAt)).monospacedDigit() }
            .width(min: 80, ideal: 90)
            .customizationID("imported")
    }

    // MARK: - Filtering

    private var filteredRows: [ArchiveRow] {
        let root = model.library.settings.rootFolder
        var rows = model.library.records.map { ArchiveRow($0, folder: ArchiveFolders.relative($0.filePath, root: root)) }
        if let folder = filter.folder { rows = rows.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") } }
        switch filter.status {
        case .all: break
        case .unpaid: rows = rows.filter { $0.record.status == .unpaid }
        case .paid: rows = rows.filter { $0.record.status == .paid }
        }
        if filter.year != 0 { rows = rows.filter { Calendar.current.component(.year, from: $0.invoiceDate) == filter.year } }
        if filter.onlyNeedsCheck { rows = rows.filter { !$0.check.isEmpty } }
        let q = filter.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            rows = rows.filter { r in
                [r.fileName, r.company, r.buyer, r.invoiceNumber, r.subject, r.folder,
                 String(format: "%.2f", r.amount), String(format: "%.2f", r.amount).replacingOccurrences(of: ".", with: ",")]
                    .contains { $0.lowercased().contains(q) }
            }
        }
        return rows.sorted(using: sortOrder)
    }

    /// "9 Dateien · 1.869,68 €", like Finder's status bar. Sums only the most common currency.
    private func footer(_ rows: [ArchiveRow]) -> String {
        let files = rows.count == 1 ? "1 Datei" : "\(rows.count) Dateien"
        let byCurrency = Dictionary(grouping: rows.filter { $0.record.fields.total != nil }) { $0.currency.isEmpty ? "EUR" : $0.currency.uppercased() }
        guard let (code, list) = byCurrency.max(by: { $0.value.count < $1.value.count }) else { return files }
        let total = list.reduce(0) { $0 + $1.amount }.formatted(.currency(code: code))
        let others = rows.count - list.count
        return files + " · " + total + (others > 0 ? " (+\(others) in anderer Währung oder ohne Betrag)" : "")
    }

    private var years: [Int] {
        Set(model.library.records.compactMap { $0.fields.invoiceDate.map { Calendar.current.component(.year, from: $0) } }).sorted(by: >)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtern", text: $filter.search).textFieldStyle(.plain)
                if !filter.search.isEmpty {
                    Button { filter.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 90, maxWidth: 300)
            .help("Nach Dateiname, Firma, Rechnungsnummer oder Betrag filtern")
            .glassEffect(.regular, in: .capsule)
            Picker("Status", selection: $filter.status) {
                ForEach(SavedView.Status.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Jahr", selection: $filter.year) {
                Text("Alle Jahre").tag(0)
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Zu prüfen", isOn: $filter.onlyNeedsCheck).toggleStyle(.button).fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Save the filters as a view, update or revert the open view, or open another one.
    private var viewsMenu: some View {
        Menu {
            if let savedView {
                Button("„\(savedView.name)“ aktualisieren") { updateView() }.disabled(!isModified)
                Button("Änderungen verwerfen") { filter = savedView }.disabled(!isModified)
                Button(savedView.starred ? "Stern entfernen" : "Mit Stern versehen (in Seitenleiste)") { toggleStar(savedView.id) }
                Divider()
                Button("Als neue Ansicht speichern …") { askName() }
            } else {
                Button("Ansicht speichern …") { askName() }
            }
            if !model.library.views.isEmpty {
                Divider()
                Section("Gespeicherte Ansichten") {
                    ForEach(model.library.views) { v in
                        Button { showView(v.id) } label: {
                            Label(v.name, systemImage: v.starred ? "star.fill" : "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
        } label: {
            Label(isModified ? "Ansicht (geändert)" : "Ansichten", systemImage: isModified ? "bookmark.fill" : "bookmark")
        }
        .help("Filter als benannte Ansicht speichern oder gespeicherte Ansicht öffnen")
    }

    private func askName() {
        newName = savedView.map { $0.name + " Kopie" } ?? ""
        naming = true
    }

    private func saveNewView() {
        var v = filter
        v.id = UUID()
        v.name = newName.trimmingCharacters(in: .whitespaces)
        v.starred = true
        model.library.views.append(v)
        showView(v.id)
    }

    private func updateView() {
        guard let i = model.library.views.firstIndex(where: { $0.id == viewID }) else { return }
        let old = model.library.views[i]
        var v = filter
        v.id = old.id
        v.name = old.name
        v.starred = old.starred
        model.library.views[i] = v
    }

    private func toggleStar(_ id: SavedView.ID) {
        guard let i = model.library.views.firstIndex(where: { $0.id == id }) else { return }
        model.library.views[i].starred.toggle()
    }

    /// Show or hide columns. Right-clicking the table header does the same.
    private var columnsMenu: some View {
        Menu {
            ForEach(Self.columnTitles, id: \.id) { c in
                Toggle(c.title, isOn: Binding(
                    get: { columns[visibility: c.id] != .hidden },
                    set: { columns[visibility: c.id] = $0 ? .visible : .hidden }))
            }
            Divider()
            Button("Spalten zurücksetzen") {
                columns = TableColumnCustomization()
                Self.applyDefaults(&columns)
            }
        } label: {
            Label("Spalten", systemImage: "tablecells")
        }
        .help("Sichtbare Spalten wählen")
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<InvoiceRecord.ID>) -> some View {
        let picked = records(ids)
        if !picked.isEmpty {
            if picked.count == 1, let r = picked.first {
                Button("In Witthüs öffnen") { open(r.id) }
            }
            Button(picked.count == 1 ? "PDF öffnen" : "\(picked.count) Dateien öffnen") { picked.forEach { NSWorkspace.shared.open($0.fileURL) } }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.fileURL)) }
            Divider()
            if picked.contains(where: { $0.status == .unpaid }) {
                Button("Heute als bezahlt markieren") { setPaid(picked, true) }
            }
            if picked.contains(where: { $0.status == .paid }) {
                Button("Als offen markieren") { setPaid(picked, false) }
            }
        }
    }

    private func records(_ ids: Set<InvoiceRecord.ID>) -> [InvoiceRecord] {
        model.library.records.filter { ids.contains($0.id) }
    }

    private func setPaid(_ list: [InvoiceRecord], _ paid: Bool) {
        for r in list where (r.status == .paid) != paid {
            do { try model.library.setPaid(r.id, paid) } catch { model.lastError = error.localizedDescription }
        }
    }

    private func dateText(_ d: Date) -> String {
        d == ArchiveRow.noDate ? "–" : d.formatted(date: .numeric, time: .omitted)
    }

    // MARK: - Remembering columns

    private static let columnsKey = "archiveColumns"

    private static func loadColumns() -> TableColumnCustomization<ArchiveRow> {
        if let data = UserDefaults.standard.data(forKey: columnsKey),
           let saved = try? JSONDecoder().decode(TableColumnCustomization<ArchiveRow>.self, from: data) {
            return saved
        }
        var c = TableColumnCustomization<ArchiveRow>()
        applyDefaults(&c)
        return c
    }

    private static func applyDefaults(_ c: inout TableColumnCustomization<ArchiveRow>) {
        for id in defaultHidden { c[visibility: id] = .hidden }
    }

    private func saveColumns() {
        if let data = try? JSONEncoder().encode(columns) { UserDefaults.standard.set(data, forKey: Self.columnsKey) }
    }
}
