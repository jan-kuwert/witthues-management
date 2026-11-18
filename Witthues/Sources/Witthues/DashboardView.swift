import Charts
import WitthuesCore
import SwiftUI

/// A block on the dashboard. Each one appears at most once.
enum DashboardWidget: String, Codable, CaseIterable, Identifiable {
    case kpis, amounts, counts, payments, companies, sources, paymentTime, unpaid, review

    var id: Self { self }

    var title: String {
        switch self {
        case .kpis: return "Kennzahlen"
        case .amounts: return "Betrag im Zeitverlauf"
        case .counts: return "Anzahl Rechnungen"
        case .payments: return "Zahlungen"
        case .companies: return "Größte Lieferanten"
        case .sources: return "Wie Rechnungen gelesen wurden"
        case .paymentTime: return "Zahlungsdauer"
        case .unpaid: return "Warten auf Zahlung"
        case .review: return "Zu prüfen"
        }
    }

    var icon: String {
        switch self {
        case .kpis: return "square.grid.2x2"
        case .amounts: return "chart.bar"
        case .counts: return "number"
        case .payments: return "eurosign.circle"
        case .companies: return "building.2"
        case .sources: return "chart.pie"
        case .paymentTime: return "clock"
        case .unpaid: return "tray.full"
        case .review: return "exclamationmark.bubble"
        }
    }

    /// The four total cards need the full width.
    var canBeHalf: Bool { self != .kpis }
}

/// A widget's place on the dashboard: order comes from the array, width from `wide`.
struct DashboardItem: Codable, Equatable, Identifiable {
    var widget: DashboardWidget
    var wide: Bool
    var id: DashboardWidget { widget }

    static let standard: [DashboardItem] = [
        .init(widget: .kpis, wide: true), .init(widget: .amounts, wide: true),
        .init(widget: .companies, wide: false), .init(widget: .sources, wide: false),
        .init(widget: .unpaid, wide: true),
    ]

    private static let key = "dashboardLayout"

    static func load() -> [DashboardItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([DashboardItem].self, from: data) else { return standard }
        var seen = Set<DashboardWidget>()
        return items.filter { seen.insert($0.widget).inserted }
    }

