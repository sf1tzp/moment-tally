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
the sim build off the Keychain and the sync path).

```bash
xcrun simctl boot "iPhone 17 Pro" && open -a Simulator
SIMCTL_CHILD_MOMENTTALLY_DEMO=1 just ios-run       # build + install + launch
just ios-test                                      # CoreTests, sim destination
xcrun simctl io booted screenshot /tmp/shot.png    # evidence
xcrun simctl ui booted appearance dark             # theme flips (light|dark)
```

- **Both size classes, always:** the root branches on `horizontalSizeClass`
  (IOSRootView) — compact gets the TabView, regular gets IPadSplitRoot. A UI
  change isn't verified until it's been seen on an iPhone sim *and* an iPad
  sim. The built .app runs on any booted simulator regardless of the build
  destination's device name, so boot the iPad and re-run `just ios-run` —
  no rebuild flags needed.
- **No AX story on iOS:** System Events doesn't reach into the simulator, so
  verification is visual — screenshot per state, or hands-on in Simulator.app.
- **Physical devices are mini-only** (`just ios-device`; signing + Xcode
  Apple ID session live there). It takes the first plugged-in device — one
  cable at a time is fine. Device loads are an explicit-ask step, never part
  of unprompted verification.
