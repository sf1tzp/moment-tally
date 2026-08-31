# MomentTally — the Mac app shell

The macOS executable target: what's left when the domain
([MomentTallyCore](../MomentTallyCore/README.md)) and the shared app layer
([MomentTallyKit](../MomentTallyKit/README.md)) are factored out.
**Membership test: "does it touch process, window, or a single-platform
framework?"**

What lives here:

- `App.swift` — `@main`, the `MenuBarExtra` scene, the `.accessory`
  activation policy. The iOS twin is `ios/App/MomentTallyApp.swift`; both
  are thin shells over the kit.
- `MacShell` — the shell-owned observables: `UpdaterModel` (Sparkle) and
  `LoginItemModel` (SMAppService). Deliberately *not* `AppModel`
  properties: neither has an iOS analogue, so they ride the SwiftUI
  environment beside the model instead (#124).
- Window machinery: `SettingsWindowManager` (the NSTabViewController
  settings window), `OnboardingWindowManager`.
- The Mac halves of split files: `BrandMac.swift` (NSImage brand
  accessors, `Bundle.module` resources), `MenuComponentsMac.swift`
  (`TagColorPicker`, the NSColorPanel sweeper, `KeyViewLoopRefresher`).
- `Views/` — the window-hosted content views (Log, Calendar, Charts,
  Settings, Help, onboarding/walkthrough). Most are portable SwiftUI that
  **#125 moves into the kit**; they're here for now, not by principle.

A note on the name: this target is `MomentTally` because it *was* the
whole app before the split — and the name is load-bearing: it's the
product/binary name inside `MomentTally.app` and the stem of the resource
bundle (`MomentTally_MomentTally.bundle`) that `bundle-app.sh` and
`Brand.resources` both key on. Renaming it to `MomentTallyMac` would be
churn across the release pipeline for symmetry's sake. The iOS app needs
no `Sources/` name at all — its shell lives outside the package (see
[ios/README.md](../../ios/README.md)), and its real implementation lives
in the kit.
