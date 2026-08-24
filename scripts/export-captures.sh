#!/usr/bin/env bash
# Export processed renditions (captures/out/) into their consumer repos and
# stamp provenance manifests. Destinations come from captures/shots.yaml:
#   to: readme   → this repo (run the pipeline from a moment-tally worktree
#                  branch, so these exports land on that branch)
#   to: website  → $1 if given (used as-is: tests, one-offs); otherwise a
#                  dated worktree of the website checkout
#                  (~/worktrees/moment-tally-website/captures-<date>, branched
#                  from origin/main) — the primary checkout
#                  ($MOMENTTALLY_WEBSITE_DIR, default ~/moment-tally-website) is
#                  never written to directly, per the worktree-PR convention
#   to: appstore → this repo (captures/appstore/) — hand-uploaded to App
#                  Store Connect, committed for provenance like readme assets
#
# Manifests record what build the batch came from: captures/manifest.json
# here (release.sh compares UI changes against its commit) and
# static/screenshots/manifest.json in the website repo. Only shots whose
# renditions are present get exported and listed; a partial batch keeps the
# previous manifest's commit untouched shots can't vouch for, so the manifest
# is only rewritten when every shot in shots.yaml exported ("complete" batch)
# — partial exports update the files but warn and leave manifests alone.
#
# Deps: brew install yq jq
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOTS="$ROOT/captures/shots.yaml"
OUT="$ROOT/captures/out"
for tool in yq jq; do
    command -v "$tool" >/dev/null \
        || { echo "error: '$tool' not found (brew install yq jq)" >&2; exit 1; }
done
[[ -d "$OUT" ]] || { echo "error: $OUT does not exist — run 'just process-captures' first" >&2; exit 1; }

if [[ $# -ge 1 ]]; then
    WEBSITE="$1"
else
    REPO="${MOMENTTALLY_WEBSITE_DIR:-$HOME/moment-tally-website}"
    [[ -e "$REPO/.git" ]] \
        || { echo "error: '$REPO' is not a git checkout (set MOMENTTALLY_WEBSITE_DIR)" >&2; exit 1; }
    # Local date, not UTC: the capture worktree convention (captures-<date>)
    # uses local dates, and a UTC evening rollover otherwise splits the pair
    # into two differently-dated worktrees.
    BRANCH="captures-$(date +%F)"
    WEBSITE="$HOME/worktrees/moment-tally-website/$BRANCH"
    if [[ ! -e "$WEBSITE/.git" ]]; then
        git -C "$REPO" fetch origin
        if git -C "$REPO" show-ref --verify -q "refs/heads/$BRANCH"; then
            git -C "$REPO" worktree add "$WEBSITE" "$BRANCH"
        else
            git -C "$REPO" worktree add "$WEBSITE" -b "$BRANCH" origin/main
        fi
    fi
fi
# .git is a file in worktrees, a directory in primary checkouts — test both.
[[ -e "$WEBSITE/.git" && -d "$WEBSITE/static/screenshots" ]] \
    || { echo "error: '$WEBSITE' is not a moment-tally-website checkout" >&2; exit 1; }

SHOTS_JSON="$(yq -o=json '.' "$SHOTS")"

exported=()   # shot ids fully exported
partial=0
while IFS=$'\t' read -r id path to; do
    # Staged filenames are destination-prefixed (see process-captures.sh).
    src="$OUT/$to-$(basename "$path")"
    [[ -f "$src" ]] || { partial=1; continue; }
    # A shot counts as exported only if ALL its renditions are present.
    for p in $(jq -r --arg id "$id" \
            '.shots[] | select(.id==$id) | .outputs[] | .to + "|" + .path' <<<"$SHOTS_JSON"); do
        [[ -f "$OUT/${p%%|*}-$(basename "${p#*|}")" ]] || continue 2
    done
    case "$to" in
        readme|appstore) dest="$ROOT/$path" ;;
        website)         dest="$WEBSITE/$path" ;;
        *)  echo "error: unknown destination for $id → $path" >&2; exit 1 ;;
    esac
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "  $(basename "$src") → $dest"
    exported+=("$id")
done < <(jq -r '.shots[] | . as $s | .outputs[] | [$s.id, .path, .to] | @tsv' <<<"$SHOTS_JSON")

(( ${#exported[@]} )) || { echo "error: nothing to export — captures/out/ has no renditions" >&2; exit 1; }
ids="$(printf '%s\n' "${exported[@]}" | awk '!seen[$0]++')"

all="$(jq -r '.shots[].id' <<<"$SHOTS_JSON")"
if (( partial )) || [[ "$ids" != "$all" ]]; then
    echo "note: partial batch ($(wc -l <<<"$ids" | tr -d ' ')/$(wc -l <<<"$all" | tr -d ' ') shots) — manifests left untouched" >&2
    exit 0
fi

MANIFEST="$(jq -n \
    --arg commit "$(git -C "$ROOT" rev-parse HEAD)" \
    --arg describe "$(git -C "$ROOT" describe --tags --always)" \
    --arg captured "$(date -u +%F)" \
    --arg host "$(hostname -s)" \
    --argjson shots "$(jq -Rn '[inputs]' <<<"$ids")" \
    '{commit: $commit, describe: $describe, captured: $captured, host: $host, shots: $shots}')"
echo "$MANIFEST" > "$ROOT/captures/manifest.json"
echo "$MANIFEST" > "$WEBSITE/static/screenshots/manifest.json"
echo "==> manifests stamped ($(git -C "$ROOT" describe --tags --always) @ $(hostname -s))"
echo "==> review the visual diffs, then commit here and in $WEBSITE and open the companion PRs"
