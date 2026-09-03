build:
  swift build

run:
  ./.build/debug/MomentTally

demo:
  ./.build/debug/MomentTally --demo

# --- iOS (#123) ---

# Regenerate ios/MomentTally.xcodeproj from ios/project.yml (the project is
# generated, never committed). Deps: brew install xcodegen; full Xcode.
# Exports the version pair project.yml substitutes into MARKETING_VERSION /
# CURRENT_PROJECT_VERSION, mirroring bundle-app.sh's derivation (VERSION env
# var overrides, as there). Regenerate after pulling before an archive, or
# the project keeps the stale numbers.
ios-project:
  #!/usr/bin/env bash
  set -euo pipefail
  MT_VERSION="${VERSION:-$(git describe --tags 2>/dev/null || echo 0.0.0)}"
  export MT_VERSION="${MT_VERSION#v}"
  export MT_BUILD="$(git rev-list --count HEAD)"
  xcodegen generate --spec ios/project.yml --project ios
  echo "Generated ios/MomentTally.xcodeproj ($MT_VERSION, build $MT_BUILD)"

# Build the iOS app for the simulator. Brand fonts inject from
# ~/.sfi/brand-assets/fonts when present (see ios/project.yml).
ios-build sim="iPhone 17 Pro": ios-project
  xcodebuild -project ios/MomentTally.xcodeproj -scheme MomentTallyIOS \
    -destination 'platform=iOS Simulator,name={{sim}}' \
    -derivedDataPath .build/ios-dd build

# Install + launch on a booted simulator (boot one with:
# `xcrun simctl boot "iPhone 17 Pro"` or from Simulator.app). Pass
# `--demo`-equivalent via: SIMCTL_CHILD_MOMENTTALLY_DEMO=1 just ios-run
ios-run: ios-build
  xcrun simctl install booted \
    ".build/ios-dd/Build/Products/Debug-iphonesimulator/Moment Tally.app"
  xcrun simctl launch booted com.streetfortress.MomentTally

# The core suite (MomentTallyCoreTests — everything free of the Mac
# executable) against an iOS simulator destination.
ios-test sim="iPhone 17 Pro": ios-project
  xcodebuild test -project ios/MomentTally.xcodeproj -scheme CoreTests \
    -destination 'platform=iOS Simulator,name={{sim}}' \
    -derivedDataPath .build/ios-dd

# Build for, install on, and launch a plugged-in iPhone/iPad (first match
# from `xcrun devicectl list devices`, or pass its identifier). One-time
# device prep: unlock + Trust This Computer, then enable Settings › Privacy
# & Security › Developer Mode. Automatic signing registers the device and
# re-mints the profile on first build (needs the Xcode Apple ID session —
# i.e. the mini, per the machine-roles split).
ios-device device="": ios-project
  #!/usr/bin/env bash
  set -euo pipefail
  id="{{device}}"
  if [[ -z "$id" ]]; then
    id=$(xcrun devicectl list devices 2>/dev/null | grep physical \
         | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)
    [[ -n "$id" ]] || { echo "error: no physical device attached" >&2; exit 1; }
  fi
  xcodebuild -project ios/MomentTally.xcodeproj -scheme MomentTallyIOS \
    -destination "platform=iOS,id=$id" -derivedDataPath .build/ios-dd \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
  xcrun devicectl device install app --device "$id" \
    ".build/ios-dd/Build/Products/Debug-iphoneos/Moment Tally.app"
  xcrun devicectl device process launch --device "$id" \
    com.streetfortress.MomentTally

# Release-archive the iOS app for App Store Connect. Safe to run anywhere
# signing certs exist (nothing uploads); the archive lands in .build/. The
# scheme's archive action builds Release (xcodegen's default).
ios-archive: ios-project
  xcodebuild archive -project ios/MomentTally.xcodeproj -scheme MomentTallyIOS \
    -destination 'generic/platform=iOS' -derivedDataPath .build/ios-dd \
    -archivePath .build/MomentTallyIOS.xcarchive -allowProvisioningUpdates

# Archive and upload to App Store Connect / TestFlight — the publish step,
# and the iOS counterpart of package-mas.sh (ios/ExportOptions.plist carries
# the store settings; destination=upload makes the export the upload). Needs
# the Xcode Apple ID session, i.e. the mini. Refuses to ship a between-tags
# build: ASC rejects describe-suffixed marketing versions anyway, so tag
# first (`just tag X.Y.Z`) — or VERSION=X.Y.Z to override, as in
# bundle-app.sh.
ios-upload:
  #!/usr/bin/env bash
  set -euo pipefail
  if [[ -z "${VERSION:-}" ]] && ! git describe --tags --exact-match >/dev/null 2>&1; then
    echo "error: HEAD isn't tagged — tag first (just tag X.Y.Z) or set VERSION=X.Y.Z" >&2
    exit 1
  fi
  just ios-archive
  xcodebuild -exportArchive -archivePath .build/MomentTallyIOS.xcarchive \
    -exportOptionsPlist ios/ExportOptions.plist -exportPath dist/ios \
    -allowProvisioningUpdates

# --- Release assets (capture pipeline) ---

