# Notch Shelf: deferred hand tests and known gaps

Every planned phase (SHELF-01 to SHELF-11) is built. The hand tests below were deferred on 2026-11-16 by the maintainer, to run in one pass later. Since SHELF-12 the shelf is the only Top Notch (still off by default); these should pass on macOS 27 and macOS 26 before a release. Per-phase detail and history stay in [CHECKLIST.md](CHECKLIST.md); this file is the single list to work from. Tick an item here and in CHECKLIST.md when it passes.

Run from a fresh build of the branch under test (`swift run portside`), with Settings > Top Notch on (since SHELF-12 the shelf is the Top Notch).

## Confirmed by hand so far

- Drag catcher: a Finder file dragged to the notch opens the shelf and never Mission Control (2026-11-15).
- SHELF-10 AirPods alert: connecting AirPods (3rd generation) shows the strip alert (2026-11-16, after the first-connection fix).
- SHELF-10b AirPods page: the tab shows while a pair is connected (2026-11-16).
- SHELF-11 hotkeys work (2026-11-16).

## Hand tests

### Core: hover, click, pin, pages

- [ ] **Hover and cards (SHELF-01, 04c).** With sessions running and music playing: hover each side of the notch (the card shows after about 0.15 s, switches when moving to the other side, closes within 0.2 s of leaving); hover the notch middle (the shelf opens on the first tab); a click on the strip or a card opens it; Reduce Motion on; VoiceOver reads the notch, tabs and selected tab.
- [ ] **Pin.** Open the shelf, click the pin (fills in the accent color), click in another app's window: the shelf stays. Click the pin again, click outside: it closes. Pinned, the close button and the toggle hotkey still close it.
- [ ] **Close paths.** Leaving closes after 0.8 s; a click outside closes at once; the close button closes; a click on the notch with the shelf open never closes or blinks it.
- [ ] **Pages (SHELF-03).** Switch tabs; close and reopen with Start on Last used (comes back); set Start on to a fixed page; turn a page off and reorder in Settings (the open shelf follows); turn Clipboard History off and on in Command Center (the tab hides and returns); heights change smoothly between pages.
- [ ] **Menu bar coordination (SHELF-02).** With Menu Bar hiding on: hover, scroll and click on and just beside the notch never reveal hidden items; the same gestures away from the notch still reveal; Settings > Menu Bar shows "In the Portside Bar" locked, and the saved choice returns when the shelf is off; click empty bar 20 times in a row with the Portside Bar (opens and closes every time; otherwise `log show --last 5m --predicate 'category == "menubar-probe"'` names the reason).
- [ ] **Classic island, shelf off.** Music with no agent running: art left, colored bars right; start an agent: loader and count come back.

### Settings (SHELF-12)

- [ ] Settings > Top Notch shows the switch, the preview and ten folded sections, with no Position, Style, Quick styles, Click action or Behavior; nothing appears or disappears except a setting's own details.
- [ ] Open each section: the preview follows (Strip and Displays and Hotkeys: the strip; Volume and brightness: the volume level; Music and Look and feel: the music card; Alerts: an AirPods alert; Shelf: the Widgets page; Agents: the Agents page; Files: the Files page with sample files). Close it: back to the strip. Change Width, Height, Corner radius, Accent, Music style: the preview follows at once.
- [ ] The preview takes no clicks and the real shelf's Files and Clipboard are unchanged after browsing Settings.
- [ ] Reset Top Notch Settings asks first; Cancel changes nothing.
- [ ] With an old `dock.json` (shelf off, Position left): the shelf shows wrapping the notch, and the retired keys are gone from `dock.json` after the next settings change.

### Music and widgets (SHELF-04, 04c)

- [ ] Hover the art or the bars: the music card shows; previous, play/pause, next and seeking work; also with a non-Spotify player (Music, a browser video).
- [ ] Pause with Hide when paused on: the strip goes back to agents or empty, and hovering then opens the shelf.
- [ ] Skip a track: the banner shows the song for 3 s; hovering it shows the music card.
- [ ] Widgets page: music, weather and calendar cards; Join on a meeting; change each slot in Settings; Vinyl style and album tint.

### Agents (SHELF-05)

- [ ] Duplicates: run a T3 thread in a project's own folder (no worktree) and one in a worktree: each shows once on the Agents page, labeled with T3's name ("T3 Code (Beta)" in the beta).
- [ ] With Claude and Codex sessions: chips show counts and filter; a finished session leaves after 5 minutes (try 1 minute in Settings), Never keeps it; usage rows match the Widgets tile.

### Clipboard (SHELF-06, 11)

