import AppKit
import Carbon.HIToolbox

/// One labeled line of a details screen (a server card).
struct CommandCenterFact: Equatable, Sendable {
    let label: String
    let value: String
}

/// An extra Action Panel row that runs its own registry command.
struct CommandCenterItemAction: Equatable, Sendable {
    let title: String
    let symbolName: String
    let invocation: CommandInvocation
    /// Key glyphs shown in the Action Panel. "⌘⇧F" also runs it from the
    /// keyboard while its item is selected.
    var shortcut: String?

    /// The reveal shortcut of a file row.
    static let revealShortcut = "⌘⇧F"
}

/// What a card row shows (the calculator).
struct CommandCenterCard: Equatable, Sendable {
    let input: String
    let output: String
}

/// One result row: a registry command, an app, a Settings pane, a
/// quicklink, a local server or the port lookup. Built from a fresh snapshot each time the
/// panel opens (see `CommandCenterCatalog`).
struct CommandCenterItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case command, application, settings, quicklink, server, snippet, shortcut, file, clipboard
        /// The port lookup's status row for the current query.
        case lookup
        /// The calculator's result for the query (P2-CMD-06).
        case calculation
        case emoji

        /// Rows made from the query itself: never counted in history, and
        /// their primary action is already a copy.
        var isQuickAnswer: Bool { self == .calculation || self == .emoji }
    }

    let id: CommandCenterResultID
    var kind: Kind
    let title: String
    /// The owning module's title, or the kind ("Application", "Running").
    var subtitle: String = ""
    var symbolName: String?
    /// App bundle whose icon replaces `symbolName`.
    var iconPath: String?
    var keywords: [String] = []
    /// nil when it can run, otherwise why it cannot. Shown in the row.
    var unavailableReason: String?
    /// Required permission scopes, by name, for the details screen.
    var permissions: [String] = []
    /// The registry command Return runs.
    var invocation: CommandInvocation
    /// Title of the primary action ("Run Command", "Open Application").
    var primaryTitle = "Run Command"
    /// What Copy puts on the pasteboard, and the action's title.
    var copyValue: String
    var copyTitle = "Copy Command ID"
    /// Frecency at snapshot time, 0 when never picked. Ranks before title.
    var usage: Double = 0
    /// Second line of the row when available (a server's PID and binds).
    var detail: String?
    /// When set, the details screen shows these instead of the generic rows.
    var facts: [CommandCenterFact] = []
    /// Action Panel rows after Show Details, each its own registry command.
    var moreActions: [CommandCenterItemAction] = []
    /// A file Quick Look can show in the panel (⌘Y).
    var previewable = false
    /// Also matches any server query (a port number, "port", "server").
    var matchesServerQueries = false
    /// Ranks first for exactly this query (`CommandCenterRanker.answerKey`):
    /// the port lookup's row and the server cards it found.
    var answers: String?
    /// Return replaces the query with this instead of running a command
    /// (the numeric search a port lookup offers).
    var queryReplacement: String?
    /// Calculator result drawn as a card: the expression, an arrow, the answer.
    var card: CommandCenterCard?
    /// Text shown where the icon goes (an emoji).
    var glyph: String?
    /// Order among rows that answer the same query, lower first.
    var answerOrder = 0

    init(
        id: CommandCenterResultID, kind: Kind, title: String, subtitle: String = "", symbolName: String? = nil,
        iconPath: String? = nil, keywords: [String] = [], unavailableReason: String? = nil, permissions: [String] = [],
        invocation: CommandInvocation, primaryTitle: String, copyValue: String, copyTitle: String, usage: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.iconPath = iconPath
        self.keywords = keywords
        self.unavailableReason = unavailableReason
        self.permissions = permissions
        self.invocation = invocation
        self.primaryTitle = primaryTitle
        self.copyValue = copyValue
        self.copyTitle = copyTitle
        self.usage = usage
    }

    /// A registry command without input, as listed by itself.
    init(id: CommandID, title: String, subtitle: String = "", symbolName: String? = nil, keywords: [String] = [],
         unavailableReason: String? = nil, permissions: [String] = [], usage: Double = 0) {
        self.init(
            id: .command(id), kind: .command, title: title, subtitle: subtitle, symbolName: symbolName,
            keywords: keywords, unavailableReason: unavailableReason, permissions: permissions,
            invocation: CommandInvocation(command: id), primaryTitle: "Run Command",
            copyValue: id.rawValue, copyTitle: "Copy Command ID", usage: usage
        )
    }
}