# Process raw demo-mode captures (captures/raw/) into distributable
# renditions in captures/out/, per captures/shots.yaml. Scene driving is the
# /capture skill's job (macbook-air) — see captures/README.md.
# Deps: brew install yq jq ffmpeg webp
process-captures:
  scripts/process-captures.sh

# Copy processed renditions into their consumer repos — readme-images/ here,
# and a dated worktree of the website repo (created from origin/main; the
# primary ~/primetime-website checkout is never written to) — and stamp
# provenance manifests in both. Pass a directory to override the destination.
export-captures *flags:
  scripts/export-captures.sh {{flags}}

# --- Distribution (#44) ---

# Assemble dist/MomentTally.app from a release build (arm64-only).
bundle:
  scripts/bundle-app.sh

# Sign the bundle for distribution: hardened runtime + secure timestamp + App
# Sandbox entitlements (#115), with Sparkle's nested executables signed first
# (see scripts/sign-app.sh).
# Run `just sign-dist "TraggoMenuApp Dev"` for a local pipeline check without
# the Developer ID cert (spctl will reject it, codesign --verify still passes).
# NB the sandbox activates for dev-signed builds too: the first launch moves
# real app data into ~/Library/Containers/com.streetfortress.MomentTally (see
# scripts/container-migration.plist).
sign-dist identity="Developer ID Application: Steven Fitzpatrick (2GY54R95TD)": bundle
  scripts/sign-app.sh dist/MomentTally.app "{{identity}}"

# Submit the signed bundle for notarization and staple the ticket. The zip is
# only the submission vehicle; the distributable is repacked post-staple by
# `just release`. One-time setup: xcrun notarytool store-credentials momenttally-notary
notarize profile="momenttally-notary":
  ditto -c -k --keepParent dist/MomentTally.app dist/notarize-upload.zip
  xcrun notarytool submit dist/notarize-upload.zip --keychain-profile {{profile}} --wait
  xcrun stapler staple dist/MomentTally.app

# Gatekeeper's verdict on the bundle (passes only once signed with a Developer
# ID cert and notarized; the dev cert is expected to fail here).
assess:
  spctl --assess --type execute --verbose dist/MomentTally.app


# Tag HEAD for release and push the tag. Accepts "1.2.3" or "v1.2.3" — any
# leading v is stripped before re-adding, so "vv1.2.3" can't happen. The final
# tag must match release.sh's preflight regex (vX.Y.Z, no prerelease/build).
# Fetches first (pruning tags deleted on the remote) and refuses to tag unless
# HEAD is exactly origin/main, so a stale checkout can't ship a release.
tag version:
  #!/usr/bin/env bash
  set -euo pipefail
  v="{{version}}"
  v="${v#v}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || { echo "error: 'v$v' is not vX.Y.Z semver" >&2; exit 1; }
  git fetch origin --tags --prune --prune-tags
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
      || { echo "error: HEAD is not at origin/main — pull first" >&2; exit 1; }
  git tag "v$v" && git push origin "v$v"

# --- Release (#45) ---

# Full pipeline from an exact vX.Y.Z tag on HEAD: build → sign → notarize →
# staple → package dist/MomentTally-<version>.zip → appcast → GitHub release on
# the public mirror → cask bump on sf1tzp/homebrew-tap. Pass --no-publish to
# stop after the appcast.
release *flags:
  scripts/release.sh {{flags}}

# --- Mac App Store variant (#115) ---

# Assemble dist/mas/MomentTally.app: the store build — sandboxed like the
# direct one, but with no Sparkle (the store owns updates), no bundled CLI
# (that stays a cask concept), and the store-only Info.plist keys.
bundle-mas:
  VARIANT=mas scripts/bundle-app.sh

# Sign the MAS bundle and wrap it in the signed installer .pkg that App Store
# Connect ingests (upload via Transporter). Needs the store cert pair — our
# installer cert carries Apple's older "3rd Party Mac Developer Installer"
# name — and a Mac App Store provisioning profile, defaulted from
# ~/.sfi/provisioning (override with MAS_PROFILE=path/to/profile). App Review
# replaces notarization on this channel, so the pkg uploads as-is.
package-mas app_id="Apple Distribution" pkg_id="3rd Party Mac Developer Installer": bundle-mas
  scripts/package-mas.sh dist/mas/MomentTally.app "{{app_id}}" "{{pkg_id}}"

# --- Server distribution (#75) ---

# Server image + Helm chart off the same vX.Y.Z tag: docker/nerdctl build →
# helm package → push to GHCR (public) and the internal gitea registry (#48).
# Runs anywhere with docker-or-nerdctl + helm + gh — no Mac needed. The GHCR
# side normally rides CI (.github/workflows/release-server.yml, triggered by
# the mirrored tag); this is the by-hand fallback and the internal-registry
# path. Pass --no-publish to build without pushing, --no-internal to skip gitea.
release-server *flags:
  scripts/release-server.sh {{flags}}

# The whole release off the tag on HEAD: app (Mac-bound) then server image +
# chart. Mac-only — and it needs docker/nerdctl + helm there too; on Apple
# Silicon the image cross-builds to linux/amd64 (see release-server.sh).
# NB `just release release-server` does NOT do this: release's variadic
# {{flags}} would swallow "release-server" as an argument.
release-all: release release-server
