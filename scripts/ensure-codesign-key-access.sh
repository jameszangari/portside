#!/bin/bash
# Ensure the Portside local signing private key allows /usr/bin/codesign
# without a keychain password prompt. Safe to call on every build.
#
# Modern macOS needs both:
#   - ACL access for /usr/bin/codesign (-T at import time)
#   - partition_id including codesign: (this script)
#
# UX: native NSAlert (Okay / Not Now), then the system Touch ID / password
# sheet via LocalAuthentication. No custom panel, no password field, no sudo
# (sudo cannot unlock the login keychain).
#
# Usage: scripts/ensure-codesign-key-access.sh
# Exit 0 even when the partition could not be updated (codesign may still
# prompt with Always Allow); exit 1 only on unexpected script failure.
set -euo pipefail

name="Portside Local Development"
partitions="apple-tool:,apple:,codesign:"
root="$(cd "$(dirname "$0")/.." && pwd)"
keychain="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/')"
# Imported PKCS#12 keys often keep ACL description "identity" even when the
# certificate common name is Portside Local Development.
descriptions=("$name" "identity")

# True when every private key that already lists /usr/bin/codesign also has
# codesign: in its partition_id entry (or there is no such key yet).
key_partition_ok() {
    security dump-keychain -a "$keychain" 2>/dev/null | awk '
        BEGIN { keys = 0; ok = 0; in_key = 0; has_codesign_app = 0; part = "" }
        /^class: 0x00000010/ {
            if (in_key && has_codesign_app) {
                keys++
                if (part ~ /codesign:/) ok++
            }
            in_key = 1; has_codesign_app = 0; part = ""
            next
        }
        /^class:/ {
            if (in_key && has_codesign_app) {
                keys++
                if (part ~ /codesign:/) ok++
            }
            in_key = 0
            next
        }
        in_key && /\/usr\/bin\/codesign/ { has_codesign_app = 1 }
        in_key && /authorizations \(1\): partition_id/ { want_part = 1; next }
        want_part {
            if ($0 ~ /description:/) {
                sub(/^[^:]*:[[:space:]]*/, "", $0)
                part = $0
            }
            want_part = 0
        }
        END {
            if (in_key && has_codesign_app) {
                keys++
                if (part ~ /codesign:/) ok++
            }
            if (keys == 0) exit 0
            exit (ok == keys) ? 0 : 1
        }
    '
}

apply_partitions() {
    local desc status=1
    for desc in "${descriptions[@]}"; do
        if security set-key-partition-list -S "$partitions" -s -t private \
            -D "$desc" -k "" "$keychain" >/dev/null 2>&1; then
            status=0
        fi
    done
    return "$status"
}

can_show_gui() {
    [ "${PORTSIDE_SKIP_KEYCHAIN_PROMPT:-}" = 1 ] && return 1
    local console_user
    console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
    [ -n "$console_user" ] && [ "$console_user" = "$(id -un)" ]
}

resolve_icon() {
    local candidate
    for candidate in \
        "$HOME/Applications/Portside.app/Contents/Resources/AppIcon.icns" \
        "$root/build/Portside.app/Contents/Resources/AppIcon.icns" \
        "$root/design/approved-icon/png/portside-approved-original-256.png" \
        "$root/Sources/portside/Support/AppIcon-256.png"
    do
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

ask_okay_and_authenticate() {
    # Native alert + Touch ID / password. Exit 0 = continue, 1 = skip.
    can_show_gui || return 1
    local icon=""
    icon="$(resolve_icon || true)"
    local helper="$root/scripts/.cache/SigningConsent"
    if [ ! -x "$helper" ] || [ "$root/scripts/SigningConsent.swift" -nt "$helper" ]; then
        mkdir -p "$root/scripts/.cache"
        if ! swiftc -O -o "$helper" "$root/scripts/SigningConsent.swift" 2>/dev/null; then
            if [ -n "$icon" ]; then
                swift "$root/scripts/SigningConsent.swift" "$icon"
            else
                swift "$root/scripts/SigningConsent.swift"
            fi
            return $?
        fi
    fi
    if [ -n "$icon" ]; then
        "$helper" "$icon"
    else
        "$helper"
    fi
}

if key_partition_ok; then
    exit 0
fi

echo "==> Allowing codesign to use the Portside signing key without prompting"
apply_partitions || true
if key_partition_ok; then
    exit 0
fi

if ask_okay_and_authenticate; then
    apply_partitions || true
    if key_partition_ok; then
        echo "codesign can now use the Portside signing key without prompting."
        exit 0
    fi
    echo "Continuing. If macOS asks about key access, choose Always Allow."
    exit 0
fi

echo "ensure-codesign-key-access: skipped. If codesign asks, choose Always Allow." >&2
exit 0