enum CommandCenterActionKind: Hashable {
    case run, showDetails, copyID
    /// Preview the file in the panel (Quick Look).
    case quickLook
    /// `moreActions[index]` of the item.
    case more(Int)
}

/// One row of the Action Panel (Cmd+K).
struct CommandCenterAction: Equatable, Identifiable {
    let kind: CommandCenterActionKind
    let title: String
    let symbolName: String
    /// Key glyphs shown at the trailing edge, nil for none.
    var shortcut: String?
    /// nil when it can run, otherwise why not.
    var disabledReason: String?
    var id: CommandCenterActionKind { kind }
}

/// A pushed view. Esc or Backspace pops one level.
enum CommandCenterScreen: Equatable {
    case details(CommandCenterResultID)
    /// Quick Look of a file, inside the panel.
    case preview(CommandCenterResultID)

    var itemID: CommandCenterResultID {
        switch self {
        case .details(let id), .preview(let id): return id
        }
    }
}

/// The footer message after Return could not run something.
struct CommandCenterNotice: Equatable {
    enum Kind: Equatable { case unavailable, failed, canceled, succeeded }
    let kind: Kind
    let message: String
}

/// The keys the panel handles itself. Anything else goes to the focused field.
enum CommandCenterKey: Equatable {
    case up, down
    case `return`, commandReturn
    case escape, commandEscape
    case commandK
    /// ⌘Y toggles the Quick Look preview of the selected file.
    case commandY
    /// ⌘⇧F runs the selected row's Show in Finder.
    case commandShiftF
    case tab
    case backspace

    /// nil while an input method is composing (marked text), so Return
    /// commits the text and Esc cancels the composition instead of acting.
    /// Letter keys go by the typed character, so Ctrl+N and Cmd+K follow the
    /// keyboard layout.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?, isComposing: Bool) {
        guard !isComposing else { return nil }
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        switch Int(keyCode) {
        case kVK_UpArrow where flags.isEmpty: self = .up
        case kVK_DownArrow where flags.isEmpty: self = .down
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags.isEmpty { self = .return } else if flags == .command { self = .commandReturn } else { return nil }
        case kVK_Escape:
            if flags.isEmpty { self = .escape } else if flags == .command { self = .commandEscape } else { return nil }
        case kVK_Tab: self = .tab
        case kVK_Delete where flags.isEmpty: self = .backspace
        default:
            switch (characters?.lowercased(), flags) {
            case ("n", .control): self = .down
            case ("p", .control): self = .up
            case ("k", .command): self = .commandK
            case ("y", .command): self = .commandY
            case ("f", [.command, .shift]): self = .commandShiftF
            default: return nil
            }
        }
    }
}

enum CommandCenterEvent: Equatable {
    /// Menu bar item: show, or bring an open panel back to key.
    case open([CommandCenterItem])
    /// Global hotkey: show when hidden, hide when visible and key.
    case hotkey([CommandCenterItem], panelIsKey: Bool)
    case query(String)
    /// Ranked IDs for a `.search` request. Dropped unless it is the latest.
    case results(CommandCenterSearchRequest, [CommandCenterResultID])
    /// A fresher snapshot while open (the app list finished loading).
    case catalog([CommandCenterItem])
    case actionQuery(String)
    case key(CommandCenterKey)
    /// Mouse: click a row (select and run its primary action).
    case activate(CommandCenterResultID)
    /// Mouse: click an action in the Action Panel.
    case performAction(CommandCenterActionKind)
    /// Mouse: the footer Actions button.
    case toggleActions
    /// Mouse: the back button of a pushed screen.
    case back
    case finished(CommandCenterResultID, CommandResult)
    /// Another app or window took key focus. Hide, never take focus back.
    case focusLost
}

