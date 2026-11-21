import AppKit
import Foundation
import WitthuesCore
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

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
        startUpdateChecks()
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

    // MARK: - Reverting paid and printed

    /// Taking back „bezahlt“ or „gedruckt“ for these invoices, waiting for the user to confirm.
    struct Revert: Identifiable {
        let id = UUID()
        var ids: [InvoiceRecord.ID]
        /// True for „gedruckt“, false for „bezahlt“.
        var printed: Bool
    }
    var revert: Revert?

    func askRevertPaid(_ ids: [InvoiceRecord.ID]) { revert = Revert(ids: ids, printed: false) }
    func askRevertPrinted(_ ids: [InvoiceRecord.ID]) { revert = Revert(ids: ids, printed: true) }

    func confirm(_ r: Revert) {
        if r.printed {
            library.setPrinted(r.ids, false)
        } else {
            for id in r.ids where library.records.first(where: { $0.id == id })?.status == .paid {
                do { try library.setPaid(id, false) } catch { lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - Updates

    /// The newest release on GitHub, once known.
    var latestRelease: Release?
    var isCheckingUpdate = false
    var isDownloadingUpdate = false
    var updateError: String?
    var lastUpdateCheck: Date?
    /// The version downloaded and waiting to be installed, now or on the next start.
    var downloadedVersion: Int? = Updates.staged().map(\.version)
    /// Asks „Jetzt installieren oder beim nächsten Start?“ after a download.
    var askingInstall = false
    /// The version whose notice the user closed; a newer one shows again.
    var dismissedUpdate = UserDefaults.standard.integer(forKey: "dismissedUpdate") {
        didSet { UserDefaults.standard.set(dismissedUpdate, forKey: "dismissedUpdate") }
    }
    var autoCheckUpdates = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheckUpdates, forKey: "autoCheckUpdates"); startUpdateChecks() }
    }
    private var updateTimer: Task<Void, Never>?

    var currentVersion: Int { Updates.current }
    var updateAvailable: Bool { (latestRelease?.version ?? 0) > currentVersion }
    /// The notice at the bottom of the sidebar: a new version not closed by the user, or one ready to install.
    var showsUpdateNotice: Bool {
        if let d = downloadedVersion, d > currentVersion { return true }
        return updateAvailable && latestRelease?.version != dismissedUpdate
    }

    /// Installs an update downloaded before, then checks GitHub on start and every six hours.
    private func startUpdateChecks() {
        updateTimer?.cancel()
        updateTimer = Task { [weak self] in
            guard let self else { return }
            if let staged = Updates.staged() {
                if staged.version > currentVersion, isInstalledApp {
                    installNow()
                    return
                }
                try? FileManager.default.removeItem(at: Updates.stagingFolder)
                downloadedVersion = nil
            }
            while autoCheckUpdates, !Task.isCancelled {
                await checkForUpdate()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// True when running as Witthüs.app, not from `swift run`.
    var isInstalledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func checkForUpdate() async {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        defer { isCheckingUpdate = false; lastUpdateCheck = Date() }
        do {
            latestRelease = try await Updates.latest()
            updateError = nil
        } catch {
            updateError = error.localizedDescription
        }
    }

    func downloadUpdate() {
        guard let release = latestRelease, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateError = nil
        Task {
            defer { isDownloadingUpdate = false }
            do {
                _ = try await Updates.download(release)
                downloadedVersion = release.version
                askingInstall = true
            } catch {
                updateError = error.localizedDescription
            }
        }
    }

    /// Puts the downloaded version in place of this app and starts it.
    func installNow() {
        do {
            try Updates.installStaged(over: Bundle.main.bundleURL)
        } catch {
            updateError = error.localizedDescription
            return
        }
        // A shell waits until this app has quit, then opens the new one.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                       Bundle.main.bundleURL.path]
        do { try p.run() } catch { updateError = error.localizedDescription; return }
        NSApp.terminate(nil)
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
