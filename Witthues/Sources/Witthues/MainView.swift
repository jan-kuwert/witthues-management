import WitthuesCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case dashboard, suppliers, unpaid, paid, archived, review, all, skipped, deleted
    /// A folder in the archive table; nil is every file.
    case archive(String?)
    /// A saved archive view.
    case view(SavedView.ID)
}

/// How the invoice lists are ordered.
enum InvoiceSort: String, CaseIterable, Identifiable {
    case skonto, newest, oldest
    var id: Self { self }
    var title: String {
        switch self {
        case .skonto: return "Skonto-Frist (früheste zuerst)"
        case .newest: return "Rechnungsdatum (neueste zuerst)"
        case .oldest: return "Rechnungsdatum (älteste zuerst)"
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var sidebar: SidebarItem = .unpaid
    @State private var selection: InvoiceRecord.ID?
    @State private var search = ""
    @AppStorage("invoiceSort") private var sort: InvoiceSort = .skonto
    @State private var dropTargeted = false
    /// An invoice the dashboard asked to open; selected once the list has switched.
    @State private var pendingOpen: InvoiceRecord.ID?
    /// The saved view being renamed from the sidebar.
    @State private var renaming: SavedView?
    @State private var drag = CommandDragOut()
    /// Shown when a folder from outside the main folder is dropped on the sidebar.
    @State private var dropProblem: String?
    /// The open "Rechnung hinzufügen" sheet, with the files dropped on the window or sidebar.
    @State private var adding: AddRequest?

    var body: some View {
        Group {
            if sidebar == .dashboard {
                // Two columns, so the charts get the full width.
                NavigationSplitView {
                    sidebarList
                } detail: {
                    DashboardView(open: { id in openInvoice(id) }, show: { sidebar = $0 })
                }
            } else if sidebar == .suppliers {
                NavigationSplitView {
                    sidebarList
                } detail: {
                    SupplierView(open: { id in openInvoice(id) })
                }
            } else if let (start, viewID) = archiveStart {
                // Two columns, so the table gets the full width.
                NavigationSplitView {
                    sidebarList
                } detail: {
                    ArchiveView(start: start, viewID: viewID, showView: { sidebar = .view($0) },
                                openFolder: { sidebar = .archive($0) })
                        .id(sidebar)
                }
            } else {
                invoiceSplitView
            }
        }
        .toolbar {
            if model.showsUpdateNotice {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if (model.downloadedVersion ?? 0) > model.currentVersion { model.askingInstall = true } else { model.downloadUpdate() }
                    } label: {
                        Label("Update", systemImage: "arrow.down.circle.fill")
                    }
                    .tint(.blue)
                    .disabled(model.isDownloadingUpdate)
                    .help("Neue Version \(model.latestRelease?.version ?? model.downloadedVersion ?? 0) herunterladen und installieren")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    adding = AddRequest()
                } label: {
                    Label("Rechnung hinzufügen", systemImage: "doc.badge.plus")
                }
                .help("Rechnung aus Fotos, per iPhone-Scan oder aus Dateien und Ordnern hinzufügen (⇧⌘N)")
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
                if !urls.isEmpty { adding = AddRequest(urls: urls) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                Label("Rechnungen hier ablegen (PDF, XML, Bilder, Ordner)", systemImage: "square.and.arrow.down")
                    .font(.title3)
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .sheet(item: $adding) { AddInvoiceSheet(initial: $0.urls) }
        .revertConfirmation()
        .updateInstallPrompt()
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
                row(.suppliers, "Lieferanten", "building.2", model.library.suppliers.count)
            }
            Section("Rechnungen") {
                let live = model.library.liveRecords
                row(.unpaid, "Offen", Stage.open.symbol, live.filter { $0.stage == .open }.count)
                row(.paid, "Bezahlt", Stage.paid.symbol, live.filter { $0.stage == .paid }.count)
                row(.archived, "Archiviert", Stage.archived.symbol, live.filter { $0.stage == .archived }.count)
                row(.review, "Zu prüfen", "exclamationmark.bubble", live.filter(\.needsReview).count)
                row(.all, "Alle", "doc.on.doc", live.count)
                row(.deleted, "Gelöscht", "trash", model.library.deleted.count)
            }
            Section("Archiv") {
                row(.archive(nil), "Alle Dateien", "tablecells", model.library.liveRecords.count)
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
        .navigationSplitViewColumnWidth(min: 210, ideal: 230)
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
            VStack(spacing: 6) {
                UpdateNotice()
                StatusLine()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
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
                } else if sidebar == .deleted {
                    DeletedList(selection: $selection)
                } else if sidebar == .paid || sidebar == .archived {
                    PaidList(records: filtered, selection: $selection, archived: sidebar == .archived)
                } else {
                    InvoiceList(records: filtered, selection: $selection)
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 420)
            .toolbar {
                if sidebar != .skipped && sidebar != .deleted {
                    ToolbarItem {
                        Menu {
                            Picker("Sortieren nach", selection: $sort) {
                                ForEach(InvoiceSort.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label("Sortieren", systemImage: "arrow.up.arrow.down")
                        }
                        .help("Sortieren: \(sort.title)")
                    }
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Firma, Nummer, Betrag")
        } detail: {
            if let id = selection, sidebar != .skipped, let r = model.library.records.first(where: { $0.id == id }) {
                // Archived and deleted invoices open locked, so nothing is changed by accident.
                InvoiceDetail(id: id, startLocked: r.stage == .archived || r.fileMissing).id(id)
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
        if !files.isEmpty { adding = AddRequest(urls: files) }
    }

    private func deleteView(_ id: SavedView.ID) {
        if sidebar == .view(id) { sidebar = .archive(nil) }
        model.library.views.removeAll { $0.id == id }
    }

    /// Shows an invoice in the "All" list with its detail open.
    private func openInvoice(_ id: InvoiceRecord.ID) {
        guard model.library.liveRecords.contains(where: { $0.id == id }) else { return }
        pendingOpen = id
        sidebar = .all
    }

    private func row(_ item: SidebarItem, _ title: String, _ icon: String, _ count: Int) -> some View {
        Label(title, systemImage: icon)
            .badge(count)
            .tag(item)
    }

    private var filtered: [InvoiceRecord] {
        var list = sidebar == .deleted ? model.library.deleted : model.library.liveRecords
        switch sidebar {
        case .unpaid: list = list.filter { $0.stage == .open }
        case .paid: list = list.filter { $0.stage == .paid }
        case .archived: list = list.filter { $0.stage == .archived }
        case .review: list = list.filter(\.needsReview)
        case .all, .skipped, .dashboard, .suppliers, .archive, .view, .deleted: break
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { r in
                [r.fields.seller, r.fields.invoiceNumber, r.origin.subject, r.origin.from,
                 r.fields.total.map { "\($0)" } ?? ""].contains { $0.lowercased().contains(q) }
            }
        }
        let now = Date()
        return list.sorted { a, b in
            // Open invoices with Skonto first, earliest deadline first, so no saving is missed; then by date.
            if sort == .skonto, let first = InvoiceRecord.bySkontoDeadline(a, b, on: now) { return first }
            let da = a.fields.invoiceDate ?? a.importedAt, db = b.fields.invoiceDate ?? b.importedAt
            return sort == .oldest ? da < db : da > db
        }
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
        let next = Self.nextSkonto(records)
        List(records, selection: $selection) { r in
            InvoiceRow(record: r, nextSkonto: r.id == next)
                .tag(r.id)
                .contextMenu {
                    Button(r.status == .paid ? "Als offen markieren …" : "Als bezahlt markieren") {
                        if r.status == .paid { model.askRevertPaid([r.id]); return }
                        do { try model.library.setPaid(r.id, true) } catch { model.lastError = error.localizedDescription }
                    }
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([r.fileURL]) }
                    Divider()
                    Button("In den Papierkorb", role: .destructive) {
                        do { try model.library.trash([r.id]) } catch { model.lastError = error.localizedDescription }
                    }
                }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("Keine Rechnungen", systemImage: "tray", description: Text("Neue Rechnungen aus den Mails erscheinen hier."))
            }
        }
    }
}

extension InvoiceList {
    /// The invoice whose Skonto runs out first.
    static func nextSkonto(_ records: [InvoiceRecord]) -> InvoiceRecord.ID? {
        records.compactMap { r in r.skontoOffer()?.deadline.map { (r.id, $0) } }.min { $0.1 < $1.1 }?.0
    }
}

struct InvoiceRow: View {
    let record: InvoiceRecord
    /// Highlighted as the Skonto deadline that comes first.
    var nextSkonto = false

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
                    Text("Datei gelöscht · Rechtsklick zum Wiederherstellen").font(.caption).foregroundStyle(.red)
                } else if record.needsReview {
                    Text(record.reviewReasons.first ?? "").font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else if record.stage == .paid {
                    Label(record.printedAt == nil ? "Nicht gedruckt" : "Gedruckt", systemImage: "printer")
                        .font(.caption).foregroundStyle(record.printedAt == nil ? .blue : .secondary).lineLimit(1)
                }
                if let offer = record.skontoOffer() { skonto(offer) }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, nextSkonto ? 6 : 0)
        .background {
            if nextSkonto {
                RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.14))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.green.opacity(0.6), lineWidth: 1) }
            }
        }
    }

