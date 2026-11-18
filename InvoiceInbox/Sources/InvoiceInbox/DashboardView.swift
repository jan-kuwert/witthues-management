import Charts
import InvoiceCore
import SwiftUI

/// Overview of all filed invoices: totals, monthly amounts, top companies, open invoices.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    /// Opens an invoice in the list.
    var open: (InvoiceRecord.ID) -> Void
    @State private var period: Period = .thisMonth

    enum Period: String, CaseIterable, Identifiable {
        case thisMonth = "Dieser Monat", thisYear = "Dieses Jahr", all = "Gesamt"
        var id: Self { self }
    }

    struct MonthAmount: Identifiable {
        var month: Date
        var status: String
        var amount: Double
        var id: String { "\(month.timeIntervalSince1970)-\(status)" }
    }

    struct NamedValue: Identifiable {
        var name: String
        var value: Double
        var id: String { name }
    }

    var body: some View {
        let all = model.library.records
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Übersicht").font(.largeTitle.weight(.semibold))
                    Spacer()
                    Picker("Zeitraum", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 340)
                }
                if all.isEmpty {
                    ContentUnavailableView("Noch keine Rechnungen", systemImage: "chart.bar",
                                           description: Text("Diagramme erscheinen, sobald Rechnungen abgelegt sind."))
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    kpis
                    card(period == .thisMonth ? "Betrag pro Tag" : "Betrag pro Monat", subtitle: "Nach Rechnungsdatum, \(currency)") { monthlyChart }
                    HStack(alignment: .top, spacing: 16) {
                        card("Größte Lieferanten", subtitle: "Summe \(currency) im Zeitraum") { companiesChart }
                        card("Wie Rechnungen gelesen wurden", subtitle: "Alle Rechnungen im Zeitraum") { sourcesChart }
                            .frame(width: 300)
                    }
                    card("Warten auf Zahlung", subtitle: "Älteste offene Rechnungen zuerst") { unpaidList }
                    if otherCurrencyCount > 0 {
                        Text("\(plural(otherCurrencyCount)) in anderer Währung \(otherCurrencyCount == 1 ? "wird" : "werden") gezählt, aber nicht in die Beträge eingerechnet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .background {
            LinearGradient(colors: [Color(red: 0.93, green: 0.94, blue: 0.95), Color(red: 0.84, green: 0.86, blue: 0.89)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.6)
                .ignoresSafeArea()
        }
    }

    // MARK: - Data

    private func currencyOf(_ r: InvoiceRecord) -> String { r.fields.currency.isEmpty ? "EUR" : r.fields.currency.uppercased() }
    private func amount(_ r: InvoiceRecord) -> Double { r.fields.total.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0 }
    private func date(_ r: InvoiceRecord) -> Date { r.fields.invoiceDate ?? r.importedAt }

    /// The most common currency; amounts in other currencies are left out of sums rather than mixed.
    private var currency: String {
        let counts = Dictionary(grouping: model.library.records.filter { $0.fields.total != nil }, by: currencyOf).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? "EUR"
    }

    private var periodStart: Date? {
        let cal = Calendar.current
        switch period {
        case .thisMonth: return cal.dateInterval(of: .month, for: Date())!.start
        case .thisYear: return cal.dateInterval(of: .year, for: Date())!.start
        case .all: return nil
        }
    }

    private var inPeriod: [InvoiceRecord] {
        guard let start = periodStart else { return model.library.records }
        return model.library.records.filter { date($0) >= start }
    }

    private var countable: [InvoiceRecord] { inPeriod.filter { currencyOf($0) == currency } }
    private var otherCurrencyCount: Int { inPeriod.filter { $0.fields.total != nil && currencyOf($0) != currency }.count }

    private func sum(_ list: [InvoiceRecord]) -> Double { list.reduce(0) { $0 + amount($1) } }
    private func money(_ v: Double) -> String { v.formatted(.currency(code: currency).precision(.fractionLength(0...2))) }

    /// Bars are days for "This month" and months otherwise.
    private var bucket: Calendar.Component { period == .thisMonth ? .day : .month }

    private var monthly: [MonthAmount] {
        let cal = Calendar.current
        var sums: [String: MonthAmount] = [:]
        for r in countable {
            let month = cal.dateInterval(of: bucket, for: date(r))!.start
            let status = r.status == .paid ? "Bezahlt" : "Offen"
            sums["\(month.timeIntervalSince1970)-\(status)", default: MonthAmount(month: month, status: status, amount: 0)].amount += amount(r)
        }
        return sums.values.sorted { $0.month < $1.month }
    }

    private var topCompanies: [NamedValue] {
        Dictionary(grouping: countable) { $0.fields.seller.isEmpty ? "Unbekannt" : $0.fields.seller }
            .map { NamedValue(name: $0.key, value: sum($0.value)) }
            .sorted { $0.value > $1.value }
            .prefix(8).map { $0 }
    }

    private var sources: [NamedValue] {
        Dictionary(grouping: inPeriod, by: \.source.label)
            .map { NamedValue(name: $0.key, value: Double($0.value.count)) }
            .sorted { $0.value > $1.value }
    }

    // MARK: - Views

    private var kpis: some View {
        let unpaid = model.library.records.filter { $0.status == .unpaid }
        let unpaidCountable = unpaid.filter { currencyOf($0) == currency }
        return HStack(spacing: 16) {
            kpi("Offen", value: money(sum(unpaidCountable)), detail: "\(plural(unpaid.count)) offen",
                icon: "tray.full", tint: .orange)
            kpi("Bezahlt", value: money(sum(countable.filter { $0.status == .paid })),
                detail: plural(inPeriod.filter { $0.status == .paid }.count), icon: "checkmark.circle", tint: .green)
            kpi("Gesamt", value: money(sum(countable)), detail: plural(inPeriod.count), icon: "sum", tint: .blue)
            kpi("Zu prüfen", value: "\(model.library.records.filter(\.needsReview).count)",
                detail: "\(model.library.skipped.count) übersprungen", icon: "exclamationmark.bubble", tint: .purple)
        }
    }

    private func plural(_ n: Int) -> String { n == 1 ? "1 Rechnung" : "\(n) Rechnungen" }

    private func kpi(_ title: String, value: String, detail: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.callout.weight(.medium)).foregroundStyle(tint)
            Text(value).font(.title.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .rect(cornerRadius: 18))
    }

    private func card<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var monthlyChart: some View {
        Chart(monthly) { m in
            BarMark(x: .value("Datum", m.month, unit: bucket), y: .value("Betrag", m.amount))
                .foregroundStyle(by: .value("Status", m.status))
                .cornerRadius(4)
        }
        .chartForegroundStyleScale(["Offen": Color.orange, "Bezahlt": Color.green])
        .chartXScale(domain: monthDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: bucket, count: period == .thisMonth ? 5 : 1)) { _ in
                AxisGridLine()
                AxisValueLabel(format: period == .thisMonth ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated).year(.twoDigits))
            }
        }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(money(d)) } } } }
        .frame(height: 240)
        .overlay { if countable.isEmpty { Text("Keine Rechnungen im Zeitraum").foregroundStyle(.secondary) } }
    }

    /// Shows every day or month of the period, including ones without invoices.
    private var monthDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let end = cal.dateInterval(of: .month, for: Date())!.end
        let first = periodStart ?? monthly.first.map(\.month) ?? cal.date(byAdding: .month, value: -11, to: end)!
        return first...end
    }

    private var companiesChart: some View {
        let data = topCompanies
        return Chart(data) { c in
            BarMark(x: .value("Betrag", c.value), y: .value("Firma", c.name))
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing) { Text(money(c.value)).font(.caption).foregroundStyle(.secondary) }
        }
        .chartXAxis(.hidden)
        .overlay { if data.isEmpty { Text("Keine Rechnungen im Zeitraum").foregroundStyle(.secondary) } }
        .frame(height: CGFloat(max(data.count, 1)) * 34 + 10)
    }

    private var sourcesChart: some View {
        Chart(sources) { s in
            SectorMark(angle: .value("Rechnungen", s.value), innerRadius: .ratio(0.6), angularInset: 2)
                .foregroundStyle(by: .value("Quelle", s.name))
                .cornerRadius(4)
        }
        .chartForegroundStyleScale([ExtractionSource.eInvoiceXML.label: Color.green, ExtractionSource.appleIntelligence.label: Color.blue,
                                    ExtractionSource.textRules.label: Color.orange, ExtractionSource.manual.label: Color.gray])
        .chartLegend(position: .bottom, alignment: .leading)
        .overlay { if sources.isEmpty { Text("Keine Rechnungen im Zeitraum").foregroundStyle(.secondary) } }
        .frame(height: 220)
    }

    private var unpaidList: some View {
        let open = model.library.records.filter { $0.status == .unpaid }.sorted { date($0) < date($1) }.prefix(8)
        return VStack(spacing: 0) {
            if open.isEmpty {
                Text("Alles bezahlt.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(open)) { r in
                Button { self.open(r.id) } label: {
                    HStack {
                        Text(r.fields.seller.isEmpty ? "Unbekannte Firma" : r.fields.seller).lineLimit(1)
                        Text(r.fields.invoiceNumber).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(daysOpen(r)).foregroundStyle(.secondary)
                        Text(r.fields.total.map { MenuBarView.money($0, r.fields.currency) } ?? "–").monospacedDigit().frame(width: 110, alignment: .trailing)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if r.id != open.last?.id { Divider() }
            }
        }
    }

    private func daysOpen(_ r: InvoiceRecord) -> String {
        let days = Calendar.current.dateComponents([.day], from: date(r), to: Date()).day ?? 0
        return days <= 0 ? "heute" : days == 1 ? "1 Tag" : "\(days) Tage"
    }
}
