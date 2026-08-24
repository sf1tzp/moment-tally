# Shared helpers for the capture drivers. Source from a zsh script:
#   source "${0:a:h}/lib.zsh"
#
# All click points are window-origin-relative offsets rehearsed on 2026-08-13
# (SwiftUI point layout — stable across displays; origins resolved at runtime).
# Requires: cliclick, ffmpeg/ffprobe, swiftc (helpers compiled on demand).

APP=${APP:-MomentTally}
TERM_APP=${TERM_APP:-Alacritty}
DRIVERS_DIR=${0:a:h}
REPO_ROOT=${DRIVERS_DIR:h:h}
HELPER_CACHE=${CAPTURE_TMP:-/tmp/capture-helpers}
mkdir -p "$HELPER_CACHE"

ax() { osascript -e "tell application \"System Events\" to tell process \"$APP\" to $1"; }
sys() { osascript -e "tell application \"System Events\" to $1"; }
frontmost() { sys "set frontmost of process \"$APP\" to true"; }
key_return() { sys 'key code 36'; }
key_escape() { sys 'key code 53'; }
hide_term() { sys "set visible of process \"$TERM_APP\" to false"; }
show_term() { sys "set visible of process \"$TERM_APP\" to true"; }

# Compile-on-demand Swift helpers vendored in .claude/skills/shared/.
helper() { # helper <name> -> echoes binary path
  local src="$REPO_ROOT/.claude/skills/shared/$1.swift" bin="$HELPER_CACHE/$1"
  [[ -x $bin && $bin -nt $src ]] || swiftc -O "$src" -o "$bin" || return 1
  echo "$bin"
}

# winid <window-title-or-empty> -> CGWindowID of $APP's window ("" = popover)
winid() {
  "$(helper winlist)" "$APP" | awk -F'|' -v t="$1" '$3==t {print $1; exit}'
}

# Resolve a window origin into WX/WY. main_origin = the "Moment Tally" window;
# any_origin = window 1 (onboarding/popover — whatever is frontmost-only).
main_origin() { read WX WY < <(ax 'get position of window "Moment Tally"' | tr -d ',' ) }
any_origin()  { read WX WY < <(ax 'get position of window 1' | tr -d ',') }

# Relative pointer verbs (offsets from $WX/$WY). rmove takes m: pairs.
rclick() { cliclick "c:$((WX+$1)),$((WY+$2))"; }
rmove()  { cliclick "m:$((WX+$1)),$((WY+$2))"; }
rapproach() { # rapproach <dx> <dy> — real moves onto the point, then click
  cliclick "m:$((WX+$1-60)),$((WY+$2))" w:150 "m:$((WX+$1)),$((WY+$2))" w:250 "c:$((WX+$1)),$((WY+$2))"
}
rtype() { cliclick -w 85 "t:$1"; }

# Menu type-select on an already-open NSMenu (longest-name wins prefix races).
menu_pick() { sleep 0.6; cliclick -w 100 "t:$1"; sleep 0.3; key_return; }

# Popover driving (shared by stills.zsh and popover-motion.zsh). The popover
# resolves as window 1 while open, even with the main window on screen.
toggle_popover() { ax 'click menu bar item 1 of menu bar 2' >/dev/null; sleep 1.2; }

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

# stop_all_timers — opens the popover, clicks every Stop button (help "Stop"),
# closes it again. A running tally dims its launcher card, so still batches
# that show the launcher want an idle state.
stop_all_timers() {
  toggle_popover
  local p
  while p=$(help_point "Stop" | tr -d ' '); [[ -n $p ]]; do
    cliclick "c:$((${p%,*}+8)),$((${p#*,}+8))"; sleep 1
  done
  toggle_popover
}

# still <out.png> <window-title-or-empty> — window-ID capture (native shadow).
still() {
  local id; id=$(winid "$2")
  [[ -n $id ]] || { echo "still: no window '$2'" >&2; return 1; }
  screencapture -x -l "$id" "$1"
}

# Guard: refuse to capture on a 1x display (the 2026-08-13 trap). A 2x check
# is cheap: window-ID still of the main window must be ~2x its point size.
assert_2x() {
  system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Screen Sharing Virtual Display" && {
    echo "BLOCKED: Screen Sharing virtual display (1x). Aborting." >&2; return 1; }
  local probe=$HELPER_CACHE/scale-probe.png w
  still "$probe" "Moment Tally" || return 1
  w=$(sips -g pixelWidth "$probe" | awk '/pixelWidth/{print $2}')
  (( w > 1500 )) || { echo "BLOCKED: still probe ${w}px wide — display is not 2x." >&2; return 1; }
}

# take <out.mov> <cap-seconds> <x,y,w,h in points> <driver-fn-or-script>
# Records via ffmpeg/avfoundation (full display, cropped to the region at the
# display scale). screencapture -v is NOT used: it wedges permanently on
# main-window takes after an appearance flip (2026-08-13, both displays —
# hangs in mach_msg past -V, no file; see ax-driving.md).
take() {
  local out=$1 cap=$2 region=$3 driver=$4 dur
  local rx=${region%%,*} rest=${region#*,}
  local ry=${rest%%,*}; rest=${rest#*,}
  local rw=${rest%%,*} rh=${rest##*,}
  # display scale: capture px width / UI point width of the main display
  local cap_w pt_w scale
  pt_w=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F'like: ' '/UI Looks like/{split($2,a," "); print a[1]; exit}')
  cap_w=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution:/{split($2,a," "); print a[1]; exit}')
  scale=$(( cap_w / pt_w ))
  rm -f "$out"
  hide_term; frontmost; sleep 1
  ( "$driver" ) &
  ffmpeg -v error -f avfoundation -capture_cursor 1 -framerate 30 \
    -pixel_format nv12 -i "Capture screen 0:none" -t "$cap" \
    -vf "crop=$((rw*scale)):$((rh*scale)):$((rx*scale)):$((ry*scale))" \
    -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -movflags +faststart \
    -y "$out"
  show_term
  wait
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" 2>/dev/null)
  echo "take: $out duration=${dur:-MISSING} (cap $cap, scale ${scale}x)"
  [[ -n $dur ]]
}
