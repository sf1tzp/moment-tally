#!/bin/zsh
# Menu-bar popover recording (~20s) + the idle popover still.
#
# Scene: demo's running timer active -> open popover -> hover Wedding Shoot
# so its quick-mark chips expand -> start a timer via the +consult chip ->
# stop the running wedding-shoot editing timer. Then (still mode) stop all
# timers, reopen, capture the idle popover still.
#
# The scene records over a plain desktop: this script swaps in a solid
# wallpaper and restores it after (backup of the wallpaper Index.plist).
#
# REHEARSE-VERIFY: chip/stop positions resolve at runtime from hover-revealed
# help attributes (chips are AX-absent until a real hover; identify by help,
# see ax-driving.md). Do one dry run per mode and eyeball the screenshots.
# Run: captures/drivers/popover-motion.zsh [out.mov]     (recording)
#      captures/drivers/popover-motion.zsh still [out.png]
set -e
source "${0:a:h}/lib.zsh"
WALL_PLIST=~/Library/Application\ Support/com.apple.wallpaper/Store/Index.plist

toggle_popover() { ax 'click menu bar item 1 of menu bar 2' >/dev/null; sleep 1.2; }
popover_geom() { # -> PX PY PW PH  (popover = the untitled window)
  read PX PY PW PH < <("$(helper winlist)" "$APP" | awk -F'|' '$3=="" {print $4; exit}' | tr ',' ' ')
}

# help_point <substr> -> "x,y" of the popover element whose help contains substr
help_point() {
  osascript <<EOF
tell application "System Events" to tell process "$APP"
  set g to group 1 of window 1
  set hs to help of UI elements of g
  set ps to position of UI elements of g
  repeat with i from 1 to (count hs)
    try
      if (item i of hs) contains "$1" then
        return ((item 1 of item i of ps) as text) & "," & ((item 2 of item i of ps) as text)
      end if
    end try
  end repeat
  return ""
end tell
EOF
}

click_help() { # click_help <substr> <dx> <dy>
  local p; p=$(help_point "$1" | tr -d ' ')
  [[ -n $p ]] || { echo "REHEARSE: no element with help ~ '$1'" >&2; return 1; }
  cliclick "m:${p%,*},$((${p#*,}+${3:-8}))" w:250 "c:$((${p%,*}+${2:-8})),$((${p#*,}+${3:-8}))"
}

solid_wallpaper() {
  cp "$WALL_PLIST" "$HELPER_CACHE/wallpaper-backup.plist"
  local png=$HELPER_CACHE/solid.png
  [[ -f $png ]] || osascript -e 'use framework "AppKit"' -e '
    set img to current application'"'"'s NSImage'"'"'s alloc()'"'"'s initWithSize:{64,64}
    img'"'"'s lockFocus()
    (current application'"'"'s NSColor'"'"'s colorWithRed:0.086 green:0.086 blue:0.102 alpha:1)'"'"'s setFill()
    current application'"'"'s NSBezierPath'"'"'s fillRect:{{0,0},{64,64}}
    img'"'"'s unlockFocus()
    set d to img'"'"'s TIFFRepresentation()
    set rep to current application'"'"'s NSBitmapImageRep'"'"'s imageRepWithData:d
    set pngd to rep'"'"'s representationUsingType:(current application'"'"'s NSBitmapImageFileTypePNG) |properties|:(missing value)
    pngd'"'"'s writeToFile:"'"$png"'" atomically:true'
  osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"$png\""
}
restore_wallpaper() {
  cp "$HELPER_CACHE/wallpaper-backup.plist" "$WALL_PLIST" && killall WallpaperAgent 2>/dev/null || true
}

if [[ $1 == still ]]; then
  OUT=${2:-$REPO_ROOT/captures/raw/popover.png}
  toggle_popover
  # stop every running timer (Stop buttons carry help "Stop"), then re-open idle
  while p=$(help_point "Stop" | tr -d ' '); [[ -n $p ]]; do
    cliclick "c:$((${p%,*}+8)),$((${p#*,}+8))"; sleep 1
  done
  toggle_popover; sleep 0.5; toggle_popover   # close + reopen to settle
  frontmost; sleep 0.5
  still "$OUT" ""
  toggle_popover
  echo "popover still -> $OUT"
  exit 0
fi

OUT=${1:-$REPO_ROOT/captures/raw/popover-motion.mov}
# Zero app windows may remain on screen (they'd overlap the popover region):
# quit-and-relaunch fresh is the caller's job; this just checks.
[[ -z $("$(helper winlist)" "$APP") ]] || { echo "BLOCKED: app windows on screen — close them (fresh --demo relaunch, skip onboarding, close main window)"; exit 1; }

solid_wallpaper; sleep 1
toggle_popover           # open once to measure geometry, leave OPEN for the take
popover_geom
toggle_popover           # ...closed again; the take re-opens it on camera

drive() {
  sleep 1.5
  toggle_popover; sleep 2
  # hover Wedding Shoot row (2nd quick-start row), entering at its own y
  cliclick "m:$((PX-40)),$((PY+236))" w:200 "m:$((PX+60)),$((PY+236))" w:300 "m:$((PX+146)),$((PY+236))" w:800
  sleep 1.2                      # chips expanded
  click_help "consult" || true   # start meeting:consult timer
  sleep 2.5
  click_help "Stop" || true      # stop the wedding-shoot editing timer
  sleep 3
  cliclick "m:$((PX+150)),$((PY+500))"
}

# region: popover + side shadow margin and headroom below for hover expansion;
# flush at the top — PY-anything catches the menu bar pills
take "$OUT" 26 "$((PX-50)),$PY,$((PW+100)),$((PH+100))" drive
restore_wallpaper
