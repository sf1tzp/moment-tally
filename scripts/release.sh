#!/usr/bin/env bash
# Release pipeline (#45): tag → build → bundle → sign → notarize → staple →
# package → publish. Run via `just release`; every step is also runnable on
# its own (see the justfile), so the pipeline stays debuggable by hand even
# once CI wraps it.
#
#   preflight  clean tree, HEAD at an exact vX.Y.Z tag, tools present
#   sign-dist  release build + .app assembly + Developer ID signing
#   notarize   notarytool submit, wait, staple the ticket
#   assess     Gatekeeper's verdict on the stapled bundle
#   package    dist/MomentTally-<version>.zip of the stapled bundle
#              (zip over DMG — Sparkle appcasts consume zips directly)
#   appcast    EdDSA-sign the zip and generate dist/appcast/appcast.xml (#46);
#              the app's SUFeedURL is the mirror's stable
#              releases/latest/download/appcast.xml redirect, so publishing
#              the appcast as a release asset *is* the feed update
#   publish    GitHub release on the public mirror: artifact, appcast, notes
#   cask bump  point sf1tzp/homebrew-tap's moment-tally cask at the new release
#
# Versioning: semver git tags (vX.Y.Z) are the source of truth. bundle-app.sh
# stamps the tag into CFBundleShortVersionString and the commit count into
# CFBundleVersion; the Help tab renders both.
#
# The server image + Helm chart ship separately off the same tag via
# scripts/release-server.sh (`just release-server`; #75) — same versioning,
# independent execution (that side needs docker/helm, not a Mac).
#
# The Mac App Store variant (#115) ships through its own, shorter path:
# `just package-mas` (scripts/package-mas.sh) builds the Sparkle-free,
# CLI-free bundle and the signed .pkg, uploaded via Transporter. App Review
# replaces the notarize/staple/assess steps on that channel, and the
# appcast/cask publishing here plays no part. Both channels are sandboxed
# with the same containment (scripts/MomentTally*.entitlements).
#
# Secrets stay in the login keychain — the "Developer ID Application"
# identity and the notarytool profile ("momenttally-notary"; one-time setup:
# xcrun notarytool store-credentials momenttally-notary). Publishing needs the
# gh CLI authenticated against github.com (brew install gh && gh auth login).
#
# Usage:
#   git tag v1.2.0 && git push origin v1.2.0
#   just release                # full pipeline
#   just release --no-publish   # everything except the GitHub release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="sf1tzp/moment-tally"

PUBLISH=1
for arg in "$@"; do
    case "$arg" in
        --no-publish) PUBLISH=0 ;;
        *) echo "unknown flag: $arg (supported: --no-publish)" >&2; exit 2 ;;
    esac
done

# --- preflight ---------------------------------------------------------------
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || { echo "preflight: working tree is dirty — commit or stash first" >&2; exit 1; }

TAG="$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null)" \
    || { echo "preflight: HEAD carries no tag — release from an exact vX.Y.Z tag" >&2; exit 1; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "preflight: tag '$TAG' is not semver (vX.Y.Z)" >&2; exit 1; }
VERSION="${TAG#v}"

for tool in just xcrun ditto; do
    command -v "$tool" >/dev/null \
        || { echo "preflight: '$tool' not found" >&2; exit 1; }
done
if (( PUBLISH )); then
    command -v gh >/dev/null \
        || { echo "preflight: publishing needs the gh CLI (brew install gh && gh auth login);" \
                  "or run with --no-publish" >&2; exit 1; }
fi

# Advisory only: releases ship regardless, but stale marketing captures are
# easy to forget — flag when UI sources moved since the last capture batch
# (captures/manifest.json, stamped by export-captures.sh).
CAP_MANIFEST="$ROOT/captures/manifest.json"
if command -v jq >/dev/null && [[ -f "$CAP_MANIFEST" ]]; then
    CAP_COMMIT="$(jq -r '.commit // empty' "$CAP_MANIFEST")"
    if [[ -n "$CAP_COMMIT" ]] && git -C "$ROOT" cat-file -e "$CAP_COMMIT^{commit}" 2>/dev/null; then
        CHANGED="$(git -C "$ROOT" diff --name-only "$CAP_COMMIT"..HEAD -- \
                       Sources/MomentTally Sources/MomentTallyCore | wc -l | tr -d ' ')"
        if [[ "$CHANGED" != 0 ]]; then
            echo "note: $CHANGED UI source files changed since the last capture batch" \
                 "($(jq -r .describe "$CAP_MANIFEST"), $(jq -r .captured "$CAP_MANIFEST"))" \
                 "— consider refreshing release assets (captures/README.md)"
        fi
    else
        echo "note: captures/manifest.json has no resolvable commit — capture provenance unknown"
    fi
fi

echo "==> releasing $TAG"

# --- build → sign → notarize → staple → assess -------------------------------
just --justfile "$ROOT/justfile" sign-dist
just --justfile "$ROOT/justfile" notarize
just --justfile "$ROOT/justfile" assess