    private func skonto(_ offer: SkontoOffer) -> some View {
        HStack(spacing: 4) {
            Image(systemName: nextSkonto ? "clock.badge.exclamationmark.fill" : "percent")
            // Short enough for the narrow list; the tooltip has the rest.
            Text("−" + (offer.amount.map { MenuBarView.money($0, record.fields.currency) } ?? PaymentTermsBox.percent(offer.percent))
                 + (offer.deadline.map { " bis " + $0.formatted(.dateTime.day(.twoDigits).month(.twoDigits)) } ?? ""))
        }
        .font(.caption.weight(nextSkonto ? .semibold : .regular))
        .foregroundStyle(offer.daysLeft().map { $0 <= 2 } == true ? .orange : .green)
        .lineLimit(1)
        .help((nextSkonto ? "Früheste Skonto-Frist · " : "") + InvoiceRow.skontoText(offer, currency: record.fields.currency))
    }

    /// „Skonto 2,40 € bis 03.12. · noch 3 Tage“
    static func skontoText(_ offer: SkontoOffer, currency: String) -> String {
        var s = "Skonto " + (offer.amount.map { MenuBarView.money($0, currency) }
                             ?? "\(NSDecimalNumber(decimal: offer.percent).stringValue.replacingOccurrences(of: ".", with: ",")) %")
        if let d = offer.deadline {
            s += " bis " + d.formatted(.dateTime.day(.twoDigits).month(.twoDigits))
            if let left = offer.daysLeft() { s += " · " + (left == 0 ? "heute" : left == 1 ? "noch 1 Tag" : "noch \(left) Tage") }
        }
        return s
    }

