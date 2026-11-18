import SwiftUI
import WitthuesCore

/// The sheet from the sidebar and the menu (⇧⌘R).
struct PastMailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ältere Mails lesen").font(.title2.weight(.semibold))
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

    var body: some View {
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
                        .help("Hört nach der aktuellen Mail auf. Schon abgelegte Rechnungen bleiben abgelegt.")
                } else {
                    Button("Lesen") {
                        // Keeps the folder order from the list, so progress reads top to bottom.
                        model.startReadingPast(mailboxes: folders.filter(chosen.contains), from: from, to: to)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || model.isChecking)
                }
            }
        }
        .task { await loadFolders() }
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
                count("Neu abgelegt", p.summary.filed, .green)
                count("Schon vorhanden", p.summary.duplicates, .blue)
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
