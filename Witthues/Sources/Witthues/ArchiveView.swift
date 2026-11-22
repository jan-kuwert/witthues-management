import WitthuesCore
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
    let amount: Double
    let currency: String
    let source: String
    let check: String
    let subject: String
    let importedAt: Date
    let printed: String
    let record: InvoiceRecord

    /// Stands in for a missing date so rows still sort; shown as "–".
    static let noDate = Date.distantPast

    init(_ r: InvoiceRecord, folder: String) {
        id = r.id
        record = r
        fileName = r.fileURL.lastPathComponent
        self.folder = folder
        invoiceDate = r.fields.invoiceDate ?? Self.noDate
        status = r.stage.label
        paidDate = r.paidDate ?? Self.noDate
        invoiceNumber = r.fields.invoiceNumber
        company = r.fields.seller
        amount = r.fields.total.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        currency = r.fields.currency
        source = r.source.label
        check = r.fileMissing ? "Datei fehlt" : (r.reviewReasons.first ?? "")
        subject = r.origin.subject
        importedAt = r.importedAt
        printed = r.printedAt == nil ? "" : "Gedruckt"
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

    struct Child {
        var path: String
        /// PDFs on disk inside, subfolders included.
        var files: Int
        /// Of those, the ones not read into the app yet.
        var unread: Int
        /// Read invoices inside that still need a check.
        var toCheck: Int
    }

    /// Direct subfolders of a folder (relative to the main folder; "" is the main folder itself) on disk, with
    /// their files. The unpaid and paid folders come first, then newest folders first.
    @MainActor static func children(of folder: String, _ library: Library) -> [Child] {
        let root = library.settings.rootFolder
        guard !root.isEmpty else { return [] }
        let prefix = folder.isEmpty ? "" : folder + "/"
        let dir = URL(fileURLWithPath: root).appendingPathComponent(folder)
        let live = library.liveRecords
        var result: [Child] = []
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let path = prefix + u.lastPathComponent
            let check = live.filter { r in
                let f = relative(r.filePath, root: root)
                return r.needsReview && (f == path || f.hasPrefix(path + "/"))
            }.count
            result.append(Child(path: path, files: Library.pdfs(in: [u]).count, unread: library.unknownFiles(in: u).count, toCheck: check))
        }
        let first = [library.settings.unpaidFolder, library.settings.paidFolder]
        return result.sorted { a, b in
            let ia = first.firstIndex(of: a.path) ?? 9, ib = first.firstIndex(of: b.path) ?? 9
            if ia != ib { return ia < ib }
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
    /// The filter rule whose editor is open.
    @State private var editingRule: FilterRule.ID?
    @State private var newName = ""
    /// The invoice opened by double-click, shown with its PDF and details instead of the table.
    @State private var opened: InvoiceRecord.ID?
    /// The table's rows, in table order, when the invoice was opened: what „Vorherige“ / „Nächste“ step through.
    @State private var openedList: [InvoiceRecord.ID] = []
    /// Checking the invoices marked „Prüfen“ one after another.
    @State private var review: ReviewSession?

    struct ReviewSession {
        /// Every invoice that needed checking when the session started, checked ones included.
        var ids: [InvoiceRecord.ID]
        var index = 0
    }
    @State private var stageRequest: StageRequest?

    init(start: SavedView, viewID: SavedView.ID?,
         showView: @escaping (SavedView.ID) -> Void, openFolder: @escaping (String) -> Void) {
        self.viewID = viewID
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
        ("number", "Rechnungsnummer"), ("company", "Firma"), ("amount", "Betrag"),
        ("currency", "Währung"), ("source", "Gelesen aus"), ("check", "Prüfen"), ("subject", "Mail-Betreff"), ("imported", "Importiert"), ("printed", "Gedruckt"),
    ]
    /// Shown until the user changes the columns.
    static let defaultHidden: Set<String> = ["currency", "source", "check", "subject", "imported"]

    var body: some View {
        if let review, review.ids.indices.contains(review.index) {
            reviewView(review)
        } else if let opened, model.library.records.contains(where: { $0.id == opened }) {
            // Same view as in the invoice lists, locked until the user unlocks it.
            InvoiceDetail(id: opened, startLocked: true)
                .id(opened)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { self.opened = nil } label: { Label("Zurück", systemImage: "chevron.left") }
                            .help("Zurück zur Tabelle")
                            .keyboardShortcut("[", modifiers: .command)
                    }
                    ToolbarItem(placement: .navigation) { stepper(opened) }
                }
        } else {
            table
        }
    }

    /// Opens an invoice; the rows shown now are what the arrows step through.
    private func open(_ id: InvoiceRecord.ID) {
        openedList = filteredRows.map(\.id)
        opened = id
    }

    /// „‹ 3 von 12 ›“: the previous and next file of the table without going back to it.
    private func stepper(_ id: InvoiceRecord.ID) -> some View {
        let i = openedList.firstIndex(of: id)
        return HStack(spacing: 6) {
            Button { if let i { opened = openedList[i - 1] } } label: { Image(systemName: "chevron.up") }
                .disabled((i ?? 0) == 0)
                .help("Vorherige Datei (⌘↑)")
                .keyboardShortcut(.upArrow, modifiers: .command)
            Text(i.map { "\($0 + 1) von \(openedList.count)" } ?? "–")
                .monospacedDigit().foregroundStyle(.secondary).fixedSize()
            Button { if let i { opened = openedList[i + 1] } } label: { Image(systemName: "chevron.down") }
                .disabled(i.map { $0 + 1 >= openedList.count } ?? true)
                .help("Nächste Datei (⌘↓)")
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Checking one after another

    /// Invoices of the table that still need checking.
    private func toCheck(_ rows: [ArchiveRow]) -> [InvoiceRecord.ID] {
        rows.filter { $0.record.needsReview }.map(\.id)
    }

    private func needsReview(_ id: InvoiceRecord.ID) -> Bool {
        model.library.records.first { $0.id == id }?.needsReview ?? false
    }

    /// One invoice at a time with a bar: where the user is, how many are checked, back and forth, done.
    private func reviewView(_ s: ReviewSession) -> some View {
        let id = s.ids[s.index]
        let done = s.ids.filter { !needsReview($0) }.count
        let allDone = done == s.ids.count
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Rechnung \(s.index + 1) von \(s.ids.count)").fontWeight(.semibold).monospacedDigit()
                ProgressView(value: Double(done), total: Double(s.ids.count))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 220)
                Text(allDone ? "Alle geprüft" : "\(done) geprüft · \(s.ids.count - done) offen")
                    .font(.callout).foregroundStyle(allDone ? .green : .secondary).monospacedDigit()
                if !needsReview(id) {
                    Label("Diese ist geprüft", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                }
                Spacer()
                Button { review?.index -= 1 } label: { Label("Vorherige", systemImage: "chevron.left") }
                    .disabled(s.index == 0)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button { review?.index += 1 } label: { Label("Nächste", systemImage: "chevron.right") }
                    .disabled(s.index + 1 >= s.ids.count)
                    .keyboardShortcut(.downArrow, modifiers: .command)
                if allDone {
                    Button("Fertig") { review = nil }.buttonStyle(.glassProminent)
                } else {
                    Button("Beenden") { review = nil }.buttonStyle(.glass)
                }
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
            Divider()
            InvoiceDetail(id: id, onReviewed: { nextToCheck() }).id(id)
        }
        .navigationTitle("Rechnungen prüfen")
    }

    /// After „Geprüft, weiter“: the next invoice still to check, after this one first, then from the start.
    private func nextToCheck() {
        guard let s = review else { return }
        let order = Array(s.ids.indices.dropFirst(s.index + 1)) + Array(s.ids.indices.prefix(s.index))
        if let next = order.first(where: { needsReview(s.ids[$0]) }) { review?.index = next }
    }

    private var table: some View {
        let rows = filteredRows
        return VStack(spacing: 0) {
            folderStrip
            filterBar
            Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
                mainColumns
                moreColumns
            }
            .contextMenu(forSelectionType: InvoiceRecord.ID.self) { ids in
                contextMenu(ids)
            } primaryAction: { ids in
                // Double-click or Return opens the invoice with its PDF and details.
                if let id = ids.first { open(id) }
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
                    if let folder = filter.folder, !unread(folder).isEmpty {
                        ContentUnavailableView {
                            Label("Dateien noch nicht eingelesen", systemImage: "doc.viewfinder")
                        } description: {
                            Text("In diesem Ordner liegen \(unread(folder).count) PDFs, die die App noch nicht kennt.")
                        } actions: {
                            importButton(folder).buttonStyle(.glassProminent)
                        }
                    } else {
                        ContentUnavailableView(model.library.liveRecords.isEmpty ? "Noch keine Rechnungen" : "Keine passenden Rechnungen",
                                               systemImage: "magnifyingglass",
                                               description: Text(model.library.liveRecords.isEmpty ? "Abgelegte Rechnungen erscheinen hier." : "Filter oder Suche ändern."))
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            let check = toCheck(filteredRows)
            if !check.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { review = ReviewSession(ids: check) } label: {
                        Label(check.count == 1 ? "1 prüfen" : "\(check.count) prüfen", systemImage: "checklist")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(.orange)
                    .help("Alle Rechnungen mit „Prüfen“ nacheinander ansehen und bestätigen")
                }
            }
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
        .stagePrompt($stageRequest)
    }

    /// PDFs in the folder (relative to the main folder) that were never read.
    private func unread(_ folder: String) -> [URL] {
        model.library.unknownFiles(in: URL(fileURLWithPath: model.library.settings.rootFolder).appendingPathComponent(folder))
    }

    /// Reads the folder's unknown files in place, after asking which stage they get.
    private func importButton(_ folder: String) -> some View {
        let files = unread(folder)
        return Button {
            let url = URL(fileURLWithPath: model.library.settings.rootFolder).appendingPathComponent(folder)
            stageRequest = StageRequest(title: files.count == 1 ? "1 Datei einlesen" : "\(files.count) Dateien einlesen",
                                        detail: folder.isEmpty ? ArchiveFolders.rootName(model.library) : folder, inPlace: true,
                                        suggested: model.library.suggestedStage(for: url)) { stage, date in
                model.startReadingFiles(files, stage: stage, paidDate: date)
            }
        } label: {
            Label(files.count == 1 ? "1 Datei einlesen …" : "\(files.count) Dateien einlesen …", systemImage: "square.and.arrow.down")
        }
        .disabled(model.isChecking || files.isEmpty)
        .help("Liest die Rechnungsdaten aus den PDFs, ohne sie zu verschieben")
    }

    // MARK: - Columns

    typealias Columns = TableColumnBuilder<ArchiveRow, KeyPathComparator<ArchiveRow>>

    @Columns private var mainColumns: some TableColumnContent<ArchiveRow, KeyPathComparator<ArchiveRow>> {
        TableColumn("Dateiname", value: \.fileName) { r in
            HStack(spacing: 6) {
                Label(r.fileName, systemImage: r.record.fileURL.pathExtension.lowercased() == "xml" ? "chevron.left.forwardslash.chevron.right" : "doc.richtext")
                    .foregroundStyle(r.record.fileMissing ? .red : .primary)
                    .help(r.record.filePath)
                if r.record.needsReview {
                    // The app was unsure about something; it counts in the overview only after a check.
                    Text("Prüfen")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: .capsule)
                        .help(r.record.reviewReasons.joined(separator: "\n") + "\nZählt erst nach der Prüfung in der Übersicht mit.")
                }
            }
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
                .background(InvoiceDetail.tint(r.record).opacity(0.18), in: .capsule)
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
        TableColumn("Betrag", value: \.amount) { r in
            Text(r.record.fields.total.map { MenuBarView.money($0, r.currency) } ?? "–")
                .monospacedDigit()
                .foregroundStyle(r.record.reviewReasons.contains { $0.contains("Betrag") } ? .orange : .primary)
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
        TableColumn("Gedruckt", value: \.printed) { r in
            Image(systemName: r.record.printedAt == nil ? "" : "printer.fill").foregroundStyle(.secondary)
        }
        .width(min: 50, ideal: 60)
        .customizationID("printed")
    }

    // MARK: - Filtering

    private var filteredRows: [ArchiveRow] {
        let root = model.library.settings.rootFolder
        var rows = model.library.liveRecords.map { ArchiveRow($0, folder: ArchiveFolders.relative($0.filePath, root: root)) }
        if let folder = filter.folder, !folder.isEmpty { rows = rows.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") } }
        rows = rows.filter { filter.matches($0.record, folder: $0.folder) }
        let q = filter.search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            rows = rows.filter { r in
                [r.fileName, r.company, r.invoiceNumber, r.subject, r.folder,
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
        Set(model.library.liveRecords.compactMap { $0.fields.invoiceDate.map { Calendar.current.component(.year, from: $0) } }).sorted(by: >)
    }

    /// Search field, the Filter menu that adds rules, and the rules as removable badges joined by „und“ or „oder“.
    private var filterBar: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Suchen", text: $filter.search).textFieldStyle(.plain)
                if !filter.search.isEmpty {
                    Button { filter.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 90, maxWidth: 260)
            .help("Nach Dateiname, Firma, Rechnungsnummer oder Betrag suchen")
            .glassEffect(.regular, in: .capsule)
            filterMenu
            // Badges wrap onto further lines when there are many.
            FlowLayout(spacing: 6) {
                ForEach(Array(filter.rules.enumerated()), id: \.element.id) { i, rule in
                    if i > 0 { joinButton }
                    ruleBadge(rule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var filterMenu: some View {
        Menu {
            Section("Filterregel hinzufügen") {
                ForEach(FilterRule.Field.allCases, id: \.self) { f in
                    Button { addRule(f) } label: { Label(f.label, systemImage: f.symbol) }
                }
            }
            if filter.rules.count > 1 {
                Picker("Regeln verknüpfen", selection: $filter.matchAny) {
                    Text("Alle Regeln müssen passen (und)").tag(false)
                    Text("Mindestens eine Regel passt (oder)").tag(true)
                }
            }
            if !filter.rules.isEmpty {
                Divider()
                Button("Alle Filter entfernen") { editingRule = nil; filter.rules = [] }
            }
        } label: {
            Label(filter.rules.isEmpty ? "Filter" : "Filter (\(filter.rules.count))",
                  systemImage: filter.rules.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Filterregel hinzufügen")
    }

    /// Switches all rules between „und“ and „oder“.
    private var joinButton: some View {
        Button(filter.matchAny ? "oder" : "und") { filter.matchAny.toggle() }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
            .help("Klicken wechselt zwischen „und“ (alle Regeln müssen passen) und „oder“ (eine Regel reicht)")
    }

    private func ruleBadge(_ rule: FilterRule) -> some View {
        let excluded = rule.op.isNegative
        let tint: Color = excluded ? .red : .accentColor
        return HStack(spacing: 5) {
            Button { editingRule = rule.id } label: {
                HStack(spacing: 4) {
                    Image(systemName: excluded ? "minus.circle" : rule.field.symbol)
                    Text(rule.field.label).fontWeight(.semibold)
                    Text(rule.summary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Klicken zum Bearbeiten")
            Button { removeRule(rule.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Filter entfernen")
        }
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(rule.isComplete ? .primary : .secondary)
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 4)
        .background(tint.opacity(rule.isComplete ? 0.16 : 0.06), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .popover(isPresented: Binding(get: { editingRule == rule.id }, set: { if !$0 { editingRule = nil } }), arrowEdge: .bottom) {
            RuleEditor(rule: ruleBinding(rule.id), years: years)
        }
        .contextMenu {
            Button("Bearbeiten …") { editingRule = rule.id }
            if let n = rule.op.negated, rule.field.kind != .flag {
                Button(excluded ? "Einschließen" : "Ausschließen") { ruleBinding(rule.id).wrappedValue.op = n }
            }
            Divider()
            Button("Filter entfernen") { removeRule(rule.id) }
        }
    }

    private func ruleBinding(_ id: FilterRule.ID) -> Binding<FilterRule> {
        Binding(get: { filter.rules.first { $0.id == id } ?? FilterRule(.company) },
                set: { new in if let i = filter.rules.firstIndex(where: { $0.id == id }) { filter.rules[i] = new } })
    }

    private func addRule(_ field: FilterRule.Field) {
        let r = FilterRule(field)
        filter.rules.append(r)
        // Rules that need a value open their editor; a „Zu prüfen“ rule is complete as added.
        if field.kind != .flag { DispatchQueue.main.async { editingRule = r.id } }
    }

    private func removeRule(_ id: FilterRule.ID) {
        if editingRule == id { editingRule = nil }
        filter.rules.removeAll { $0.id == id }
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
                            ForEach(subs, id: \.path) { s in folderTile(s) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.top, 10)
            let waiting = unread(folder)
            if model.isReadingPast {
                MailProgressPanel().padding(.horizontal, 14).padding(.top, 8)
            } else if !waiting.isEmpty, !filteredRows.isEmpty {
                HStack {
                    Label(waiting.count == 1 ? "1 Datei in diesem Ordner ist noch nicht eingelesen." : "\(waiting.count) Dateien in diesem Ordner sind noch nicht eingelesen.",
                          systemImage: "doc.viewfinder")
                        .foregroundStyle(.secondary)
                    Spacer()
                    importButton(folder).buttonStyle(.glass)
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.top, 8)
            }
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

    private func folderTile(_ child: ArchiveFolders.Child) -> some View {
        let path = child.path
        let starred = folderView(path) != nil
        let url = URL(fileURLWithPath: model.library.settings.rootFolder).appendingPathComponent(path)
        return Button { openFolder(path) } label: {
            VStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .frame(height: 38)
                Text((path as NSString).lastPathComponent).font(.callout).lineLimit(1)
                Text(child.files == 1 ? "1 Datei" : "\(child.files) Dateien").font(.caption).foregroundStyle(.secondary)
                if child.unread > 0 {
                    Text("\(child.unread) nicht eingelesen").font(.caption2).foregroundStyle(.blue)
                } else if child.toCheck > 0 {
                    Text("\(child.toCheck) prüfen").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            .frame(width: 118, height: 110)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        // Can be dragged onto the sidebar to add it there, or to Finder.
        .draggable(url)
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
            if child.unread > 0 {
                Button("Dateien einlesen …") {
                    let files = model.library.unknownFiles(in: url)
                    stageRequest = StageRequest(title: "\(files.count) Dateien einlesen", detail: path, inPlace: true,
                                                suggested: model.library.suggestedStage(for: url)) { stage, date in
                        model.startReadingFiles(files, stage: stage, paidDate: date)
                    }
                }
            }
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
                Button("Öffnen") { open(r.id) }
            }
            Button(picked.count == 1 ? "PDF öffnen" : "\(picked.count) Dateien öffnen") { picked.forEach { NSWorkspace.shared.open($0.fileURL) } }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(picked.map(\.fileURL)) }
            Divider()
            if picked.contains(where: { $0.status == .unpaid }) {
                Button("Heute als bezahlt markieren") { setPaid(picked, true) }
            }
            if picked.contains(where: { $0.status == .paid }) {
                Button("Als offen markieren …") { model.askRevertPaid(picked.filter { $0.status == .paid }.map(\.id)) }
            }
            if picked.contains(where: { $0.stage == .paid }) {
                Button("Ins Archiv verschieben") {
                    do { try model.library.archive(picked.map(\.id)) } catch { model.lastError = error.localizedDescription }
                }
            }
            Button(picked.allSatisfy { $0.printedAt != nil } ? "Als nicht gedruckt markieren …" : "Als gedruckt markieren") {
                if picked.allSatisfy({ $0.printedAt != nil }) { model.askRevertPrinted(picked.map(\.id)) }
                else { model.library.setPrinted(picked.map(\.id), true) }
            }
            Divider()
            Button("In den Papierkorb", role: .destructive) {
                do { try model.library.trash(picked.map(\.id)) } catch { model.lastError = error.localizedDescription }
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

/// Edits one filter rule: condition, value and whether it excludes.
struct RuleEditor: View {
    @Binding var rule: FilterRule
    let years: [Int]
    @Environment(\.dismiss) private var dismiss
    @FocusState private var valueFocused: Bool

    private var usesDay: Bool { rule.op == .before || rule.op == .after }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(rule.field.label, systemImage: rule.field.symbol).font(.headline)
            Picker("Bedingung", selection: $rule.op) {
                ForEach(rule.field.ops, id: \.self) { Text($0.label(for: rule.field)).tag($0) }
            }
            .labelsHidden()
            switch rule.field.kind {
            case .text:
                TextField("Text", text: $rule.value).textFieldStyle(.roundedBorder).focused($valueFocused).onSubmit { dismiss() }
            case .number:
                TextField("Betrag, z. B. 100 oder 49,90", text: $rule.value).textFieldStyle(.roundedBorder).focused($valueFocused).onSubmit { dismiss() }
            case .date:
                if usesDay {
                    DatePicker("Datum", selection: Binding(get: { FilterRule.date(from: rule.value) ?? Date() },
                                                           set: { rule.value = FilterRule.dayString($0) }),
                               displayedComponents: .date)
                        .labelsHidden()
                } else {
                    TextField("Jahr oder Monat, z. B. 2026 oder 2026-03", text: $rule.value).textFieldStyle(.roundedBorder).focused($valueFocused).onSubmit { dismiss() }
                    if !years.isEmpty {
                        HStack {
                            ForEach(Array(years.prefix(4)), id: \.self) { y in
                                Button(String(y)) { rule.value = String(y) }.controlSize(.small)
                            }
                        }
                    }
                }
            case .status:
                Picker("Status", selection: $rule.value) {
                    Text("Offen").tag(InvoiceStatus.unpaid.rawValue)
                    Text("Bezahlt").tag(InvoiceStatus.paid.rawValue)
                }
                .pickerStyle(.segmented).labelsHidden()
            case .source:
                Picker("Gelesen aus", selection: $rule.value) {
                    ForEach(ExtractionSource.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
            case .flag:
                EmptyView()
            }
            if let n = rule.op.negated, rule.field.kind != .flag {
                Toggle("Ausschließen", isOn: Binding(get: { rule.op.isNegative }, set: { if $0 != rule.op.isNegative { rule.op = n } }))
                    .help("Rechnungen, auf die das zutrifft, ausblenden")
            }
        }
        .padding(14)
        .frame(width: 290)
        // Typing goes straight into the value.
        .onAppear { DispatchQueue.main.async { valueFocused = true } }
        .onChange(of: rule.op) {
            // „vor“ / „nach“ need a full day; keep the value usable when switching.
            if rule.field.kind == .date, usesDay, FilterRule.date(from: rule.value) == nil { rule.value = FilterRule.dayString(Date()) }
        }
    }
}

/// Lays out views left to right and wraps to a new line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let r = rows(subviews, width: width)
        let height = r.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + spacing * CGFloat(max(r.count - 1, 0))
        let used = r.map { row in row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(row.count - 1, 0)) }.max() ?? 0
        return CGSize(width: width.isFinite ? width : used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let h = row.map(\.1.height).max() ?? 0
            var x = bounds.minX
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (h - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += h + spacing
        }
    }
}