/// What the controller must do after an event. The state machine itself
/// touches no AppKit, so every transition is testable.
enum CommandCenterEffect: Equatable {
    /// Record the frontmost app, order the panel in and make it key.
    case present
    /// Visible but not key: make it key again.
    case focusPanel
    /// Order out. `restoreFocus` reactivates the recorded app when
    /// Portside took activation during the session.
    case dismiss(restoreFocus: Bool)
    /// Execute the item's invocation through the registry.
    case run(CommandCenterResultID)
    /// Execute the item's `moreActions[index]` through the registry.
    case runAction(CommandCenterResultID, Int)
    case cancelRun
    /// Rank `query` against the current items off the main thread, then
    /// send `.results`. Cancels any search in flight.
    case search(CommandCenterSearchRequest)
    /// A result ran successfully: count it for ranking.
    case recordUsage(CommandCenterResultID)
    case copy(String)
    /// VoiceOver announcement. The controller coalesces rapid ones.
    case announce(String)
}

struct CommandCenterOutcome: Equatable {
    /// The event was consumed. A key that was not stays with the text field.
    var handled: Bool
    var effects: [CommandCenterEffect] = []

    static let ignored = CommandCenterOutcome(handled: false)
    static func handled(_ effects: [CommandCenterEffect] = []) -> CommandCenterOutcome {
        CommandCenterOutcome(handled: true, effects: effects)
    }
}

/// Command Center interaction state (P2-REA-01 contract). A value type: the
/// controller sends events and performs the returned effects. `presenting`
/// and `dismissing` from the research table are the synchronous `.present`
/// and `.dismiss` effects, so they are not stored here.
struct CommandCenterState: Equatable {
    enum Mode: Equatable {
        case hidden, searching, actions, screen, running
    }

    struct ActionPanel: Equatable {
        let itemID: CommandCenterResultID
        var query = ""
        var highlight: CommandCenterActionKind?
    }

    private(set) var isVisible = false
    private(set) var query = ""
    private(set) var items: [CommandCenterItem] = [] {
        didSet { positions = Dictionary(items.enumerated().map { ($1.id, $0) }) { first, _ in first } }
    }
    private var positions: [CommandCenterResultID: Int] = [:]
    private(set) var results: [CommandCenterItem] = []
    /// Keyed by ID, so it survives a re-rank.
    private(set) var selection: CommandCenterResultID?
    private(set) var actionPanel: ActionPanel?
    private(set) var stack: [CommandCenterScreen] = []
    private(set) var running: CommandCenterResultID?
    /// The running invocation keeps the panel open when it succeeds.
    private var runStaysOpen = false
    private(set) var notice: CommandCenterNotice?
    /// Bumped by every query change and catalog refresh. Only results for
    /// the latest generation are applied.
    private(set) var searchGeneration = 0
    /// A search is in flight; `results` still shows the previous query's.
    var isSearching: Bool { pendingSearch != nil }
    private var pendingSearch: CommandCenterSearchRequest?

    var mode: Mode {
        if !isVisible { return .hidden }
        if running != nil { return .running }
        if actionPanel != nil { return .actions }
        if !stack.isEmpty { return .screen }
        return .searching
    }

    var selectedItem: CommandCenterItem? { selection.flatMap(item) }

    func item(_ id: CommandCenterResultID) -> CommandCenterItem? { positions[id].map { items[$0] } }

    /// The item Cmd+K and Return act on: the pushed screen's, else the selection.
    var targetItem: CommandCenterItem? {
        if let top = stack.last { return item(top.itemID) }
        return selectedItem
    }

