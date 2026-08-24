#!/bin/zsh
# The onboarding walkthrough recording (~52s), beats verified 2026-08-13.
#
# Precondition: MomentTally --demo FRESHLY relaunched (a fresh launch fully
# resets the walkthrough), welcome window up. This script clicks Continue,
# then records the 7-page drive. Run: captures/drivers/onboarding-motion.zsh [out.mov]
set -e
source "${0:a:h}/lib.zsh"
OUT=${1:-$REPO_ROOT/captures/raw/onboarding.mov}

frontmost; sleep 0.5
ax 'click UI element 2 of group 1 of window 1' >/dev/null   # welcome -> walkthrough
sleep 1.5
any_origin
read WW WH < <(ax 'get size of window 1' | tr -d ',')
[[ $WW == 700 ]] || echo "WARN: walkthrough window ${WW}pt wide (offsets assume 700)"

next() { rmove 651 558; sleep 0.25; rclick 651 558; sleep 1.2; }

drive() {
  sleep 1.5
  # p1 — live timer: open editor, add mood:focused, Done
  rmove 460 308; sleep 0.15; rmove 537 308; sleep 0.3; rclick 537 308; sleep 1.0   # pencil
  rapproach 165 323; sleep 0.8                                                     # + Add Mark
  rapproach 196 313; sleep 0.4; rtype "mood"; sleep 0.3                            # key (fields shift ~14pt after add)
  rapproach 407 313; sleep 0.4; rtype "focused"; sleep 1.0                         # value
  rapproach 548 375; sleep 1.2                                                     # Done
  next
  # p2 — Group by: project -> type
  sleep 2.0
  rmove 493 128; sleep 0.15; rapproach 493 160; menu_pick "type"; sleep 2.0
  next
  # p3 — static
  sleep 4.0
  next
  # p4 — corrupt Fused facts, heal (same point both states)
  sleep 1.5
  rapproach 194 359; sleep 2.5
  rclick 194 359; sleep 1.5
  next
  # p5 — quick chips (same-key chips swap, showing the one-per-key rule)
  sleep 1.5
  rmove 175 236; sleep 0.15; rapproach 175 297; sleep 1.0                          # +review
  rapproach 105 297; sleep 1.2                                                     # +planning (swaps in)
  next
  # p6 — open Freelance persona (body click; the ⊕ ignores synthetic clicks)
  sleep 1.2
  cliclick "m:$((WX-47)),$((WY+172))" w:150 "m:$((WX+73)),$((WY+172))" w:150 \
           "m:$((WX+187)),$((WY+172))" w:350 "c:$((WX+187)),$((WY+172))"; sleep 1.2
  rapproach 157 166; sleep 0.3; rtype "Client Rebrand"; sleep 1.3                # name field
  next
  # p7 — dwell to the end
  sleep 2; rmove 353 266
}

take "$OUT" 60 "$WX,$WY,700,592" drive
