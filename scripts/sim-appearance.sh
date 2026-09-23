#!/usr/bin/env bash
# Match simulators to the Mac's appearance: dark when macOS is in Dark Mode,
# light otherwise — so a demo launched from a dark desktop comes up dark like
# the Mac app beside it. Pass device names/UDIDs, or nothing for every booted
# device. MT_SIM_APPEARANCE=dark|light overrides the host reading.
set -euo pipefail

mode="${MT_SIM_APPEARANCE:-}"
if [[ -z "$mode" ]]; then
  # The key is absent (not "Light") in light mode, hence the fallback.
  mode="$(defaults read -g AppleInterfaceStyle 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  mode="${mode:-light}"
fi

if [[ $# -eq 0 ]]; then
  set -- $(xcrun simctl list devices booted -j | python3 -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs: print(d["udid"])')
fi

for device in "$@"; do
  xcrun simctl ui "$device" appearance "$mode"
done
echo "Simulator appearance: $mode ($# device(s))"
