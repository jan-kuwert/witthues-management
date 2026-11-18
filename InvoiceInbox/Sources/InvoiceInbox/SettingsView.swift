import AppKit
import InvoiceCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            FolderSettings().tabItem { Label("Folders", systemImage: "folder") }
            MailSettings().tabItem { Label("Mail", systemImage: "envelope") }
            CheckSettings().tabItem { Label("Checking", systemImage: "clock.arrow.circlepath") }
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
            Section("Main folder") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                    Text(library.settings.rootFolder.isEmpty ? "Not chosen" : library.settings.rootFolder)
                        .lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(library.settings.rootFolder.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { chooseRoot() }.buttonStyle(.glass)
                    if !library.settings.rootFolder.isEmpty {
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: library.settings.rootFolder)) }
                            .buttonStyle(.glass)
                    }
                }
                Text("Pick an existing folder, for example inside OneDrive. Existing subfolders are reused; missing ones are created when needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Templates") {
                templateField("Unpaid folder", text: $library.settings.unpaidFolder, existingPicker: true)
                templateField("Paid folder (archive)", text: $library.settings.paidFolder, existingPicker: true)
                templateField("File name", text: $library.settings.fileName, existingPicker: false)
                Text("Use / for subfolders, e.g. {yyyy}/{yyyy}-{mm}. The .pdf ending is added automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                let o = model.library.organizer
                let f = AppSettings.sampleFields
                LabeledContent("New invoice") {
                    Text(o.relativePath(for: f, status: .unpaid, paidDate: nil)).font(.callout.monospaced()).textSelection(.enabled)
                }
                LabeledContent("After paid (today)") {
                    Text(o.relativePath(for: f, status: .paid, paidDate: Date())).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            Section("Variables") {
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

    @ViewBuilder
    private func templateField(_ label: String, text: Binding<String>, existingPicker: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(label, text: text).textFieldStyle(.roundedBorder)
                if existingPicker {
                    Button("Pick folder…") { pickSubfolder(into: text) }
                        .buttonStyle(.glass)
                        .disabled(model.library.settings.rootFolder.isEmpty)
                        .help("Choose or create a folder inside the main folder")
                }
            }
            let unknown = PathTemplate.unknownVariables(in: text.wrappedValue)
            if !unknown.isEmpty {
                Text("Unknown: \(unknown.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as main folder"
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
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        guard url.path.hasPrefix(root.path) else {
            model.lastError = "Choose a folder inside the main folder."
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
            Section("Account") {
                TextField("Email address", text: $library.settings.username, prompt: Text("name@your-domain.de"))
                SecureField("Mailbox password", text: $password, prompt: Text("Password from the Telekom Homepage Center"))
                    .onSubmit { savePassword() }
                TextField("Server", text: $library.settings.imapHost)
                HStack {
                    TextField("Port", value: $library.settings.imapPort, format: .number.grouping(.never)).frame(width: 140)
                    Toggle("SSL/TLS", isOn: $library.settings.useTLS)
                }
            }
            Section("Folder to read") {
                if folders.isEmpty {
                    TextField("Mail folder", text: $library.settings.mailbox)
                } else {
                    Picker("Mail folder", selection: $library.settings.mailbox) {
                        ForEach(folders, id: \.self) { Text($0).tag($0) }
                    }
                }
                DatePicker("On first check, read mail since", selection: $library.settings.importSince, displayedComponents: .date)
                Button("Read the folder again from that date") { model.library.resetMailboxPosition() }
                    .help("Invoices already filed are recognised and not filed twice")
            }
            Section {
                HStack {
                    Button(testing ? "Testing…" : "Save & test connection") { test() }
                        .buttonStyle(.glassProminent)
                        .disabled(testing || library.settings.username.isEmpty)
                    Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Text("Mails are only read, never changed, moved or marked as read.").font(.caption).foregroundStyle(.secondary)
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
                testResult = "Connected. \(folders.count) folders found."
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
            Section("Automatic checks") {
                Toggle("Check mail when the app starts", isOn: $library.settings.checkOnLaunch)
                Picker("Then check every", selection: $library.settings.checkIntervalMinutes) {
                    Text("Never (only “Check now”)").tag(0)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("60 minutes").tag(60)
                }
                .onChange(of: library.settings.checkIntervalMinutes) { model.restartTimer() }
                Toggle("Start Invoice Inbox at login", isOn: $m.startsAtLogin)
                Text("The app lives in the menu bar. Closing the window keeps it checking; quit it from the menu bar icon to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reading invoices") {
                Toggle("Use Apple Intelligence for invoices without e-invoice data", isOn: $library.settings.useAppleIntelligence)
                LabeledContent("Apple Intelligence", value: Extractor.appleIntelligenceStatus)
                Text("ZUGFeRD, Factur-X and XRechnung data is always read first. Everything runs on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }
}
