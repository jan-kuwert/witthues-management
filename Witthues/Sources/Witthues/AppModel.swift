import AppKit
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
        // Files deleted or moved in Finder leave the lists when the user comes back to the app.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.library.refreshFiles() }
        }
        restartTimer()
        // Payment terms for invoices filed before the app read them.
        Task { await library.readMissingTerms() }
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
    func startReadingPast(mailboxes: [String], from: Date, to: Date, stage: Stage, paidDate: Date?) {
        runImport(notice: ("ältere Rechnung", "ältere Rechnungen"), text: \.pastText) { [library] progress in
            try await MailChecker.readPast(library: library, password: Keychain.password(for: library.settings.username) ?? "",
                                           mailboxes: mailboxes, from: from, to: to, stage: stage, paidDate: paidDate, progress: progress)
        }
    }

    /// Starts adding the invoice PDFs already lying in these folders with the chosen stage, without moving them.
    func startReadingFolders(_ folders: [URL], stage: Stage, paidDate: Date?) {
        runImport(notice: ("vorhandene Rechnung", "vorhandene Rechnungen"), text: \.filesText) { [library, extractor] progress in
            try await library.indexFolders(folders, stage: stage, paidDate: paidDate, extractor: extractor, progress: progress)
        }
    }

    /// Reads these files (already in place) with the chosen stage.
    func startReadingFiles(_ files: [URL], stage: Stage, paidDate: Date?) {
        runImport(notice: ("vorhandene Rechnung", "vorhandene Rechnungen"), text: \.filesText) { [library, extractor] progress in
            try await library.indexFiles(files, stage: stage, paidDate: paidDate, extractor: extractor, progress: progress)
        }
    }

    private func runImport(notice: (one: String, many: String), text: @escaping (CheckSummary) -> String,
                           work: @escaping @MainActor (@MainActor (MailProgress) -> Void) async throws -> CheckSummary) {
        guard !isChecking else {
            pastResult = "Es läuft gerade ein Abruf. Bitte kurz warten und erneut versuchen."
            return
        }
        isChecking = true
        isReadingPast = true
        progress = MailProgress(step: "Wird vorbereitet …")
        pastResult = nil
        pastTask = Task {
            defer { isChecking = false; isReadingPast = false; progress = nil }
            do {
                let summary = try await work { [weak self] in self?.progress = $0 }
                if summary.filed > 0 { notify(summary.filed == 1 ? "1 \(notice.one) erfasst" : "\(summary.filed) \(notice.many) erfasst") }
                pastResult = ([text(summary)] + summary.errors).joined(separator: "\n")
            } catch is CancellationError {
                pastResult = "Abgebrochen. " + (progress.map { text($0.summary) } ?? "")
            } catch {
                pastResult = error.localizedDescription
            }
        }
    }

    func cancelReadingPast() { pastTask?.cancel() }

    /// What happened to one file added by hand.
    enum AddResult {
        case filed(InvoiceRecord), duplicate, failed(String)
    }

    /// Files one invoice the user added by hand (dropped, picked, photographed or scanned) with the stage they chose.
    func importFile(_ data: Data, name: String, stage: Stage, paidOn date: Date?) async -> AddResult {
        do {
            let record = try await library.ingestFile(data: data, fileName: name, stage: stage, paidOn: date,
                                                      origin: MailOrigin(subject: "Von Hand hinzugefügt", attachmentName: name),
                                                      extractor: extractor)
            return record.map(AddResult.filed) ?? .duplicate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Imports run one after another, each after the one before.
    private var addTask: Task<Void, Never>?

    /// Imports files added by hand in the background, so the app stays usable. Progress, the result and errors
    /// show at the bottom of the sidebar.
    func startAdding(_ files: [(data: Data, name: String)], stage: Stage, paidDate: Date?) {
        guard !files.isEmpty else { return }
        let previous = addTask
        addTask = Task {
            await previous?.value
            // Waits for a running mail check, then keeps the next one from starting until the files are filed.
            while isChecking { try? await Task.sleep(for: .milliseconds(500)) }
            isChecking = true
            defer { isChecking = false; progress = nil }
            var p = MailProgress(step: "Dateien werden importiert …")
            p.unit = "Datei"
            p.total = files.count
            for (n, file) in files.enumerated() {
                p.current = n + 1
                p.subject = file.name
                progress = p
                switch await importFile(file.data, name: file.name, stage: stage, paidOn: paidDate) {
                case .filed: p.summary.filed += 1
                case .duplicate: p.summary.duplicates += 1
                case .failed(let e): p.summary.errors.append("\(file.name): \(e)")
                }
                progress = p
            }
            let s = p.summary
            lastResult = [s.filed == 1 ? "1 Rechnung hinzugefügt" : "\(s.filed) Rechnungen hinzugefügt",
                          s.duplicates > 0 ? "\(s.duplicates) schon vorhanden" : nil].compactMap { $0 }.joined(separator: " · ")
            lastCheck = Date()
            // With errors, the line says what worked too; the tooltip has every error.
            lastError = s.errors.isEmpty ? nil
                : lastResult + " · " + (s.errors.count == 1 ? "1 Datei nicht importiert: " : "\(s.errors.count) Dateien nicht importiert: ")
                    + s.errors.joined(separator: "; ")
        }
    }

    var unpaidCount: Int { library.liveRecords.filter { $0.status == .unpaid }.count }

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
