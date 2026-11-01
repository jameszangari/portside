# Features

Full feature list. The [README](../README.md) keeps a short summary.

## Reveal and hide

- Edge reveal driven by an `NSTrackingArea` on a thin edge window. No polling timers in the reveal/hide path.
- Non-activating panel: the first click works and the frontmost app keeps focus.
- Animated slide with a configurable duration, an instant option, and Reduce Motion support.
- Cancelable one-shot hide delay, canceled on re-entering the edge zone, the panel, or an open group grid.
- Dragging a file to the edge reveals the dock, and it stays up while the drag is over it. Hides with the normal delay after the drop or when the drag leaves.
- Timing logs for mouseEntered (or draggingEntered), animation start, and panel-interactive.
- Auto-hide toggle (menu bar item, separator right-click menu, Settings, or Cmd+Option+D). With hiding off, the dock stays revealed.
- Multi-display: an edge zone on every screen; the dock follows the display whose edge you hit. Works across Spaces and over fullscreen apps. Does not reveal while you are holding a mouse button (for example dragging a window); file drags to the edge still reveal.
- Notification badges, the same ones the macOS Dock shows, with no permission needed. They update while the dock is visible. Same size, placement, font and red as the native badge. Badge color is a setting (Appearance > Badges: macOS Red, Accent Color, system colors, or Custom from the Portside palette). Toggle in Settings. Group tiles show the sum of member badges.

## Apps

- Pinned apps with running indicators, updated from `NSWorkspace` notifications.
- Drag any tile to any slot: apps, groups, spacers, widgets, folders, and Trash can sit anywhere, in any order. Separators are items too: right-click one for Add Separator, Move Separator, Remove Separator, and Reset Layout. Trash can move but not be dragged out.
- Drag to reorder. Drag an .app from Finder onto the strip to pin it (a tile-sized insertion gap opens at the drop slot, same as folders).
- Drag an icon out of the dock to remove it, like the native Dock: the icon floats under the cursor for the whole drag (strip leaves a gap), a "Remove" label shows once it is clearly outside, and releasing it there removes it with a short poof (instant under Reduce Motion). Dragging back over the dock reorders as usual, and Escape puts it back. Works for app tiles, group tiles, and widgets (a group with apps in it asks first, see Groups); an app dragged out of an open group grid asks Remove from Group or Remove from Dock.
- Drop files on an app tile to open them in that app, like the native Dock. Only tiles whose app can open the files highlight and accept the drop (Finder takes folders). A not-running pinned app launches with the bounce.
- Running apps that are not pinned show after the pinned section.
- Activity icons on a running app's top-left corner: a green camera or orange microphone (the macOS privacy dot colors), an animated sound wave while it plays audio, or pulsing dots while it is Working (busy CPU in the app or its child processes, on by default for T3 Code, Claude, Codex; per app via Show Working Icon in the right-click menu). One icon at a time in that order; group tiles show their strongest member. Each kind toggles in General > Activity Icons. Animations pause while the dock is hidden and stay still under Reduce Motion.
- Native Dock options (General > Dock): Show indicators for open applications, Show suggested and recent apps (up to 3 recently quit apps after the running apps), Make hidden apps translucent (Cmd-H fades the icon).
- Right-click menu: Keep in Dock or Remove from Dock, Add to Group, Open at Login (checkbox), Show in Finder, then for running apps Hide (Show if hidden) and Quit. Hold Option and Quit becomes Force Quit. Open at Login for other apps uses System Events (may ask for Automation once); Portside's own tile uses the same SMAppService path as Settings.
- App tiles, group tiles, Portside's own tile and group cells: short click opens (or toggles the group); hold for 0.5s opens its menu (simultaneous with the tap, not exclusive); moving first starts a drag. Hover labels track the magnified icon's spring frames so they stay centered.
- Dock menus take the keyboard while open (Escape closes them, arrows move through them) without taking focus from the frontmost app.
- Separator right-click menu: Turn Hiding On/Off, Turn Magnification On/Off, Position on Screen (Left, Bottom, Right, checkmark on the current one), Add Spacer (Regular / Small), Dock Settings, Quit Portside.
- Spacers: empty gaps between pinned apps (like native Dock spacer tiles). Reorder by drag; drag out or Remove Spacer to delete. Imported from the macOS Dock on first launch and via Import.
- The app menu opens above the icon (beside it on the side docks), like the native Dock.
- Native Dock modifier clicks on app tiles and group grid cells: Cmd-click reveals the app in Finder (no launch), Option-click switches to the app and hides the one that was frontmost, Cmd+Option-click switches and hides all other apps. Portside itself is never hidden.
- Native-style launch bounce for pinned apps on any edge (sideways on the side docks) and for apps opened from a group grid (optional, off under Reduce Motion).
- Hover labels in a reusable non-activating overlay panel, styled as a speech bubble with a tail pointing at the icon, like the native Dock, using the dock's own background (style, frost and tint).
- "Add App to Dock..." from the menu bar item.

