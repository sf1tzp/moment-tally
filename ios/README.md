# ios/ — the Xcode world

Everything Xcode-specific in one directory, deliberately *outside*
`Sources/`:

- `project.yml` — the xcodegen spec. The `.xcodeproj` it generates is
  gitignored; regenerate with `just ios-project`.
- `App/MomentTallyApp.swift` — the iOS shell: `@main`, font registration,
  and `MomentTallyRootView()`. The Mac twin is
  `Sources/MomentTally/App.swift`. It's ~20 lines because the real iOS
  implementation lives in
  [MomentTallyKit](../Sources/MomentTallyKit/README.md)
  (`Views/IOS*.swift`) — the shell can only see the kit's small `public`
  façade (the package-access boundary stops at the package edge).

## Why top-level, not under Sources/?

`Sources/` is SwiftPM territory: each directory there is a target declared
in `Package.swift`, buildable by `swift build` with Command Line Tools
alone — the Mac pipeline's deliberate property. An iOS app bundle can't be
a SwiftPM product (simulator, device deploy, and App Store upload all
require Xcode), so the app shell and project spec sit outside the package
in their own tree, keeping the boundary legible: if it's under `ios/`,
only Xcode ever reads it.

The Xcode app target is named `MomentTallyIOS` — not `MomentTally`,
which collides with the package's Mac executable product and makes
Xcode's by-name matching drag Sparkle into the iOS link.

## Commands

    just ios-project     # regenerate the .xcodeproj
    just ios-build       # build for the simulator
    just ios-run         # install + launch on a booted simulator
    just ios-test        # core+kit suite on a simulator destination
    just ios-device      # build, install, launch on a plugged-in iPhone

Brand fonts inject at build time from `~/.sfi/brand-assets/fonts` when
present (never committed — this repo mirrors publicly); builds without
them fall back to system faces.
