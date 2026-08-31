# MomentTallyCLI — the scriptable surface

The command-line executable (#80): export to stdout, timer start/stop/
status for scripts and agent hooks (#79). It opens the same store file the
Mac app uses, through the same [MomentTallyCore](../MomentTallyCore/README.md)
code, and posts a distributed notification on writes so a running app
picks them up.

The product is `moment-tally-cli` (the `-cli` suffix guards against a
case-insensitive `.build/` collision with the app binary); distribution
installs it under the plain name — see `bundle-app.sh`.

macOS-only by nature: there is no CLI on iOS, which is why core's
store-change observer is `#if os(macOS)`.
