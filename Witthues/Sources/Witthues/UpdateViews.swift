import AppKit
import SwiftUI
import WitthuesCore

extension View {
    /// Asks before „bezahlt“ or „gedruckt“ is taken back; the request comes from `AppModel.askRevertPaid/Printed`.
    func revertConfirmation() -> some View { modifier(RevertConfirmation()) }

    /// After an update was downloaded: install now (restarts the app) or on the next start.
    func updateInstallPrompt() -> some View { modifier(UpdateInstallPrompt()) }
}

private struct RevertConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let r = model.revert
        let many = (r?.ids.count ?? 0) > 1
        content.confirmationDialog(
            r?.printed == true ? (many ? "\(r!.ids.count) Rechnungen als nicht gedruckt markieren?" : "Als nicht gedruckt markieren?")
                               : (many ? "\(r!.ids.count) Rechnungen wieder als offen markieren?" : "Wieder als offen markieren?"),
            isPresented: Binding(get: { model.revert != nil }, set: { if !$0 { model.revert = nil } }),
            presenting: r
        ) { r in
            Button(r.printed ? "Nicht gedruckt" : "Als offen markieren", role: .destructive) { model.confirm(r) }
            Button("Abbrechen", role: .cancel) {}
        } message: { r in
            Text(r.printed ? "Das Druckdatum wird gelöscht."
                           : "Das Zahlungsdatum wird gelöscht und die Datei wandert zurück in den Ordner für offene Rechnungen.")
        }
        .confirmationDialog(
            (model.notInvoice?.count ?? 0) > 1 ? "\(model.notInvoice!.count) Dateien sind keine Rechnungen?" : "Keine Rechnung?",
            isPresented: Binding(get: { model.notInvoice != nil }, set: { if !$0 { model.notInvoice = nil } }),
            presenting: model.notInvoice
        ) { ids in
            Button("Keine Rechnung", role: .destructive) { model.confirmNotInvoice(ids) }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Kommt unter „Keine Rechnungen“ und zählt nicht mehr mit. Die Datei verlässt den Ordner und landet im Papierkorb; mit „Als Rechnung ablegen“ lässt sie sich zurückholen.")
        }
    }
}

private struct UpdateInstallPrompt: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert("Version \(model.downloadedVersion ?? 0) ist bereit",
                      isPresented: Binding(get: { model.askingInstall }, set: { model.askingInstall = $0 })) {
            Button("Jetzt installieren") { model.installNow() }
            Button("Beim nächsten Start", role: .cancel) {}
        } message: {
            Text("Jetzt installieren startet Witthüs neu. Sonst wird das Update beim nächsten Start installiert. Alle Daten bleiben erhalten.")
        }
    }
}

/// At the bottom of the sidebar: a new version to download, or one downloaded and waiting. The × hides it until
/// the next version; Settings → Updates always has it.
struct UpdateNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showsUpdateNotice {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: "arrow.down.circle.fill")
                        .fontWeight(.medium)
                        .foregroundStyle(.blue)
                    Spacer(minLength: 4)
                    if !ready {
                        Button {
                            model.dismissedUpdate = model.latestRelease?.version ?? 0
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Ausblenden bis zur nächsten Version")
                    }
                }
                if model.isDownloadingUpdate {
                    ProgressView().progressViewStyle(.linear)
                } else if ready {
                    Button("Jetzt installieren") { model.installNow() }.buttonStyle(.glassProminent)
                    Text("Sonst beim nächsten Start").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Herunterladen") { model.downloadUpdate() }.buttonStyle(.glassProminent)
                }
                if let e = model.updateError {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.blue.opacity(0.12)), in: .rect(cornerRadius: 12))
        }
    }

    private var ready: Bool { (model.downloadedVersion ?? 0) > model.currentVersion }

    private var title: String {
        if ready { return "Version \(model.downloadedVersion!) bereit" }
        return "Neue Version \(model.latestRelease?.version ?? 0)"
    }
}

/// Settings → Updates: installed and newest version, checking by hand, downloading and installing.
struct UpdateSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Form {
            Section("Version") {
                LabeledContent("Installiert", value: model.currentVersion > 0 ? "Version \(model.currentVersion)" : "Eigener Build (ohne Nummer)")
                LabeledContent("Neueste auf GitHub") {
                    if model.isCheckingUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(model.latestRelease.map { "Version \($0.version)" } ?? "–")
                    }
                }
                if let last = model.lastUpdateCheck {
                    LabeledContent("Zuletzt geprüft", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                HStack {
                    Button {
                        Task { await model.checkForUpdate() }
                    } label: {
                        Label("Jetzt prüfen", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isCheckingUpdate)
                    Spacer()
                    action
                }
                if let e = model.updateError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
            }
            if let r = model.latestRelease, r.version > model.currentVersion {
                Section("Neu in Version \(r.version)") {
                    ScrollView {
                        Text(r.notes.isEmpty ? "Keine Beschreibung." : r.notes)
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    Link("Auf GitHub ansehen", destination: r.page).font(.callout)
                }
            }
            Section("Automatisch") {
                Toggle("Beim Start und alle 6 Stunden nach Updates suchen", isOn: $m.autoCheckUpdates)
                Text("Updates kommen von github.com/\(Updates.repository). Ein heruntergeladenes Update wird beim nächsten Start installiert, falls es nicht vorher installiert wurde. Einstellungen, Passwort und Rechnungen bleiben erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
    }

    @ViewBuilder private var action: some View {
        if let d = model.downloadedVersion, d > model.currentVersion {
            Button("Version \(d) jetzt installieren") { model.installNow() }.buttonStyle(.glassProminent)
        } else if model.isDownloadingUpdate {
            ProgressView().controlSize(.small)
        } else if model.updateAvailable {
            Button("Version \(model.latestRelease!.version) herunterladen") { model.downloadUpdate() }.buttonStyle(.glassProminent)
        } else if model.latestRelease != nil {
            Label("Aktuell", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}
