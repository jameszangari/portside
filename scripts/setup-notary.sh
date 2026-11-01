#!/bin/bash
# Stores Apple notarytool credentials in the login keychain (one-time).
# Usage: scripts/setup-notary.sh
#
# Needs:
#   - An Apple Developer Program membership
#   - An app-specific password from https://appleid.apple.com
#     (Sign-In and Security > App-Specific Passwords), labeled e.g. Portside Notary
#
# Profile name defaults to "portside-notary" (override with NOTARY_PROFILE).
# Team ID defaults to WNZ8H4UHQE (override with NOTARY_TEAM_ID).
# After this, scripts/build-app.sh --notarize can submit without prompts.
set -euo pipefail

profile="${NOTARY_PROFILE:-portside-notary}"
team_id="${NOTARY_TEAM_ID:-WNZ8H4UHQE}"

if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    echo "Notary profile '$profile' is already stored and working."
    exit 0
fi

echo "Storing notarytool profile '$profile' for team $team_id."
echo "Enter your Apple ID email, then an app-specific password (not your Apple ID password)."
echo "Create one at appleid.apple.com > Sign-In and Security > App-Specific Passwords."
echo

if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_APP_PASSWORD:-}" ]; then
    xcrun notarytool store-credentials "$profile" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$team_id" \
        --password "$NOTARY_APP_PASSWORD"
else
    xcrun notarytool store-credentials "$profile" --team-id "$team_id"
fi

echo
echo "Verifying..."
xcrun notarytool history --keychain-profile "$profile" >/dev/null
echo "Notary profile '$profile' ready."