## Layout

- Bottom, Left, or Right position, switchable live.
- Drag the separator to resize icons live (clamped to what fits, persisted).
- Icon gap (0 to 8pt, default 6) between tiles, live in Settings; same gap on side docks. At 0, every item keeps the app-icon minimum spacing; separator air tracks the gap (5pt plus the gap per side).
- Magnification on every position: app and group tiles grow under the cursor with a smooth falloff to their neighbors, away from the screen edge (up on the bottom, sideways on the sides), past a shelf that keeps its thickness while it lengthens. Near the ends of a long dock the shelf stays on screen. Widgets and separators keep their size. Magnified size 16 to 128pt, set live in Settings. Hold Control-Shift over the dock to flip it for a moment. Labels, right-click and press-and-hold follow the magnified icon, and a launch bounce plays at the magnified size. Off during drags and while a group grid or menu is up. Under Reduce Motion the size follows the cursor without the spring.

## Widgets

- Clock, Battery, Calendar, Weather, System Stats, plus optional CPU and Memory tiles.
- Calendar connects from the signed app, explains failed requests, and opens Calendar privacy settings when access is denied. Permission changes are checked on click and refresh.
- Enable, disable, and reorder in Settings, or toggle from the menu bar item.
- Every widget has a square (Small) design: an analog clock face, a Calendar-icon date with a dot for the next event, text-free concentric CPU (outer, blue) and memory (inner, purple) rings, and the existing Weather and Battery tiles. Side docks always use Small, so the column stays one tile wide.
- Hover labels show live readings: CPU / memory percentages, battery and charging state, weather temperature and location, clock date/time, and Calendar date/event or access status. Labels refresh with widget data. Click actions are unchanged.
- CPU, Memory and Battery show one large number without a tiny label or percent sign, sized to keep a clear gap from the ring (shared `RingGauge`). At 100 the number becomes a "full" symbol (full battery, filled CPU or memory chip); 99 and below show two digits. Charging shows as a small bolt in the tile's corner, outside the ring. Below 28pt they switch to an SF Symbol in the ring (Battery picks a level or bolt glyph from charge state). Hover for the named percentage. System Stats keeps concentric rings; Wide adds color-matched numbers with neutral CPU / RAM labels. CPU and Memory start disabled and open Activity Monitor.
- Widget text uses system typography scaled from a 32pt tile reference, so the same size ratio holds across the icon-size range. At small dock sizes, Clock Wide shows just the time and Calendar shows the date with a status symbol and a red bar matching the date text width; secondary details stay in hover labels. Weather keeps its symbol and temperature.
- On the bottom dock, Clock, Calendar and System Stats can be Small or Wide. Pick with the iOS-style size row in the widget's right-click menu (with Remove Widget and Edit Widgets...) or in Settings > Widgets.

## Groups

