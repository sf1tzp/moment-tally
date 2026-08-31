# MomentTallyKit — the shared app layer

The app, minus the shell. **Membership test: "is this something *any*
Moment Tally app renders or observes?"** Two shells (the Mac menu-bar app
and the iOS app) build against this one module, which is what makes
cross-platform parity structural rather than copy-maintained (#123/#124,
completed by #125).

The name follows Apple's own convention: `-Kit` frameworks (AppKit,
UIKit, WidgetKit) are what you build an app against; `Core-` frameworks
are the engine underneath. Same relationship here — the kit sits on
[MomentTallyCore](../MomentTallyCore/README.md) exactly like UIKit sits
on CoreGraphics.

What lives here:

- `AppModel` and its sub-models (`HistoryModel`, `TagReviewModel`,
  `SpanEditSession`) — the observable state both apps drive.
- `Brand` — colors, gradients, typography, `TallyMarkShape` (the favicon
  geometry both platforms draw).
- The portable components and views (`Views/`): the launcher grid,
  menu/chip primitives, reorder grips, the anchored color picker.
- The iOS app's actual surfaces (`Views/IOS*.swift`, whole-file
  `#if os(iOS)`): the TabView root, the touch launcher home, the span
  editor sheet. The iOS *shell* (`ios/App/`) is ~20 lines; the iOS app is
  implemented here.
- The service layer both apps share: sync/import clients, `Keychain`,
  `BuildEntitlements`, `LogFilter`.

Rules of the module:

- **SwiftUI yes; AppKit/UIKit only behind `#if os(...)`,** and only for
  small forks (color decomposition, dynamic colors). Anything that
  *fronts* single-platform machinery — NSWindow managers, NSColorPanel,
  Sparkle, SMAppService — belongs to the shell instead (see
  [Sources/MomentTally](../MomentTally/README.md) and its `*Mac.swift`
  splits).
- **`package` access** throughout, with one exception: the few symbols the
  Xcode-built iOS shell needs (`MomentTallyRootView`, `BrandFonts`) are
  `public`. The shell sits outside the SwiftPM package boundary and can't
  see `package` symbols — and it can't portably join the boundary either,
  because SwiftPM derives `-package-name` from the checkout directory, so
  worktrees would each mint a different name.
- Navigation stays abstract: portable views route through the
  `openAppSection` environment action (`Navigation.swift`); each shell
  decides what that means (settings-window tab on the Mac, TabView
  tab/sheet on iOS).

Ties break on **who consumes it, not what it imports** — `TrailingRange`
is pure Foundation and could compile in core, but only UI reads it, so
it's here.