    /// Every action for `item` in the current context, before the panel filter.
    func actions(for item: CommandCenterItem) -> [CommandCenterAction] {
        var list = [CommandCenterAction(kind: .run, title: item.primaryTitle, symbolName: "return", shortcut: "↩",
                                        disabledReason: item.unavailableReason)]
        if stack.last != .details(item.id) {
            list.append(CommandCenterAction(kind: .showDetails, title: "Show Details", symbolName: "info.circle", shortcut: "⌘↩"))
        }
        if item.previewable, stack.last != .preview(item.id) {
            list.append(CommandCenterAction(kind: .quickLook, title: "Quick Look", symbolName: "eye", shortcut: "⌘Y",
                                            disabledReason: item.unavailableReason))
        }
        for (index, action) in item.moreActions.enumerated() {
            list.append(CommandCenterAction(kind: .more(index), title: action.title, symbolName: action.symbolName,
                                            shortcut: action.shortcut, disabledReason: item.unavailableReason))
        }
        // A server's copies go through the registry (primary and more actions);
        // a quick answer's and a snippet's primary action is the copy.
        if item.kind != .server, item.kind != .lookup, item.kind != .snippet, item.kind != .clipboard, !item.kind.isQuickAnswer {
            list.append(CommandCenterAction(kind: .copyID, title: item.copyTitle, symbolName: "doc.on.doc"))
        }
        return list
    }

    /// The Action Panel's rows after its own filter.
    var visibleActions: [CommandCenterAction] {
        guard let panel = actionPanel, let item = item(panel.itemID) else { return [] }
        return Self.filterActions(actions(for: item), query: panel.query)
    }

    // MARK: Events

    mutating func send(_ event: CommandCenterEvent) -> CommandCenterOutcome {
        switch event {
        case .open(let items):
            if isVisible { return .handled([.focusPanel]) }
            return present(items)
        case .hotkey(let items, let panelIsKey):
            if !isVisible { return present(items) }
            if !panelIsKey { return .handled([.focusPanel]) }
            return .handled(dismiss(restoreFocus: true, cancelRun: true))
        case .query(let text):
            guard isVisible, text != query else { return .ignored }
            query = text
            notice = nil
            return .handled(search(preservingSelection: false))
        case .results(let request, let ids):
            guard isVisible, request == pendingSearch else { return .ignored }
            pendingSearch = nil
            apply(ids, resetSelection: !request.preservesSelection)
            return .handled(request.preservesSelection ? [] : [.announce(resultsAnnouncement)])
        case .catalog(let fresh):
            guard isVisible else { return .ignored }
            // The Local Servers or port lookup row at the top stands in until
            // servers arrive; the first match takes the selection then. A query
            // whose results have not landed yet keeps its fresh selection too.
            let placeholder = selection != nil && results.first?.id == selection
                && (selectedItem?.matchesServerQueries == true || selectedItem?.answers != nil)
            let queryPending = pendingSearch.map { !$0.preservesSelection } ?? false
            items = fresh
            // A row that vanished mid-session closes its panel or screen.
            if let panel = actionPanel, item(panel.itemID) == nil { actionPanel = nil }
            let kept = stack.filter { item($0.itemID) != nil }
            stack = kept
            return .handled(search(preservingSelection: !placeholder && !queryPending))
        case .actionQuery(let text):
            guard var panel = actionPanel, text != panel.query else { return .ignored }
            panel.query = text
            actionPanel = panel
            let first = visibleActions.first?.kind
            actionPanel?.highlight = first
            return .handled()
        case .key(let key):
            guard isVisible else { return .ignored }
            return handle(key)
        case .activate(let id):
            guard isVisible, running == nil, results.contains(where: { $0.id == id }) else { return .ignored }
            actionPanel = nil
            stack = []
            selection = id
            return .handled(primary(id))
        case .performAction(let kind):
            guard actionPanel != nil, running == nil else { return .ignored }
            return .handled(perform(kind))
        case .toggleActions:
            guard isVisible else { return .ignored }
            return handle(.commandK)
        case .back:
            guard isVisible, actionPanel == nil, !stack.isEmpty else { return .ignored }
            return .handled(pop())
        case .finished(let id, let result):
            guard isVisible, running == id else { return .ignored }
            running = nil
            return .handled(finish(id, result))
        case .focusLost:
            guard isVisible else { return .ignored }
            // Work in flight is left to finish; its result is dropped.
            return .handled(dismiss(restoreFocus: false, cancelRun: false))
        }
    }

