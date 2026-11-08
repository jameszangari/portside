import AppKit
import QuickLookUI
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: CommandCenterLayout.cornerRadius, style: .continuous))
        // Drawn over the glass, not as part of its content, so opening the
        // Action Panel does not change how the window's glass reads.
        .overlay(alignment: .bottomTrailing) {
            if state.actionPanel != nil {
                // Capped 8 pt under the header so it never covers the search
                // field; a long action list scrolls instead of growing the window.
                CommandCenterActionPanel(center: center)
                    .padding(.top, 60)
                    .padding(.trailing, 10)
                    .padding(.bottom, 40)
                    .frame(maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.actionPanel != nil)
        .background { shadow }
        .environment(\.fileAuthorizer) { path in
            if case .success(let url) = center.authorizeFile(path) { return url }
            return nil
        }
        // Room for the shadow inside the transparent window.
        .padding(CommandCenterLayout.shadowMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Center")
    }

    /// A soft shadow outside the glass only: drawn from a shape whose own
    /// area is cut away, so it never darkens the translucent panel.
    private var shadow: some View {
        let shape = RoundedRectangle(cornerRadius: CommandCenterLayout.cornerRadius, style: .continuous)
        return shape
            .fill(.black)
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
            .compositingGroup()
            .mask {
                Rectangle()
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
                    .padding(-CommandCenterLayout.shadowMargin)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
                    placeholder: "Search apps, commands and Settings",
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
            switch screen {
            case .details(let id):
                CommandCenterDetails(item: state.item(id))
                    .frame(minHeight: Self.minContentHeight, alignment: .top)
            case .preview(let id):
                CommandCenterPreview(result: center.previewURL(for: id))
                    .frame(height: Self.previewHeight)
            }
        } else if state.results.isEmpty {
            Text("No results")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.minContentHeight)
        } else {
            results
        }
    }

    /// Tall enough for a short Action Panel to fit above the footer.
    private static let minContentHeight: CGFloat = 176
    private static let previewHeight: CGFloat = 340

    private var results: some View {
        let rows = min(max(state.results.count, 1), CommandCenterLayout.visibleRows)
        // A card row is taller; count the first rows that fit.
        let shown = state.results.prefix(rows).reduce(CGFloat(0)) { $0 + ($1.card == nil ? CommandCenterLayout.rowHeight : CommandCenterLayout.cardHeight) }
        let height = max(shown + 12, Self.minContentHeight)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.results) { item in
                        if let card = item.card {
                            CommandCenterCardRow(item: item, card: card, isSelected: item.id == state.selection) {
                                center.send(.activate(item.id))
                            }
                            .id(item.id)
                        } else {
                            CommandCenterRow(item: item, isSelected: item.id == state.selection) {
                                center.send(.activate(item.id))
                            }
                            .id(item.id)
                        }
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
                Image(systemName: Self.symbol(notice.kind))
                    .foregroundStyle(notice.kind == .canceled || notice.kind == .succeeded ? Color.secondary : Color.orange)
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
                CommandCenterKeyHint(title: item.unavailableReason == nil ? item.primaryTitle : "Unavailable", keys: "↩")
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

    private static func symbol(_ kind: CommandCenterNotice.Kind) -> String {
        switch kind {
        case .canceled: return "xmark.circle"
        case .succeeded: return "checkmark.circle"
        case .unavailable, .failed: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Rows

/// The calculator's result: expression, arrow, answer, in one card.
private struct CommandCenterCardRow: View {
    let item: CommandCenterItem
    let card: CommandCenterCard
    let isSelected: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 0) {
                Text(card.input)
                    .frame(maxWidth: .infinity)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44)
                Text(card.output)
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 30, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.horizontal, 12)
            .frame(height: CommandCenterLayout.cardHeight - 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.12 : 0.07))
            )
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.input) equals \(card.output)")
        .accessibilityHint(item.primaryTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct CommandCenterRow: View {
    let item: CommandCenterItem
    let isSelected: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 10) {
                CommandCenterIcon(item: item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(item.unavailableReason == nil ? .primary : .secondary)
                    if let line = item.unavailableReason ?? item.detail {
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
        .accessibilityValue(item.unavailableReason.map { "Unavailable. \($0)" } ?? [item.detail, item.subtitle].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(item.unavailableReason == nil ? item.primaryTitle : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The app's own icon for app rows, else the SF Symbol.
private struct CommandCenterIcon: View {
    let item: CommandCenterItem

    var body: some View {
        if let glyph = item.glyph {
            Text(glyph)
                .font(.system(size: 20))
                .frame(width: 24)
                .accessibilityHidden(true)
        } else if item.kind == .file, item.previewable, let path = item.iconPath {
            FileThumbnailIcon(path: path)
        } else if let path = item.iconPath {
            Image(nsImage: CommandCenterIconCache.icon(for: path))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .frame(width: 24)
                .accessibilityHidden(true)
        } else {
            Image(systemName: item.symbolName ?? "command")
                .font(.system(size: 14))
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// `NSWorkspace.icon(forFile:)` hands back a lazily drawn image, so only the
/// rows on screen pay for drawing, once per app per session of the process.
@MainActor
enum CommandCenterIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
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
        VStack(spacing: 0) {
            // The list at its own height when it fits, otherwise scrolling
            // with the highlighted action kept in view.
            ViewThatFits(in: .vertical) {
                list
                ScrollViewReader { proxy in
                    ScrollView { list }
                        .onChange(of: center.state.actionPanel?.highlight) { _, highlight in
                            guard let highlight else { return }
                            proxy.scrollTo(highlight)
                        }
                }
            }
            Divider()
            CommandCenterTextField(
                placeholder: "Search actions",
                text: center.state.actionPanel?.query ?? "",
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

    private var list: some View {
        let state = center.state
        return VStack(spacing: 0) {
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
                .id(action.kind)
            }
            if state.visibleActions.isEmpty {
                Text("No matching actions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
        }
        .padding(6)
    }
}

// MARK: - Quick Look screen

/// The file's Quick Look preview inside the panel. The URL arrives already
/// checked against the chosen folders; otherwise the reason is shown and
/// nothing is loaded.
private struct CommandCenterPreview: View {
    let result: Result<URL, CommandFailure>

    var body: some View {
        switch result {
        case .success(let url):
            Group {
                switch MediaKind.of(url) {
                case .audio: AudioPreview(url: url)
                case .video: VideoPreview(url: url)
                case .other: QuickLookPreview(url: url)
                }
            }
            .accessibilityLabel("Preview of \(url.lastPathComponent)")
        case .failure(let failure):
            Text(failure.reason)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    /// Releases the Quick Look service connection when the screen goes away.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

// MARK: - Details screen

private struct CommandCenterDetails: View {
    let item: CommandCenterItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item, !item.facts.isEmpty {
                // A server card: what the listing said, nothing guessed.
                ForEach(Array(item.facts.enumerated()), id: \.offset) { _, fact in
                    row(fact.label, fact.value)
                }
                if let reason = item.unavailableReason { row("Status", "Unavailable. \(reason)") }
            } else if let item {
                row("Status", item.unavailableReason.map { "Unavailable. \($0)" } ?? "Available")
                row(item.kind == .command ? "Module" : "Kind", item.subtitle)
                row("Result ID", item.id.rawValue)
                row("Runs", item.invocation.command.rawValue)
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
