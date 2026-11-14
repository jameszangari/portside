import SwiftUI

/// A folded group of detail settings. The header row names what is inside
/// and shows the current values, so a pane can be read without opening
/// anything; the controls are listed under it only when opened. Starts
/// closed, and opens itself when Settings search lands on it (its title is
/// its search anchor). Use inside a Form section, one after another.
struct SettingsFold<Content: View>: View {
    let title: String
    let symbol: String
    let summary: String
    var anchors: [String] = []
    @ViewBuilder let content: () -> Content
    @State private var open = false

    init(_ title: String, symbol: String, summary: String, anchors: [String] = [], @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.anchors = anchors
        self.content = content
    }

    var body: some View {
        Group {
            SettingsFoldRow(title, symbol: symbol, summary: summary, anchors: anchors, open: $open)
            if open { content() }
        }
    }
}

/// A fold's header row alone, for a fold whose contents are whole sections
/// (the caller shows them while `open`).
struct SettingsFoldRow: View {
    let title: String
    let symbol: String
    let summary: String
    /// Search anchors inside the fold that should open it too.
    var anchors: [String] = []
    @Binding var open: Bool
    @Environment(\.settingsHighlight) private var highlight

    init(_ title: String, symbol: String, summary: String, anchors: [String] = [], open: Binding<Bool>) {
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.anchors = anchors
        _open = open
    }

    private func opens(_ name: String?) -> Bool { name.map { $0 == title || anchors.contains($0) } ?? false }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsAnchor(title)
        .accessibilityLabel(summary.isEmpty ? title : "\(title), \(summary)")
        .accessibilityHint(open ? "Hides these settings" : "Shows these settings")
        .onAppear { if opens(highlight) { open = true } }
        .onChange(of: highlight) { _, name in if opens(name) { open = true } }
    }
}

/// "On" items joined for a fold summary: "Camera, Microphone", or `none`.
func settingsList(_ items: [(String, Bool)], none: String = "Off") -> String {
    let on = items.filter(\.1).map(\.0)
    return on.isEmpty ? none : on.joined(separator: ", ")
}

/// Seconds as a short summary value: "150 ms", "Instant".
func settingsMilliseconds(_ seconds: Double) -> String {
    seconds == 0 ? "Instant" : "\(Int((seconds * 1000).rounded())) ms"
}
