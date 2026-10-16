#!/usr/bin/env bash
# kurl-rec -- a tiny, curl-only HLS live-stream recorder
#
# by theMekanik & Ding Dong
#
# Why this exists: the standard recorders (ffmpeg, yt-dlp, streamlink) pull
# playlists and segments with heavy HTTP stacks that some proxies, locked-down
# networks, and minimal containers quietly mangle -- reads truncate, streams
# die, recordings stop. curl's reads stay clean on those same roads. kurl-rec
# is the fallback that keeps recording: bash + curl + coreutils, nothing else
# to install, nothing else to break.
#
# How it works:
#   - Polls the media playlist every --poll seconds (default 3)
#   - Downloads each new segment to a temp file and appends it to the output
#     ONLY on success -- a failed segment can never truncate the recording
#   - Remembers seen segment URLs, so restarts and hiccups never duplicate
#   - Twitch mode: resolves its own signed playback token and RE-RESOLVES it
#     after repeated playlist failures -- when the session dies, it asks for
#     a new key instead of quitting
#   - Exits cleanly when the playlist carries #EXT-X-ENDLIST
#
# Usage:
#   kurl-rec.sh --url URL       [-o out.ts] [--variant N] [--poll SEC]
#   kurl-rec.sh --twitch NAME   [-o out.ts] [--quality NAME] [--poll SEC]
#   kurl-rec.sh --kick NAME     [-o out.ts] [--poll SEC]
#
# Examples:
#   kurl-rec.sh --url https://example.com/live/index.m3u8 -o show.ts
#   kurl-rec.sh --twitch somestreamer -o stream.ts
#   kurl-rec.sh --kick somestreamer -o stream.ts
#
# The engine records ANY HLS stream you can hand it a playable playlist
# URL for. Built-in resolvers: Twitch, Kick. YouTube Live and TikTok Live
# work in --url mode with a manifest URL extracted by other tools (their
# URLs hide behind signed page/API responses). Instagram Live is
# login-walled and not supported.
#
# Output is a raw .ts (MPEG-TS) stream copy. Remux when you're done:
#   ffmpeg -i out.ts -c copy out.mp4
#
# Released under [ soaꓘKontrolled TS ] -- Forking Required / Lockdown Forbidden.
# See LICENSE.md.

set -u

TWITCH_CLIENT_ID="kimne78kx3ncx6brgo4mv6wki5h1ko"  # Twitch's public web client id

MODE="" ; SOURCE="" ; OUT="" ; QUALITY="chunked" ; VARIANT=0 ; POLL=3

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --url)     MODE="url";    SOURCE="$2"; shift 2 ;;
    --twitch)  MODE="twitch"; SOURCE="$2"; shift 2 ;;
    --kick)    MODE="kick";   SOURCE="$2"; shift 2 ;;
    -o|--out)  OUT="$2"; shift 2 ;;
    --quality) QUALITY="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --poll)    POLL="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "kurl-rec: unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "$MODE" ] || usage 1
