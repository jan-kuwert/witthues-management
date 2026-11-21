import SwiftUI
import WitthuesCore

/// The suppliers: names to edit as the user likes them, other spellings, invoices and totals per supplier,
/// and merging suppliers that are the same company.
struct SupplierView: View {
    @Environment(AppModel.self) private var model
    let open: (InvoiceRecord.ID) -> Void
    @State private var selection: Set<Supplier.ID> = []
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\SupplierRow.name)]

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Suchen", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                mergeMenu
                Button {
                    let s = Supplier(name: "Neuer Lieferant")
                    model.library.suppliers.append(s)
                    selection = [s.id]
                } label: {
                    Label("Lieferant hinzufügen", systemImage: "plus")
                }
                .buttonStyle(.glass)
            }
            suggestions
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { r in SupplierNameField(name: r.supplier.name) { rename(r.supplier.id, $0) } }
                    .width(min: 160, ideal: 240)
                TableColumn("Andere Schreibweisen") { r in
                    Text(r.supplier.aliases.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
                        .help(r.supplier.aliases.joined(separator: "\n"))
                }
                .width(min: 120, ideal: 260)
                TableColumn("Rechnungen", value: \.count) { r in Text("\(r.count)").monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("Summe", value: \.total) { r in
                    Text(r.count == 0 ? "–" : MenuBarView.money(r.total, r.currency)).monospacedDigit()
                }
                .width(min: 90, ideal: 120)
                TableColumn("Letzte Rechnung", value: \.last) { r in
                    Text(r.last == .distantPast ? "–" : r.last.formatted(date: .numeric, time: .omitted))
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: Supplier.ID.self) { ids in
                let chosen = model.library.suppliers.filter { ids.contains($0.id) }
                if chosen.count > 1 {
                    ForEach(chosen) { s in Button("Zusammenführen zu „\(s.name)“") { merge(ids, into: s.id) } }
                    Divider()
                }
                if chosen.count == 1, let s = chosen.first,
                   let latest = model.library.records(of: s).filter({ !$0.fileMissing }).max(by: { $0.importedAt < $1.importedAt }) {
                    Button("Neueste Rechnung öffnen") { open(latest.id) }
                }
                Button(chosen.count == 1 ? "Lieferant entfernen" : "\(chosen.count) Lieferanten entfernen", role: .destructive) {
                    model.library.suppliers.removeAll { ids.contains($0.id) }
                }
                .help("Nur aus der Liste; Rechnungen bleiben unverändert")
            }
            Text("Namen per Doppelklick ändern: Rechnungen und Dateinamen des Lieferanten bekommen den neuen Namen, der alte bleibt als Schreibweise erkannt. Mehrere auswählen (⌘-Klick) zum Zusammenführen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .navigationTitle("Lieferanten")
    }

    private struct SupplierRow: Identifiable {
        let supplier: Supplier
        let count: Int
        let total: Decimal
        let currency: String
        let last: Date
        var id: Supplier.ID { supplier.id }
        var name: String { supplier.name }
    }

    private var rows: [SupplierRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let live = model.library.liveRecords
        return model.library.suppliers
            .filter { q.isEmpty || ([$0.name] + $0.aliases).contains { $0.lowercased().contains(q) } }
            .map { s in
                let keys = Set(([s.name] + s.aliases).map(Supplier.key))
                let mine = live.filter { keys.contains(Supplier.key($0.fields.seller)) }
                // Summed in the supplier's usual currency; amounts in others are left out rather than mixed.
                let code = { (r: InvoiceRecord) in r.fields.currency.isEmpty ? "EUR" : r.fields.currency.uppercased() }
                let currency = Dictionary(grouping: mine, by: code).max { $0.value.count < $1.value.count }?.key ?? "EUR"
                return SupplierRow(supplier: s, count: mine.count,
                                   total: mine.filter { code($0) == currency }.compactMap(\.fields.total).reduce(0, +), currency: currency,
                                   last: mine.compactMap(\.fields.invoiceDate).max() ?? .distantPast)
            }
            .sorted(using: sortOrder)
    }

    /// Pairs that look like the same company, each with a button per direction.
    @ViewBuilder private var suggestions: some View {
        let pairs = model.library.suppliers.similarPairs().prefix(5).map { (id: $0.0.id.uuidString + $0.1.id.uuidString, a: $0.0, b: $0.1) }
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Vielleicht dieselbe Firma", systemImage: "arrow.triangle.merge").font(.headline)
                ForEach(pairs, id: \.id) { pair in
                    let a = pair.a, b = pair.b
                    HStack(spacing: 8) {
                        Text(a.name).fontWeight(.medium).lineLimit(1)
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                        Text(b.name).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Button("Zu „\(a.name)“") { merge([a.id, b.id], into: a.id) }
                        Button("Zu „\(b.name)“") { merge([a.id, b.id], into: b.id) }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 14))
        }
    }

    private var mergeMenu: some View {
        let chosen = model.library.suppliers.filter { selection.contains($0.id) }
        return Menu {
            ForEach(chosen) { s in Button("Alle zu „\(s.name)“") { merge(selection, into: s.id) } }
        } label: {
            Label("Zusammenführen", systemImage: "arrow.triangle.merge")
        }
        .fixedSize()
        .disabled(chosen.count < 2)
        .help("Ausgewählte Lieferanten zu einem zusammenführen; ihre Rechnungen bekommen dessen Namen")
    }

    /// Renames a supplier and returns the name it has afterwards.
    private func rename(_ id: Supplier.ID, _ name: String) -> String {
        do { try model.library.renameSupplier(id, to: name) } catch { model.lastError = error.localizedDescription }
        return model.library.suppliers.first { $0.id == id }?.name ?? name
    }

    private func merge(_ ids: Set<Supplier.ID>, into target: Supplier.ID) {
        do {
            try model.library.mergeSuppliers(ids, into: target)
            selection = [target]
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}

/// The supplier's name, saved (and given to its invoices) with Return or when leaving the field.
/// Takes no environment: table cells of a just-merged supplier can update after leaving the table.
private struct SupplierNameField: View {
    let name: String
    let rename: (String) -> String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear { text = name }
            .onChange(of: name) { text = name }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard text != name else { return }
        text = rename(text)
    }
}
