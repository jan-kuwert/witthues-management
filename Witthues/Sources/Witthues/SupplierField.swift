import AppKit
import SwiftUI

/// The company field: completes the best known supplier inline while typing (Tab takes it) and lists the closest
/// suppliers below it (↑/↓ to pick, Tab or Return to take, a click takes it too). Native, because SwiftUI text
/// fields don't let Tab and the arrow keys be handled.
struct SupplierField: View {
    @Binding var text: String
    var placeholder: String
    /// Best matches for the typed text, best first.
    var suggestions: (String) -> [String]
    /// The name that starts with the typed text, for completing it in the field.
    var completion: (String) -> String?
    var highlight: Bool
    /// Called once editing is done (Return, Tab past the field, leaving it, or picking a suggestion).
    var onCommit: () -> Void

    @State private var editing = false
    @State private var highlighted: Int?

    var body: some View {
        let list = editing ? suggestions(text).filter { $0.caseInsensitiveCompare(text) != .orderedSame } : []
        VStack(alignment: .leading, spacing: 4) {
            SupplierTextField(text: $text, placeholder: placeholder, list: list, completion: completion,
                              editing: $editing, highlighted: $highlighted, onCommit: onCommit)
                .frame(height: 22)
                .overlay {
                    if highlight { RoundedRectangle(cornerRadius: 6).strokeBorder(.orange, lineWidth: 2).allowsHitTesting(false) }
                }
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, name in
                        HStack(spacing: 6) {
                            Image(systemName: "building.2").foregroundStyle(.secondary)
                            Text(name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if i == 0 && highlighted == nil { Text("⇥").foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(i == highlighted ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 5))
                        .contentShape(.rect)
                        .onTapGesture { pick(name) }
                    }
                }
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5) }
                .help("Bekannte Lieferanten, beste Übereinstimmung zuerst. ↑/↓ wählen, Tab übernimmt.")
            }
        }
    }

    private func pick(_ name: String) {
        text = name
        highlighted = nil
        editing = false
        onCommit()
    }
}

private struct SupplierTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var list: [String]
    var completion: (String) -> String?
    @Binding var editing: Bool
    @Binding var highlighted: Int?
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.placeholderString = placeholder
        f.bezelStyle = .roundedBezel
        f.isBezeled = true
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        f.isEnabled = context.environment.isEnabled
        // While typing the field owns its text (it may show a completion); otherwise it shows the saved name.
        if let editor = f.currentEditor() as? NSTextView {
            // A suggestion picked with the mouse while the field still has focus.
            if !editing, editor.string != text {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        } else if f.stringValue != text {
            f.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SupplierTextField
        /// Set for Backspace and Delete, so deleting the completion doesn't bring it straight back.
        private var deleting = false
        /// Leaving the field waits a moment, so a click on a suggestion is not lost when the field loses focus.
        private var pendingEnd: DispatchWorkItem?

        init(_ parent: SupplierTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            pendingEnd?.cancel()
            parent.editing = true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let editor = field.currentEditor() as? NSTextView else { return }
            pendingEnd?.cancel()
            parent.editing = true
            let typed = editor.string
            parent.text = typed
            parent.highlighted = nil
            defer { deleting = false }
            let length = (typed as NSString).length
            guard !deleting, editor.selectedRange() == NSRange(location: length, length: 0),
                  let full = parent.completion(typed), full.count > typed.count else { return }
            // Keeps what was typed and shows the rest of the name selected, so typing on replaces it.
            let shown = typed + full.dropFirst(typed.count)
            editor.string = shown
            editor.setSelectedRange(NSRange(location: length, length: (shown as NSString).length - length))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
                deleting = true
                return false
            case #selector(NSResponder.insertTab(_:)):
                if let i = parent.highlighted, parent.list.indices.contains(i) {
                    accept(parent.list[i], textView); return true
                }
                if textView.selectedRange().length > 0, let full = parent.completion(parent.text) {
                    accept(full, textView); return true
                }
                if let first = parent.list.first, !parent.text.isEmpty, parent.completion(parent.text) == nil {
                    // No name starts with the text (a typo): Tab takes the best match from the list.
                    accept(first, textView); return true
                }
                return false
            case #selector(NSResponder.moveDown(_:)):
                guard !parent.list.isEmpty else { return false }
                parent.highlighted = min((parent.highlighted ?? -1) + 1, parent.list.count - 1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard let i = parent.highlighted else { return false }
                parent.highlighted = i == 0 ? nil : i - 1
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if let i = parent.highlighted, parent.list.indices.contains(i) {
                    accept(parent.list[i], textView)
                } else if textView.selectedRange().length > 0, let full = parent.completion(parent.text) {
                    accept(full, textView)
                }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc drops the shown completion and closes the list.
                textView.string = parent.text
                parent.highlighted = nil
                parent.editing = false
                return true
            default:
                return false
            }
        }

        private func accept(_ name: String, _ textView: NSTextView) {
            textView.string = name
            textView.setSelectedRange(NSRange(location: (name as NSString).length, length: 0))
            parent.text = name
            parent.highlighted = nil
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // A completion that was not taken is not kept.
            (obj.object as? NSTextField)?.stringValue = parent.text
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.parent.editing else { return }
                self.parent.editing = false
                self.parent.highlighted = nil
                self.parent.onCommit()
            }
            pendingEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}
