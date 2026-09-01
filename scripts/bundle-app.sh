#!/usr/bin/env bash
# Assemble a MomentTally.app bundle from the SwiftPM release build.
#
# The bundle ships under the Moment Tally identity (#44); target and binary
# are also named MomentTally since the rename, so the copy is 1:1.
#
# Two variants (#115):
#   direct  (default) dist/MomentTally.app — Sparkle + bundled CLI, signed by
#           sign-app.sh with Developer ID and notarized.
#   mas     dist/mas/MomentTally.app — the Mac App Store build: no Sparkle
#           (the store owns updates; shipping an updater is a rejection),
#           no bundled CLI (a cask concept the store can't install), and
#           the store-only Info.plist tweaks. Signed + packaged by
#           package-mas.sh; App Review replaces notarization.
# Both variants carry the container migration manifest and are sandboxed at
# signing time — containment never diverges between channels.
#
# Env:
#   VERSION      marketing version (default: git describe, 0.0.0 before any tag)
#   ARCHS        slices to build, space-separated (default: arm64 x86_64).
#                Set ARCHS=arm64 for a faster native-only dev bundle.
#   VARIANT      "direct" (default) or "mas".
#   BRAND_FONTS_DIR  licensed brand fonts to inject (default:
#                ~/.sfi/brand-assets/fonts; skipped when absent).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MomentTally"
VARIANT="${VARIANT:-direct}"
case "$VARIANT" in
    direct) APP="$ROOT/dist/$APP_NAME.app" ;;
    mas)    APP="$ROOT/dist/mas/$APP_NAME.app" ;;
    *) echo "error: VARIANT='$VARIANT' (supported: direct, mas)" >&2; exit 2 ;;
esac

VERSION="${VERSION:-$(git -C "$ROOT" describe --tags 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"

# The MAS variant builds with MOMENTTALLY_MAS=1 (Package.swift drops the
# Sparkle product and defines MAS_BUILD) in its own scratch path, so object
# files compiled with different flags never mix with the direct build's.
BUILD_ENV=()
BUILD_FLAGS=()
SCRATCH="$ROOT/.build"
if [[ "$VARIANT" == mas ]]; then
    BUILD_ENV=(MOMENTTALLY_MAS=1)
    SCRATCH="$ROOT/.build/mas"
    BUILD_FLAGS=(--scratch-path "$SCRATCH")
fi

# Universal binary (#114): one build per slice, stitched with lipo. SwiftPM's
# native multi-arch mode (--arch arm64 --arch x86_64 in one invocation) needs
# XCBuild from full Xcode; separate single-arch builds are the recipe that
# also works on a Command Line Tools-only machine. Only the two Mach-O
# executables need stitching — Sparkle's prebuilt XCFramework and the
# resource bundle are already universal/arch-independent, so those come
# from the first arch's build dir.
ARCHS="${ARCHS:-arm64 x86_64}"
for ARCH in $ARCHS; do
    env ${BUILD_ENV[@]+"${BUILD_ENV[@]}"} \
        swift build --package-path "$ROOT" -c release --arch "$ARCH" \
        ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
done
# --arch builds land in <scratch>/<arch>-apple-macosx/release, not .build/release.
REL="$SCRATCH/${ARCHS%% *}-apple-macosx/release"

