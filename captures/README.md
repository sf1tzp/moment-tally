# Release-asset capture pipeline

Everything the README and [moment-tally.com](https://moment-tally.com) show is
the app's own demo mode — seeded data, unretouched UI. This directory makes
that capture batch reproducible instead of a per-session improvisation.

| Piece | Role |
| --- | --- |
| `shots.yaml` | The shot list: every asset, the scene it must show, and which renditions ship where. Update a shot's `scene` in the same PR that changes its surface. |
| `raw/` (gitignored) | Native-resolution captures as they come off `screencapture` — `<id>.png` stills (`<id>-light.png` for light-appearance variants), `<id>.mov` recordings. |
| `out/` (gitignored) | Processed renditions (`just process-captures`), staged as `<to>-<file>`: WebP stills, the README GIF, scaled mp4s, App Store composites. |
| `appstore/` (committed) | Mac App Store screenshots: dark and light stills composited onto a flattened 2880×1800 (16:10) canvas — charcoal for dark, light surface grey for the `-light` set — per the App Store Connect spec. Uploaded by hand at submission time. |
| `manifest.json` | Provenance of the last exported batch: app commit, version, date, host, shots covered. `just release` warns when UI sources changed since this commit. |

## Refreshing the batch

1. On macbook-air, in a fresh moment-tally worktree branch off origin/main
   (`git worktree add ~/worktrees/moment-tally/captures-<date> -b captures-<date>
   origin/main`): `swift build` and launch with `--demo` (quit the installed
   app first). Running the pipeline from that worktree keeps the README
   exports and the provenance commit on the branch, never on a primary
   checkout.
2. Run the `/capture` skill — it drives each scene in `shots.yaml` and lands
   raw captures in `captures/raw/`. Partial refreshes are fine: only the raw
   files present are processed and exported.
3. `just process-captures` — deps: `brew install yq jq ffmpeg webp`.
4. `just export-captures` — copies renditions into `readme-images/` here and
   into a matching dated worktree of the website repo, which it creates from
   origin/main under `~/worktrees/moment-tally-website/` (the primary website
   checkout — `$MOMENTTALLY_WEBSITE_DIR`, default `~/moment-tally-website` — is
   only used as the repo to branch from, never written to). Stamps provenance
   manifests in both. Pass an explicit directory to override the destination.
5. Review the image diffs in both worktrees, commit and push each branch, and
   open the companion PRs (e.g. PrimeTime#102 + primetime-website#22).

Future platforms (iOS) keep this contract — same shot list, different capture
backend (XCUITest + simctl instead of AX driving).
