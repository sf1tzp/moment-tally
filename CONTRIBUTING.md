# Contributing to Moment Tally

Thanks for your interest in Moment Tally. Bug reports, feature discussion, and
patches are all welcome — with one piece of paperwork explained below that
keeps the project's licensing structure intact.

Moment Tally is developed on an internal forge and push-mirrored to GitHub. The
GitHub repository is where we triage public issues and review pull requests,
but changes land through the canonical repository — a maintainer will carry
your reviewed PR across.

## Contribution terms

Moment Tally's public releases are open source: AGPL-3.0-or-later — see
[NOTICE](NOTICE). In addition, Moment Tally's copyright holder distributes
(or plans to distribute)
app builds through channels whose terms are incompatible with copyleft, such
as Apple's App Store. That dual-channel model only works if the copyright
holder retains sufficient rights over everything that ships.

By submitting a contribution (pull request, patch, or code snippet intended
for inclusion), you agree to the following:

1. **Developer Certificate of Origin.** You certify the
   [DCO](https://developercertificate.org) — that you wrote the contribution
   or otherwise have the right to submit it under the project's licenses.
   Record this by signing off each commit (`git commit -s`, producing a
   `Signed-off-by:` trailer matching your commit author identity).

2. **License grant.** Your contribution is licensed under
   AGPL-3.0-or-later, the license covering the files it modifies.

3. **Relicensing grant.** You additionally grant Steven Fitzpatrick (Street
   Fortress Industries) a perpetual, worldwide, irrevocable, royalty-free
   right to relicense and distribute your contribution, in original or
   modified form, under other license terms — including proprietary terms
   used for app-store distribution. This grant is non-exclusive: your own
   rights to your contribution are unaffected, and public releases containing
   it remain open source as above.

If you can't agree to these terms — for example because of an employment
agreement — please open an issue describing the change instead of submitting
code, and we'll take it from there.

## Development

The [README](README.md) covers building and running the app (`just build`,
`just run`, `just demo`). Run `swift test` before submitting;
keep commits focused and their subjects in the imperative mood.

`swift test` works on Linux too: off-Mac the manifest drops the app layers
and `MomentTallyTests`, and the CloudKit-backed files in
`MomentTallyCoreTests` gate themselves out, so what runs is the rest of the
core suite — the store, migrations, exports — the same set CI runs on every
push. `MomentTallyTests` (the app module) and the CloudKit tests still need
a Mac.
