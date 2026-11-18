import AppKit
import WitthuesCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            FolderSettings().tabItem { Label("Ordner", systemImage: "folder") }
            MailSettings().tabItem { Label("Mail", systemImage: "envelope") }
            PastMailForm(folderListHeight: 200)
                .padding(20)
                .frame(height: 520, alignment: .top)
                .tabItem { Label("Einlesen", systemImage: "clock.arrow.circlepath") }
            CheckSettings().tabItem { Label("Abruf", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620)
        .padding(.vertical, 8)
    }
}

/// Main folder, unpaid and paid folder templates, file name template, with a live preview.
struct FolderSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var library = model.library
        Form {
            Section("Hauptordner") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(library.settings.rootFolder.isEmpty ? "Nicht gewählt" : library.settings.rootFolder)
                        .lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(library.settings.rootFolder.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Wählen …") { chooseRoot() }.buttonStyle(.glass)
                    if !library.settings.rootFolder.isEmpty {
                        Button("Öffnen") { NSWorkspace.shared.open(URL(fileURLWithPath: library.settings.rootFolder)) }
                            .buttonStyle(.glass)
                    }
                }
                Text("Einen bestehenden Ordner wählen, zum Beispiel in OneDrive. Vorhandene Unterordner werden weiterverwendet, fehlende bei Bedarf angelegt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                stageFolder(.open, "Neue Rechnungen aus Mails, bis sie bezahlt sind.", text: $library.settings.unpaidFolder)
                stageFolder(.paid, "Bezahlt, wartet auf Drucken und Archivieren.", text: $library.settings.paidFolder)
                stageFolder(.archived, "Gedruckt und abgeschlossen. Mit Platzhaltern, z. B. ein Ordner pro Monat.", text: $library.settings.archiveFolder)
                Text("Alle Ordner liegen im Hauptordner. / trennt Unterordner, z. B. {yyyy}/{yyyy}-{mm}.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Ordner je Status")
            }
            Section("Dateiname") {
                templateField("Dateiname", text: $library.settings.fileName, existingPicker: false)
                Text("Die Endung .pdf wird automatisch angehängt.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Vorschau") {
                let o = model.library.organizer
                let f = AppSettings.sampleFields
                ForEach(Stage.allCases) { stage in
                    LabeledContent(stage.label) {
                        Text(o.relativePath(for: f, stage: stage, paidDate: stage == .open ? nil : Date()))
                            .font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section("Platzhalter") {
                LazyVGrid(columns: [GridItem(.fixed(120), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                    ForEach(PathTemplate.variables, id: \.name) { v in
                        Text(v.name).font(.callout.monospaced()).textSelection(.enabled)
                        Text(v.help).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }

    private func stageFolder(_ stage: Stage, _ note: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(stage.label, systemImage: stage.symbol).font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
            templateField(stage.label, text: text, existingPicker: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func templateField(_ label: String, text: Binding<String>, existingPicker: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(label, text: text).textFieldStyle(.roundedBorder)
                if existingPicker {
                    Button("Ordner wählen …") { pickSubfolder(into: text) }
                        .buttonStyle(.glass)
                        .disabled(model.library.settings.rootFolder.isEmpty)
                        .help("Ordner im Hauptordner wählen oder neu anlegen")
                }
            }
            let unknown = PathTemplate.unknownVariables(in: text.wrappedValue)
            if !unknown.isEmpty {
                Text("Unbekannt: \(unknown.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Als Hauptordner verwenden"
        if !model.library.settings.rootFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: model.library.settings.rootFolder) }
        if panel.runModal() == .OK, let url = panel.url { model.library.settings.rootFolder = url.path }
    }

    /// Picks (or creates, via the panel's New Folder button) a folder under the main folder and uses its relative path.
    private func pickSubfolder(into text: Binding<String>) {
        let root = URL(fileURLWithPath: model.library.settings.rootFolder).standardizedFileURL
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = root
        panel.prompt = "Diesen Ordner verwenden"
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        guard url.path.hasPrefix(root.path) else {
            model.lastError = "Bitte einen Ordner innerhalb des Hauptordners wählen."
            return
        }
        let rel = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !rel.isEmpty { text.wrappedValue = rel }
    }
}

/// IMAP account, password in the Keychain, connection test.
struct MailSettings: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var testResult = ""
    @State private var testing = false
    @State private var folders: [String] = []

    var body: some View {
        @Bindable var library = model.library
        Form {
            Section("Konto") {
                TextField("E-Mail-Adresse", text: $library.settings.username, prompt: Text("name@ihre-domain.de"))
                SecureField("Postfach-Passwort", text: $password, prompt: Text("Passwort aus dem Telekom Homepage Center"))
                    .onSubmit { savePassword() }
                TextField("Server", text: $library.settings.imapHost)
                HStack {
                    TextField("Port", value: $library.settings.imapPort, format: .number.grouping(.never)).frame(width: 140)
                    Toggle("SSL/TLS", isOn: $library.settings.useTLS)
                }
            }
            Section("Zu lesender Mailordner") {
                if folders.isEmpty {
                    TextField("Mailordner", text: $library.settings.mailbox)
                } else {
                    Picker("Mailordner", selection: $library.settings.mailbox) {
                        ForEach(folders, id: \.self) { Text($0).tag($0) }
                    }
                }
                DatePicker("Beim ersten Abruf Mails lesen ab", selection: $library.settings.importSince, displayedComponents: .date)
                Button("Ordner ab diesem Datum neu lesen") { model.library.resetMailboxPosition() }
                    .help("Bereits abgelegte Rechnungen werden erkannt und nicht doppelt abgelegt")
            }
            Section {
                HStack {
                    Button(testing ? "Teste …" : "Speichern & Verbindung testen") { test() }
                        .buttonStyle(.glassProminent)
                        .disabled(testing || library.settings.username.isEmpty)
                    Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Text("Mails werden nur gelesen – nie geändert, verschoben oder als gelesen markiert.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .onAppear { password = Keychain.password(for: model.library.settings.username) ?? "" }
        .onDisappear { savePassword() }
    }

    private func savePassword() {
        Keychain.setPassword(password, for: model.library.settings.username)
    }

    private func test() {
        savePassword()
        testing = true
        testResult = ""
        let s = model.library.settings
        Task {
            do {
                folders = try await MailChecker.testConnection(settings: s, password: password).sorted()
                testResult = "Verbunden. \(folders.count) Ordner gefunden."
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

/// When mail is checked, start at login, Apple Intelligence.
struct CheckSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var library = model.library
        @Bindable var m = model
        Form {
            Section("Automatischer Abruf") {
                Toggle("Mails beim Start der App abrufen", isOn: $library.settings.checkOnLaunch)
                Picker("Danach abrufen alle", selection: $library.settings.checkIntervalMinutes) {
                    Text("Nie (nur „Jetzt abrufen“)").tag(0)
                    Text("2 Minuten").tag(2)
                    Text("5 Minuten").tag(5)
                    Text("15 Minuten").tag(15)
                    Text("30 Minuten").tag(30)
                    Text("60 Minuten").tag(60)
                }
                .onChange(of: library.settings.checkIntervalMinutes) { model.restartTimer() }
                Toggle("Witthüs beim Anmelden starten", isOn: $m.startsAtLogin)
                Text("Die App sitzt in der Menüleiste. Wird das Fenster geschlossen, ruft sie weiter Mails ab; zum Stoppen über das Menüleisten-Symbol beenden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rechnungen lesen") {
                Toggle("Apple Intelligence für Rechnungen ohne E-Rechnungsdaten nutzen", isOn: $library.settings.useAppleIntelligence)
                LabeledContent("Apple Intelligence", value: Extractor.appleIntelligenceStatus)
                Text("ZUGFeRD-, Factur-X- und XRechnung-Daten werden immer zuerst gelesen. Alles läuft auf diesem Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }
}