    private var icon: String {
        if record.fileMissing { return "trash" }
        if record.needsReview { return "exclamationmark.circle.fill" }
        return record.status == .paid ? "checkmark.circle.fill" : "circle"
    }

    private var color: Color {
        if record.fileMissing { return .red }
        if record.needsReview { return .orange }
        return record.status == .paid ? .green : .secondary
    }
}

/// PDF on the left half, fields and actions on a glass panel on the right. Locked invoices (archived ones, or
/// opened from the archive table) show the fields read-only until the lock at the top is opened.
struct InvoiceDetail: View {
    @Environment(AppModel.self) private var model
    let id: InvoiceRecord.ID
    @State private var locked: Bool
    /// Opened locked (archived, deleted, from the archive table): shows „Bearbeiten“ / „Fertig“.
    private let lockable: Bool
    /// Set while checking invoices one after another: called after „Geprüft, weiter“ to show the next one.
    private let onReviewed: (() -> Void)?
    @State private var fields = InvoiceFields()
    @State private var totalText = ""
    @State private var hasDate = true
    @State private var paidDate = Date()
    /// The file name without extension, as shown in the field.
    @State private var fileName = ""
    @State private var loaded = false
    /// The field being typed in; leaving it saves, so lists and the dashboard follow right away.
    @FocusState private var focusedField: String?

