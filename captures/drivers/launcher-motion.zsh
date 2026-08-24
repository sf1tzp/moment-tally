#!/bin/zsh
# Launcher tab recording (~15s): hover Kitchen -> Reading -> Workout, then
# click Workout's +bike chip so an activity:bike timer starts.
#
# Beats verified 2026-08-13: chips reveal on 180ms hover intent as plain
# SwiftUI views (no AX presence, no help) floating over the card; +bike sits
# at a stable card-relative offset. Chips stay suppressed while the tally is
# RUNNING — if a prior run started Workout, click the card once to stop it.
# Run: captures/drivers/launcher-motion.zsh [out.mov]
set -e
source "${0:a:h}/lib.zsh"
OUT=${1:-$REPO_ROOT/captures/raw/launcher-motion.mov}

frontmost; sleep 0.5
main_origin
ax 'click button "Launcher" of toolbar 1 of window "Moment Tally"' >/dev/null; sleep 1.5

drive() {
  sleep 2
  # Kitchen -> Reading -> Workout, entering each card at its own height
  rmove 260 134; sleep 0.2; rmove 389 134; sleep 2.2          # Kitchen
  rmove 693 100; sleep 0.2; rmove 693 134; sleep 2.2          # Reading
  rmove 610 134; sleep 0.2; rmove 541 134; sleep 2.0          # Workout (chips reveal on intent)
  rmove 522 141; sleep 0.4; rclick 522 141                    # +bike chip
  sleep 3.5
  rmove 400 400
}

take "$OUT" 20 "$WX,$WY,780,648" drive
