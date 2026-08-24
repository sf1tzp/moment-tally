#!/bin/zsh
# All still shots (dark + light variants) per captures/shots.yaml, except the
# popover still (see popover-motion.zsh — it needs the timers stopped).
#
# Precondition: MomentTally --demo running, onboarding dismissed, main window
# open. Run: captures/drivers/stills.zsh [raw-dir]
# Staging side effects: all timers stopped (the seeded running timer dims
# its launcher card; popover-motion's recording needs it back — the
# quit-and-relaunch before that script restores it), week navigator on
# previous week, History on Last 30 days type×project Separately, Marks
# proj row expanded — all harmless for the recordings that follow.
set -e
source "${0:a:h}/lib.zsh"
RAW=${1:-$REPO_ROOT/captures/raw}
mkdir -p "$RAW"

tab() { ax "click button \"$1\" of toolbar 1 of window \"Moment Tally\"" >/dev/null; sleep 1.5; }

stage_and_shoot() { # <suffix: "" | "-light">
  local sfx=$1
  tab Launcher;             still "$RAW/launcher$sfx.png"     "Moment Tally"
  tab Tallies;              still "$RAW/label-sets$sfx.png"   "Moment Tally"
  tab Log;                  still "$RAW/log$sfx.png"          "Moment Tally"
  tab Calendar; sleep 0.5;  still "$RAW/calendar$sfx.png"     "Moment Tally"
  tab History;  sleep 0.5;  still "$RAW/history$sfx.png"      "Moment Tally"
  tab Marks;                still "$RAW/label-review$sfx.png" "Moment Tally"
  tab Settings;             still "$RAW/settings$sfx.png"     "Moment Tally"
}

# Dark is the canonical theme — don't assume the system is in it (a stray
# light-mode session shipped a light capture as launcher.png once).
osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true'
sleep 2
frontmost; sleep 0.5
main_origin
assert_2x

# --- one-time staging (dark pass) ------------------------------------------
# Idle timers: the demo seed launches with a running wedding-shoot timer,
# and a running tally dims its launcher card — stop everything so the
# launcher stills show full-colour cards.
stop_all_timers; frontmost; sleep 0.5

# Log/Calendar: most recent full week -> one step back from Today.
tab Log
ax 'click button 1 of group 1 of group 1 of window "Moment Tally"' >/dev/null; sleep 1

# History: Range = Last 30 days; left donut = type, right = project. Since
# the broad-audience seed (#215) the left Group-by defaults to client, so
# both pickers are staged explicitly.
tab History
ax 'click pop up button 1 of group 1 of group 1 of window "Moment Tally"' >/dev/null
menu_pick "Last 30 days"; sleep 1
# Left Group-by — its AX position is exposed but nested oddly; rehearsed
# window-relative offset, then menu type-select.
rmove 60 153; sleep 0.2; rapproach 116 153
menu_pick "type"; sleep 1
# Right Group-by AX-aliases to the left in side-by-side mode — coordinate
# click (rehearsed offset), then menu type-select.
rmove 505 130; sleep 0.2; rapproach 505 159
menu_pick "project"; sleep 1

# Marks: expand the drifted `proj` key — second-to-last top-level row with
# the broad-audience seed (between lang and show). Row heading text is not
# AX-exposed, so the index is the anchor; AXPress its disclosure triangle.
tab Marks
nrows=$(ax 'count rows of outline 1 of scroll area 1 of group 1 of group 1 of window "Moment Tally"')
ax "perform action \"AXPress\" of UI element 2 of UI element 1 of row $((nrows-1)) of outline 1 of scroll area 1 of group 1 of group 1 of window \"Moment Tally\"" >/dev/null
sleep 1

# --- dark pass --------------------------------------------------------------
stage_and_shoot ""

# --- light pass (staging persists across the appearance flip; full set, the
# appstore batch ships light variants of every still) ------------------------
osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to false'
sleep 3; frontmost; sleep 0.5
stage_and_shoot "-light"
osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true'
sleep 2

echo "stills done -> $RAW"
ls -la "$RAW"/*.png | awk '{print $NF}' | while read f; do
  sips -g pixelWidth "$f" | awk -v f="$f" '/pixelWidth/{print f": "$2"px"}'
done
