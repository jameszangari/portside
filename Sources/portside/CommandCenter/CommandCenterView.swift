import AppKit
import SwiftUI

/// Search field, results (or a pushed screen), footer, and the Action Panel
/// over the bottom-trailing corner. Every key goes through
/// `CommandCenter.send`; the view only renders state and forwards clicks.
struct CommandCenterView: View {
    @ObservedObject var center: CommandCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: CommandCenterState { center.state }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: CommandCenterLayout.width)
        .overlay(alignment: .bottomTrailing) {
            if state.actionPanel != nil {
                CommandCenterActionPanel(center: center)
                    .padding(.trailing, 10)
                    .padding(.bottom, 40)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.actionPanel != nil)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: CommandCenterLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Center")
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            if let screen = state.stack.last {
                Button { center.send(.back) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Text(state.item(screen.itemID)?.title ?? "")
                    .font(.system(size: 17, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                CommandCenterTextField(
                    placeholder: "Search Portside commands",
                    text: state.query,
                    fontSize: 19,
                    onChange: { center.send(.query($0)) },
                    onCreate: { center.searchField = $0 }
                )
            }
            if state.running != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Running")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let screen = state.stack.last {
            CommandCenterDetails(item: state.item(screen.itemID))
                .frame(minHeight: Self.minContentHeight, alignment: .top)
        } else if state.results.isEmpty {
            Text("No matching commands")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.minContentHeight)
        } else {
            results
        }
    }

    /// Tall enough for the Action Panel to fit above the footer.
    private static let minContentHeight: CGFloat = 176

    private var results: some View {
        let rows = min(max(state.results.count, 1), CommandCenterLayout.visibleRows)
        let height = max(CGFloat(rows) * CommandCenterLayout.rowHeight + 12, Self.minContentHeight)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.results) { item in
                        CommandCenterRow(item: item, isSelected: item.id == state.selection) {
                            center.send(.activate(item.id))
                        }
                        .id(item.id)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)
            .frame(height: height)
            .onChange(of: state.selection) { _, selection in
                guard let selection else { return }
                proxy.scrollTo(selection)
            }
            .accessibilityLabel("Results")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let notice = state.notice {
                Image(systemName: notice.kind == .canceled ? "xmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(notice.kind == .canceled ? Color.secondary : Color.orange)
                    .accessibilityHidden(true)
                Text(notice.message)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(notice.message)
            } else {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(state.stack.isEmpty ? "Command Center" : "Details")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let item = state.targetItem {
                CommandCenterKeyHint(title: item.unavailableReason == nil ? "Run" : "Unavailable", keys: "↩")
                    .opacity(item.unavailableReason == nil ? 1 : 0.5)
                Divider().frame(height: 14)
                Button { center.send(.toggleActions) } label: {
                    CommandCenterKeyHint(title: "Actions", keys: "⌘K")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Actions")
                .accessibilityHint("Shows more actions for \(item.title)")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Rows

private struct CommandCenterRow: View {
    let item: CommandCenterItem
    let isSelected: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName ?? "command")
                    .font(.system(size: 14))
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(item.unavailableReason == nil ? .primary : .secondary)
                    if let reason = item.unavailableReason {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: CommandCenterLayout.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Tab moves between controls, not through every result.
        .focusable(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.unavailableReason.map { "Unavailable. \($0)" } ?? item.subtitle)
        .accessibilityHint(item.unavailableReason == nil ? "Runs the command" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct CommandCenterKeyHint: View {
    let title: String
    let keys: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text(keys)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Action Panel

private struct CommandCenterActionPanel: View {
    @ObservedObject var center: CommandCenter

    var body: some View {
        let state = center.state
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(state.visibleActions) { action in
                    Button { center.send(.performAction(action.kind)) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: action.symbolName)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(action.title)
                                .foregroundStyle(action.disabledReason == nil ? .primary : .secondary)
                            Spacer(minLength: 8)
                            if let shortcut = action.shortcut {
                                Text(shortcut).foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(action.kind == state.actionPanel?.highlight ? Color.primary.opacity(0.1) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel(action.title)
                    .accessibilityValue(action.disabledReason.map { "Unavailable. \($0)" } ?? "")
                    .accessibilityAddTraits(action.kind == state.actionPanel?.highlight ? [.isButton, .isSelected] : .isButton)
                }
                if state.visibleActions.isEmpty {
                    Text("No matching actions")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
            }
            .padding(6)
            Divider()
            CommandCenterTextField(
                placeholder: "Search actions",
                text: state.actionPanel?.query ?? "",
                fontSize: 13,
                onChange: { center.send(.actionQuery($0)) },
                onCreate: { center.actionField = $0 }
            )
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }
}

// MARK: - Details screen

private struct CommandCenterDetails: View {
    let item: CommandCenterItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                row("Status", item.unavailableReason.map { "Unavailable. \($0)" } ?? "Available")
                row("Module", item.subtitle)
                row("Command ID", item.id.rawValue)
                row("Keywords", item.keywords.isEmpty ? "None" : item.keywords.joined(separator: ", "))
                row("Permissions", item.permissions.isEmpty ? "None" : item.permissions.joined(separator: ", "))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Text field

/// AppKit text field so the controller can put focus on it synchronously and
/// read marked text (IME) from its field editor.
struct CommandCenterTextField: NSViewRepresentable {
    let placeholder: String
    let text: String
    let fontSize: CGFloat
    let onChange: (String) -> Void
    let onCreate: (NSTextField) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityLabel(placeholder)
        onCreate(field)
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.onChange = onChange
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !composing, field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }

    /// Takes focus when inserted into a key window (the Action Panel field,
    /// the search field after a screen pops).
    final class FocusingTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window, window.isKeyWindow, self.currentEditor() == nil else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