    private mutating func present(_ items: [CommandCenterItem]) -> CommandCenterOutcome {
        self = CommandCenterState()
        isVisible = true
        self.items = items
        apply(CommandCenterRanker.defaultOrder(items).map(\.id), resetSelection: true)
        return .handled([.present, .announce("Command Center. \(resultsAnnouncement)")])
    }

    private mutating func dismiss(restoreFocus: Bool, cancelRun: Bool) -> [CommandCenterEffect] {
        let wasRunning = running != nil
        self = CommandCenterState()
        return (wasRunning && cancelRun ? [.cancelRun] : []) + [.dismiss(restoreFocus: restoreFocus)]
    }

    private mutating func handle(_ key: CommandCenterKey) -> CommandCenterOutcome {
        if key == .commandEscape {
            return .handled(dismiss(restoreFocus: true, cancelRun: true))
        }
        if running != nil {
            // Esc cancels; the handler's `.canceled` result lands in `finish`.
            // Other keys wait for the result, but Tab still moves focus.
            switch key {
            case .escape: return .handled([.cancelRun])
            case .tab, .backspace: return .ignored
            default: return .handled()
            }
        }
        if [.up, .down, .return, .commandReturn, .commandK, .commandY, .commandShiftF].contains(key) { flushPendingSearch() }
        switch key {
        case .escape:
            // One step per press: Action Panel, pushed screen, query, window.
            if actionPanel != nil {
                actionPanel = nil
                return .handled()
            }
            if !stack.isEmpty { return .handled(pop()) }
            if !query.isEmpty {
                query = ""
                notice = nil
                _ = search(preservingSelection: false)
                return .handled([.announce("Search cleared. \(resultsAnnouncement)")])
            }
            return .handled(dismiss(restoreFocus: true, cancelRun: true))
        case .up, .down:
            let delta = key == .down ? 1 : -1
            if actionPanel != nil { return .handled(moveHighlight(delta)) }
            if !stack.isEmpty { return .handled() }
            return .handled(moveSelection(delta))
        case .return:
            if let highlight = actionPanel?.highlight { return .handled(perform(highlight)) }
            if actionPanel != nil { return .handled() }
            guard let item = targetItem else { return .handled() }
            return .handled(primary(item.id))
        case .commandReturn:
            if let highlight = actionPanel?.highlight { return .handled(perform(highlight)) }
            if actionPanel != nil { return .handled() }
            guard let item = targetItem, actions(for: item).contains(where: { $0.kind == .showDetails }) else {
                return .handled()
            }
            return .handled(push(.details(item.id)))
        case .commandY:
            guard let item = targetItem, item.previewable else { return .handled() }
            actionPanel = nil
            if stack.last == .preview(item.id) { return .handled(pop()) }
            if let reason = item.unavailableReason {
                notice = CommandCenterNotice(kind: .unavailable, message: reason)
                return .handled([.announce("\(item.title) is unavailable. \(reason)")])
            }
            return .handled(push(.preview(item.id)))
        case .commandShiftF:
            guard let item = targetItem,
                  let index = item.moreActions.firstIndex(where: { $0.shortcut == CommandCenterItemAction.revealShortcut }) else { return .handled() }
            actionPanel = nil
            return .handled(runAction(item.id, index))
        case .commandK:
            if actionPanel != nil {
                actionPanel = nil
                return .handled()
            }
            guard let item = targetItem else { return .handled() }
            actionPanel = ActionPanel(itemID: item.id)
            let visible = visibleActions
            actionPanel?.highlight = visible.first?.kind
            return .handled([.announce("Actions for \(item.title). \(visible.count) actions.")])
        case .backspace:
            // On an empty query (or a screen with no field) Backspace goes back.
            if actionPanel == nil, !stack.isEmpty { return .handled(pop()) }
            return .ignored
        case .tab, .commandEscape:
            // Tab moves between controls through the normal key-view loop.
            return .ignored
        }
    }

