import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import WitthuesCore

/// Adds an invoice that is already paid: from Photos, scanned with the iPhone camera, or from files and folders.
/// It is read like a mail attachment and filed straight into the archive folder.
struct PaidImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var paidDate = Date()
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @State private var scanRequest = 0
    @State private var working = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bezahlte Rechnung hinzufügen").font(.title2.weight(.semibold))
            Text("Die Rechnung wird gelesen, umbenannt und direkt im Archivordner für bezahlte Rechnungen abgelegt.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Bezahlt am", selection: $paidDate, displayedComponents: .date)
                .fixedSize()
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
                .background(ScanAnchor(request: scanRequest) { data, name in run([(data, name)]) })
                .help("Öffnet die Kamera des iPhones (Continuity-Kamera). iPhone und Mac brauchen dieselbe Apple-ID und WLAN/Bluetooth.")
                Button { pickingFiles = true } label: {
                    tile("Datei oder Ordner", "folder", "PDF, XML oder Bild")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
            }
            .disabled(working)
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Wird gelesen …").foregroundStyle(.secondary)
                } else if let result {
                    Label(result, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onChange(of: photos) {
            let items = photos
            photos = []
            guard !items.isEmpty else { return }
            working = true
            Task {
                var files: [(Data, String)] = []
                for (i, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        files.append((data, "Foto \(i + 1).\(ext)"))
                    }
                }
                run(files)
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.pdf, .xml, .image, .folder], allowsMultipleSelection: true) { picked in
            guard case .success(let urls) = picked else { return }
            run(Self.files(in: urls))
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

    private func run(_ files: [(Data, String)]) {
        guard !files.isEmpty else { working = false; return }
        working = true
        Task {
            result = await model.importPaid(files, paidOn: paidDate)
            working = false
        }
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
            } else {
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