# lipo <product> into <dest> from every arch's build dir (a single-arch
# ARCHS just produces a thin binary — lipo -create is fine with one input).
lipo_bin() {
    local slices=()
    for ARCH in $ARCHS; do
        slices+=("$SCRATCH/$ARCH-apple-macosx/release/$1")
    done
    lipo -create "${slices[@]}" -output "$2"
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo_bin "$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
if [[ "$VARIANT" == direct ]]; then
    # The scriptable CLI (#80) rides in the bundle under its user-facing name —
    # the SwiftPM product is moment-tally-cli to preserve the guard against a
    # case-insensitive .build collision with the app binary. Users get it on
    # PATH via the cask's binary stanza (or a manual symlink to
    # Contents/Helpers/moment-tally).
    # Direct-only: sandboxed store apps can't install CLI tools, so the cask
    # channel owns the CLI (#115).
    mkdir -p "$APP/Contents/Helpers"
    lipo_bin moment-tally-cli "$APP/Contents/Helpers/moment-tally"
    # Sparkle rides along for auto-update (#46) — SwiftPM drops the framework
    # next to the binary; the bundled binary reaches this copy via the
    # @executable_path/../Frameworks rpath set in Package.swift.
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$REL/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The container migration manifest (#115): on the first sandboxed launch,
# macOS reads Contents/Resources/container-migration.plist and moves the
# pre-sandbox data into the freshly created container. Both variants carry
# it — whichever channel a user upgrades through migrates their data.
cp "$ROOT/scripts/container-migration.plist" \
   "$APP/Contents/Resources/container-migration.plist"
# The SwiftPM resource bundle (brand font + masthead icon). Brand.resources
# looks here — swift build's Bundle.module accessor does NOT check
# Contents/Resources, only the .app root and the builder's absolute .build path.
ditto "$REL/MomentTally_MomentTallyKit.bundle" \
      "$APP/Contents/Resources/MomentTally_MomentTallyKit.bundle"
# Licensed brand fonts (PR #202): live in the private sfi/brand-assets repo —
# never in this one, which mirrors to public GitHub — and inject at bundle
# time when the build machine has a checkout. Brand.registerFonts() scans
# Contents/Resources/Fonts at launch and falls back to system faces when the
# directory is absent, so a mirror build still assembles a working app.
FONTS_DIR="${BRAND_FONTS_DIR:-$HOME/.sfi/brand-assets/fonts}"
if [[ -d "$FONTS_DIR" ]]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    find "$FONTS_DIR" -maxdepth 1 \( -name '*.otf' -o -name '*.ttf' \) \
        -exec cp {} "$APP/Contents/Resources/Fonts/" \;
    # Browser-downloaded fonts carry com.apple.quarantine (plus provenance
    # and friends), and App Store Connect rejects any quarantined file in a
    # submission (error 91109 — the same trap package-mas.sh strips off the
    # profile). Clear xattrs on the injected copies; nothing reads them.
    xattr -cr "$APP/Contents/Resources/Fonts"
    echo "Injected brand fonts from $FONTS_DIR"
fi
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" \
    "$ROOT/scripts/Info.plist.in" > "$APP/Contents/Info.plist"
if [[ "$VARIANT" == mas ]]; then
    # No Sparkle in the store build — its Info.plist keys go too (a feed URL
    # in a store binary would only confuse App Review).
    for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks \
               SUEnableInstallerLauncherService; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist"
    done
    # Export-compliance declaration: nothing beyond exempt HTTPS, declared in
    # the binary so App Store Connect skips the per-build questionnaire.
    /usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" \
        "$APP/Contents/Info.plist"
    # The store icon: App Store Connect extracts icons only from a compiled
    # asset catalog (CFBundleIconName + Assets.car) — the bare .icns that
    # serves the direct channel uploads fine but renders as the generic
    # placeholder in Transporter/ASC. Rebuild the catalog from the canonical
    # .icns at bundle time. actool ships with full Xcode, which only this
    # variant requires — the direct channel stays CLT-only buildable.
    ICON_SCRATCH="$(mktemp -d)"
    iconutil --convert iconset "$ROOT/Resources/AppIcon.icns" \
        --output "$ICON_SCRATCH/AppIcon.iconset"
    APPICONSET="$ICON_SCRATCH/Assets.xcassets/AppIcon.appiconset"
    mkdir -p "$APPICONSET"
    cp "$ICON_SCRATCH/AppIcon.iconset/"*.png "$APPICONSET/"
    printf '{"info":{"author":"xcode","version":1}}' \
        > "$ICON_SCRATCH/Assets.xcassets/Contents.json"
    cat > "$APPICONSET/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png",     "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",     "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",   "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png","idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",   "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png","idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",   "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png","idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
    xcrun actool "$ICON_SCRATCH/Assets.xcassets" \
        --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ICON_SCRATCH/partial.plist" > /dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" \
        "$APP/Contents/Info.plist"
    rm -rf "$ICON_SCRATCH"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Built $APP ($VERSION, build $BUILD; ${ARCHS// /+}; $VARIANT)"
