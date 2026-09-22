#!/usr/bin/env bash
# The device layout matrix (#269), PolyPane-style: boot one simulator per form
# factor and tile a DeviceHub window for each across the main display, so a
# UI change is seen on every size class at once.
#
# Xcode 27 replaced Simulator.app with Device Hub (Xcode.app/Contents/
# Applications/DeviceHub.app): one tabbed window shows one device at a time,
# and selecting a sidebar row *switches* the tab rather than opening another,
# so a side-by-side view is one window per device (File › New Window, pick
# the device, hide the sidebar) — which is exactly what this script drives
# through System Events. DeviceHub has no scripting dictionary and its
# devices:// URL scheme does not open a device, hence AX.
#
# Devices: MT_MATRIX overrides the default trio, separated by "|". The iPad
# mini stands in for the unfolded iPhone Duo until Xcode ships a Duo device
# type (none in 27.0 — `xcrun simctl list devicetypes`); the folded Duo is
# a normal iPhone. A device missing from the simulator set is created from
# the device type of the same name on the newest iOS runtime.
#
# Requires: full Xcode (DeviceHub), Accessibility permission for the
# terminal (the same grant the Mac AX verify flow uses).
set -euo pipefail

IFS='|' read -r -a DEVICES <<< "${MT_MATRIX:-iPhone 17 Pro|iPad mini (A17 Pro)|iPad Pro 11-inch (M5)}"
DEVICEHUB="$(xcode-select -p)/../Applications/DeviceHub.app"
[[ -d "$DEVICEHUB" ]] || { echo "DeviceHub.app not found under $(xcode-select -p) — is xcode-select pointing at Xcode 27+?" >&2; exit 1; }

runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
rts.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rts[-1]["identifier"])')"

udid_for() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name:
            print(d["udid"]); sys.exit()
' "$1"
}

for name in "${DEVICES[@]}"; do
  udid="$(udid_for "$name")"
  if [[ -z "$udid" ]]; then
    type="$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
for t in json.load(sys.stdin)["devicetypes"]:
    if t["name"] == sys.argv[1]:
        print(t["identifier"]); break
' "$name")"
    [[ -n "$type" ]] || { echo "No simulator or device type named \"$name\"" >&2; exit 1; }
    udid="$(xcrun simctl create "$name" "$type" "$runtime")"
    echo "Created $name ($udid)"
  fi
  # boot is not idempotent: an already-booted device is an error we ignore.
  if ! xcrun simctl boot "$udid" 2>/dev/null; then
    xcrun simctl list devices | grep -q "$udid.*Booted" || { echo "Could not boot $name" >&2; exit 1; }
  fi
  echo "Booted $name ($udid)"
done

open -a "$DEVICEHUB"
# Give the hub its first window before driving it.
for _ in $(seq 1 20); do
  osascript -e 'tell application "System Events" to tell process "DeviceHub" to return count of windows' 2>/dev/null | grep -qv '^0$' && break
  sleep 0.5
done

# One window per device, tiled left to right across the main display. An
# existing window already showing the device is reused (re-runs re-tile).
osascript - "${DEVICES[@]}" <<'EOF'
on run devices
  tell application "Finder" to set {x0, y0, x1, y1} to bounds of window of desktop
  set y0 to y0 + 25 -- menu bar
  -- Keep clear of the Dock (Finder's desktop bounds include it).
  set dockSide to "bottom"
  try
    set dockSide to do shell script "defaults read com.apple.dock orientation"
  end try
  tell application "System Events" to tell process "Dock" to set {dockW, dockH} to size of list 1
  if dockSide is "left" then
    set x0 to x0 + dockW
  else if dockSide is "right" then
    set x1 to x1 - dockW
  else
    set y1 to y1 - dockH
  end if
  set n to count of devices
  set colWidth to (x1 - x0) div n
  tell application "System Events" to tell process "DeviceHub"
    set frontmost to true
    repeat with i from 1 to n
      set devName to item i of devices
      -- Windows are addressed by name throughout: System Events' window
      -- references are index-based, and raising a window reorders the
      -- indices under a reference held across the raise.
      set winName to missing value
      set winNames to name of every window
      repeat with candidate in winNames
        if (candidate as string) starts with devName then
          set winName to candidate as string
          exit repeat
        end if
      end repeat
      if winName is missing value then
        click menu item "New Window" of menu 1 of menu bar item "File" of menu bar 1
        delay 1.5
        perform action "AXRaise" of window 1
        -- A new window inherits the previous one's device and sidebar state;
        -- the sidebar has to be visible to pick the device from it.
        if exists menu item "Show Sidebar" of menu 1 of menu bar item "View" of menu bar 1 then
          click menu item "Show Sidebar" of menu 1 of menu bar item "View" of menu bar 1
          delay 0.5
        end if
        -- The sidebar outline: pick the row whose title is the device.
        set ol to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of splitter group 1 of group 1 of window 1
        set found to false
        repeat with r in rows of ol
          try
            if value of static text 1 of UI element 1 of r is devName then
              select r
              set found to true
              exit repeat
            end if
          end try
        end repeat
        if not found then error "DeviceHub sidebar has no row named " & devName
        delay 1.5
        set winName to name of window 1
      end if
      perform action "AXRaise" of window winName
      delay 0.8
      -- Sidebar state is per window; the menu title says which way it
      -- toggles, and it lags the raise, so check again after a beat.
      repeat 3 times
        if exists menu item "Hide Sidebar" of menu 1 of menu bar item "View" of menu bar 1 then
          click menu item "Hide Sidebar" of menu 1 of menu bar item "View" of menu bar 1
          delay 0.5
          exit repeat
        end if
        delay 0.5
      end repeat
      set position of window winName to {x0 + (i - 1) * colWidth, y0}
      set size of window winName to {colWidth, y1 - y0}
      delay 0.3
      click menu item "Zoom to Fit" of menu 1 of menu bar item "View" of menu bar 1
    end repeat
  end tell
end run
EOF
echo "Tiled ${#DEVICES[@]} DeviceHub windows."