# --- package ------------------------------------------------------------------
# --norsrc: the bundle's files carry com.apple.provenance xattrs, which ditto
# would otherwise store as AppleDouble (._*) sidecar entries. Archive Utility —
# how testers double-click the zip — extracts those as real files, and the ones
# landing in Sparkle.framework's root break the code seal ("unsealed contents
# present in the root directory of an embedded framework"), so Gatekeeper
# rejects the quarantined app with the could-not-verify-malware dialog (#112).
ARTIFACT="$ROOT/dist/MomentTally-$VERSION.zip"
ditto -c -k --norsrc --keepParent "$ROOT/dist/MomentTally.app" "$ARTIFACT"
echo "==> packaged $ARTIFACT"

# --- release notes -------------------------------------------------------------
# Commit subjects since the previous tag, with a hand-written intro spliced in
# from releases/<version>.md when one is committed (write it before tagging —
# `just tag` prompts when it's missing). Trailing "(#N)" issue/PR refs are
# stripped from the subjects: they point at gitea, but on the GitHub release
# they'd autolink to the mirror's unrelated numbering.
NOTES="$ROOT/dist/RELEASE_NOTES.md"
PREV="$(git -C "$ROOT" describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
INTRO="$ROOT/releases/$VERSION.md"
{
    echo "## Moment Tally $VERSION"
    echo
    if [[ -s "$INTRO" ]]; then
        cat "$INTRO"
        echo
    fi
    git -C "$ROOT" log --format='- %s' "${PREV:+$PREV..}$TAG" \
        | sed -E 's/( \(#[0-9]+\))+$//'
} > "$NOTES"

# --- appcast (#46) -------------------------------------------------------------
# A staging dir with only this release's zip: generate_appcast signs every
# archive it finds, and dist/ also holds the unsigned notarize-upload.zip.
# One entry per appcast is enough — the feed URL always points at the latest
# release's copy, and Sparkle only ever offers the newest version anyway.
# The EdDSA private key comes from the login keychain (generate_keys; #45's
# secrets decision), the tools from scripts/sparkle-tools.sh.
SPARKLE_BIN="$("$ROOT/scripts/sparkle-tools.sh")"
APPCAST_DIR="$ROOT/dist/appcast"
rm -rf "$APPCAST_DIR" && mkdir -p "$APPCAST_DIR"
cp "$ARTIFACT" "$APPCAST_DIR/"
cp "$NOTES" "$APPCAST_DIR/MomentTally-$VERSION.md"   # embedded as the entry's notes
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$MIRROR/releases/download/$TAG/" \
    --link "https://github.com/$MIRROR" \
    --embed-release-notes \
    -o "$APPCAST_DIR/appcast.xml" \
    "$APPCAST_DIR"
echo "==> appcast at $APPCAST_DIR/appcast.xml"

# --- publish -------------------------------------------------------------------
if (( !PUBLISH )); then
    echo "==> skipping publish (--no-publish); artifact and notes are in dist/"
    exit 0
fi

# The gitea repo push-mirrors to $MIRROR on an interval; the tag must have
# arrived there (and still point at our commit) before the release can hang
# off it. If this fails, wait for the mirror sync or trigger it in gitea.
LOCAL_SHA="$(git -C "$ROOT" rev-parse "$TAG")"
MIRROR_SHA="$(gh api "repos/$MIRROR/git/ref/tags/$TAG" --jq .object.sha 2>/dev/null)" \
    || { echo "publish: tag $TAG not on $MIRROR yet — wait for the push-mirror sync" >&2; exit 1; }
[[ "$MIRROR_SHA" == "$LOCAL_SHA" ]] \
    || { echo "publish: $TAG on $MIRROR points at $MIRROR_SHA, local is $LOCAL_SHA" >&2; exit 1; }

gh release create "$TAG" "$ARTIFACT" "$APPCAST_DIR/appcast.xml" \
    --repo "$MIRROR" \
    --title "Moment Tally $VERSION" \
    --notes-file "$NOTES" \
    --verify-tag
echo "==> published https://github.com/$MIRROR/releases/tag/$TAG"

# --- cask bump (#47) -----------------------------------------------------------
# Point the tap's cask at the release just published. The tap's main is
# ruleset-protected (PRs only, squash merge, no required approvals), so the
# bump lands as a branch → PR → immediate self-merge; --delete-branch keeps
# merged branches from accumulating. Sparkle keeps installed apps current
# either way, so a failed bump is an inconvenience, not an outage — rerun
# these steps by hand if anything here fails.
TAP="sf1tzp/homebrew-tap"
SHA256="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
TAP_DIR="$(mktemp -d)"
gh repo clone "$TAP" "$TAP_DIR" -- --depth 1 --quiet
git -C "$TAP_DIR" switch -qc "moment-tally-$VERSION"
sed -i '' \
    -e "s/^  version .*/  version \"$VERSION\"/" \
    -e "s/^  sha256 .*/  sha256 \"$SHA256\"/" \
    "$TAP_DIR/Casks/moment-tally.rb"
git -C "$TAP_DIR" commit -aqm "moment-tally $VERSION"
git -C "$TAP_DIR" push -qu origin "moment-tally-$VERSION"
gh pr create --repo "$TAP" --head "moment-tally-$VERSION" \
    --title "moment-tally $VERSION" \
    --body "Automated cask bump from Moment Tally's release pipeline ($TAG)."
gh pr merge --repo "$TAP" "moment-tally-$VERSION" --squash --delete-branch
rm -rf "$TAP_DIR"
echo "==> cask bumped to $VERSION on $TAP"
