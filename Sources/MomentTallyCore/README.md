# MomentTallyCore — the domain engine

The layer every consumer shares, including headless ones. **Membership
test: "could the CLI (or a test with no UI framework) need it?"** If yes,
it belongs here.

What lives here: the domain types (`TimeSpan`, `SpanLabel`,
`LabelDefinition`, `TagSet`), the GRDB-backed local store
(`LocalBackend`), sync in all its forms (`SyncEngine`, `CloudKitTransport`,
`CloudSyncController`, the CK record codec), demo mode + seeding, export,
and the cross-process store-change notification the CLI posts.

Rules of the module:

- **No UI imports.** Never SwiftUI, AppKit, or UIKit. Platform forks are
  rare and tiny (the `NSFullUserName()` gate in `LocalBackend` is the
  canonical example) — if a file needs more than that, it probably belongs
  in [MomentTallyKit](../MomentTallyKit/README.md).
- **`package` access** on the cross-module surface: visible to the other
  targets in this package, API to nobody outside it.
- Consumed by everything: the Mac app, the iOS app (via the kit), the CLI,
  and both test targets.

Tests live in `Tests/MomentTallyCoreTests`, which deliberately depends
only on core + kit so the suite also runs against an iOS simulator
destination (`just ios-test`).