    // MARK: Steps

    private mutating func primary(_ id: CommandCenterResultID) -> [CommandCenterEffect] {
        guard let item = item(id) else { return [] }
        if let reason = item.unavailableReason {
            notice = CommandCenterNotice(kind: .unavailable, message: reason)
            return [.announce("\(item.title) is unavailable. \(reason)")]
        }
        if let replacement = item.queryReplacement {
            // Search instead of run: the field shows the new query.
            stack = []
            query = replacement
            notice = nil
            return search(preservingSelection: false) + [.announce("Searching \(replacement).")]
        }
        notice = nil
        running = id
        runStaysOpen = item.invocation.staysOpen
        return [.run(id)]
    }

    private mutating func runAction(_ id: CommandCenterResultID, _ index: Int) -> [CommandCenterEffect] {
        guard let item = item(id), item.moreActions.indices.contains(index) else { return [] }
        if let reason = item.unavailableReason {
            notice = CommandCenterNotice(kind: .unavailable, message: reason)
            return [.announce("\(item.title) is unavailable. \(reason)")]
        }
        notice = nil
        running = id
        runStaysOpen = item.moreActions[index].invocation.staysOpen
        return [.runAction(id, index)]
    }

    private mutating func perform(_ kind: CommandCenterActionKind) -> [CommandCenterEffect] {
        guard let panel = actionPanel, let item = item(panel.itemID),
              actions(for: item).contains(where: { $0.kind == kind }) else { return [] }
        actionPanel = nil
        switch kind {
        case .run: return primary(item.id)
        case .showDetails: return push(.details(item.id))
        case .quickLook: return push(.preview(item.id))
        case .copyID: return [.copy(item.copyValue)] + dismiss(restoreFocus: true, cancelRun: false)
        case .more(let index): return runAction(item.id, index)
        }
    }

    private mutating func push(_ screen: CommandCenterScreen) -> [CommandCenterEffect] {
        stack.append(screen)
        notice = nil
        let title = item(screen.itemID)?.title ?? ""
        if case .preview = screen { return [.announce("Preview of \(title).")] }
        return [.announce("Details for \(title).")]
    }

    private mutating func pop() -> [CommandCenterEffect] {
        stack.removeLast()
        notice = nil
        if let top = stack.last, let item = item(top.itemID) {
            if case .preview = top { return [.announce("Preview of \(item.title).")] }
            return [.announce("Details for \(item.title).")]
        }
        return [.announce("Back to search. \(resultsAnnouncement)")]
    }

    private mutating func finish(_ id: CommandCenterResultID, _ result: CommandResult) -> [CommandCenterEffect] {
        let title = item(id)?.title ?? id.rawValue
        let staysOpen = runStaysOpen
        runStaysOpen = false
        // Server and lookup rows belong to one session: never kept in history.
        let kind = item(id)?.kind
        let usage: [CommandCenterEffect] = kind == nil || kind == .server || kind == .lookup || kind == .file || kind == .clipboard || kind?.isQuickAnswer == true ? [] : [.recordUsage(id)]
        switch result {
        case .success(let message) where staysOpen:
            // It updated the panel (a refresh): stay, and say what happened.
            notice = message.map { CommandCenterNotice(kind: .succeeded, message: $0) }
            return usage + [.announce(message ?? "\(title) finished.")]
        case .success:
            // The command did its work (and may have moved focus): just hide.
            return usage + dismiss(restoreFocus: false, cancelRun: false)
        case .canceled:
            notice = CommandCenterNotice(kind: .canceled, message: "\(title) was canceled.")
        case .unavailable(let reason):
            // Availability changed since the snapshot: mark the row too.
            if let index = positions[id] { items[index].unavailableReason = reason }
            apply(results.map(\.id), resetSelection: false)
            notice = CommandCenterNotice(kind: .unavailable, message: reason)
        case .failed(let reason), .invalidInput(let reason):
            notice = CommandCenterNotice(kind: .failed, message: reason)
        case .unknownCommand:
            notice = CommandCenterNotice(kind: .failed, message: "\(title) is no longer available.")
        }
        return [.announce(notice?.message ?? "")]
    }

