---
name: capture
description: Produce the canonical demo-mode screenshot/recording batch for the README and website, per captures/shots.yaml. Run on macbook-air when asked to refresh release assets; on other machines only when the user explicitly insists.
---

# Capturing release assets

> **Machine gate:** same as verify — this is a build/launch/AX-drive cycle,
> so run it unprompted only on macbook-air (check `hostname`).

The contract is `captures/shots.yaml`: one entry per asset with the scene it
must show and the renditions that ship. Read it first — it, not this file, is
the source of truth for what to capture. See `captures/README.md` for the
pipeline overview.

> **Scripted choreography exists** — `captures/drivers/` holds committed,
> window-origin-relative drivers for every shot (see its README for run
> order and which are verified vs REHEARSE-VERIFY). Prefer running those
> over re-deriving scenes interactively; fall back to hand-driving only
> when a surface changed enough to break a driver, and fold fixes back
> into the scripts. Before anything: `assert_2x` in `drivers/lib.zsh`
> guards the 1x-display trap (Screen Sharing virtual display / native-1x
> monitor modes) — captures must be 2x.

## Flow

1. **Build from the commit you'll vouch for, in a worktree.** The provenance
   manifest stamps `HEAD` at export, and the README exports land in the tree
   you run from — so work from a fresh worktree branch off origin/main
   (`git worktree add ~/worktrees/moment-tally/captures-<date> -b
   captures-<date> origin/main`), never a primary checkout. There:
   `swift build`, then launch `./.build/debug/MomentTally --demo` (demo mode
   never touches the Keychain, so the unsigned binary launches with zero
   prompts). Quit the installed app first — see the two-instances caveat in
   [shared/ax-driving.md](../shared/ax-driving.md).
2. **Walk the shot list.** For each shot, stage the `scene` and capture into
   `captures/raw/` — `<id>.png` for stills, `<id>.mov` for recordings, native
   (2x retina) resolution, no scaling here. Driving and capture techniques
   (element map, window-ID stills, region recordings, all the AX caveats)
   live in [shared/ax-driving.md](../shared/ax-driving.md).
   A partial refresh is fine: capture only the shots whose surfaces changed.
   Outputs with `theme: light` need a second capture of the same scene as
   `<id>-light.png`: flip the system appearance with
   `osascript -e 'tell app "System Events" to tell appearance preferences to
   set dark mode to false'`, give the app a beat to re-render, re-stage, and
   capture. Do all dark shots first, then the light batch in one appearance
   flip — and flip dark mode back on when done.
3. **Process:** `just process-captures` (deps: `brew install yq jq ffmpeg
   webp`). Missing raws are listed and skipped.
4. **Export:** `just export-captures` — copies renditions into
   `readme-images/` in this worktree and into a dated worktree of the
   website repo it creates from origin/main (the primary website checkout is
   never written to), and on a complete batch stamps the provenance
   manifests in both. An explicit `[website-dir]` argument overrides the
   destination.
5. **Ship:** review the visual diffs in both worktrees — open each changed
   asset, confirm the scene contract — then commit and push both branches
   and open the paired PRs (pattern: PrimeTime#102 + primetime-website#22).
   The website PR goes via `tea pr create` (internal gitea).

If a surface has visibly changed such that its `scene` description no longer
matches what's best to show, update the shot's `scene` in the same PR.
