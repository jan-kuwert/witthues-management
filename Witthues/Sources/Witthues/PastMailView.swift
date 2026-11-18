import AppKit
import SwiftUI
import WitthuesCore

/// The sheet from the sidebar and the menu (⇧⌘R).
struct PastMailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Einlesen").font(.title2.weight(.semibold))
            PastMailForm(folderListHeight: 180)
            HStack {
                if model.isReadingPast {
                    Text("Läuft auch weiter, wenn dieses Fenster geschlossen wird.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

/// Reads mails from a chosen date range and folders again, for invoices from before the first check,
/// from other folders (such as an archive folder in Apple Mail), or after changing settings.
/// Shows the progress of the run while it reads.
struct PastMailForm: View {
    @Environment(AppModel.self) private var model
    var folderListHeight: CGFloat = 150
    @State private var from = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var folders: [String] = []
    @State private var chosen: Set<String> = []
    @State private var loadError: String?
    @State private var source = Source.mail
    /// Folders on disk to read, such as the main folder with invoices filed before the app.
    @State private var diskFolders: [URL] = []
    @State private var stageRequest: StageRequest?

    enum Source: String, CaseIterable, Identifiable {
        case mail = "Aus Mails", folders = "Aus vorhandenen Ordnern"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Quelle", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isReadingPast)
            if source == .mail { mailOptions } else { folderOptions }
            if model.isReadingPast {
                MailProgressPanel()
            } else if let result = model.pastResult {
                Label(result, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if model.isReadingPast {
                    Button("Abbrechen", role: .cancel) { model.cancelReadingPast() }
                        .buttonStyle(.glass)
                        .help("Hört nach der aktuellen Datei auf. Schon Erfasstes bleibt erfasst.")
                } else {
                    Button("Lesen …") { askStage() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isChecking || (source == .mail ? chosen.isEmpty : diskFolders.isEmpty))
                }
            }
        }
        .stagePrompt($stageRequest)
        .task { await loadFolders() }
        .onAppear {
            let root = model.library.settings.rootFolder
            if diskFolders.isEmpty, !root.isEmpty { diskFolders = [URL(fileURLWithPath: root)] }
        }
    }

    /// Asks which stage the invoices get, then starts reading.
    private func askStage() {
        if source == .mail {
            // Keeps the folder order from the list, so progress reads top to bottom.
            let boxes = folders.filter(chosen.contains)
            stageRequest = StageRequest(title: "Mails einlesen",
                                        detail: "\(boxes.map(IMAPClient.displayName).joined(separator: ", ")), \(from.formatted(date: .numeric, time: .omitted)) bis \(to.formatted(date: .numeric, time: .omitted))",
                                        inPlace: false, suggested: .open) { [from, to] stage, date in
                model.startReadingPast(mailboxes: boxes, from: from, to: to, stage: stage, paidDate: date)
            }
        } else {
            let list = diskFolders
            stageRequest = StageRequest(title: "Ordner einlesen", detail: list.map(\.lastPathComponent).joined(separator: ", "),
                                        inPlace: true, suggested: list.first.map(model.library.suggestedStage) ?? .archived) { stage, date in
                model.startReadingFolders(list, stage: stage, paidDate: date)
            }
        }
    }

    /// Existing invoice PDFs are read where they lie, without moving or renaming, so they count in the statistics.
    private var folderOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Liest Rechnungs-PDFs, die schon in Ordnern liegen (mit Unterordnern), und nimmt sie in die Liste und die Übersicht auf. Die Dateien werden nicht verschoben oder umbenannt. Vor dem Lesen fragt die App, ob sie als offen, bezahlt oder archiviert gelten. Schon bekannte Dateien werden übersprungen.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Ordner").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                if diskFolders.isEmpty {
                    Text("Noch kein Ordner gewählt.").foregroundStyle(.secondary)
                }
                ForEach(diskFolders, id: \.self) { url in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(url.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { diskFolders.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Ordner aus der Liste nehmen")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .disabled(model.isReadingPast)
            Button("Ordner hinzufügen …") { addFolders() }.disabled(model.isReadingPast)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Hinzufügen"
        if !model.library.settings.rootFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: model.library.settings.rootFolder) }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !diskFolders.contains(url) { diskFolders.append(url) }
    }

    private var mailOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Durchsucht Mails aus dem Zeitraum in den gewählten Ordnern nach Rechnungen. Schon abgelegte Rechnungen werden erkannt und nicht doppelt abgelegt. Der normale Abruf läuft danach unverändert weiter.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                DatePicker("Von", selection: $from, displayedComponents: .date).fixedSize()
                DatePicker("Bis", selection: $to, displayedComponents: .date).fixedSize()
            }
            .disabled(model.isReadingPast)
            VStack(alignment: .leading, spacing: 6) {
                Text("Mailordner").font(.headline)
                if let loadError {
                    HStack {
                        Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Erneut versuchen") { Task { await loadFolders() } }
                    }
                } else if folders.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Ordner werden geladen …").foregroundStyle(.secondary) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(folders, id: \.self) { f in
                                Toggle(IMAPClient.displayName(f), isOn: Binding(
                                    get: { chosen.contains(f) },
                                    set: { if $0 { chosen.insert(f) } else { chosen.remove(f) } }))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(height: folderListHeight)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .disabled(model.isReadingPast)
                }
            }
        }
    }

    private func loadFolders() async {
        loadError = nil
        do {
            folders = try await model.mailboxes()
            let current = model.library.settings.mailbox
            if chosen.isEmpty, folders.contains(current) { chosen = [current] }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// The running import: a bar for the current folder, the mail being read and what came out so far.
struct MailProgressPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.progress ?? MailProgress(step: "Startet …")
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = p.fraction {
                ProgressView(value: fraction) {
                    Text(p.text).monospacedDigit()
                } currentValueLabel: {
                    Text(p.subject.isEmpty ? " " : "„\(p.subject)“").lineLimit(1).truncationMode(.middle)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text(p.step.isEmpty ? "Startet …" : p.step) }
            }
            HStack(spacing: 18) {
                count("Gelesen", p.summary.messages, .secondary)
                count(p.unit == "Datei" ? "Neu erfasst" : "Neu abgelegt", p.summary.filed, .green)
                count(p.unit == "Datei" ? "Schon bekannt" : "Schon vorhanden", p.summary.duplicates, .blue)
                count("Keine Rechnung", p.summary.skipped, .orange)
                count("Fehler", p.summary.errors.count, p.summary.errors.isEmpty ? .secondary : .red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func count(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(n)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