    init(id: InvoiceRecord.ID, startLocked: Bool = false, onReviewed: (() -> Void)? = nil) {
        self.onReviewed = onReviewed
        self.id = id
        _locked = State(initialValue: startLocked)
        lockable = startLocked
    }

    private var record: InvoiceRecord? { model.library.records.first { $0.id == id } }

    var body: some View {
        if let record {
            HSplitView {
                PDFPreview(url: record.fileURL)
                    // Loads the file again once it is back after a restore.
                    .id(record.fileMissing)
                    .frame(minWidth: 300)
                    .overlay(alignment: .bottom) {
                        if !record.fileMissing { FileDragChip(url: record.fileURL).padding(12) }
                    }
                    .overlay {
                        if record.fileMissing {
                            ContentUnavailableView {
                                Label("Datei gelöscht", systemImage: "trash")
                            } description: {
                                Text("Die Datei liegt im Papierkorb oder wurde gelöscht. „Wiederherstellen“ holt sie zurück; ist sie ganz weg, lässt sie sich selbst auswählen.")
                            } actions: {
                                RestoreButtons(id: record.id)
                            }
                        }
                    }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(record)
                        if !record.reviewReasons.isEmpty { reviewBox(record) }
                        form.disabled(locked)
                        if let terms = record.fields.terms { PaymentTermsBox(record: record, terms: terms) }
                        filing(record)
                        origin(record)
                    }
                    .padding(16)
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
            .onAppear { load(record) }
            // Changes are kept when switching to another invoice, so the lists show them right away.
            .onDisappear { saveIfChanged() }
        }
    }

    private func header(_ r: InvoiceRecord) -> some View {
        HStack(spacing: 8) {
            if lockable {
                // The button says what it does: start editing, or save and lock again.
                if locked {
                    Button { locked = false } label: {
                        Label("Bearbeiten", systemImage: "pencil")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(r.fileMissing)
                    .help("Felder freigeben, um sie zu ändern")
                } else {
                    Button { saveIfChanged(); locked = true } label: {
                        Label("Fertig", systemImage: "checkmark")
                    }
                    .buttonStyle(.glass)
                    .help("Änderungen speichern und wieder sperren")
                }
            }
            Label(r.source.label, systemImage: r.source == .eInvoiceXML ? "checkmark.seal.fill" : r.source == .appleIntelligence ? "apple.intelligence" : "text.viewfinder")
                .font(.caption).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.tint(r.source == .eInvoiceXML ? .green.opacity(0.3) : .clear), in: .capsule)
            Spacer()
            Text(r.fileMissing ? "Gelöscht" : r.stage.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular.tint(Self.tint(r).opacity(0.35)), in: .capsule)
        }
    }

    static func tint(_ r: InvoiceRecord) -> Color {
        if r.fileMissing { return .red }
        switch r.stage {
        case .open: return .orange
        case .paid: return .blue
        case .archived: return .green
        }
    }