command -v curl >/dev/null || { echo "kurl-rec: curl is required" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT" ] || OUT="kurl-rec-$STAMP.ts"
WORKDIR="${OUT}.kurlparts"
mkdir -p "$WORKDIR"
SEEN="$WORKDIR/seen.txt"; touch "$SEEN"
UA="Mozilla/5.0 (kurl-rec)"

log() { echo "[kurl-rec $(date +%H:%M:%S)] $*"; }

resolve_twitch() {
  # Ask Twitch for a playback token, then build the usher master URL.
  local resp sig val master varurl
  resp="$(curl -s -X POST 'https://gql.twitch.tv/gql' \
    -H "Client-Id: $TWITCH_CLIENT_ID" -H "User-Agent: $UA" \
    -d "{\"operationName\":\"PlaybackAccessToken_Template\",\"query\":\"query PlaybackAccessToken_Template(\\$login: String!, \\$isLive: Boolean!, \\$vodID: ID!, \\$isVod: Boolean!, \\$playerType: String!) { streamPlaybackAccessToken(channel: \\$login, params: {platform: \\\"web\\\", playerBackend: \\\"mediaplayer\\\", playerType: \\$playerType}) @include(if: \\$isLive) { value signature __typename } }\",\"variables\":{\"isLive\":true,\"login\":\"$SOURCE\",\"isVod\":false,\"vodID\":\"\",\"playerType\":\"site\"}}")" || return 1
  if command -v python3 >/dev/null; then
    read -r sig val <<EOF
$(printf '%s' "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); t=d["data"]["streamPlaybackAccessToken"]; print(t["signature"], t["value"])' 2>/dev/null)
EOF
  fi
  if [ -z "${sig:-}" ] || [ -z "${val:-}" ]; then
    sig="$(printf '%s' "$resp" | grep -o '"signature":"[^"]*"' | head -1 | cut -d'"' -f4)"
    val="$(printf '%s' "$resp" | sed -n 's/.*"value":"\(.*\)","__typename".*/\1/p' | head -1 | sed 's/\\"/"/g; s/\\\\/\\/g')"
  fi
  [ -n "$sig" ] && [ -n "$val" ] || return 1
  master="$(curl -s -G 'https://usher.ttvnw.net/api/channel/hls/'"$SOURCE"'.m3u8' \
    --data-urlencode "token=$val" -d "sig=$sig" -d 'allow_source=true' \
    -H "User-Agent: $UA")" || return 1
  varurl="$(printf '%s\n' "$master" | grep -A1 "NAME=\"$QUALITY\"" | grep '^http' | head -1)"
  [ -n "$varurl" ] || varurl="$(printf '%s\n' "$master" | grep '^http' | head -1)"
  [ -n "$varurl" ] || return 1
  printf '%s' "$varurl"
}

resolve_kick() {
  # Kick plays over IVS HLS; the master URL is constructible from the
  # channel name. The generic master/variant logic takes it from there.
  SOURCE="https://fa723fc1b171.us-west-2.playback.live-video.net/api/channel/hls/$SOURCE/master.m3u8"
  MODE="url"
  resolve_url
}

resolve_url() {
  # If SOURCE is a master playlist, pick variant N; if it's already a media
  # playlist, use it as-is.
  local master varurl
  master="$(curl -s -H "User-Agent: $UA" "$SOURCE")" || return 1
  if printf '%s' "$master" | grep -q 'EXT-X-STREAM-INF'; then
    varurl="$(printf '%s\n' "$master" | grep '^http' | sed -n "$((VARIANT+1))p")"
    if [ -z "$varurl" ]; then
      # relative variant paths: resolve against the master URL's directory
      local rel base
      rel="$(printf '%s\n' "$master" | grep -v '^#' | grep -v '^$' | sed -n "$((VARIANT+1))p")"
      base="${SOURCE%/*}/"
      varurl="${base}${rel}"
    fi
    [ -n "$varurl" ] || return 1
    printf '%s' "$varurl"
  else
    printf '%s' "$SOURCE"
  fi
}

MEDIA=""
resolve() {
  case "$MODE" in
    twitch) MEDIA="$(resolve_twitch)" ;;
    kick)   MEDIA="$(resolve_kick)" ;;
    *)      MEDIA="$(resolve_url)" ;;
  esac
  [ -n "$MEDIA" ]
}

log "resolving stream..."
until resolve; do log "resolve failed; retrying in 10s"; sleep 10; done
log "media playlist: $MEDIA"
log "recording -> $OUT  (poll ${POLL}s)"

FAILS=0
while true; do
  PL="$(curl -s --max-time 15 -H "User-Agent: $UA" "$MEDIA")" || PL=""
  if [ -z "$PL" ]; then
    FAILS=$((FAILS+1))
    if [ "$MODE" = "twitch" ] && [ "$FAILS" -ge 8 ]; then
      log "playlist failing -- re-resolving token"
      resolve && { log "re-resolved: $MEDIA"; FAILS=0; }
    fi
    sleep "$POLL"; continue
  fi
  FAILS=0
  BASE="${MEDIA%/*}/"
  NEW=0
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      http*) SEG="$line" ;;
      //*)   SEG="https:$line" ;;
      /*)    SEG="$(printf '%s' "$MEDIA" | cut -d/ -f1-3)$line" ;;
      *)     SEG="${BASE}${line}" ;;
    esac
    if ! grep -qxF "$SEG" "$SEEN"; then
      TMP="$WORKDIR/seg.tmp"
      if curl -s --max-time 30 -H "User-Agent: $UA" -o "$TMP" "$SEG" && [ -s "$TMP" ]; then
        cat "$TMP" >> "$OUT"
        echo "$SEG" >> "$SEEN"
        NEW=$((NEW+1))
      fi
      rm -f "$TMP"
    fi
  done <<EOF
$(printf '%s\n' "$PL" | grep -v '^#' | grep -v '^$')
EOF
  [ "$NEW" -gt 0 ] && log "+$NEW segments  ($(stat -c%s "$OUT" 2>/dev/null || echo 0) bytes)"
  if printf '%s' "$PL" | grep -q 'EXT-X-ENDLIST'; then
    log "ENDLIST -- stream ended. Final size: $(stat -c%s "$OUT" 2>/dev/null || echo 0) bytes -> $OUT"
    exit 0
  fi
  sleep "$POLL"
done