    private mutating func moveSelection(_ delta: Int) -> [CommandCenterEffect] {
        guard !results.isEmpty else { return [] }
        let current = results.firstIndex { $0.id == selection } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        guard next != current || selection == nil else { return [] }
        selection = results[next].id
        notice = nil
        let item = results[next]
        var text = "\(item.title), \(next + 1) of \(results.count)"
        if let reason = item.unavailableReason { text += ". Unavailable: \(reason)" }
        return [.announce(text)]
    }

    private mutating func moveHighlight(_ delta: Int) -> [CommandCenterEffect] {
        let visible = visibleActions
        guard !visible.isEmpty else { return [] }
        let current = visible.firstIndex { $0.kind == actionPanel?.highlight } ?? 0
        let next = min(max(current + delta, 0), visible.count - 1)
        guard next != current else { return [] }
        actionPanel?.highlight = visible[next].kind
        var text = visible[next].title
        if let reason = visible[next].disabledReason { text += ". Unavailable: \(reason)" }
        return [.announce(text)]
    }

    /// New generation for the current query. An empty query is the default
    /// list, ranked right here (it is the first frame on open and after Esc
    /// clears); anything else is ranked off the main thread.
    private mutating func search(preservingSelection: Bool) -> [CommandCenterEffect] {
        searchGeneration += 1
        if CommandCenterRanker.terms(query).isEmpty {
            pendingSearch = nil
            apply(CommandCenterRanker.defaultOrder(items).map(\.id), resetSelection: !preservingSelection)
            return preservingSelection ? [] : [.announce(resultsAnnouncement)]
        }
        let request = CommandCenterSearchRequest(generation: searchGeneration, query: query, preservesSelection: preservingSelection)
        pendingSearch = request
        return [.search(request)]
    }

    /// A key that acts on the list arrived before the off-main ranking:
    /// rank here so it acts on the latest query, never the previous one.
    /// The late delivery for this generation is then dropped.
    private mutating func flushPendingSearch() {
        guard let request = pendingSearch else { return }
        pendingSearch = nil
        apply(CommandCenterRanker.rank(items, query: request.query) ?? [], resetSelection: !request.preservesSelection)
    }

    /// Shows `ids` in order. The selection stays on its row when asked and
    /// the row is still there, otherwise it moves to the first result.
    private mutating func apply(_ ids: [CommandCenterResultID], resetSelection: Bool) {
        results = ids.compactMap(item)
        if resetSelection || !results.contains(where: { $0.id == selection }) {
            selection = results.first?.id
        }
    }

    private var resultsAnnouncement: String {
        switch results.count {
        case 0: return "No results."
        case 1: return "1 result."
        default: return "\(results.count) results."
        }
    }

    // MARK: Filtering

    /// Action Panel filter: every query word starts a word of the title.
    static func filterActions(_ actions: [CommandCenterAction], query: String) -> [CommandCenterAction] {
        let terms = CommandCenterRanker.terms(query)
        guard !terms.isEmpty else { return actions }
        return actions.filter { action in
            let words = CommandCenterRanker.words(CommandCenterRanker.normalize(action.title))
            return terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
        }
    }
}
