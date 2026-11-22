import SwiftUI
import WitthuesCore

/// Invoices picked for „Gemeinsam bearbeiten“, in table order.
struct BulkEditRequest: Identifiable {
    let id = UUID()
    let ids: [InvoiceRecord.ID]
}

/// Sets the same company, status, printed mark or check for many invoices at once, after a confirmation.
struct BulkEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [InvoiceRecord.ID]

    @State private var setCompany = false
    @State private var company = ""
    @State private var setStatus = false
    @State private var paid = true
    @State private var paidDate = Date()
    @State private var setPrinted = false
    @State private var printed = true
    @State private var checked = false
    @State private var confirming = false

    private var trimmedCompany: String { company.trimmingCharacters(in: .whitespaces) }

    private var edit: BulkEdit {
        BulkEdit(company: setCompany ? trimmedCompany : nil, paid: setStatus ? paid : nil, paidDate: paidDate,
                 printed: setPrinted ? printed : nil, checked: checked)
    }

    private var countText: String { ids.count == 1 ? "1 Rechnung" : "\(ids.count) Rechnungen" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(countText) gemeinsam bearbeiten").font(.headline)
                Text("Nur angehakte Angaben werden geändert. Alles andere bleibt bei jeder Rechnung, wie es ist.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Toggle("Firma", isOn: $setCompany).toggleStyle(.checkbox)
                    SupplierField(text: $company, placeholder: "Firma (Absender) für alle",
                                  suggestions: { model.library.suppliers.suggestions(for: $0).map(\.name) },
                                  completion: { model.library.suppliers.completion(for: $0) },
                                  highlight: false, onCommit: {})
                        .opacity(setCompany ? 1 : 0.5)
                }
                GridRow {
                    Toggle("Status", isOn: $setStatus).toggleStyle(.checkbox)
                    HStack {
                        Picker("Status", selection: $paid) {
                            Text("Offen").tag(false)
                            Text("Bezahlt").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        if paid {
                            DatePicker("am", selection: $paidDate, displayedComponents: .date)
                        }
                    }
                    .disabled(!setStatus)
                }
                GridRow {
                    Toggle("Gedruckt", isOn: $setPrinted).toggleStyle(.checkbox)
                    Picker("Gedruckt", selection: $printed) {
                        Text("Gedruckt").tag(true)
                        Text("Nicht gedruckt").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(!setPrinted)
                }
                GridRow {
                    Toggle("Geprüft", isOn: $checked).toggleStyle(.checkbox)
                    Text("„Prüfen“-Hinweise entfernen; die Rechnungen zählen dann in der Übersicht mit.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen …") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(edit.isEmpty || (setCompany && trimmedCompany.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
        // Typing a company or changing a value ticks its box, so nothing typed is silently ignored.
        .onChange(of: company) { if !trimmedCompany.isEmpty { setCompany = true } }
        .onChange(of: paid) { setStatus = true }
        .onChange(of: paidDate) { setStatus = true }
        .onChange(of: printed) { setPrinted = true }
        .alert("\(countText) ändern?", isPresented: $confirming) {
            Button("Ändern") { apply() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text((edit.summary + (edit.company != nil || edit.paid != nil ? ["", "Die Dateien werden dazu umbenannt oder verschoben."] : []))
                .joined(separator: "\n"))
        }
    }

    private func apply() {
        let problems = model.library.apply(edit, to: ids)
        if !problems.isEmpty {
            model.lastError = "Nicht alle Rechnungen konnten geändert werden:\n" + problems.joined(separator: "\n")
        }
        dismiss()
    }
}

/// Every saved view and starred folder: open, star, rename or delete them in one place.
struct ViewsManager: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var open: (SavedView.ID) -> Void

    @State private var editing: SavedView?
    @State private var deleting: SavedView?

    var body: some View {
        let views = model.library.views.filter { $0.isFolder != true }
        let folders = model.library.views.filter { $0.isFolder == true }
        VStack(alignment: .leading, spacing: 12) {
            Text("Ansichten verwalten").font(.headline)
            List {
                Section("Gespeicherte Ansichten") {
                    if views.isEmpty {
                        Text("Noch keine. Filter setzen und „Als Ansicht speichern …“ wählen.").foregroundStyle(.secondary)
                    }
                    ForEach(views) { row($0) }
                }
                if !folders.isEmpty {
                    Section("Ordner in der Seitenleiste") {
                        ForEach(folders) { row($0) }
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .sheet(item: $editing) { v in
            ViewEditor(title: v.isFolder == true ? "Ordner bearbeiten" : "Ansicht bearbeiten", name: v.name, icon: v.symbol) { name, icon in
                guard let i = model.library.views.firstIndex(where: { $0.id == v.id }) else { return }
                model.library.views[i].name = name
                model.library.views[i].icon = icon
            }
        }
        .alert("„\(deleting?.name ?? "")“ löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Löschen", role: .destructive) {
                if let id = deleting?.id { model.library.views.removeAll { $0.id == id } }
                deleting = nil
            }
            Button("Abbrechen", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting?.isFolder == true
                 ? "Der Ordner und seine Dateien bleiben erhalten; nur der Eintrag in der Seitenleiste verschwindet."
                 : "Die Rechnungen bleiben erhalten; nur die gespeicherten Filter werden gelöscht.")
        }
    }

    private func row(_ v: SavedView) -> some View {
        HStack(spacing: 10) {
            Image(systemName: v.symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(v.name)
                if v.isFolder == true, let f = v.folder {
                    Text(f).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(v.rules.isEmpty ? "Keine Filter" : v.rules.count == 1 ? "1 Filter" : "\(v.rules.count) Filter")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if v.isFolder != true {
                Button { setStar(v) } label: { Image(systemName: v.starred ? "star.fill" : "star") }
                    .foregroundStyle(v.starred ? .yellow : .secondary)
                    .help(v.starred ? "Aus der Seitenleiste entfernen" : "In der Seitenleiste zeigen")
            }
            Button { editing = v } label: { Image(systemName: "pencil") }
                .help("Name und Symbol ändern")
            Button { open(v.id); dismiss() } label: { Image(systemName: "arrow.right.circle") }
                .help("Öffnen")
            Button(role: .destructive) { deleting = v } label: { Image(systemName: "trash") }
                .foregroundStyle(.red)
                .help("Löschen")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(count: 2) { open(v.id); dismiss() }
    }

    private func setStar(_ v: SavedView) {
        guard let i = model.library.views.firstIndex(where: { $0.id == v.id }) else { return }
        model.library.views[i].starred.toggle()
    }
}