- User-defined groups of apps shown as one tile that opens a grid.
- Custom group icon: pick any SF Symbol (searchable by name and keyword, about 7,200 symbols) and a color from the shared palette editor (Symbol and Color tabs with a live preview) to replace the mini app grid on the tile. The picker shows under the name field when a group is created or renamed, from the tile menu (Change Icon...), and from Settings > Groups (click the group's icon, which shows a pencil on hover, or the Change Icon... button next to Ungroup and Delete). "Remove Icon" goes back to the app grid. Style per icon: System follows the macOS icon style (Default, Dark, Clear, Tinted) so it sits with the app icons; Light or Dark pins that one icon. A pencil beside the open grid's title jumps to the name and icon editor.
- Inline naming on creation; rename from the open grid title (click it), the tile menu, or Settings. Ungroup and remove-from-group from context menus.
- Removing a group that has apps ("Remove from Dock", or dragging its tile out) asks first: Ungroup Instead (default, apps return as normal tiles), Remove Group, or Cancel. Empty groups go without asking. The alert gives focus back to the previous app.
- Optional open on hover, with configurable open delay and close grace.
- Dragging a file or app over a group tile opens its grid immediately. Drop an app from Finder, or drag a dock app (pinned or unpinned running) onto the tile or into the grid to add it (a dashed tile-sized gap follows the cursor so you choose the slot). Drop a file on a member that can open it (it highlights) to open it there. The grid closes when the drag leaves both the tile and the grid.
- Resting a file drag on a running app tile for about 600ms brings that app forward (native spring-load).
- Drag a member inside the open grid to reorder it. Dragging a member out asks Remove from Group (stays on the dock next to the group) or Remove from Dock, or Cancel.

## Appearance

- Icons match the macOS icon style (Default, Dark, Clear, Tinted) like the native Dock, and refresh when you change it in System Settings. Or pick "Original" to show each app's own artwork.
- One color picker for every color (background, tints, badges, group icons): preview and hex field, swatches in labeled Brand, Neutrals, macOS and RGB sections, Hue, Saturation, Tint, Shade, and Opacity where it applies, plus Reset Adjustments.
- Dock background, three distinct styles that each keep their own settings, plus corner radius. Open group grids and hover labels use the same look.
  - Liquid Glass (default): the system glass with Strength and an optional tint color. Regular is the frosted system glass; Clear is see-through with refraction at the edges (falls back to the public clear glass if the private variant goes away).
  - Frosted: a blur material (Ultra Thin to Ultra Thick) with Strength, a tint with its own opacity, and an optional border.
  - Solid: a color, linear gradient (with angle), or radial gradient; every color has its own opacity, plus overall Opacity and an optional border.
  - Reset applies to the current style only.
  - Text and dots on the dock follow the background, not just dark mode: a light solid color or tint gets black hover-label text, running dots, and grid labels; a dark one gets white.
  - Colors come from Portside's own palette instead of the macOS color panel: 20 preset swatches plus Saturation, Tint, Shade and Opacity sliders, inline in Settings. Gradients edit one stop at a time (click its chip). The custom badge color uses the same palette. Widgets keep their own frosted card whatever the Frost setting. Accessibility Reduce Transparency turns glass into opaque frosted live; Reduce Motion is respected for slides, springs, and the poof.

## Folder stacks

- Filesystem folders pin in the right section by default (after widgets and a separator, before Trash; drag to put it anywhere), separate from app groups. Drag a folder from Finder onto the dock to add one (an insertion gap opens at the drop slot, like the native Dock); reorder among stacks; drag out or Remove from Dock to unpin.
- Tile shows a mini grid of the folder's contents (the folder's own icon, with no card, when empty or with Display as Folder). Click opens the stack as a Grid, Fan, or List; click an item to open it. Fan curves up from the tile with a name beside each icon (first 10, then "N more in Finder"). Menu: Open, Show in Finder, View as, Sort by, Folders First, Show Hidden Files, Display as Folder, Remove from Dock. The open stack's ... button pops the same AppKit menu (first click on Folders First and the other checkboxes fires). Settings are per stack.
- Sort by Custom Order (default: name, plus the slots you drop items into), Name, Date Added, Date Modified (newest first), or Kind. Drops choose a slot only in Custom Order with Grid or List; otherwise the item just lands in the folder.
- Drop files or apps onto a stack (or into its open grid) to move them into the folder (copy if move fails). Dragging over a stack tile opens its grid immediately. In the open grid, an insertion gap follows the cursor so you choose the slot; order is kept in dock.json. Contents update via FSEvents (no polling).
- Native Dock folder tiles from `persistent-others` import on first launch and via Import from macOS Dock, with their view (fan, grid, list), sort (name, date added, date modified, kind), and Display as Folder choice. Plain file tiles are still skipped.

## Trash

