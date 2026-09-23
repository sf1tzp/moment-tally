# Verification helpers — source from a zsh script or an interactive shell:
#   source .claude/skills/shared/verify.zsh
# Builds on the capture drivers' lib.zsh (AX verbs, window IDs, stills) and
# adds the review-density side: screenshots downsampled for reading, contact
# sheets, and Device Hub touch driving by screenshot coordinates.
source "${0:a:h}/../../../captures/drivers/lib.zsh"
SHARED_DIR=${0:a:h}

# Review density: a screenshot is read, not shipped, so cap the long edge.
# VSHOT_MAX=0 keeps full resolution (a capture batch never uses these).
VSHOT_MAX=${VSHOT_MAX:-900}

_vshrink() { (( VSHOT_MAX > 0 )) && sips -Z "$VSHOT_MAX" "$1" >/dev/null; }

# vshot <out.png> <window-title-or-empty> — a Mac window still (window-ID
# capture, native shadow) at review density.
vshot() { still "$1" "$2" && _vshrink "$1"; }

# simshot <out.png> <simulator-name> — a simulator screenshot at review
# density. Name the device: `booted` is arbitrary with the matrix up.
simshot() {
  xcrun simctl io "$2" screenshot "$1" >/dev/null 2>&1 && _vshrink "$1"
}

# vsheet <out.png> <cellWidth> <columns> <in.png>... — one contact sheet from
# many shots (tile.swift, compiled on demand): one image read instead of N.
vsheet() {
  local out=$1 cell=$2 cols=$3; shift 3
  "$(helper tile)" "$out" "$cell" "$cols" "$@"
}

# --- Device Hub touch driving ---------------------------------------------
# Taps and swipes on a simulator, addressed in the pixel space of a
# screenshot you have just read — no by-hand mapping. The device screen's
# frame comes from Device Hub's accessibility tree (the `iOSContentGroup`
# element), so a toggled sidebar or inspector re-maps itself instead of
# silently shifting every tap.
#
#   devhub_tap   <simulator-name> <x> <y> [image.png]
#   devhub_swipe <simulator-name> <x1> <y1> <x2> <y2> [image.png]
#
# Coordinates are pixels of `image` (default: a fresh full-size simctl
# screenshot, i.e. device pixels). The helper raises the device window and
# clicks its title first — the first click on a non-key Device Hub window
# only focuses it.

# _devhub_frame <simulator-name> -> "x y w h tx ty": the device screen's
# frame on the Mac, plus the window title's centre (the focusing click).
_devhub_frame() {
  osascript - "$1" <<'APPLESCRIPT'
on run argv
  set devName to item 1 of argv
  tell application "System Events" to tell process "DeviceHub"
    set winName to missing value
    set winNames to name of every window
    repeat with candidate in winNames
      if (candidate as string) starts with devName then
        set winName to candidate as string
        exit repeat
      end if
    end repeat
    if winName is missing value then error "no Device Hub window for " & devName
    set w to window winName
    perform action "AXRaise" of w
    delay 0.6
    set g to my findContent(w, 0)
    if g is missing value then error "no iOSContentGroup in " & winName
    set p to position of g
    set s to size of g
    -- The title's centre too: a real click there focuses the window
    -- harmlessly (an AX click doesn't make it key).
    set tp to position of static text 1 of w
    set ts to size of static text 1 of w
    return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of s) as text) & " " & ((item 2 of s) as text) & " " & (((item 1 of tp) + (item 1 of ts) div 2) as text) & " " & (((item 2 of tp) + (item 2 of ts) div 2) as text)
  end tell
end run

on findContent(e, depth)
  tell application "System Events"
    try
      if subrole of e is "iOSContentGroup" then return e
    end try
    if depth > 8 then return missing value
    try
      repeat with c in UI elements of e
        set r to my findContent(c, depth + 1)
        if r is not missing value then return r
      end repeat
    end try
  end tell
  return missing value
end findContent
APPLESCRIPT
}

# _devhub_map <sim> <image-or-empty> <x> <y> -> "macX macY"
_devhub_map() {
  local sim=$1 image=$2 x=$3 y=$4 fx fy fw fh tx ty iw ih
  read fx fy fw fh tx ty < <(_devhub_frame "$sim") || return 1
  cliclick "c:$tx,$ty"; sleep 0.4
  if [[ -z $image ]]; then
    image=$HELPER_CACHE/devhub-probe.png
    xcrun simctl io "$sim" screenshot "$image" >/dev/null 2>&1 || return 1
  fi
  iw=$(sips -g pixelWidth "$image" | awk '/pixelWidth/{print $2}')
  ih=$(sips -g pixelHeight "$image" | awk '/pixelHeight/{print $2}')
  echo $(( fx + x * fw / iw )) $(( fy + y * fh / ih ))
}

devhub_tap() {
  local sim=$1 x=$2 y=$3 image=$4 mx my
  read mx my < <(_devhub_map "$sim" "$image" "$x" "$y") || return 1
  cliclick "m:$((mx-12)),$my" w:150 "m:$mx,$my" w:150 "c:$mx,$my"
}

devhub_swipe() {
  local sim=$1 x1=$2 y1=$3 x2=$4 y2=$5 image=$6 ax ay bx by
  read ax ay < <(_devhub_map "$sim" "$image" "$x1" "$y1") || return 1
  read bx by < <(_devhub_map "$sim" "$image" "$x2" "$y2") || return 1
  local mx=$(( (ax + bx) / 2 )) my=$(( (ay + by) / 2 ))
  cliclick "m:$ax,$ay" w:200 "dd:$ax,$ay" w:100 "m:$mx,$my" w:60 "m:$bx,$by" w:200 "du:$bx,$by"
}
