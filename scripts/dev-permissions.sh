#!/bin/bash
# Development helper: see which Portside copy macOS will judge, then walk the
# privacy panes for it. macOS allows no script to grant these; you flip each
# switch yourself. Never edits the TCC database and never touches Full Disk
# Access grants.
#
# Usage: scripts/dev-permissions.sh [--status] [--reset]
#   (no flag)  print status, then open each pane, Return moves to the next
#   --status   print status only
#   --reset    clear Portside's own grants so the next launch can ask afresh
#              (for rows left stale by switching signatures), after a y/N
# APP=/path/to/Portside.app picks the copy; default is the first of
# ~/Applications/Portside.app, /Applications/Portside.app.
set -euo pipefail

bundle_id="com.james.portside"
pane="x-apple.systempreferences:com.apple.preference.security"
# Service (for tccutil), URL anchor, label. Full Disk Access is listed last
# and only opened: it is never reset.
panes=(
    "Accessibility|Privacy_Accessibility|Accessibility (window features, Menu Bar Items)"
    "ScreenCapture|Privacy_ScreenCapture|Screen & System Audio Recording (window previews, audio levels)"
    "Calendar|Privacy_Calendars|Calendars (Calendar widget)"
    "AppleEvents|Privacy_Automation|Automation (Trash, login items, Now Playing, agent tabs)"
    "|Privacy_AllFiles|Full Disk Access (optional, protected files such as the Trash)"
)

mode=walk
case "${1:-}" in
    "") ;;
    --status) mode=status ;;
    --reset) mode=reset ;;
    *) echo "Usage: scripts/dev-permissions.sh [--status] [--reset]" >&2; exit 2 ;;
esac

signer() {
    local details
    details="$(codesign -dvv "$1" 2>&1)" || { echo "unsigned or unreadable"; return; }
    if grep -q '^Signature=adhoc' <<<"$details"; then
        echo "ad hoc (grants are lost whenever the binary changes)"
    else
        grep -m1 '^Authority=' <<<"$details" | cut -d= -f2-
    fi
}

copies=()
for candidate in "$HOME/Applications/Portside.app" "/Applications/Portside.app"; do
    [ -d "$candidate" ] && copies+=("$candidate")
done
app="${APP:-${copies[0]:-}}"

echo "Copies of Portside (macOS keeps one grant per bundle ID, $bundle_id):"
if [ "${#copies[@]}" -eq 0 ]; then
    echo "  none installed. Build one: scripts/build-app.sh --install"
else
    for copy in "${copies[@]}"; do echo "  $copy: $(signer "$copy")"; done
fi
if [ -n "$app" ]; then
    echo "Using: $app"
    if [ "${#copies[@]}" -gt 1 ]; then
        echo "Warning: copies signed differently share one grant, so opening the other one leaves it stale. Use one copy while testing."
    fi
fi
echo "swift run: a bare executable is judged as the app that launched it, so grant your terminal, not Portside."

case "$mode" in
    status) exit 0 ;;
    reset)
        echo
        echo "This clears these macOS privacy grants for $bundle_id only:"
        for entry in "${panes[@]}"; do
            service="${entry%%|*}"
            [ -n "$service" ] && echo "  $service"
        done
        read -r -p "Quit Portside first. Clear them? [y/N] " answer
        [ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Nothing changed."; exit 0; }
        for entry in "${panes[@]}"; do
            service="${entry%%|*}"
            [ -n "$service" ] && /usr/bin/tccutil reset "$service" "$bundle_id"
        done
        echo "Cleared. Open Portside, then Settings > Integrations > Set Up Permissions."
        exit 0
        ;;
esac

echo
echo "Turn Portside on in each pane. Panes listing nothing fill in after the feature first asks."
for entry in "${panes[@]}"; do
    rest="${entry#*|}"
    anchor="${rest%%|*}"
    label="${rest#*|}"
    echo "-> $label"
    open "$pane?$anchor"
    read -r -p "   Return for next... "
done
echo "Done. Quit and reopen Portside so it reads the new grants."
