import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WitthuesCore

/// Opens the "Rechnung hinzufügen" sheet, optionally with files that were dropped on the window.
struct AddRequest: Identifiable {
    let id = UUID()
    var urls: [URL] = []
}

/// Adds invoices by hand: from Photos, scanned with the iPhone camera, from files and folders, or dropped on the
/// window or this sheet. The files are listed first; „Importieren“ reads them like mail attachments and files them
/// into the folder of the chosen stage, and each row then shows what came out.
struct AddInvoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initial: [URL] = []
    @State private var stage = Stage.paid
    @State private var withDate = true
    @State private var paidDate = Date()
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @State private var scanRequest = 0
    @State private var items: [Item] = []
    @State private var working = false
    @State private var dropTargeted = false

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var data: Data
        var running = false
        /// nil until imported.
        var result: AppModel.AddResult?
    }

    private var pending: [Item] { items.filter { $0.result == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rechnung hinzufügen").font(.title2.weight(.semibold))
            Text("Als was soll die Rechnung importiert werden?").font(.headline)
            StagePicker(stage: $stage).disabled(working)
            Text("Die Rechnung wird gelesen, umbenannt und im Ordner „\(model.library.settings.folderTemplate(stage))“ abgelegt.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if stage != .open {
                HStack {
                    Toggle("Bezahlt am", isOn: $withDate)
                    DatePicker("Bezahlt am", selection: $paidDate, displayedComponents: .date).labelsHidden().disabled(!withDate)
                }
                .disabled(working)
            }
            HStack(spacing: 12) {
                PhotosPicker(selection: $photos, matching: .images) {
                    tile("Aus Fotos", "photo.on.rectangle", "Ein oder mehrere Fotos")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                Button { scanRequest += 1 } label: {
                    tile("Scannen", "doc.viewfinder", "Mit der iPhone-Kamera")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                .background(ScanAnchor(request: scanRequest) { data, name in add([(data, name)]) })
                .help("Öffnet die Kamera des iPhones (Continuity-Kamera). iPhone und Mac brauchen dieselbe Apple-ID und WLAN/Bluetooth.")
                Button { pickingFiles = true } label: {
                    tile("Datei oder Ordner", "folder", "Oder hierher ziehen")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
            }
            .disabled(working)
            fileList
            HStack {
                if !items.isEmpty, !working, pending.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if pending.isEmpty {
                    Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction).disabled(working)
                } else {
                    Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                    Button(pending.count == 1 ? "1 Datei importieren" : "\(pending.count) Dateien importieren") { run() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(working)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
            }
        }
        // Files dragged onto the open sheet join the list.
        .dropDestination(for: URL.self) { urls, _ in
            add(Self.files(in: urls))
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { if !initial.isEmpty { add(Self.files(in: initial)) } }
        .onChange(of: photos) {
            let picked = photos
            photos = []
            guard !picked.isEmpty else { return }
            Task {
                var files: [(Data, String)] = []
                for (i, item) in picked.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        files.append((data, "Foto \(i + 1).\(ext)"))
                    }
                }
                add(files)
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.pdf, .xml, .image, .folder], allowsMultipleSelection: true) { picked in
            guard case .success(let urls) = picked else { return }
            add(Self.files(in: urls))
        }
    }

    /// The chosen files, waiting or with what came out of each.
    @ViewBuilder private var fileList: some View {
        if items.isEmpty {
            Label("Noch keine Datei gewählt. Dateien lassen sich auch hierher ziehen.", systemImage: "tray.and.arrow.down")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        if item.id != items.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: items.count < 5)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(item.name)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                detail(item).font(.caption).lineLimit(1)
            }
            Spacer(minLength: 6)
            if item.running {
                ProgressView().controlSize(.small)
            } else if let result = item.result {
                switch result {
                case .filed(let r):
                    Image(systemName: r.needsReview ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(r.needsReview ? .orange : .green)
                case .duplicate: Image(systemName: "equal.circle.fill").foregroundStyle(.blue)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            } else {
                Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(working)
                    .help("Aus der Liste nehmen")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func detail(_ item: Item) -> some View {
        switch item.result {
        case nil:
            Text(item.running ? "Wird gelesen …" : "Bereit · \(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file))")
                .foregroundStyle(.secondary)
        case .filed(let r)?:
            let company = r.fields.seller.isEmpty ? "Unbekannte Firma" : r.fields.seller
            let amount = r.fields.total.map { " · " + MenuBarView.money($0, r.fields.currency) } ?? ""
            Text("\(company)\(amount) · unter „\(r.stage.label)“" + (r.needsReview ? " · bitte prüfen" : ""))
                .foregroundStyle(r.needsReview ? .orange : .secondary)
        case .duplicate?:
            Text("War schon vorhanden, nicht doppelt abgelegt").foregroundStyle(.blue)
        case .failed(let message)?:
            Text(message).foregroundStyle(.red)
        }
    }

    private var summary: String {
        var filed = 0, duplicates = 0, failed = 0
        for item in items {
            switch item.result {
            case .filed?: filed += 1
            case .duplicate?: duplicates += 1
            case .failed?: failed += 1
            case nil: break
            }
        }
        var parts: [String] = []
        if filed > 0 { parts.append(filed == 1 ? "1 abgelegt" : "\(filed) abgelegt") }
        if duplicates > 0 { parts.append("\(duplicates) schon vorhanden") }
        if failed > 0 { parts.append("\(failed) nicht lesbar") }
        return parts.joined(separator: " · ")
    }

    private static func symbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "xml": return "chevron.left.forwardslash.chevron.right"
        default: return "photo"
        }
    }

    /// Adds files to the list; nothing is imported until „Importieren“.
    private func add(_ files: [(Data, String)]) {
        items += files.map { Item(name: $0.1, data: $0.0) }
    }

    /// Imports the waiting files one after another, so each row shows its result as soon as it has one.
    private func run() {
        working = true
        let date = stage != .open && withDate ? paidDate : nil
        let chosen = stage
        Task {
            for id in pending.map(\.id) {
                guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
                items[i].running = true
                let result = await model.importFile(items[i].data, name: items[i].name, stage: chosen, paidOn: date)
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].running = false
                    items[i].result = result
                }
            }
            working = false
        }
    }

    private func tile(_ title: String, _ icon: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.tint).frame(height: 34)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 148, height: 110)
        .contentShape(.rect)
    }

    /// The chosen files, plus the invoice files inside chosen folders and their subfolders.
    static func files(in urls: [URL]) -> [(Data, String)] {
        var found: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let all = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)?
                    .compactMap { $0 as? URL } ?? []
                found += all.filter { Library.importableExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if Library.importableExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found.compactMap { u in (try? Data(contentsOf: u)).map { ($0, u.lastPathComponent) } }
    }
}

/// Opens the Continuity Camera menu ("Dokumente scannen", "Foto aufnehmen" on a nearby iPhone or iPad)
/// each time `request` changes, and hands back what the device sends.
struct ScanAnchor: NSViewRepresentable {
    var request: Int
    var received: (Data, String) -> Void

    func makeNSView(context: Context) -> ScanReceiver {
        let v = ScanReceiver()
        v.lastRequest = request
        return v
    }

    func updateNSView(_ view: ScanReceiver, context: Context) {
        view.received = received
        if request != view.lastRequest {
            view.lastRequest = request
            DispatchQueue.main.async { view.showDeviceMenu() }
        }
    }
}

/// An AppKit view that asks macOS for a scan or photo from a nearby device and receives it.
final class ScanReceiver: NSView, NSServicesMenuRequestor {
    var lastRequest = 0
    var received: ((Data, String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func showDeviceMenu() {
        // The device menu goes to the first responder, which must accept images or PDFs.
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Vom iPhone importieren", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, returnType == .pdf || NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        if let pdf = pasteboard.data(forType: .pdf) {
            received?(pdf, "Scan.pdf")
            return true
        }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            received?(tiff, "Foto.tiff")
            return true
        }
        return false
    }
}