    private func reviewBox(_ r: InvoiceRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Bitte prüfen", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            ForEach(r.reviewReasons, id: \.self) { Text("• \($0)").font(.callout) }
            Text("Zählt erst nach der Prüfung in der Übersicht mit.").font(.caption).foregroundStyle(.secondary)
            Button(onReviewed == nil ? "Geprüft, passt so" : "Geprüft, weiter") {
                saveIfChanged()
                model.library.markReviewed(id)
                onReviewed?()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(onReviewed == nil ? nil : KeyboardShortcut(.return, modifiers: .command))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 14))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Firma (Absender)").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 4) {
                        SupplierField(text: $fields.seller, placeholder: "Firma (Absender)",
                                      suggestions: { model.library.suppliers.suggestions(for: $0).map(\.name) },
                                      completion: { model.library.suppliers.completion(for: $0) },
                                      highlight: similarSupplier != nil, onCommit: { saveIfChanged() })
                        CopyButton(value: fields.seller, label: "Firma (Absender)")
                    }
                }
                supplierHint
            }
            field("Rechnungsnummer", text: $fields.invoiceNumber, copy: true)
            HStack {
                Toggle("Datum", isOn: $hasDate).toggleStyle(.checkbox)
                Spacer()
                DatePicker("", selection: Binding(get: { fields.invoiceDate ?? Date() }, set: { fields.invoiceDate = $0 }),
                           displayedComponents: .date)
                    .labelsHidden().disabled(!hasDate)
            }
            HStack {
                field("Betrag", text: $totalText, copy: true, highlight: amountInvalid)
                field("Währung", text: $fields.currency).frame(width: 80)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .onChange(of: focusedField) { old, _ in if old != nil { saveIfChanged() } }
    }

    /// Text in the Betrag field that is not an amount; the saved amount stays until it is fixed.
    private var amountInvalid: Bool {
        !totalText.trimmingCharacters(in: .whitespaces).isEmpty && TextRulesBridge.amount(totalText) == nil
    }

    /// A known supplier much like the typed company name, probably the same company spelled differently.
    private var similarSupplier: Supplier? {
        if case .close(let s) = model.library.suppliers.match(fields.seller) { return s }
        return nil
    }

    /// Under the company name: the closest known supplier to take over, or that the name is new.
    @ViewBuilder private var supplierHint: some View {
        if OwnCompany.isOwn(fields.seller) {
            Label("Das ist der Empfänger (Witthüs), nicht der Lieferant", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if let s = similarSupplier {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Ähnlicher Lieferant: \(s.name)").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Übernehmen") {
                    fields.seller = s.name
                    saveIfChanged()
                }
                .buttonStyle(.link)
                .help("„\(s.name)“ eintragen; die gelesene Schreibweise wird künftig automatisch zugeordnet")
                Button("Anderer") {
                    saveIfChanged()
                    model.library.rejectMatch(id, supplier: s.id)
                }
                .buttonStyle(.link)
                .help("Ist ein anderer Lieferant: wird als eigener Lieferant angelegt und nie wieder mit „\(s.name)“ verwechselt")
            }
            .font(.caption)
            .help("Gibt es diesen Lieferanten schon unter anderem Namen? „Übernehmen“ setzt den bekannten Namen ein.")
        } else if !fields.seller.trimmingCharacters(in: .whitespaces).isEmpty,
                  case .none = model.library.suppliers.match(fields.seller) {
            Label("Neuer Lieferant, wird beim Speichern angelegt", systemImage: "plus.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(_ label: String, text: Binding<String>, copy: Bool = false, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                // Return or leaving the field saves right away.
                TextField(label, text: text).textFieldStyle(.roundedBorder).labelsHidden()
                    .focused($focusedField, equals: label)
                    .onSubmit { saveIfChanged() }
                    .overlay {
                        if highlight { RoundedRectangle(cornerRadius: 6).strokeBorder(.orange, lineWidth: 2).allowsHitTesting(false) }
                    }
                if copy { CopyButton(value: text.wrappedValue, label: label) }
            }
        }
    }

    private func filing(_ r: InvoiceRecord) -> some View {
        let edited = editedFields
        let o = model.library.organizer
        let ext = r.fileURL.pathExtension.isEmpty ? "pdf" : r.fileURL.pathExtension
        let templateName = o.baseName(for: edited, paidDate: r.paidDate)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Dateiname").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("Dateiname", text: $fileName).textFieldStyle(.roundedBorder).onSubmit { saveIfChanged() }
                    Text(".\(ext)").foregroundStyle(.secondary)
                }
                templateHint(templateName, matches: fileName == templateName) { fileName = templateName }
            }
            .disabled(locked)
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Speichern & umbenennen") { save(r) }
                            .buttonStyle(.glass)
                            .disabled(locked || !isChanged(r) || fileName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([r.fileURL]) }
                            .buttonStyle(.glass)
                            .disabled(r.fileMissing)
                    }
                    if !r.fileMissing { stageControls(r) }
                    Divider()
                    printing(r)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder private func stageControls(_ r: InvoiceRecord) -> some View {
        switch r.stage {
        case .open:
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
            .disabled(locked)
        case .paid, .archived:
            HStack {
                Text("Bezahlt am \(r.paidDate?.formatted(date: .numeric, time: .omitted) ?? "–")")
                Spacer()
                Button("Als offen markieren …") { saveIfChanged(); model.askRevertPaid([id]) }.buttonStyle(.glass).disabled(locked)
            }
            HStack {
                if r.stage == .archived {
                    Label("Im Archiv", systemImage: "archivebox").foregroundStyle(.secondary)
                } else {
                    Label("Noch nicht im Archiv", systemImage: "tray").foregroundStyle(.secondary)
                    Spacer()
                    Button("Ins Archiv verschieben") {
                        saveIfChanged()
                        do { try model.library.archive([id]); if let r = record { load(r) } }
                        catch { model.lastError = error.localizedDescription }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }

    /// Print this invoice, mark it printed by hand, or move it to the trash.
    private func printing(_ r: InvoiceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { InvoicePrinter.print([r], title: r.fileURL.deletingPathExtension().lastPathComponent, model: model) } label: {
                    Label("Drucken", systemImage: "printer")
                }
                .buttonStyle(.glass)
                .disabled(r.fileMissing)
                .help("Beidseitig auf A4 drucken; danach als gedruckt markiert")
                Spacer()
                Toggle("Gedruckt", isOn: Binding(get: { r.printedAt != nil },
                                                   set: { $0 ? model.library.setPrinted([r.id], true) : model.askRevertPrinted([r.id]) }))
                    .toggleStyle(.checkbox)
                    .help("Merkt sich, welche Rechnungen schon auf Papier abgelegt sind")
            }
            if let p = r.printedAt {
                Text("Gedruckt am \(p.formatted(date: .numeric, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            }
            if !r.fileMissing {
                Button(role: .destructive) {
                    do { try model.library.trash([r.id]) } catch { model.lastError = error.localizedDescription }
                } label: {
                    Label("In den Papierkorb", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .font(.callout)
                .disabled(locked)
            }
        }
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

    private func isChanged(_ r: InvoiceRecord) -> Bool { editedFields != r.fields || fileName != currentName(r) }

    /// Saves edits that were not saved yet (Return, switching invoices, archiving).
    private func saveIfChanged() {
        guard loaded, !locked, let r = record, !r.fileMissing, isChanged(r),
              !fileName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        save(r)
    }

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
        f.total = totalText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : TextRulesBridge.amount(totalText) ?? fields.total
        if !hasDate { f.invoiceDate = nil }
        f.currency = f.currency.uppercased()
        return f
    }

    private func load(_ r: InvoiceRecord) {
        fields = r.fields
        totalText = r.fields.total.map(InvoiceText.editableAmount) ?? ""
        hasDate = r.fields.invoiceDate != nil
        paidDate = Date()
        fileName = currentName(r)
        loaded = true
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

/// Brings a deleted invoice back: from the Trash or wherever the file went, otherwise from a file the user picks.
struct RestoreButtons: View {
    @Environment(AppModel.self) private var model
    let id: InvoiceRecord.ID
    @State private var notFound = false

    var body: some View {
        Button("Wiederherstellen") {
            do { if try !model.library.restore(id) { notFound = true } } catch { model.lastError = error.localizedDescription }
        }
        .help("Holt die Datei aus dem Papierkorb oder von dort, wohin sie verschoben wurde, zurück")
        Button("Datei auswählen …") { pick() }
            .help("Die Datei selbst suchen, etwa wenn sie umbenannt oder kopiert wurde")
            .alert("Datei nicht gefunden", isPresented: $notFound) {
                Button("Datei auswählen …") { pick() }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Die Datei ist weder im Papierkorb noch an einem neuen Ort. Sie können sie selbst auswählen.")
            }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .xml, .image]
        panel.prompt = "Zuordnen"
        if let r = model.library.records.first(where: { $0.id == id }) {
            panel.directoryURL = r.fileURL.deletingLastPathComponent()
            panel.message = "Datei für \(r.fields.seller.isEmpty ? r.fileURL.lastPathComponent : r.fields.seller) auswählen"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.library.relink(id, to: url) } catch { model.lastError = error.localizedDescription }
    }
}

/// A handle on top of the PDF: drag it to Finder, Mail or another app to hand over a copy of the file.
struct FileDragChip: View {
    let url: URL

    var body: some View {
        Label(url.lastPathComponent, systemImage: "doc.richtext")
            .font(.callout).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
            .onDrag {
                // A copy of the file under its own name; the original stays where it is.
                let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
                provider.suggestedName = url.deletingPathExtension().lastPathComponent
                return provider
            } preview: {
                Label(url.lastPathComponent, systemImage: "doc.richtext").padding(8)
            }
            .help("Ziehen, um die Datei in den Finder, eine Mail oder eine andere App zu legen")
    }
}

/// Invoices whose file was deleted, in the app or in Finder. They no longer count anywhere and can be cleared.
struct DeletedList: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: InvoiceRecord.ID?
    @State private var confirming = false

    var body: some View {
        List(model.library.deleted, selection: $selection) { r in
            InvoiceRow(record: r).tag(r.id)
                .contextMenu { RestoreButtons(id: r.id) }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.library.deleted.isEmpty {
                Button("Gelöschte leeren", role: .destructive) { confirming = true }
                    .buttonStyle(.glass)
                    .padding(10)
            }
        }
        .confirmationDialog("Alle gelöschten Rechnungen aus der App entfernen?", isPresented: $confirming) {
            Button("Leeren", role: .destructive) { selection = nil; model.library.clearDeleted() }
        } message: {
            Text("Die Dateien selbst sind schon weg (Papierkorb oder Finder). Das lässt sich nicht rückgängig machen.")
        }
        .overlay {
            if model.library.deleted.isEmpty {
                ContentUnavailableView("Nichts gelöscht", systemImage: "trash",
                                       description: Text("Rechnungen, deren Datei gelöscht wurde, auch im Finder, erscheinen hier."))
            }
        }
    }
}

struct SkippedList: View {
    @Environment(AppModel.self) private var model
    @State private var stageRequest: StageRequest?

    var body: some View {
        List(model.library.skipped) { s in
            VStack(alignment: .leading, spacing: 3) {
                Text(s.origin.attachmentName).fontWeight(.medium)
                Text(s.origin.subject).font(.caption)
                Text(s.reason).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Als Rechnung ablegen …") {
                        stageRequest = StageRequest(title: "Als Rechnung ablegen", detail: s.origin.attachmentName, inPlace: s.inPlace == true) { stage, date in
                            Task {
                                do { try await model.library.importSkipped(s.id, stage: stage, paidDate: date, extractor: model.extractor) }
                                catch { model.lastError = error.localizedDescription }
                            }
                        }
                    }
                    .buttonStyle(.glass)
                    Button("Öffnen") { NSWorkspace.shared.open(URL(fileURLWithPath: s.storedPath)) }.buttonStyle(.glass)
                    Button(s.inPlace == true ? "Entfernen" : "Löschen", role: .destructive) { model.library.deleteSkipped(s.id) }
                        .buttonStyle(.glass)
                        .help(s.inPlace == true ? "Aus der Liste entfernen; die Datei bleibt im Ordner" : "Den gespeicherten Anhang löschen")
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
        .stagePrompt($stageRequest)
        .overlay {
            if model.library.skipped.isEmpty {
                ContentUnavailableView("Nichts übersprungen", systemImage: "tray",
                                       description: Text("PDFs aus Mails und Ordnern, die keine Rechnungen sind, erscheinen hier."))
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

/// Copies a field's value; stays usable while the fields are locked.
struct CopyButton: View {
    let value: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? .green : .secondary)
        .disabled(value.isEmpty)
        // Copying never changes anything, so it works on locked invoices too.
        .environment(\.isEnabled, !value.isEmpty)
        .help("\(label) kopieren")
    }
}

/// Skonto, due date and direct debit as read from the invoice, with what paying in time saves.
struct PaymentTermsBox: View {
    let record: InvoiceRecord
    let terms: PaymentTerms

    var body: some View {
        let invoiced = record.fields.invoiceDate
        let currency = record.fields.currency
        let offer = record.skontoOffer()
        VStack(alignment: .leading, spacing: 8) {
            Label("Zahlungsbedingungen", systemImage: "calendar.badge.clock").font(.headline)
            if let p = terms.discountPercent {
                let deadline = terms.discountDeadline(invoiceDate: invoiced)
                let saving = terms.discount(on: record.fields.total)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Skonto \(Self.percent(p))").fontWeight(.semibold)
                        Spacer()
                        if let saving { Text("− " + MenuBarView.money(saving, currency)).monospacedDigit().fontWeight(.semibold) }
                    }
                    if let deadline {
                        Text("Frist: \(deadline.formatted(date: .numeric, time: .omitted))" + daysText(offer, deadline: deadline))
                            .font(.callout)
                    } else if terms.directDebit {
                        Text("Wird beim Abbuchen abgezogen").font(.callout)
                    } else {
                        Text("Keine Frist angegeben").font(.callout).foregroundStyle(.secondary)
                    }
                    if let total = record.fields.total, let saving, offer != nil {
                        Text("Statt \(MenuBarView.money(total, currency)) nur \(MenuBarView.money(total - saving, currency)) überweisen")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(skontoTint(offer: offer, deadline: deadline).opacity(0.22)), in: .rect(cornerRadius: 10))
            }
            if let due = terms.due(invoiceDate: invoiced) {
                row(terms.directDebit ? "Abbuchung am" : "Fällig am", due.formatted(date: .numeric, time: .omitted),
                    late: record.stage == .open && !terms.directDebit && Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date()))
            } else if terms.netDays == 0 {
                row("Fällig", "sofort")
            }
            if terms.directDebit {
                Label("Wird abgebucht, keine Überweisung nötig", systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.secondary)
            }
            if !terms.text.isEmpty {
                Text(terms.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .help("So steht es in der Rechnung")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func row(_ title: String, _ value: String, late: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(late ? .red : .primary).fontWeight(late ? .semibold : .regular)
        }
        .font(.callout)
    }

    private func daysText(_ offer: SkontoOffer?, deadline: Date) -> String {
        guard record.stage == .open else { return "" }
        guard let left = offer?.daysLeft() else { return " · abgelaufen" }
        return left == 0 ? " · heute letzter Tag" : left == 1 ? " · noch 1 Tag" : " · noch \(left) Tage"
    }

    private func skontoTint(offer: SkontoOffer?, deadline: Date?) -> Color {
        guard record.stage == .open else { return .clear }
        guard offer != nil else { return deadline == nil ? .clear : .red }
        return (offer?.daysLeft() ?? 99) <= 2 ? .orange : .green
    }

    static func percent(_ p: Decimal) -> String {
        NSDecimalNumber(decimal: p).stringValue.replacingOccurrences(of: ".", with: ",") + " %"
    }
}
