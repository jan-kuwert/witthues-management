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

    /// Direct subfolders of a folder (relative to the main folder; "" is the main folder itself), from disk and
    /// from filed invoices, with the number of invoices inside each, subfolders included.
    /// The unpaid folder comes first, then newest folders first.
    @MainActor static func children(of folder: String, _ library: Library) -> [(path: String, count: Int)] {
        let root = library.settings.rootFolder
        guard !root.isEmpty else { return [] }
        let prefix = folder.isEmpty ? "" : folder + "/"
        var counts: [String: Int] = [:]
        for r in library.records {
            let f = relative(r.filePath, root: root)
            guard !f.hasPrefix("/"), f.hasPrefix(prefix), f.count > prefix.count,
                  let name = f.dropFirst(prefix.count).split(separator: "/").first else { continue }
            counts[prefix + name, default: 0] += 1
        }
        let dir = URL(fileURLWithPath: root).appendingPathComponent(folder)
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            counts[prefix + u.lastPathComponent, default: 0] += 0
        }
        let unpaid = library.settings.unpaidFolder
        return counts.map { (path: $0.key, count: $0.value) }.sorted { a, b in
            if (a.path == unpaid) != (b.path == unpaid) { return a.path == unpaid }
            return a.path.localizedStandardCompare(b.path) == .orderedDescending
        }
    }

    /// The main folder's own name, such as "Rechnungen".
    @MainActor static func rootName(_ library: Library) -> String {
        let name = (library.settings.rootFolder as NSString).lastPathComponent
        return name.isEmpty ? "Hauptordner" : name
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
    /// Shows a folder (relative to the main folder) in the archive.
    var openFolder: (String) -> Void

    /// The filters in use. Starts from the saved view or the sidebar folder, and is saved as a view on request.
    @State private var filter: SavedView
    @State private var selection = Set<InvoiceRecord.ID>()
    @State private var sortOrder = [KeyPathComparator(\ArchiveRow.invoiceDate, order: .reverse)]
    @State private var columns: TableColumnCustomization<ArchiveRow> = ArchiveView.loadColumns()
    @State private var naming = false
    @State private var newName = ""

    init(start: SavedView, viewID: SavedView.ID?, open: @escaping (InvoiceRecord.ID) -> Void,
         showView: @escaping (SavedView.ID) -> Void, openFolder: @escaping (String) -> Void) {
        self.viewID = viewID
        self.open = open
        self.showView = showView
        self.openFolder = openFolder
        _filter = State(initialValue: start)
    }

    private var savedView: SavedView? { viewID.flatMap { id in model.library.views.first { $0.id == id } } }
    /// The saved view's filters were changed here and not saved yet.
    private var isModified: Bool { savedView.map { !$0.sameFilters(as: filter) } ?? false }

    private var title: String {
        if let savedView { return savedView.name }
        return filter.folder.map { $0.isEmpty ? ArchiveFolders.rootName(model.library) : ($0 as NSString).lastPathComponent } ?? "Alle Dateien"
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
            folderStrip
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
                if let folder = filter.folder, !folder.isEmpty, viewID == nil || savedView?.isFolder == true {
                    let starred = folderView(folder) != nil
                    Button { toggleFolderStar(folder) } label: {
                        Label(starred ? "Stern entfernen" : "Ordner mit Stern versehen", systemImage: starred ? "star.fill" : "star")
                    }
                    .help(starred ? "Ordner aus der Seitenleiste entfernen" : "Ordner in der Seitenleiste unter „Archiv“ zeigen")
                }
                viewsMenu
                columnsMenu
            }
        }
        .sheet(isPresented: $naming) {
            ViewEditor(title: "Ansicht speichern",
                       note: "Speichert den aktuellen Ordner und die Filter. Die Ansicht bekommt einen Stern und erscheint in der Seitenleiste unter „Ansichten“.",
                       name: newName, icon: "star.fill") { name, icon in saveNewView(name, icon) }
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
        if let folder = filter.folder, !folder.isEmpty { rows = rows.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") } }
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
                    ForEach(model.library.views.filter { $0.isFolder != true }) { v in
                        Button { showView(v.id) } label: {
                            Label(v.name, systemImage: v.symbol)
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

    private func saveNewView(_ name: String, _ icon: String) {
        var v = filter
        v.id = UUID()
        v.name = name
        v.icon = icon
        v.isFolder = nil
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
        v.icon = old.icon
        v.isFolder = old.isFolder
        model.library.views[i] = v
    }

    /// The starred-folder entry for a folder, if it has one.
    private func folderView(_ path: String) -> SavedView? {
        model.library.views.first { $0.isFolder == true && $0.folder == path }
    }

    /// Stars a folder (it shows up in the sidebar with a folder icon and its name) or removes the star.
    private func toggleFolderStar(_ path: String) {
        if let v = folderView(path) {
            model.library.views.removeAll { $0.id == v.id }
            if viewID == v.id { openFolder(path) }
        } else {
            model.library.views.append(SavedView(name: (path as NSString).lastPathComponent, folder: path, icon: "folder", isFolder: true))
        }
    }

    // MARK: - Folder browser

    /// Path bar and the folder's subfolders as Finder-like tiles, shown when a folder is open.
    @ViewBuilder private var folderStrip: some View {
        if let folder = filter.folder {
            let subs = ArchiveFolders.children(of: folder, model.library)
            VStack(alignment: .leading, spacing: 10) {
                pathBar(folder)
                if !subs.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(subs, id: \.path) { s in folderTile(s.path, s.count) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.top, 10)
        }
    }

    private func pathBar(_ folder: String) -> some View {
        let parts = folder.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            crumb(ArchiveFolders.rootName(model.library), "", current: parts.isEmpty)
            ForEach(parts.indices, id: \.self) { i in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                crumb(parts[i], parts[...i].joined(separator: "/"), current: i == parts.count - 1)
            }
            Spacer()
            Button("Im Finder öffnen", systemImage: "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: model.library.settings.rootFolder).appendingPathComponent(folder))
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.horizontal, 16)
    }

    private func crumb(_ title: String, _ path: String, current: Bool) -> some View {
        Button { openFolder(path) } label: {
            Label(title, systemImage: path.isEmpty ? "folder.fill" : "folder")
                .font(.callout.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(current)
    }

    private func folderTile(_ path: String, _ count: Int) -> some View {
        let starred = folderView(path) != nil
        let url = URL(fileURLWithPath: model.library.settings.rootFolder).appendingPathComponent(path)
        return Button { openFolder(path) } label: {
            VStack(spacing: 4) {
                Image(systemName: path == model.library.settings.unpaidFolder ? "folder.fill.badge.questionmark" : "folder.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(height: 38)
                Text((path as NSString).lastPathComponent).font(.callout).lineLimit(1)
                Text(count == 1 ? "1 Datei" : "\(count) Dateien").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 108, height: 96)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Button { toggleFolderStar(path) } label: {
                Image(systemName: starred ? "star.fill" : "star").foregroundStyle(starred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .padding(7)
            .help(starred ? "Stern entfernen" : "Mit Stern in die Seitenleiste")
        }
        .contextMenu {
            Button("Öffnen") { openFolder(path) }
            Button(starred ? "Stern entfernen" : "Mit Stern in die Seitenleiste") { toggleFolderStar(path) }
            Divider()
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .help(path)
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

/// Name and sidebar icon of a saved view, for saving a new one or editing it.
struct ViewEditor: View {
    let title: String
    var note: String? = nil
    @State var name: String
    @State var icon: String
    var save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    static let icons = [
        "star.fill", "bookmark.fill", "flag.fill", "heart.fill", "tag.fill", "pin.fill",
        "folder", "archivebox", "tray.full", "doc.text", "checkmark.circle", "exclamationmark.triangle",
        "eurosign.circle", "creditcard", "cart", "calendar", "clock", "building.2",
        "phone", "wifi", "bolt", "car", "shippingbox", "fork.knife",
    ]

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            Text("Symbol").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.icons, id: \.self) { s in
                    Button { icon = s } label: {
                        Image(systemName: s)
                            .font(.system(size: 15))
                            .frame(width: 34, height: 30)
                            .background(icon == s ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 7))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(s)
                }
            }
            HStack {
                Label(trimmed.isEmpty ? "Vorschau" : trimmed, systemImage: icon)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { save(trimmed, icon); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