- Trash stays at the far end on Bottom, Left, and Right, with native empty/full icons, magnification, and a hover label. "Show Trash in dock" (General > Dock) applies live and defaults on.
- Click opens Finder's Trash. Right-click or hold for Open and Empty Trash. Emptying asks for confirmation in Finder; empty or unreadable Trash disables the command.
- Drop files and folders from Finder to move them to the Trash. Dragging a dock tile onto Trash asks first: Remove from Dock, Move to Trash (apps and folder stacks), or Cancel. State updates use directory events, with no polling.
- Empty/full icon: prefers listing `~/.Trash` (Full Disk Access). If that is denied, uses Finder's trash count when Automation is already allowed. FSEvents watches the Trash folder (works without Full Disk Access). If neither read path works, the icon stays empty and a dismissible Settings hint links to Full Disk Access. Drops optimistically flip to full; Empty Trash flips to empty, then the watcher confirms.
- Empty Trash needs Automation permission for Finder. Denial and file-operation failures appear inline in Settings and in the Trash hover label. Under `swift run`, macOS may attribute permissions to the launching terminal; use the built app for permission testing.

## Settings window

- System Settings-style layout: a sidebar with General, Appearance, Widgets, Groups, and System panes, and the selected pane on the right. Changes apply live.
- Fixed 760 x 560 window (wide and short); long panes scroll instead of growing the window. Always opens centered on the primary display (same spot every time).
- While Settings is focused and auto-hide is on, the dock stays revealed for live preview; the toggle stays On. Leaving Settings (or closing it) restores normal auto-hide.
- Sidebar shows the Portside icon and version (`v0.2.0`; hover for author and build hash) and a Check for Updates button.
- Drag widget rows to reorder them.
- Global hotkey to open Settings (General > Keyboard), default ⌘⇧D, customizable, clearable. Menu bar Settings… still uses ⌘,.

## Native Dock

- "Hide the macOS Dock" (Settings > System): keeps the native Dock from ever appearing while Portside runs, using the autohide-delay trick. Its exact prior settings are saved first and restored when you turn this off, quit, or stop Portside with Ctrl+C or `kill`. After a crash or `kill -9`, the next launch restores them first.
- First launch (no `dock.json`): pinned apps, folder stacks, position, and icon size are taken from the native Dock (Finder first). If a Hide-the-Dock backup exists, position and size come from it instead of the live values.
- "Import from macOS Dock..." (Settings > System > Import): a confirmation sheet shows what was found. Add missing apps (appended, nothing reordered) or replace the apps (groups and widgets stay; stacks merge or replace with apps), and optionally take the native position and icon size. Apps no longer on disk, spacers, and non-folder other tiles are skipped; folder stacks from `persistent-others` import. Your dock is copied to `dock.json.before-import` first, and "Undo last import" restores it. Read only: nothing in `com.apple.dock` is written.
- "Restore macOS Dock" in the menu bar item, and `portside --restore-dock` (restores from the backup and exits, no UI).

## Branding

- Liquid Glass app icon compiled from the Icon Composer document (`design/brand/icon-composer/AppIcon.icon`). It follows the system icon style (light, dark, tinted) in Finder and the native Dock, and Portside's own dock tile, Settings header, alerts, and About panel use the same system-rendered icon, so it matches the size and look of every other app. Under `swift run` the icon is borrowed from a built `Portside.app` when one exists.
- Menu bar item uses the sail mark as a template image, so it follows light, dark, and tinted menu bars.
- "About Portside" in the menu bar item: the standard About panel with the version, author, and repo link.

## App bundle and startup

- `scripts/build-app.sh` builds a signed `build/Portside.app` with the brand icon, version from `VERSION`, and the Calendar / Finder / System Events Automation usage strings. `--install` copies it to `~/Applications`.
- App builds reuse a local code signing certificate after one-time setup, keeping the signing identity stable across rebuilds for macOS permission matching. Setup preserves the saved certificate fingerprint even when another certificate has the same name.
- "Open Portside at login" (Settings > System > Startup) through `SMAppService`. macOS is the source of truth; the toggle shows its real status, links to Login Items when approval is needed, and is disabled under `swift run`.
- "Open Settings when Portside launches" (Settings > System > Startup, `openSettingsOnLaunch`, off by default).
