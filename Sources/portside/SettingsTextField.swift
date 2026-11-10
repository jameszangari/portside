import SwiftUI

/// The one text input for Settings: a boxed field with a hint inside, so it
/// always reads as somewhere to type. Hints say what to enter, not an example.
struct SettingsTextField: View {
    enum Kind {
        case name, url, search, code

        var hint: String {
            switch self {
            case .name: "Enter a name"
            case .url: "Enter a URL"
            case .search: "Search"
            case .code: "Enter a value"
            }
        }
    }

    /// Also the VoiceOver label.
    let label: String
    @Binding var text: String
    var kind = Kind.name
    var onSubmit: () -> Void = {}

    init(_ label: String, text: Binding<String>, kind: Kind = .name, onSubmit: @escaping () -> Void = {}) {
        self.label = label
        _text = text
        self.kind = kind
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(label, text: $text, prompt: Text(kind.hint))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit(onSubmit)
            .accessibilityLabel(label)
    }
}

/// A multi-line input with the same box and a hint while empty.
struct SettingsTextArea: View {
    let label: String
    @Binding var text: String
    var hint = "Enter text"
    var height: CGFloat = 64
    var monospaced = false

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(hint).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 5).allowsHitTesting(false)
                }
            }
            .accessibilityLabel(label)
    }
}
