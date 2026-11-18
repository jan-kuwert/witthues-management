import Foundation
import WitthuesCore
import Observation
import ServiceManagement
import UserNotifications

/// App state shared by the window, the menu bar item and settings: runs mail checks on launch,
/// on a timer while the app is open, and when the user asks.
@MainActor @Observable
final class AppModel {
    let library = Library()
    var isChecking = false
    /// Where the running mail check or past-mail import stands; nil when nothing runs.
    var progress: MailProgress?
    /// True while older mails are read; the result of the last run, for the settings and the sheet.
    var isReadingPast = false
    var pastResult: String?
    private var pastTask: Task<Void, Never>?
    var lastCheck: Date?
    var lastResult = ""
    var lastError: String?
    /// Shows the sheet for reading older mail; set from the menu and the sidebar.
    var showingPastMail = false
    private var timer: Task<Void, Never>?

    init() {
        restartTimer()
        if library.settings.checkOnLaunch { checkNow() }
    }

    var extractor: Extractor { Extractor(useAppleIntelligence: library.settings.useAppleIntelligence) }

    func restartTimer() {
        timer?.cancel()
        let minutes = library.settings.checkIntervalMinutes
        guard minutes > 0 else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { break }
                await self?.check()
            }
        }
    }

    func checkNow() {
        Task { await check() }
    }

    func check() async {
        library.refreshFiles()
        guard !isChecking, library.settings.isMailConfigured, library.settings.isFolderConfigured else {
            if !library.settings.isMailConfigured || !library.settings.isFolderConfigured {
                lastError = "Bitte in den Einstellungen den Hauptordner wählen und das Mailkonto eintragen."
            }
            return
        }
        isChecking = true
        defer { isChecking = false; progress = nil; lastCheck = Date() }
        do {
            let password = Keychain.password(for: library.settings.username) ?? ""
            let summary = try await MailChecker.check(library: library, password: password) { [weak self] in self?.progress = $0 }
            lastResult = summary.text
            lastError = nil
            if summary.filed > 0 { notify(summary.filed == 1 ? "1 neue Rechnung abgelegt" : "\(summary.filed) neue Rechnungen abgelegt") }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The account's mail folders, for choosing which ones to read again.
    func mailboxes() async throws -> [String] {
        try await MailChecker.testConnection(settings: library.settings,
                                             password: Keychain.password(for: library.settings.username) ?? "").sorted()
    }

    /// Starts reading mails from a date range in the chosen folders again. It runs on even when the window
    /// that started it closes; progress and the result are on the model.
    func startReadingPast(mailboxes: [String], from: Date, to: Date) {
        guard !isChecking else {
            pastResult = "Es läuft gerade ein Abruf. Bitte kurz warten und erneut versuchen."
            return
        }
        isChecking = true
        isReadingPast = true
        pastResult = nil
        pastTask = Task {
            defer { isChecking = false; isReadingPast = false; progress = nil }
            do {
                let password = Keychain.password(for: library.settings.username) ?? ""
                let summary = try await MailChecker.readPast(library: library, password: password, mailboxes: mailboxes,
                                                             from: from, to: to) { [weak self] in self?.progress = $0 }
                if summary.filed > 0 { notify(summary.filed == 1 ? "1 ältere Rechnung abgelegt" : "\(summary.filed) ältere Rechnungen abgelegt") }
                pastResult = ([summary.pastText] + summary.errors).joined(separator: "\n")
            } catch is CancellationError {
                pastResult = "Abgebrochen. " + (progress?.summary.pastText ?? "")
            } catch {
                pastResult = error.localizedDescription
            }
        }
    }

    func cancelReadingPast() { pastTask?.cancel() }

    /// Files PDFs or e-invoice XMLs dropped on the window, the same way as mail attachments.
    func importFiles(_ urls: [URL]) async {
        for url in urls where ["pdf", "xml"].contains(url.pathExtension.lowercased()) {
            do {
                let data = try Data(contentsOf: url)
                _ = try await library.ingest(data: data, fileName: url.lastPathComponent,
                                             origin: MailOrigin(subject: "Von Hand hinzugefügt", attachmentName: url.lastPathComponent),
                                             extractor: extractor)
            } catch {
                lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Files invoices that are already paid; returns a short German summary for the user.
    func importPaid(_ files: [(Data, String)], paidOn date: Date) async -> String {
        var filed = 0, duplicates = 0
        var failed: [String] = []
        for (data, name) in files {
            do {
                if try await library.ingestPaid(data: data, fileName: name, paidOn: date,
                                                origin: MailOrigin(subject: "Bezahlt, von Hand hinzugefügt", attachmentName: name),
                                                extractor: extractor) != nil {
                    filed += 1
                } else {
                    duplicates += 1
                }
            } catch {
                failed.append(name)
                lastError = "\(name): \(error.localizedDescription)"
            }
        }
        var parts: [String] = []
        if filed > 0 { parts.append(filed == 1 ? "1 Rechnung als bezahlt abgelegt" : "\(filed) Rechnungen als bezahlt abgelegt") }
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 war schon vorhanden" : "\(duplicates) waren schon vorhanden") }
        if !failed.isEmpty { parts.append("nicht lesbar: " + failed.joined(separator: ", ")) }
        return parts.isEmpty ? "Nichts hinzugefügt" : parts.joined(separator: " · ")
    }

    var unpaidCount: Int { library.records.filter { $0.status == .unpaid }.count }

    // MARK: - Start at login

    var startsAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Beim Anmelden starten: \(error.localizedDescription)"
            }
        }
    }

    private func notify(_ text: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Witthüs"
            content.body = text
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
