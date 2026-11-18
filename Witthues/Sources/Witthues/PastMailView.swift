import SwiftUI
import WitthuesCore

/// Reads mails from a chosen date range and folders again, for invoices from before the first check,
/// from other folders (such as an archive folder in Apple Mail), or after changing settings.
struct PastMailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var folders: [String] = []
    @State private var chosen: Set<String> = []
    @State private var loadError: String?
    @State private var working = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ältere Mails lesen").font(.title2.weight(.semibold))
            Text("Durchsucht Mails aus dem Zeitraum in den gewählten Ordnern nach Rechnungen. Schon abgelegte Rechnungen werden erkannt und nicht doppelt abgelegt. Der normale Abruf läuft danach unverändert weiter.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                DatePicker("Von", selection: $from, displayedComponents: .date).fixedSize()
                DatePicker("Bis", selection: $to, displayedComponents: .date).fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Mailordner").font(.headline)
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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
                    .frame(height: 180)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(model.progress.isEmpty ? "Wird gelesen …" : model.progress).foregroundStyle(.secondary).lineLimit(1)
                } else if let result {
                    Label(result, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Schließen") { dismiss() }.disabled(working)
                Button("Lesen") { run() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
        .task { await loadFolders() }
    }

    private func loadFolders() async {
        do {
            folders = try await model.mailboxes()
            let current = model.library.settings.mailbox
            chosen = folders.contains(current) ? [current] : []
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func run() {
        working = true
        result = nil
        Task {
            // Keeps the folder order from the list, so progress reads top to bottom.
            result = await model.readPast(mailboxes: folders.filter(chosen.contains), from: from, to: to)
            working = false
        }
    }
}
