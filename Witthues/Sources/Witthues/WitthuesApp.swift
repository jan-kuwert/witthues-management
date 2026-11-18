import AppKit
import WitthuesCore
import SwiftUI

@main
struct WitthuesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Witthüs", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Mails jetzt abrufen") { model.checkNow() }
                    .keyboardShortcut("r")
                    .disabled(model.isChecking)
                Button("Mails oder Ordner einlesen …") { model.showingPastMail = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.isChecking ? "arrow.triangle.2.circlepath" : "doc.text.magnifyingglass")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar popover: status, a "Check now" button and the newest invoices.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Witthüs").font(.headline)
                Spacer()
                Text("\(model.unpaidCount) offen").foregroundStyle(.secondary)
            }
            StatusLine()
            GlassEffectContainer {
                HStack {
                    Button {
                        model.checkNow()
                    } label: {
                        Label("Jetzt abrufen", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isChecking)
                    Button("Öffnen") {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                    .buttonStyle(.glass)
                    Button {
                        openSettings()
                        NSApp.activate()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.glass)
                    Spacer()
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                    }
                    .buttonStyle(.glass)
                    .help("Beenden; Mails werden dann nicht mehr abgerufen")
                }
            }
            if !model.library.records.isEmpty {
                Divider()
                ForEach(model.library.records.prefix(5)) { r in
                    HStack {
                        Image(systemName: r.status == .paid ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(r.status == .paid ? .green : .orange)
                        Text(r.fields.seller.isEmpty ? r.origin.attachmentName : r.fields.seller).lineLimit(1)
                        Spacer()
                        Text(r.fields.total.map { Self.money($0, r.fields.currency) } ?? "").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    static func money(_ d: Decimal, _ currency: String) -> String {
        d.formatted(.currency(code: currency.isEmpty ? "EUR" : currency))
    }
}

/// "Checking…", the last result or the last error.
struct StatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.isChecking {
                if let fraction = model.progress?.fraction {
                    ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(model.progress.map(\.text).flatMap { $0.isEmpty ? nil : $0 } ?? "Mails werden abgerufen …")
            } else if let error = model.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(3)
            } else if let last = model.lastCheck {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("\(model.lastResult) · \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                Image(systemName: "clock")
                Text("Noch nicht abgerufen")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
