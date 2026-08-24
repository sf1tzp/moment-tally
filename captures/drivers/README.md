# Capture drivers

Committed choreography for the `/capture` batch (captures/shots.yaml), so a
re-run is a handful of script invocations instead of an interactive AX
session. Rehearsed 2026-08-13; AX techniques and caveats live in
[.claude/skills/shared/ax-driving.md](../../.claude/skills/shared/ax-driving.md).

All click points are **window-origin-relative** (SwiftUI point layout is
stable across displays); each script resolves the window origin at runtime.
Deps: `cliclick`, `ffmpeg`, `swiftc` (Swift helpers in `.claude/skills/shared/`
compile on demand). `lib.zsh` refuses to run a batch on a 1x display
(`assert_2x` — the Screen Sharing virtual-display trap).

## Run order (state pollution matters)

| # | Script | Precondition | Notes |
|---|--------|--------------|-------|
| 1 | `onboarding-motion.zsh` | fresh `--demo` launch, welcome up | verified beats |
| 2 | `stills.zsh` | fresh relaunch, onboarding skipped | all dark + light stills except popover; stops timers (running card dims), stages week-nav/History/Marks |
| 3 | `history-motion.zsh` | after stills.zsh | verified beats; restores its staging |
| 4 | `launcher-motion.zsh` | after stills | REHEARSE-VERIFY: starts an activity:bike timer |
| 5 | `label-review-motion.zsh` | LAST window recording | REHEARSE-VERIFY: approves the proj→project merge (mutates data) |
| 6 | `popover-motion.zsh` | fresh relaunch, **no app windows** | REHEARSE-VERIFY: solid wallpaper, needs running seed timer |
| 7 | `popover-motion.zsh still` | after 6 | stops timers, captures idle popover still, dark + light |

Between 5 and 6: quit and relaunch `--demo` (resets the merge, the bike timer,
and restores the seeded running timer), skip onboarding, close the main window.

REHEARSE-VERIFY scripts encode the full recipe but haven't produced a shipped
take yet: dry-run them once, eyeball the screenshot/first take, then record.
After any take: `ffprobe` the duration and extract 2–3 beat frames — takes can
end early (see ax-driving.md).

Then: `just process-captures` && `just export-captures` per captures/README.md.
