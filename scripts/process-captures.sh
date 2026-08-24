#!/usr/bin/env bash
# Process raw captures (captures/raw/) into distributable renditions in
# captures/out/, per the outputs table in captures/shots.yaml. Idempotent —
# every present raw file is (re)processed; missing ones are listed and
# skipped so partial re-capture batches work.
#
# Deps: brew install yq jq ffmpeg webp
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHOTS="$ROOT/captures/shots.yaml"
RAW="$ROOT/captures/raw"
OUT="$ROOT/captures/out"

for tool in yq jq ffmpeg cwebp; do
    command -v "$tool" >/dev/null \
        || { echo "error: '$tool' not found (brew install yq jq ffmpeg webp)" >&2; exit 1; }
done
[[ -d "$RAW" ]] || { echo "error: $RAW does not exist — capture first (/capture skill)" >&2; exit 1; }
mkdir -p "$OUT"

# One |-delimited line per output: id|kind|to|path|format|width|fps|theme.
# NOT @tsv: tab is IFS whitespace, so `read` collapses runs of tabs and an
# empty width/fps would shift `theme` into the wrong variable (shipped dark
# captures as -light renditions until 2026-08-24). A non-whitespace IFS
# preserves empty fields.
outputs() {
    yq -o=json '.' "$SHOTS" | jq -r '
        .shots[] | . as $s | .outputs[] |
        [$s.id, $s.kind, .to, .path, .format,
         (.width // "" | tostring), (.fps // "" | tostring), (.theme // "")] | join("|")'
}

missing=()
while IFS='|' read -r id kind to path format width fps theme; do
    ext=png; [[ "$kind" == recording ]] && ext=mov
    # theme: light renditions come from the <id>-light raw; default is dark.
    raw="$RAW/$id${theme:+-$theme}.$ext"
    if [[ ! -f "$raw" ]]; then
        missing+=("$(basename "$raw")")
        continue
    fi
    # Staged filenames are destination-prefixed: readme label-review.png and
    # appstore label-review.png are different renditions of the same shot.
    dst="$OUT/$to-$(basename "$path")"
    if [[ "$to" == appstore ]]; then
        # Mac App Store screenshots must be exactly 16:10 (2880×1800 here),
        # flattened RGB. Fit the capture into a 90% box and overlay it — alpha
        # intact, so the window shadow lands softly — on a canvas matching the
        # rendition's theme: charcoal for dark, the website's light surface
        # grey for theme:light.
        canvas=0x17151a; [[ "$theme" == light ]] && canvas=0xf5f5f7
        ffmpeg -nostdin -v error -y \
            -f lavfi -i "color=c=$canvas:s=2880x1800" -i "$raw" \
            -filter_complex "[1]scale=2592:1620:force_original_aspect_ratio=decrease:flags=lanczos[fg];[0][fg]overlay=(W-w)/2:(H-h)/2:format=auto,format=rgb24" \
            -frames:v 1 -update 1 "$dst"
        echo "  $id → $(basename "$dst")"
        continue
    fi
    case "$format" in
        png)
            cp "$raw" "$dst" ;;
        webp)
            cwebp -quiet -q 90 -metadata none "$raw" -o "$dst" ;;
        gif)
            # Two-pass palette for legible UI text at GIF's 256 colors.
            # -nostdin: ffmpeg must not eat the while-loop's input stream.
            ffmpeg -nostdin -v error -y -i "$raw" \
                -vf "fps=${fps:-12},scale=${width:?gif needs width}:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
                "$dst" ;;
        mp4)
            # -2: keep height even for yuv420p; -an: captures carry no audio.
            ffmpeg -nostdin -v error -y -i "$raw" \
                -vf "scale=${width:?mp4 needs width}:-2:flags=lanczos" \
                -c:v libx264 -crf 20 -preset slow -pix_fmt yuv420p \
                -movflags +faststart -an "$dst" ;;
        *)  echo "error: unknown format '$format' for shot '$id'" >&2; exit 1 ;;
    esac
    echo "  $id → $(basename "$dst")"
done < <(outputs)

if (( ${#missing[@]} )); then
    printf 'skipped (no raw capture): %s\n' "$(printf '%s ' "${missing[@]}" | tr ' ' '\n' | sort -u | paste -sd' ' -)" >&2
fi
echo "==> renditions in $OUT"
