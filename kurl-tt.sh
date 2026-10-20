#!/usr/bin/env bash
# kurl-tt -- record TikTok Live with curl, through the FLV hose
#
# by theMekanik & Ding Dong
#
# The story (short version; the long funny one is in TIKTOK.md):
#   TikTok Live has two doors. The HLS door hands its playlist to anyone,
#   then refuses every segment to every client we sent -- curl (404),
#   ffmpeg (skips segment after segment), even yt-dlp's own downloader.
#   The segments are guarded by the session they were issued to, and a
#   photocopy of the playlist makes you a stranger at that door.
#
#   The FLV door is a hose. One continuous stream, no playlist, no
#   segments, no rotating window -- nothing for a guard to stand in
#   front of. Once you hold the FLV address, plain curl drinks at full
#   stream rate.
#
# So kurl-tt appoints yt-dlp POWER OF ATTORNEY FOR THE ADDRESS ONLY:
# yt-dlp (in plain clothes: home IP, browser user-agent, the anonymous
# guest pass TikTok hands every visitor) asks the desk where the hose
# is. Then it goes home, and curl does the work -- in its own tongue,
# under its own name.
#
# Usage:
#   kurl-tt.sh --tiktok @handle        [-o out.flv] [--quality flv-hd]
#   kurl-tt.sh --tiktok https://www.tiktok.com/@handle/live
#
# Examples:
#   kurl-tt.sh --tiktok @somestreamer -o some-live.flv
#
# Behavior:
#   - Extracts the FLV URL via yt-dlp, then appends the stream to
#     <out>.part with curl --fail
#   - If the hose drops mid-stream, it re-extracts (fresh address) and
#     keeps appending -- the recording survives the hiccup
#   - When the live ends, extraction fails for good: the .part is
#     sealed to the final name and the script exits clean
#   - Restarting with the same -o keeps appending to the same .part --
#     unless the final file already exists, then it refuses (no
#     overwriting sealed recordings, ever)
#
# Output is a raw .flv stream copy. Remux when you're done:
#   ffmpeg -i out.flv -c copy out.mp4
#
# Requirements: bash, curl, coreutils -- and yt-dlp, summoned once per
# extraction for directory assistance. The one heavy friend on retainer.
# It never touches the stream itself. That's the point.
#
# Released under [ soaꓘKontrolled TS ] -- Forking Required / Lockdown
# Forbidden. See LICENSE.md.

set -u

SOURCE="" ; OUT="" ; QUALITY="flv-hd" ; MAXDROPS=10

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tiktok)  SOURCE="$2"; shift 2 ;;
    -o|--out)  OUT="$2"; shift 2 ;;
    --quality) QUALITY="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "kurl-tt: unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "$SOURCE" ] || { echo "kurl-tt: --tiktok @handle or live URL required" >&2; usage 1; }
command -v curl    >/dev/null 2>&1 || { echo "kurl-tt: curl not found" >&2; exit 1; }
command -v yt-dlp >/dev/null 2>&1 || { echo "kurl-tt: yt-dlp not found -- the attorney must be on retainer (extraction only)" >&2; exit 1; }

# Resolve the live page URL
case "$SOURCE" in
  http://*|https://*) LIVE="$SOURCE" ;;
  @*)                 LIVE="https://www.tiktok.com/$SOURCE/live" ;;
  *)                  LIVE="https://www.tiktok.com/@$SOURCE/live" ;;
esac

# Default output name from the handle when -o is not given
if [ -z "$OUT" ]; then
  NAME="$(printf '%s' "$SOURCE" | sed 's|.*/||; s|^@||')"
  OUT="tiktok-${NAME}-$(date +%Y%m%d-%H%M%S).flv"
fi
PART="$OUT.part"

[ -e "$OUT" ] && { echo "kurl-tt: $OUT already exists (sealed). Refusing to overwrite." >&2; exit 1; }

extract() { yt-dlp --no-warnings -f "$QUALITY" -g "$LIVE" 2>/dev/null; }

echo "kurl-tt: $LIVE"
echo "kurl-tt: recording -> $PART (quality $QUALITY)"

DROPS=0 ; MISS=0
while : ; do
  URL="$(extract)"
  if [ -z "$URL" ]; then
    MISS=$((MISS+1))
    if [ "$MISS" -ge 3 ]; then
      echo "kurl-tt: no stream address after $MISS tries -- the live is over."
      break
    fi
    sleep 10 ; continue
  fi
  MISS=0
  echo "kurl-tt: hose connected ($(printf '%s' "$URL" | sed 's|https://||; s|/.*||'))"
  curl -s --fail "$URL" >> "$PART"
  DROPS=$((DROPS+1))
  SIZE="$(stat -c%s "$PART" 2>/dev/null || stat -f%z "$PART")"
  echo "kurl-tt: hose dropped (drop $DROPS, $SIZE bytes banked). Re-asking the desk..."
  [ "$DROPS" -ge "$MAXDROPS" ] && { echo "kurl-tt: too many drops -- sealing what we have."; break; }
  sleep 5
done

if [ -s "$PART" ]; then
  mv "$PART" "$OUT"
  SIZE="$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")"
  echo "kurl-tt: sealed -> $OUT ($SIZE bytes)"
  echo "kurl-tt: remux with: ffmpeg -i \"$OUT\" -c copy \"${OUT%.flv}.mp4\""
else
  rm -f "$PART"
  echo "kurl-tt: nothing was recorded."
  exit 1
fi
