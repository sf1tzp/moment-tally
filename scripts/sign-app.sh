#!/usr/bin/env bash
# Distribution signing (#44, #46, #115): hardened runtime + secure timestamp,
# App Sandbox entitlements on the outer app. (The MAS variant signs through
# scripts/package-mas.sh instead — different certs, no hardened runtime.)
#
# codesign without --deep signs only the outer bundle, so Sparkle's nested
# executables are signed explicitly first, inside-out (Apple's recommended
# order; --deep would also strip Downloader.xpc's sandbox entitlements).
#
# Usage: sign-app.sh <app-bundle> <identity>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
IDENTITY="$2"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }

# The app's claim of what it may do (#115, #121) — embedding it in the
# signature is what turns it on; there is no build-time step. Always work on
# a copy: the iCloud handling below edits it.
APP_ENTITLEMENTS="$(mktemp -t app-entitlements).plist"
HELPER_ENTITLEMENTS="$(mktemp -t dev-helper-entitlements).plist"
trap 'rm -f "$APP_ENTITLEMENTS" "$HELPER_ENTITLEMENTS"' EXIT
cp "$ROOT/scripts/MomentTally.entitlements" "$APP_ENTITLEMENTS"

# iCloud (#121): restricted entitlements — an app carrying them launches
# only when the signature embeds a provisioning profile that grants them.
# With MT_PROVISIONING_PROFILE set (a profile including the iCloud
# container), embed it; without one, strip the iCloud keys so the build
# stays launchable — the app's runtime gate then simply doesn't offer
# iCloud sync.
#
# Developer ID signing defaults to the machine-conventional profile path
# (the BRAND_FONTS_DIR precedent: present on the publishing machine,
# gracefully absent on a mirror build). Only for Developer ID — a profile
# only launches apps signed by certificates it lists, so defaulting it for
# a dev identity would produce an app that signs cleanly and dies at
# launch; dev runs pass their development profile explicitly.
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
    MT_PROVISIONING_PROFILE="${MT_PROVISIONING_PROFILE:-$HOME/.sfi/provisioning/Moment_Tally_Developer_ID_Profile.provisionprofile}"
    [[ -f "$MT_PROVISIONING_PROFILE" ]] || MT_PROVISIONING_PROFILE=""
fi
if [[ -n "${MT_PROVISIONING_PROFILE:-}" ]]; then
    cp "$MT_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    # CloudKit maps the process to its App ID through the (also restricted)
    # application-identifier + team-identifier entitlements — Xcode injects
    # them from the profile; do the same here. Copying the profile's own
    # values keeps signature and profile agreeing by construction.
    PROFILE_PLIST="$(mktemp -t profile).plist"
    security cms -D -i "$MT_PROVISIONING_PROFILE" > "$PROFILE_PLIST"
    for KEY in com.apple.application-identifier com.apple.developer.team-identifier; do
        /usr/libexec/PlistBuddy -c "Add :$KEY string $(/usr/libexec/PlistBuddy \
            -c "Print :Entitlements:$KEY" "$PROFILE_PLIST")" "$APP_ENTITLEMENTS"
    done
    # The container environment is a claim, not an inference: without this
    # entitlement cloudd picks for itself, and it kept even a Developer ID
    # build in Development. Claim what the profile grants — Developer ID
    # profiles pin the string "Production"; development profiles allow both
    # (an array), and a dev-profile build is the Development case.
    CK_ENV="$(/usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.developer.icloud-container-environment" \
        "$PROFILE_PLIST" 2>/dev/null || true)"
    case "$CK_ENV" in *Array*) CK_ENV=Development ;; esac
    if [[ -n "$CK_ENV" ]]; then
        /usr/libexec/PlistBuddy \
            -c "Add :com.apple.developer.icloud-container-environment string $CK_ENV" \
            "$APP_ENTITLEMENTS"
    fi
    rm -f "$PROFILE_PLIST"
else
    echo "note: MT_PROVISIONING_PROFILE unset — signing without iCloud entitlements" >&2
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-services" \
        "$APP_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-container-identifiers" \
        "$APP_ENTITLEMENTS"
fi

# Hardened-runtime library validation only loads libraries from the same
# team, and the self-signed dev cert has no Team ID — so a dev-signed app
# would refuse to load the bundled Sparkle at launch. Disable validation for
# the dev identity only (the dev build stays sandboxed too); Developer ID
# (both signatures share the real team) stays strict.
EXEC_FLAGS=()
if [[ "$IDENTITY" != "Developer ID Application"* ]]; then
    /usr/libexec/PlistBuddy \
        -c "Add :com.apple.security.cs.disable-library-validation bool true" \
        "$APP_ENTITLEMENTS"
    # Sparkle's helper executables get only the validation exception — they
    # are not sandboxed themselves (the installer's whole job is to work
    # outside the app's sandbox).
    cat > "$HELPER_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
EOF
    EXEC_FLAGS=(--entitlements "$HELPER_ENTITLEMENTS")
fi

# Downloader.xpc ships with its own sandbox entitlements — preserve them.
# (Unused while the app holds network.client itself, but kept stock per
# Sparkle's signing guidance.)
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign ${EXEC_FLAGS[@]+"${EXEC_FLAGS[@]}"} "$SPARKLE/Versions/B/Autoupdate"
sign ${EXEC_FLAGS[@]+"${EXEC_FLAGS[@]}"} "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
# The bundled CLI (#80): nested code, signed before the outer bundle. It
# links everything statically — library validation stays strict. Deliberately
# *not* sandboxed: it is its own process (the app's sandbox never extends to
# it), has no bundle identity to hang a container on, and its job is plain
# filesystem access to the store from a terminal.
sign "$APP/Contents/Helpers/moment-tally"
sign --entitlements "$APP_ENTITLEMENTS" "$APP"

codesign --verify --strict --verbose=2 "$APP"
