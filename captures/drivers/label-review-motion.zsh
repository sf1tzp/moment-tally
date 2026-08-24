#!/bin/zsh
# Marks tab recording (~20s): expand the drifted `proj` key, drag its
# menu-shoot value onto the canonical `project` key, show the staged
# sentence, Approve Changes so the tree collapses.
#
# MUTATES DEMO DATA (the merge is approved) — run this LAST among the window
# recordings, after all stills. A fresh --demo relaunch restores the drift.
#
# Beats verified 2026-08-13: the reworked Marks tree only forms a drag from a
# row that is ALREADY SELECTED — a cold smoothdrag mousedown rubber-band
# selects instead. So: click the value row once, then smoothdrag it onto the
# key row. Approve Changes sits pinned bottom-right of the window (+705,+625).
# Run: captures/drivers/label-review-motion.zsh [out.mov]
set -e
source "${0:a:h}/lib.zsh"
OUT=${1:-$REPO_ROOT/captures/raw/label-review-motion.mov}
SMOOTHDRAG=$(helper smoothdrag)

frontmost; sleep 0.5
main_origin
ax 'click button "Marks" of toolbar 1 of window "Moment Tally"' >/dev/null; sleep 1.5

rows_y() { ax 'get position of rows of outline 1 of scroll area 1 of group 1 of group 1 of window "Moment Tally"' | tr ',' '\n' | awk 'NR%2==0' | tr -d ' '; }

# Key row order — RE-VERIFY against the 2026-08 broad-audience seed (keys:
# client project proj deliverable type meeting recipe activity book lang
# show); the drag below assumes project = row 3, proj = last.
PROJECT_Y=$(rows_y | sed -n 3p)
PROJ_Y=$(rows_y | tail -1)

drive() {
  sleep 2
  # expand proj (chevron at the key-row left edge)
  cliclick "m:$((WX+16)),$((PROJ_Y-20))" w:150 "m:$((WX+16)),$((PROJ_Y+13))" w:200 "c:$((WX+16)),$((PROJ_Y+13))"
  sleep 2
  # value row appears under proj; select it, then drag it onto project
  local val_y=$((PROJ_Y+26+12))
  cliclick "c:$((WX+180)),$val_y"; sleep 1.0
  frontmost
  "$SMOOTHDRAG" $((WX+180)) $val_y $((WX+180)) $((PROJECT_Y+13)) 900
  sleep 2.5   # staged-move sentence visible in the bottom bar
  # Approve Changes — pinned bottom-right of the window
  rmove 705 600; sleep 0.2; rapproach 705 625
  sleep 3   # tree collapses to one key fewer
  rmove 400 300
}

take "$OUT" 26 "$WX,$WY,780,648" drive