    static func save(_ items: [DashboardItem]) {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Overview of all filed invoices. The user picks the widgets, their order and width, and the time span.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    /// Opens an invoice in the list.
    var open: (InvoiceRecord.ID) -> Void
    /// Shows a list from the sidebar, for the cards at the top.
    var show: (SidebarItem) -> Void

    @AppStorage("dashboardPeriod") private var period: DashboardPeriod = .thisMonth
    @AppStorage("dashboardFrom") private var fromStamp: Double = 0
    @AppStorage("dashboardTo") private var toStamp: Double = 0
    @State private var layout = DashboardItem.load()
    @State private var editing = false
    /// The widget a dragged widget is hovering over; nil for the drop zone at the end.
    @State private var dropTarget: DashboardWidget?
    @State private var endTargeted = false

    struct Point: Identifiable {
        var date: Date
        var status: String
        var value: Double
        var id: String { "\(date.timeIntervalSince1970)-\(status)" }
    }

    struct NamedValue: Identifiable {
        var name: String
        var value: Double
        var id: String { name }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if editing { editBar }
                if model.library.records.isEmpty {
                    ContentUnavailableView("Noch keine Rechnungen", systemImage: "chart.bar",
                                           description: Text("Diagramme erscheinen, sobald Rechnungen abgelegt sind."))
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    if layout.isEmpty {
                        ContentUnavailableView("Keine Widgets", systemImage: "square.dashed",
                                               description: Text("Über „Anpassen“ Widgets hinzufügen."))
                            .frame(maxWidth: .infinity, minHeight: 300)
                    }
                    ForEach(rows, id: \.self) { row in
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(row, id: \.self) { w in widget(w) }
                            // A half-width widget on its own keeps its width.
                            if row.count == 1, item(row[0])?.wide == false { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                    }
                    if editing { endDropZone }
                    if otherCurrencyCount > 0 {
                        Text("\(plural(otherCurrencyCount)) in anderer Währung \(otherCurrencyCount == 1 ? "wird" : "werden") gezählt, aber nicht in die Beträge eingerechnet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .animation(.snappy, value: layout)
        }
        .background {
            LinearGradient(colors: [Color(red: 0.93, green: 0.94, blue: 0.95), Color(red: 0.84, green: 0.86, blue: 0.89)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.6)
                .ignoresSafeArea()
        }
        .onChange(of: layout) { DashboardItem.save(layout) }
        .onChange(of: period) { old, new in
            // Start a custom span from the span shown before, so the dates are a useful starting point.
            if new == .custom, let span = old.interval() ?? allSpan {
                fromStamp = span.start.timeIntervalSince1970
                toStamp = span.end.addingTimeInterval(-1).timeIntervalSince1970
            }
        }
    }

    // MARK: - Header and editing

    private var header: some View {
        HStack(spacing: 12) {
            Text("Übersicht").font(.largeTitle.weight(.semibold))
            Spacer()
            if period == .custom {
                DatePicker("Von", selection: dateBinding($fromStamp), displayedComponents: .date)
                    .fixedSize()
                DatePicker("Bis", selection: dateBinding($toStamp), displayedComponents: .date)
                    .fixedSize()
            }
            Picker("Zeitraum", selection: $period) {
                ForEach([[DashboardPeriod.thisMonth, .lastMonth], [.thisQuarter, .lastQuarter],
                         [.thisYear, .lastYear, .last12Months], [.all, .custom]], id: \.self) { group in
                    ForEach(group) { Text($0.label).tag($0) }
                    if group.last != .custom { Divider() }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Zeitraum für Diagramme und Summen")
            if editing {
                Button { editing = false } label: { Label("Fertig", systemImage: "checkmark") }
                    .buttonStyle(.glassProminent)
            } else {
                Button { editing = true } label: { Label("Anpassen", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.glass)
                    .help("Widgets hinzufügen, entfernen, verschieben und ihre Breite ändern")
            }
        }
    }

    private var editBar: some View {
        HStack(spacing: 12) {
            Label("Widgets ziehen, um sie zu verschieben. Mit den Knöpfen oben rechts Breite ändern oder entfernen.",
                  systemImage: "hand.draw")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(DashboardWidget.allCases.filter { w in !layout.contains { $0.widget == w } }) { w in
                    Button { layout.append(DashboardItem(widget: w, wide: !w.canBeHalf || w == .amounts)) } label: {
                        Label(w.title, systemImage: w.icon)
                    }
                }
            } label: {
                Label("Widget hinzufügen", systemImage: "plus")
            }
            .fixedSize()
            .disabled(layout.count == DashboardWidget.allCases.count)
            Button("Standard wiederherstellen") { layout = DashboardItem.standard }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var endDropZone: some View {
        Text("Hierher ziehen, um ein Widget ans Ende zu setzen")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(endTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: endTargeted ? 3 : 1, dash: [6, 4]))
            }
            .dropDestination(for: String.self) { ids, _ in
                move(ids.first, before: nil)
            } isTargeted: { endTargeted = $0 }
    }

    private func dateBinding(_ stamp: Binding<Double>) -> Binding<Date> {
        Binding { stamp.wrappedValue == 0 ? Date() : Date(timeIntervalSince1970: stamp.wrappedValue) }
            set: { stamp.wrappedValue = $0.timeIntervalSince1970 }
    }

    private func item(_ w: DashboardWidget) -> DashboardItem? { layout.first { $0.widget == w } }

    /// Wide widgets get a row of their own; two half-width widgets in a row share one.
    private var rows: [[DashboardWidget]] {
        var rows: [[DashboardWidget]] = []
        for i in layout {
            if !i.wide, let last = rows.last, last.count == 1, item(last[0])?.wide == false {
                rows[rows.count - 1].append(i.widget)
            } else {
                rows.append([i.widget])
            }
        }
        return rows
    }

    /// Moves the dragged widget next to `target`: after it when dragged down, before it when dragged up, last for nil.
    private func move(_ raw: String?, before target: DashboardWidget?) -> Bool {
        guard let raw, let w = DashboardWidget(rawValue: raw), w != target,
              let from = layout.firstIndex(where: { $0.widget == w }) else { return false }
        let moved = layout.remove(at: from)
        if let target, let to = layout.firstIndex(where: { $0.widget == target }) {
            layout.insert(moved, at: from <= to ? to + 1 : to)
        } else {
            layout.append(moved)
        }
        return true
    }

    @ViewBuilder
    private func widget(_ w: DashboardWidget) -> some View {
        let content = widgetContent(w).frame(maxWidth: .infinity)
        if editing {
            content
                // Catches clicks so cards and lists don't open while arranging.
                .overlay { Color.white.opacity(0.001) }
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(dropTarget == w ? Color.accentColor : Color.secondary.opacity(0.45),
                                      style: StrokeStyle(lineWidth: dropTarget == w ? 3 : 1, dash: [6, 4]))
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) { editControls(w) }
                .draggable(w.rawValue) {
                    Label(w.title, systemImage: w.icon).padding(10).glassEffect(.regular, in: .capsule)
                }
                .dropDestination(for: String.self) { ids, _ in
                    move(ids.first, before: w)
                } isTargeted: { on in
                    if on { dropTarget = w } else if dropTarget == w { dropTarget = nil }
                }
        } else {
            content
        }
    }

    private func editControls(_ w: DashboardWidget) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).help("Ziehen zum Verschieben")
            if w.canBeHalf, let i = layout.firstIndex(where: { $0.widget == w }) {
                Button {
                    layout[i].wide.toggle()
                } label: {
                    Image(systemName: layout[i].wide ? "rectangle.split.2x1" : "rectangle")
                }
                .help(layout[i].wide ? "Halbe Breite" : "Volle Breite")
            }
            Button {
                layout.removeAll { $0.widget == w }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .help("„\(w.title)“ entfernen")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .padding(8)
    }

    @ViewBuilder
    private func widgetContent(_ w: DashboardWidget) -> some View {
        switch w {
        case .kpis: kpis
        case .amounts:
            card(bucket == .day ? "Betrag pro Tag" : "Betrag pro Monat", subtitle: "Nach Rechnungsdatum, \(currency)") {
                timeChart(series(countable, date: date, value: amount), money: true)
            }
        case .counts:
            card(bucket == .day ? "Rechnungen pro Tag" : "Rechnungen pro Monat", subtitle: "Nach Rechnungsdatum, alle Währungen") {
                timeChart(series(inPeriod, date: date) { _ in 1 }, money: false)
            }
        case .payments:
            card("Zahlungen", subtitle: "Bezahlte Beträge nach Zahlungsdatum, \(currency)") {
                timeChart(series(paidInPeriod, date: { $0.paidDate ?? date($0) }, value: amount), money: true)
            }
        case .companies: card("Größte Lieferanten", subtitle: "Summe \(currency) im Zeitraum") { companiesChart }
        case .sources: card("Wie Rechnungen gelesen wurden", subtitle: "Alle Rechnungen im Zeitraum") { sourcesChart }
        case .paymentTime: card("Zahlungsdauer", subtitle: "Tage vom Rechnungsdatum bis zur Zahlung") { paymentTime }
        case .unpaid:
            card("Warten auf Zahlung", subtitle: "Älteste offene Rechnungen zuerst") {
                invoiceList(model.library.records.filter { $0.status == .unpaid }.sorted { date($0) < date($1) },
                            empty: "Alles bezahlt.") { Text(daysOpen($0)) }
            }
        case .review:
            card("Zu prüfen", subtitle: "Felder, die jemand ansehen sollte") {
                invoiceList(model.library.records.filter(\.needsReview).sorted { date($0) > date($1) },
                            empty: "Nichts zu prüfen.") { Text($0.reviewReasons.first ?? "").lineLimit(1) }
            }
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

    /// The span shown; nil for „Gesamt“.
    private var range: DateInterval? {
        guard period == .custom else { return period.interval() }
        let cal = Calendar.current
        let from = fromStamp == 0 ? Date() : Date(timeIntervalSince1970: fromStamp)
        let to = toStamp == 0 ? Date() : Date(timeIntervalSince1970: toStamp)
        let start = cal.startOfDay(for: min(from, to))
        return DateInterval(start: start, end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(from, to)))!)
    }

    /// From the month of the oldest invoice to the end of this month.
    private var allSpan: DateInterval? {
        let cal = Calendar.current
        guard let first = model.library.records.map(date).min() else { return nil }
        let end = cal.dateInterval(of: .month, for: max(Date(), model.library.records.map(date).max()!))!.end
        return DateInterval(start: cal.dateInterval(of: .month, for: first)!.start, end: end)
    }

    private func contains(_ d: Date) -> Bool { range.map { d >= $0.start && d < $0.end } ?? true }

    private var inPeriod: [InvoiceRecord] { model.library.records.filter { contains(date($0)) } }
    private var countable: [InvoiceRecord] { inPeriod.filter { currencyOf($0) == currency } }
    private var otherCurrencyCount: Int { inPeriod.filter { $0.fields.total != nil && currencyOf($0) != currency }.count }
    /// Paid in the span, by payment date.
    private var paidInPeriod: [InvoiceRecord] {
        model.library.records.filter { $0.status == .paid && currencyOf($0) == currency && contains($0.paidDate ?? date($0)) }
    }

    private func sum(_ list: [InvoiceRecord]) -> Double { list.reduce(0) { $0 + amount($1) } }
    private func money(_ v: Double) -> String { v.formatted(.currency(code: currency).precision(.fractionLength(0...2))) }

    /// Bars are days for spans up to about two months and months otherwise.
    private var bucket: Calendar.Component {
        guard let range else { return .month }
        return range.duration <= 62 * 86_400 ? .day : .month
    }

    private func series(_ records: [InvoiceRecord], date: (InvoiceRecord) -> Date, value: (InvoiceRecord) -> Double) -> [Point] {
        let cal = Calendar.current
        var sums: [String: Point] = [:]
        for r in records {
            let start = cal.dateInterval(of: bucket, for: date(r))!.start
            let status = r.status == .paid ? "Bezahlt" : "Offen"
            sums["\(start.timeIntervalSince1970)-\(status)", default: Point(date: start, status: status, value: 0)].value += value(r)
        }
        return sums.values.sorted { $0.date < $1.date }
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

    // MARK: - Widgets

    private var kpis: some View {
        let unpaid = model.library.records.filter { $0.status == .unpaid }
        let unpaidCountable = unpaid.filter { currencyOf($0) == currency }
        return HStack(spacing: 16) {
            kpi("Offen", value: money(sum(unpaidCountable)), detail: "\(plural(unpaid.count)) offen",
                icon: "tray.full", tint: .orange, opens: .unpaid)
            kpi("Bezahlt", value: money(sum(countable.filter { $0.status == .paid })),
                detail: plural(inPeriod.filter { $0.status == .paid }.count), icon: "checkmark.circle", tint: .green, opens: .paid)
            kpi("Gesamt", value: money(sum(countable)), detail: plural(inPeriod.count), icon: "sum", tint: .blue, opens: .all)
            kpi("Zu prüfen", value: "\(model.library.records.filter(\.needsReview).count)",
                detail: "\(model.library.skipped.count) übersprungen", icon: "exclamationmark.bubble", tint: .purple, opens: .review)
        }
    }

    private func plural(_ n: Int) -> String { n == 1 ? "1 Rechnung" : "\(n) Rechnungen" }

    /// A total at the top; clicking it opens the matching list.
    private func kpi(_ title: String, value: String, detail: String, icon: String, tint: Color, opens: SidebarItem) -> some View {
        Button { show(opens) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.callout.weight(.medium)).foregroundStyle(tint)
                Text(value).font(.title.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint.opacity(0.08)).interactive(), in: .rect(cornerRadius: 18))
        .help("„\(title)“ öffnen")
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

    /// Bars per day or month, split into open and paid, over the whole span including empty days or months.
    private func timeChart(_ data: [Point], money isMoney: Bool) -> some View {
        let domain = range ?? allSpan ?? DateInterval(start: Date(), duration: 1)
        let months = Calendar.current.dateComponents([.month], from: domain.start, to: domain.end).month ?? 0
        return Chart(data) { p in
            BarMark(x: .value("Datum", p.date, unit: bucket), y: .value(isMoney ? "Betrag" : "Anzahl", p.value))
                .foregroundStyle(by: .value("Status", p.status))
                .cornerRadius(4)
        }
        .chartForegroundStyleScale(["Offen": Color.orange, "Bezahlt": Color.green])
        .chartXScale(domain: domain.start...domain.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: bucket, count: bucket == .day ? 7 : max(1, months / 12))) { _ in
                AxisGridLine()
                AxisValueLabel(format: bucket == .day ? .dateTime.day().month(.abbreviated) : .dateTime.month(.abbreviated).year(.twoDigits))
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(isMoney ? money(d) : d.formatted()) } }
            }
        }
        .frame(height: 240)
        .overlay { if data.isEmpty { Text("Keine Rechnungen im Zeitraum").foregroundStyle(.secondary) } }
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

    private var paymentTime: some View {
        let cal = Calendar.current
        let days = paidInPeriod.compactMap { r -> Int? in
            guard let paid = r.paidDate, let invoiced = r.fields.invoiceDate else { return nil }
            return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: invoiced), to: cal.startOfDay(for: paid)).day ?? 0)
        }.sorted()
        let average = days.isEmpty ? 0 : Double(days.reduce(0, +)) / Double(days.count)
        return VStack(alignment: .leading, spacing: 10) {
            if days.isEmpty {
                Text("Keine bezahlten Rechnungen im Zeitraum").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(average.formatted(.number.precision(.fractionLength(0)))).font(.system(size: 44, weight: .semibold)).monospacedDigit()
                    Text("Tage im Schnitt").foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    stat("Median", "\(days[days.count / 2]) Tage")
                    stat("Schnellste", "\(days.first!) Tage")
                    stat("Längste", "\(days.last!) Tage")
                    stat("Bezahlt", plural(days.count))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func invoiceList<Detail: View>(_ records: [InvoiceRecord], empty: String,
                                           @ViewBuilder detail: @escaping (InvoiceRecord) -> Detail) -> some View {
        let shown = Array(records.prefix(8))
        return VStack(spacing: 0) {
            if shown.isEmpty {
                Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(shown) { r in
                Button { self.open(r.id) } label: {
                    HStack {
                        Text(r.fields.seller.isEmpty ? "Unbekannte Firma" : r.fields.seller).lineLimit(1)
                        Text(r.fields.invoiceNumber).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        detail(r).foregroundStyle(.secondary)
                        Text(r.fields.total.map { MenuBarView.money($0, r.fields.currency) } ?? "–").monospacedDigit().frame(width: 110, alignment: .trailing)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if r.id != shown.last?.id { Divider() }
            }
            if records.count > shown.count {
                Text("und \(records.count - shown.count) weitere").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        }
    }

    private func daysOpen(_ r: InvoiceRecord) -> String {
        let days = Calendar.current.dateComponents([.day], from: date(r), to: Date()).day ?? 0
        return days <= 0 ? "heute" : days == 1 ? "1 Tag" : "\(days) Tage"
    }
}