- [ ] With Clipboard History on: newest first; click one and paste elsewhere; drag one into a text field; delete one on hover; pause history in Settings and Resume from the page.
- [ ] Clear: click Clear, then Cancel (nothing changes); Clear, then Clear History (Nothing copied yet; Command Center's `clip` search is empty too).
- [ ] Search from the tab: click Search above the cards, type (cards filter over the whole history), the field's close button (back to the six newest, no blink; the shelf stays open); Return copies the first match and closes the shelf.
- [ ] Search clipboard hotkey in TextEdit: type a word (cards filter), Return (the shelf closes, TextEdit stays frontmost, paste gives the match); again, then Escape (closes, typing goes back to TextEdit).

### Files and drag catcher (SHELF-06b)

- [ ] Drag a Finder file onto the compact notch: the shelf opens on Files and the file shows; drag it out to the Desktop (a copy appears, the original stays).
- [ ] Turn on Remove after dragging out and repeat (the tile leaves); drop a seventh file (the oldest leaves).
- [ ] Click a tile (opens); right click each menu item (Open, Show in Finder, Copy, AirDrop, Remove from Shelf).
- [ ] Drop a file on the AirDrop card, and click the card with files on the shelf (the AirDrop picker appears).
- [ ] Delete a file in Finder and reopen the page (its tile is gone); set Keep files for 1 hour and relaunch (files stay until then).
- [ ] Drag a file over the notch and away without dropping (the shelf closes); turn the Files tab off (drops are refused).

### Alerts (SHELF-07, 10)

- [ ] A calendar event 5 minutes out shows the countdown and Join; reorder the strip so Music beats Meeting.
- [ ] Meeting timer: once a meeting of up to 3 hours starts, the strip counts up each second and the card shows the span and minutes left; at its end it leaves; an event over 3 hours (or with no end) leaves a minute after it starts.
- [ ] Plug in the charger (Charging alert); with Low battery at 30% on battery near it, the red alert shows.
- [ ] An agent finishing while music plays shows Finished on the right for 4 s.
- [ ] AirPods: hover the alert (Left, Right, Case bars match Control Center's Bluetooth menu); take a bud out and wait for the 5-minute read (no alert unless it crosses the low mark); disconnect (nothing shows); Beats or AirPods Max if at hand (one Battery bar).
- [ ] Live AirPods levels: turn it on (macOS asks for Bluetooth access; allow); take a bud out or put one back: the AirPods tab and alert levels update within a few seconds instead of up to 5 minutes; deny access in System Settings and reopen Settings (the note shows); turn it off (no Bluetooth scanning).
- [ ] AirPods page: disconnect (the tab goes; an open shelf on it moves to the first tab); reconnect (back within a few seconds); take a bud out, open the tab (its level updates); turn the page off in Settings (never shows).
- [ ] Turn each alert off in Settings: it no longer shows.

### Volume and brightness (SHELF-09, 09b)

- [ ] Volume up, down and mute: symbol and bar track each press, gone 1.5 s after the last; a change from Control Center or an app's slider shows too; switching output to headphones shows no HUD for the switch, then their level.
- [ ] Brightness up and down shows; automatic brightness under changing light for a minute never shows; closing the lid with an external display shows no brightness HUD and nothing breaks.
- [ ] Replace the macOS indicator on: only the notch shows, with the number; holding a key repeats; Option and Shift give quarter steps; mute then volume up unmutes; an HDMI output with no volume control still works through macOS; with Accessibility off, macOS shows its own and Settings offers Allow Accessibility; restricted mode turns it off.

### Hotkeys (SHELF-11)

- [ ] Open or close twice (opens on the start page, then closes); Open on Files with the pointer away (stays, closes after 30 s); hover it before the time runs out (stays, then closes 0.8 s after leaving).
- [ ] Pick a chord macOS uses (Cmd-Space): the warning shows; turn the shelf off: the hotkeys do nothing.

### Displays and full screen (SHELF-08)

Matrix on macOS 26 and 27, built-in notched display plus one external.

- [ ] For each of Notched display, Display you're using, Primary, All: the shelf appears where expected; switching apps between displays moves it with Display you're using.
- [ ] Full-screen an app with Show in full screen off (the shelf is gone) and on (it stays, hover opens it).
- [ ] Unplug the external display: the shelf rebuilds on the remaining one.
- [ ] External display without a notch: the capsule sits in the menu bar, shrinks when idle, grows when music plays; hover and click work.
- [ ] Menu Bar hiding still never reveals on the notch; Escape and a click outside close the shelf on every display.

## Known gaps

### Worth building

- Return in clipboard search copies only the first match; no arrow keys or Tab inside the shelf (Bartender has none either). Without a search the Clipboard tab shows only the six newest.
- Not kept across relaunch: the Agents chip choice and the Last used page.
- With Displays > All, a hotkey opens only the shelf on the pointer's display.
- Alert duration is fixed at 4 s.
- Collapse grace is 0.8 s; the research measured about 0.85 s in Bartender.

### Accepted limits

- After a search ends with the shelf still open (the field's close button, another tab), the shelf keeps the keyboard until it closes, so typing goes nowhere until then; handing it back sooner would blink the shelf.
- Escape only closes the shelf while Portside is the active app (as in Bartender); the shelf never takes the keyboard except during clipboard search. Use the close button or the toggle hotkey.
- Files are references: a file moved or renamed leaves the shelf. Only one file drags out at a time. The AirDrop picker brings Portside forward.
- During a file drag the pointer cannot enter the menu bar, so files cannot be dropped on menu bar items (Dropover, Yoink) or the notch's own header. A drag started from Portside itself is not caught.
- Display you're using follows app focus, not the pointer alone; a window spanning displays counts by its center.
- Weather alerts depend on the 15-minute weather refresh. Meeting alerts need Calendar access, granted from the Widgets Calendar card.
- Live AirPods levels pick the connected model's advert by model and signal strength, so a stranger's identical AirPods within a few meters can trigger an extra read (harmless: the read itself comes from this Mac's connection). Bluetooth LE scanning while a pair is connected costs some power.
- AirPods: a pair connected but not used for audio is noticed only on the next Bluetooth audio device change; AirPods charging in the case are not shown (the case reports only while a bud is out, and AirPods 3 omitted it with both buds in); Beats map to a generic headphones symbol.
- Volume and brightness: no feedback sound on volume change; keyboard backlight and external display brightness are left to macOS and not shown; outputs without a volume control (some HDMI) show nothing; the brightness filter is unverified against a real key press. Play, pause and skip keys are untouched.
- Album tint and Vinyl are SwiftUI, not Bartender's Metal effects; seeking in Spotify and Music relies on AppleScript and its next notification; the song banner shows on every display the shelf uses.
- The copied texts are visible to anyone looking at the open shelf.
