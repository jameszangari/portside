# Take over: Portside, a native macOS dock replacement (personal project)

You're taking over a half-built project from a weaker local model that kept looping. Work autonomously, verify everything yourself, and don't trust the previous agent's claims (it marked "swift build passes" done without proof).

## Project
- Location: ~/Developer/custom-dock (Swift Package Manager, executable target "portside", sources in Sources/portside/)
- Name is "Portside", bundle id com.james.portside. It replaces a third-party app called Dockset (dev.benja.dockset). Never touch Dockset, /Applications, or its preferences.
- Machine: Apple Silicon M4 Max, macOS 27.0.1, Xcode 27.1. Confirm toolchain versions before choosing APIs.
- Read docs/PLAN.md (architecture, milestones A-F, acceptance criteria) and docs/CHECKLIST.md (Milestone A status) first.

## Why this exists
Dockset feels laggy because its edge reveal uses repeating polling timers (about 50ms armed, 250ms idle), and its window isn't instantly interactive. Portside fixes that: an NSTrackingArea on a thin edge window (event-driven, zero polling in the reveal/hide path) plus a non-activating NSPanel. Responsiveness is the entire point. Reveal should begin within about one frame (16ms) of the cursor touching the edge, and the first click must work without stealing focus from the frontmost app.

## Hard rules
1. Never hand-write an .xcodeproj or project.pbxproj. SPM only. (The previous agent looped on this.)
2. Run `swift build` after every batch of changes and read the real output. Run `swift run` yourself to catch launch crashes. A clean build is not proof it works. Source `scripts/swift-env.sh` first (or export `SWIFT_ENABLE_EXPLICIT_MODULES=NO`) so clean/cold debug builds stay fast on Xcode 26/27. Never run two SwiftPM commands against this repo's `.build` in parallel; they serialize on a lock and look hung.
3. If you repeat the same action twice with the same result, stop and rethink.
4. Public APIs only through Milestone E. Private APIs (CoreDock, SkyLight, badges) only in Milestone F, behind dlopen/dlsym guards so an OS update degrades gracefully instead of crashing.
5. No polling timers in the reveal/hide path. Allowed timers: one cancelable hide-delay timer, widget refresh, running-app cache refresh.
6. Don't modify com.apple.dock settings until Milestone F, and then always save the user's exact prior values first and restore them on quit. Test the restore.
7. No em dashes in docs or comments I'll read.
8. If a task needs a new private API, isolate it in its own guarded file (dlopen/dlsym, graceful fallback) and mention it in docs/ARCHITECTURE.md Notes.

## Current state
Milestone A files exist: DockEngine, EdgeTracker, DockPanel, DockModel, DockStrip (placeholder), PortsideApp, Info.plist, Package.swift. It builds but crashes at launch.

Known bugs, fix in this order:
1. CRASH: DockEngine has two lazy properties that depend on each other (dockPanel needs edgeTracker, edgeTracker needs dockPanel), causing infinite recursion. DockPanel stores edgeTracker but never uses it. Remove that dependency: DockPanel(dockModel:) only.
2. DockPanel never calls orderFrontRegardless(), so it never appears on screen.
3. The edge window uses alphaValue = 0 with a clear background. macOS passes mouse events through fully transparent windows, so mouseEntered may never fire. Use alphaValue 1 with a near-invisible background (for example NSColor(white: 0, alpha: 0.01)). Verify with logs that mouseEntered actually fires.
4. Hide logic: the panel covers the edge window when revealed, so the edge view gets mouseExited immediately and the dock hides while the user is hovering it. Add a tracking area on the panel itself. The hide timer must be a cancelable DispatchWorkItem, canceled on re-enter of either the edge zone or the panel.
5. EdgeTracker.start() calls NSApp.activate(ignoringOtherApps:), which steals focus. Remove it. Make sure the app runs as an accessory (NSApp.setActivationPolicy(.accessory)) since an SPM executable ignores LSUIElement in Info.plist.
6. Logging: os.Logger interpolated Strings print as <private>. Use numeric interpolation with format: .fixed(precision: 2) for timings. Logs are viewable with: log stream --level info --predicate 'subsystem == "com.james.portside"'
7. The slide isn't animated (setFrame without animating; animationDuration is unused). Implement a real slide with NSAnimationContext, default 150ms, plus an instant option, and respect Reduce Motion.
8. DockEngine.start() reveals the panel immediately. It should start hidden.

## Milestones (from PLAN.md)
A: edge tracker + non-activating panel + slide + timing logs. B: pinned apps + running indicators (NSWorkspace notifications), drag reorder, persistence. C: widget plugin system with 3+ widgets (clock, battery, calendar, plus weather/system stats). D: grouped folders that expand/collapse. E: settings window (reveal delay, hide delay, animation duration, icon size, magnification) applying live. F: hide the native Dock via the autohide-delay trick only (one mechanism, not two), save/restore exact prior values, launch at login via SMAppService, badges if feasible.

The user's native Dock settings to match and restore: bottom position, small size, magnification off, indicators on, recents off, auto-hide on, minimize effect Scale, minimize-into-app-icon on. Read exact values at runtime with `defaults read com.apple.dock`; don't hardcode.

## Process
- Fix the crash and bugs 2-8 first, then add timing instrumentation that logs mouseEntered, animation start, and panel-interactive timestamps.
- You can build and launch, but hover and click behavior needs a human. After Milestone A is working, stop and give me a short numbered hand-test script (move to the bottom edge, check reveal speed and logs, leave and re-enter during the hide delay, click an item while another app is frontmost). Wait for my results before Milestone B.
- Repeat that gate for each milestone: build, run, summarize what changed, give me the hand test, wait.
- Keep docs/CHECKLIST.md updated with status and findings per milestone.
- Note that the native Dock is set to auto-hide at the bottom, so until Milestone F both docks may react to the bottom edge. For testing, you may put the edge on the left or right temporarily.
- Be concise. I'm a front-end dev (React/TypeScript), new to Swift, so SwiftUI-to-React analogies help.
## Definition of done
Follow this at the end of every task, before reporting.
1. Update docs/CHECKLIST.md: mark finished items, add new findings or deferred items, and note known gaps honestly.
2. Update the short "Features" and "Planned" sections of README.md, and the matching detail in docs/FEATURES.md. Move an item from Planned to Features only when it is built and working. Keep wording short and match the existing style. Never list a feature that isn't in the code.
3. If you added a Swift file, add it to the project layout tree in docs/ARCHITECTURE.md with a one-line description, and tell me to `git add` it.
4. If dock.json gained new keys or the settings changed, update docs/DATA.md.
5. Final report, in this order: what changed, what I should hand test (a short numbered list), new untracked files, known gaps.
6. Never commit or push unless I ask. When I ask to commit, commit directly on main; no feature branch needed while the project is in its early stages.
