import SwiftUI
import WitthuesCore

/// An import waiting for the user to say which stage its invoices get.
struct StageRequest: Identifiable {
    let id = UUID()
    /// Such as "12 Dateien einlesen".
    var title: String
    /// Where the invoices come from.
    var detail: String
    /// True when the files stay where they are (folders already in place); false when they are filed by the templates.
    var inPlace: Bool
    var suggested: Stage = .open
    var run: (Stage, Date?) -> Void
}

extension View {
    /// Asks for the stage before an import starts, every time something is imported by hand.
    func stagePrompt(_ request: Binding<StageRequest?>) -> some View {
        sheet(item: request) { StagePrompt(request: $0) }
    }
}

/// Offen, Bezahlt or Archiviert, with where the files will end up and an optional payment date.
struct StagePrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: StageRequest
    @State private var stage: Stage
    @State private var withDate = false
    @State private var paidDate = Date()

    init(request: StageRequest) {
        self.request = request
        _stage = State(initialValue: request.suggested)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.title3.weight(.semibold))
            if !request.detail.isEmpty {
                Text(request.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle)
            }
            Text("Als was sollen die Rechnungen importiert werden?").font(.headline)
            StagePicker(stage: $stage)
            Label(where_, systemImage: request.inPlace ? "folder" : "arrow.right.doc.on.clipboard")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if stage != .open {
                HStack {
                    Toggle("Bezahlt am", isOn: $withDate)
                    DatePicker("Bezahlt am", selection: $paidDate, displayedComponents: .date).labelsHidden().disabled(!withDate)
                    Spacer()
                }
                if !withDate {
                    Text("Ohne Datum stehen sie unter „Ohne Zahlungsdatum“.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Importieren") {
                    request.run(stage, stage != .open && withDate ? paidDate : nil)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var where_: String {
        if request.inPlace {
            return "Die Dateien bleiben, wo sie sind, und erscheinen unter „\(stage.label)“."
        }
        return "Ablage im Ordner „\(model.library.settings.folderTemplate(stage))“ und unter „\(stage.label)“."
    }
}

/// The three stages as a segmented control.
struct StagePicker: View {
    @Binding var stage: Stage

    var body: some View {
        Picker("Status", selection: $stage) {
            ForEach(Stage.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
