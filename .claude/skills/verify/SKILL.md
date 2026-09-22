---
name: verify
description: Build, launch, and verify Moment Tally changes — the Mac app AX-driven in demo mode, the iOS app in the simulator. Auto-invoke only on macbook-air; on any other machine (check `hostname`) run only when the user explicitly asks to verify.
---

# Verifying Moment Tally

> **Machine gate:** only invoke this skill unprompted on macbook-air. Per the
> machine split (2026-09-12), the air is the iteration machine — Mac verify
> and iOS simulator work both live there — while macmini is Steven's main
> workstation for other projects and the verification/publishing end: don't
> start build/launch/drive cycles there unless he explicitly asks (device
> loads and interactive checks on the mini are usually his call, via screen
> sharing or a plugged-in device).

## Build & launch

```bash
just build          # swift build + codesign with "TraggoMenuApp Dev"
./.build/debug/MomentTally > /tmp/app.log 2>&1 &   # plain bash background; wait ~5-10s
```

On a machine with no codesigning identity (e.g. macbook-air), skip `just
build` and use plain `swift build`. Demo mode (`--demo` or `MOMENTTALLY_DEMO=1`)
never touches the Keychain — token reads and sync connects are guarded by
`!isDemo` — so the unsigned binary launches with zero prompts and is the
preferred target for screenshots and AX driving there.

**Keychain gotcha (fixed 2026-07-23 on macmini):** if launches prompt for the
login-keychain password after every rebuild, the "TraggoMenuApp Dev" cert has
no codeSign trust entry (`security find-identity -v -p codesigning` shows 0
valid), so the ACL's cert-anchored requirement can never validate. Fix once
per machine:

```bash
security find-certificate -c "TraggoMenuApp Dev" -p > /tmp/dev-cert.pem
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/dev-cert.pem   # user confirms a dialog
```

(Setting "Always Trust" in Keychain Access can silently fail to persist —
verify with `security dump-trust-settings`.) A launch stuck in
`SecItemCopyMatching` (state `SN`, ~0 CPU, never appears in System Events)
means a dialog is waiting; only the user can dismiss it.

## Driving it

The element map, screenshot/recording techniques, and every AX caveat (the
text-entry unreliability, the two-instances trap, the popover toggle state)
live in [shared/ax-driving.md](../shared/ax-driving.md) — read it before any
System Events work. The same reference backs the `capture` skill (release
asset batches); add new AX learnings there, not here.

## Verification-specific caveats

- There is no server any more (the sync server went in #272, the Traggo
  import in #275): the local store is the only backend, and iCloud is the
  only transport. A non-demo launch runs against the real local database —
  create your own test timespan (quick-start a tag set, stop it) and delete
  it when done.

## iOS (simulator)

Simulator builds are unsigned — any machine with the iOS runtime works; the
machine gate above still decides where this runs unprompted. Demo mode is the
default verification target here too (`SIMCTL_CHILD_MOMENTTALLY_DEMO=1` keeps
the sim build off the Keychain and the sync path). Needs full Xcode (27+):
the Command Line Tools alone can't build the package any more (no SwiftUI
macro plugin for `@Entry`), so `xcode-select -p` must point at Xcode.app.

```bash
SIMCTL_CHILD_MOMENTTALLY_DEMO=1 just ios-matrix-run   # the matrix: tile + build + launch everywhere
SIMCTL_CHILD_MOMENTTALLY_DEMO=1 just ios-run          # one device (boots "iPhone 17 Pro" if needed)
just ios-test                                         # CoreTests, sim destination
xcrun simctl io "iPhone 17 Pro" screenshot /tmp/shot.png   # evidence, per device
xcrun simctl ui "iPhone 17 Pro" appearance dark            # theme flips (light|dark)
```

- **The device matrix is the gate (#269):** `just ios-matrix` boots an
  iPhone 17 Pro, an iPad mini (the stand-in for the unfolded iPhone Duo —
  Xcode 27.0 has no Duo device type; `MT_MATRIX="A|B|C"` swaps devices in)
  and an iPad Pro 11-inch, and tiles one Device Hub window per device across
  the display, PolyPane-style. `ios-matrix-run` adds one build and an install
  + launch on every booted simulator. Re-running re-tiles. The root branches
  on `horizontalSizeClass` (IOSRootView) — compact gets the TabView, regular
  gets IPadSplitRoot — so a UI change isn't verified until it's been seen on
  the phone *and* both tablets; orientation flips are Controls › Rotate in
  each window.
- **Device Hub, not Simulator.app:** Xcode 27 replaced Simulator.app with
  `Xcode.app/Contents/Applications/DeviceHub.app` — a tabbed window that
  shows one device at a time (a sidebar click switches the tab), hence one
  window per device. It has no scripting dictionary; scripts/ios-matrix.sh
  drives its menus and sidebar through System Events (needs the terminal's
  Accessibility grant). Headless `simctl boot` / `io screenshot` work
  without it.
- **Name the device in simctl calls:** with several simulators up,
  `booted` resolves to an arbitrary one (observed: the last booted). The
  recipes take a name; do the same in ad-hoc commands.
- **No AX story on iOS:** System Events doesn't reach into the simulator, so
  verification is visual — screenshot per state, or hands-on in Device Hub.
  For a tap when there is no other way, the Device Hub window *is* a Mac
  window: `cliclick` at the screen point of the device's UI element works
  (map simulator points onto the window's device frame from a screenshot).
- **Physical devices are mini-only** (`just ios-device`; signing + Xcode
  Apple ID session live there). It takes the first plugged-in device — one
  cable at a time is fine. Device loads are an explicit-ask step, never part
  of unprompted verification.
