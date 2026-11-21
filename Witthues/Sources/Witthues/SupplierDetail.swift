import SwiftUI
import WitthuesCore

/// One supplier: its name (to change), figures over all its invoices, address, mail addresses, other spellings and
/// the invoices themselves (double-click opens one).
struct SupplierDetail: View {
    @Environment(AppModel.self) private var model
    let id: Supplier.ID
    let open: (InvoiceRecord.ID) -> Void
    let back: () -> Void
    @State private var address = ""

    private var supplier: Supplier? { model.library.suppliers.first { $0.id == id } }

    var body: some View {
        if let s = supplier {
            let invoices = model.library.records(of: s).filter { !$0.fileMissing }
            let stats = SupplierStats(invoices)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Button(action: back) { Label("Lieferanten", systemImage: "chevron.left") }
                            .buttonStyle(.glass)
                        SupplierNameField(name: s.name) { name in
                            do { try model.library.renameSupplier(id, to: name) } catch { model.lastError = error.localizedDescription }
                            return model.library.suppliers.first { $0.id == id }?.name ?? name
                        }
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: 420)
                        .help("Name ändern: Rechnungen und Dateinamen bekommen ihn, der alte bleibt als Schreibweise erkannt")
                    }
                    kpis(stats)
                    HStack(alignment: .top, spacing: 16) {
                        contact(s, invoices)
                        spellings(s)
                    }
                    invoiceTable(invoices)
                }
                .padding(16)
            }
            .navigationTitle(s.name)
            .task(id: id) {
                await model.library.findAddress(id)
                address = supplier?.address ?? ""
            }
        }
    }

    // MARK: - Figures

    private func kpis(_ st: SupplierStats) -> some View {
        let m = { (d: Decimal) in MenuBarView.money(d, st.currency) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            kpi("Rechnungen", "\(st.count)", st.first.map { "seit \($0.formatted(date: .numeric, time: .omitted))" } ?? "", "doc.on.doc", .blue)
            kpi("Bezahlt", m(st.paid), "\(st.paidCount) bezahlt", "checkmark.circle", .green)
            kpi("Offen", m(st.open), "\(st.openCount) offen", "tray.full", .orange)
            kpi("Ø je Rechnung", st.count == 0 ? "–" : m(st.average), "Gesamt \(m(st.total))", "sum", .purple)
            kpi("Skonto gespart", m(st.skontoSaved), st.skontoMissed > 0 ? "Verpasst: \(m(st.skontoMissed))" : "bei Zahlung in der Frist",
                "percent", .green)
            kpi("Skonto möglich", m(st.skontoOpen), "bei offenen Rechnungen", "clock.badge.exclamationmark", .teal)
        }
    }

    private func kpi(_ title: String, _ value: String, _ detail: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.callout.weight(.medium)).foregroundStyle(tint)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .rect(cornerRadius: 16))
    }

    // MARK: - Address and spellings

    private func contact(_ s: Supplier, _ invoices: [InvoiceRecord]) -> some View {
        let mails = Self.mailAddresses(invoices)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Kontakt", systemImage: "building.2").font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                Text("Adresse").font(.caption).foregroundStyle(.secondary)
                TextField("Aus den Rechnungen, sonst hier eintragen", text: $address, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit(saveAddress)
                    .onChange(of: id) { address = supplier?.address ?? "" }
                    .onDisappear(perform: saveAddress)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("E-Mail-Adressen").font(.caption).foregroundStyle(.secondary)
                if mails.isEmpty {
                    Text("Keine, die Rechnungen kamen nicht per Mail").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(mails, id: \.self) { mail in
                    if let url = URL(string: "mailto:\(mail)") {
                        Link(mail, destination: url).font(.callout)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func saveAddress() {
        guard let i = model.library.suppliers.firstIndex(where: { $0.id == id }) else { return }
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.library.suppliers[i].address ?? "" != a { model.library.suppliers[i].address = a.isEmpty ? nil : a }
    }

    private func spellings(_ s: Supplier) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Andere Schreibweisen", systemImage: "character.cursor.ibeam").font(.headline)
            if s.aliases.isEmpty {
                Text("Keine. Beim Umbenennen oder Zusammenführen kommen die alten Namen hierher.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(s.aliases, id: \.self) { alias in
                HStack {
                    Text(alias)
                    Spacer()
                    Button {
                        guard let i = model.library.suppliers.firstIndex(where: { $0.id == id }) else { return }
                        model.library.suppliers[i].aliases.removeAll { $0 == alias }
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Diese Schreibweise nicht mehr diesem Lieferanten zuordnen")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Invoices

    private func invoiceTable(_ invoices: [InvoiceRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rechnungen", systemImage: "doc.text").font(.headline)
            Table(invoices.sorted { ($0.fields.invoiceDate ?? $0.importedAt) > ($1.fields.invoiceDate ?? $1.importedAt) }) {
                TableColumn("Rechnungsdatum") { r in Text(r.fields.invoiceDate?.formatted(date: .numeric, time: .omitted) ?? "–") }
                TableColumn("Rechnungsnummer") { r in Text(r.fields.invoiceNumber.isEmpty ? "–" : r.fields.invoiceNumber) }
                TableColumn("Betrag") { r in
                    Text(r.fields.total.map { MenuBarView.money($0, r.fields.currency) } ?? "–").monospacedDigit()
                }
                TableColumn("Status") { r in
                    Text(r.stage.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(InvoiceDetail.tint(r).opacity(0.2), in: .capsule)
                }
                TableColumn("Bezahlt am") { r in Text(r.paidDate?.formatted(date: .numeric, time: .omitted) ?? "–") }
                TableColumn("Skonto") { r in Text(SupplierStats.skontoLabel(r)).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: InvoiceRecord.ID.self) { ids in
                if let id = ids.first { Button("Öffnen") { open(id) } }
            } primaryAction: { ids in
                if let id = ids.first { open(id) }
            }
            .frame(minHeight: 260)
            Text("Doppelklick öffnet die Rechnung mit PDF.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Mail addresses the supplier's invoices came from, most frequent first.
    static func mailAddresses(_ invoices: [InvoiceRecord]) -> [String] {
        let re = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
        var counts: [String: Int] = [:]
        for r in invoices {
            let s = r.origin.from
            for m in re?.matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? [] {
                if let range = Range(m.range, in: s) { counts[s[range].lowercased(), default: 0] += 1 }
            }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }
}

/// Figures over one supplier's invoices, summed in its usual currency.
struct SupplierStats {
    var currency = "EUR"
    var count = 0, paidCount = 0, openCount = 0
    var total: Decimal = 0, paid: Decimal = 0, open: Decimal = 0
    /// Skonto of invoices paid within the deadline (assuming it was deducted), and of those paid too late.
    var skontoSaved: Decimal = 0, skontoMissed: Decimal = 0
    /// Skonto open invoices can still save.
    var skontoOpen: Decimal = 0
    var first: Date?
    var average: Decimal { count == 0 ? 0 : total / Decimal(count) }

    init(_ invoices: [InvoiceRecord]) {
        let code = { (r: InvoiceRecord) in r.fields.currency.isEmpty ? "EUR" : r.fields.currency.uppercased() }
        currency = Dictionary(grouping: invoices, by: code).max { $0.value.count < $1.value.count }?.key ?? "EUR"
        count = invoices.count
        first = invoices.compactMap(\.fields.invoiceDate).min()
        for r in invoices where code(r) == currency {
            let amount = r.fields.total ?? 0
            total += amount
            if r.status == .paid {
                paidCount += 1
                paid += amount
                if let t = r.fields.terms, let d = t.discount(on: r.fields.total) {
                    if t.discountAvailable(invoiceDate: r.fields.invoiceDate, on: r.paidDate ?? Date()) { skontoSaved += d } else { skontoMissed += d }
                }
            } else {
                openCount += 1
                open += amount
                skontoOpen += r.skontoOffer()?.amount ?? 0
            }
        }
    }

    /// „2 % · 23,80 €“, with whether it was used or still possible.
    static func skontoLabel(_ r: InvoiceRecord) -> String {
        guard let t = r.fields.terms, let p = t.discountPercent else { return "–" }
        var s = PaymentTermsBox.percent(p)
        if let d = t.discount(on: r.fields.total) { s += " · " + MenuBarView.money(d, r.fields.currency) }
        if r.status == .paid {
            s += t.discountAvailable(invoiceDate: r.fields.invoiceDate, on: r.paidDate ?? Date()) ? " · genutzt" : " · verpasst"
        } else if r.skontoOffer() == nil {
            s += " · abgelaufen"
        }
        return s
    }
}
