#!/usr/bin/env bash
# kurl-dash -- a tiny, curl-only DASH live-stream recorder
#
# by theMekanik & Ding Dong
#
# The sibling of kurl-rec.sh (HLS). Same doctrine, different manifest:
#   - Polls the MPD every --poll seconds (default 3)
#   - Downloads each segment to a temp file and appends it ONLY on success --
#     a failed segment can never truncate the recording
#   - Remembers seen segments, so restarts and hiccups never duplicate
#   - Keeps retrying when the manifest fetch fails -- live streams wobble,
#     the recorder doesn't quit
#   - Dependencies: bash + curl + coreutils. No ffmpeg, no node, no pip.
#
# Supported MPD shapes (the common ones):
#   - SegmentTemplate with $Number$ (fixed-duration or SegmentTimeline)
#   - SegmentTemplate with $Time$ (SegmentTimeline)
#   - SegmentList with explicit segment URLs
#   - One video + one audio adaptation set (highest-bandwidth video wins)
#
# Output: two fragmented-MP4 files, <out>-video.mp4 and <out>-audio.mp4
# (init segment + media segments, directly playable). Mux when done:
#   ffmpeg -i <out>-video.mp4 -i <out>-audio.mp4 -c copy <out>.mp4
#
# Usage:
#   kurl-dash.sh --url MPD_URL [-o outbase] [--poll SEC] [--lag N]
#                [--max-segments N] [--idle-exit SEC]
#
# Why DASH matters: some platforms serve their live streams as DASH rather
# than HLS -- Instagram Live among them (reachable with an authenticated
# session: the signed-in client is handed the MPD URL, and this recorder
# takes it from there).
#
# Released under [ soaꓘKontrolled TS ] -- Forking Required / Lockdown Forbidden.
# See LICENSE.md.

set -u

MPD_URL="" ; OUTBASE="" ; POLL=3 ; LAG=2 ; MAXSEG=0 ; IDLE_EXIT=0

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --url) MPD_URL="$2"; shift 2 ;;
    -o|--out) OUTBASE="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    --lag) LAG="$2"; shift 2 ;;
    --max-segments) MAXSEG="$2"; shift 2 ;;
    --idle-exit) IDLE_EXIT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "kurl-dash: unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "$MPD_URL" ] || usage 1
command -v curl >/dev/null || { echo "kurl-dash: curl is required" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUTBASE" ] || OUTBASE="kurl-dash-$STAMP"
WORKDIR="${OUTBASE}.kurlparts"
mkdir -p "$WORKDIR"
UA="Mozilla/5.0 (kurl-dash)"
BASE="${MPD_URL%/*}/"

log() { echo "[kurl-dash $(date +%H:%M:%S)] $*"; }
attr() { # attr NAME -- reads tag text on stdin
  sed -n "s/.* $1=\"\([^\"]*\)\".*/\1/p" | head -1
}
iso2epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }
iso_dur2secs() { # ISO8601 duration PT#H#M#S -> integer seconds (bash only)
  local d="$1" h=0 m=0 s=0
  d="${d#PT}"
  if [[ "$d" =~ ([0-9]+)H ]]; then h="${BASH_REMATCH[1]}"; fi
  if [[ "$d" =~ ([0-9]+)M ]]; then m="${BASH_REMATCH[1]}"; fi
  if [[ "$d" =~ ([0-9]+)(\.[0-9]+)?S ]]; then s="${BASH_REMATCH[1]}"; fi
  echo $(( h * 3600 + m * 60 + s ))
}
fmt_sub() { # fmt_sub TEMPLATE NUMBER TIME REPID BANDWIDTH
  local t="$1" num="$2" tim="$3" rid="$4" bw="$5" w
  t="${t//\$RepresentationID\$/$rid}"
  t="${t//\$Bandwidth\$/$bw}"
  if [[ "$t" =~ \$Number\%0([0-9]+)d\$ ]]; then w="${BASH_REMATCH[1]}"
    t="$(printf '%s' "$t" | sed "s/\\\$Number%0${w}d\\\$/$(printf "%0${w}d" "$num")/")"
  fi
  t="${t//\$Number\$/$num}"
  if [[ "$t" =~ \$Time\%0([0-9]+)d\$ ]]; then w="${BASH_REMATCH[1]}"
    t="$(printf '%s' "$t" | sed "s/\\\$Time%0${w}d\\\$/$(printf "%0${w}d" "$tim")/")"
  fi
  t="${t//\$Time\$/$tim}"
  t="${t//\$\$/$}"
  printf '%s' "$t"
}
absurl() { # absurl URL -- resolve against MPD base
  case "$1" in
    http*) printf '%s' "$1" ;;
    //*)   printf 'https:%s' "$1" ;;
    /*)    printf '%s%s' "$(printf '%s' "$MPD_URL" | cut -d/ -f1-3)" "$1" ;;
    *)     printf '%s%s' "$BASE" "$1" ;;
  esac
}

# Parse the MPD into a per-track plan file:
#   track<TAB>repId<TAB>bandwidth<TAB>initUrl<TAB>timescale<TAB>startNumber<TAB>duration<TAB>mediaTemplate<TAB>timeline(t:d,r;...)
# Plus LIST lines for SegmentList tracks:
#   track<TAB>repId<TAB>bandwidth<TAB>LIST<TAB>initUrl<TAB>segUrl1 segUrl2 ...
parse_mpd() {
  local mpd="$1" plan="$2"
  sed 's/></>\n</g' "$mpd" > "$WORKDIR/norm.xml"
  local mpdbase; mpdbase="$(grep -m1 '<BaseURL>' "$WORKDIR/norm.xml" | sed 's/.*<BaseURL>//; s|</BaseURL>.*||')"
  [ -n "$mpdbase" ] && BASE="$(absurl "$mpdbase")"
  awk -v plan_out="$plan" '
    function geta(line, name,   re,v) { if (match(line, name"=\"[^\"]*\"")) { v=substr(line, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v); return v } return "" }
    function flush_set(   i) {
      if (setmime == "") return
      # choose template source: set-level default, rep-level overrides handled at rep flush
      for (i = 1; i <= nrep; i++) {
        track = (setmime ~ /video/) ? "video" : (setmime ~ /audio/) ? "audio" : "other"
        if (track == "other") continue
        t_init = (rep_init[i] != "") ? rep_init[i] : set_init
        t_media = (rep_media[i] != "") ? rep_media[i] : set_media
        t_ts = (rep_ts[i] != "") ? rep_ts[i] : set_ts
        t_sn = (rep_sn[i] != "") ? rep_sn[i] : set_sn
        t_dur = (rep_dur[i] != "") ? rep_dur[i] : set_dur
        t_tl = (rep_tl[i] != "") ? rep_tl[i] : set_tl
        if (list_mode) {
          printf "LIST\t%s\t%s\t%s\t%s\t%s\n", track, rep_id[i], rep_bw[i], t_init, list_urls > planfile
        } else if (t_media != "") {
          printf "TPL\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", track, rep_id[i], rep_bw[i], t_init, t_ts, t_sn, t_dur, t_media, t_tl > planfile
        }
      }
    }
    BEGIN { planfile = plan_out }
    /<AdaptationSet/ { flush_set(); setmime=geta($0,"mimeType"); set_init=set_media=set_ts=set_sn=set_dur=set_tl=""; nrep=0; currep=0; list_mode=0; list_urls=""; in_tl=0 }
    /<Representation/ {
      nrep++; currep=nrep
      rep_id[nrep]=geta($0,"id"); rep_bw[nrep]=geta($0,"bandwidth"); if (rep_bw[nrep]=="") rep_bw[nrep]=0
      rm=geta($0,"mimeType"); if (rm != "") setmime=rm
      rep_init[nrep]=rep_media[nrep]=rep_ts[nrep]=rep_sn[nrep]=rep_dur[nrep]=rep_tl[nrep]=""
    }
    /<SegmentTemplate/ {
      ini=geta($0,"initialization"); med=geta($0,"media"); ts=geta($0,"timescale"); if (ts=="") ts=1
      sn=geta($0,"startNumber"); if (sn=="") sn=1; du=geta($0,"duration")
      if (currep > 0 && rep_open) { rep_init[currep]=ini; rep_media[currep]=med; rep_ts[currep]=ts; rep_sn[currep]=sn; rep_dur[currep]=du; pending_tl="rep" }
      else { set_init=ini; set_media=med; set_ts=ts; set_sn=sn; set_dur=du; pending_tl="set" }
    }
    /<SegmentTimeline>/ { in_tl=1; tlbuf="" }
    /<S / || /<S\/>/ || /<S>/ { if (in_tl) { t=geta($0,"t"); d=geta($0,"d"); r=geta($0,"r"); if (r=="") r=0; tlbuf = tlbuf t ":" d ":" r ";" } }
    /<\/SegmentTimeline>/ { in_tl=0; if (pending_tl=="rep") rep_tl[currep]=tlbuf; else set_tl=tlbuf }
    /<SegmentList/ { list_mode=1 }
    /<Initialization/ { iu=geta($0,"sourceURL"); if (iu != "") { if (currep>0) rep_init[currep]=iu; else set_init=iu } }
    /<SegmentURL/ { su=geta($0,"media"); if (su != "") list_urls = list_urls su " " }
    /<Representation/ { rep_open=1 }
    /<\/Representation>/ { rep_open=0 }
    END { flush_set() }
  ' "$WORKDIR/norm.xml"
  # keep only the best-bandwidth rep per track
  : > "$plan.best"
  for tr in video audio; do
    grep -P "^(TPL|LIST)\t$tr\t" "$plan" 2>/dev/null | sort -t "$(printf '\t')" -k3,3 -nr | head -1 >> "$plan.best"
  done
  mv "$plan.best" "$plan"
}

fetch_track_segments() { # plan-line fields; echoes "KEY URL" pairs to download
  :
}

log "fetching MPD: $MPD_URL"
LAST_NEW_EPOCH="$(date +%s)"
TOTAL_NEW=0

while true; do
  if ! curl -sLf --max-time 20 -H "User-Agent: $UA" -o "$WORKDIR/mpd.xml" "$MPD_URL" || [ ! -s "$WORKDIR/mpd.xml" ]; then
    log "MPD fetch failed; retrying in ${POLL}s"
    sleep "$POLL"; continue
  fi
  TYPE="$(sed 's/></>\n</g' "$WORKDIR/mpd.xml" | grep -m1 '<MPD' | attr type)"
  AST_RAW="$(sed 's/></>\n</g' "$WORKDIR/mpd.xml" | grep -m1 '<MPD' | attr availabilityStartTime)"
  AST="$(iso2epoch "${AST_RAW:-1970-01-01T00:00:00Z}")"
  NOW="$(date -u +%s)"
  parse_mpd "$WORKDIR/mpd.xml" "$WORKDIR/plan.tsv"
  ROUND_NEW=0

  while IFS="$(printf '\t')" read -r kind track rid bw f5 f6 f7 f8 f9 f10; do
    [ -n "$kind" ] || continue
    NOW="$(date -u +%s)"  # refresh per track: earlier tracks may take a while
    OUTFILE="${OUTBASE}-${track}.mp4"
    SEEN="$WORKDIR/seen-${track}.txt"; touch "$SEEN"
    if [ "$kind" = "LIST" ]; then
      INIT_URL="$f5"; SEGLIST="$f6"
      KEY="INIT:$rid"
      if ! grep -qxF "$KEY" "$SEEN"; then
        if curl -sLf --max-time 30 -H "User-Agent: $UA" -o "$WORKDIR/tmp.bin" "$(absurl "$INIT_URL")" && [ -s "$WORKDIR/tmp.bin" ]; then
          cat "$WORKDIR/tmp.bin" >> "$OUTFILE"; echo "$KEY" >> "$SEEN"; log "$track: init appended"
        fi
      fi
      idx=0
      for su in $SEGLIST; do
        idx=$((idx+1)); KEY="SEG:$rid:$idx"
        grep -qxF "$KEY" "$SEEN" && continue
        if curl -sLf --max-time 30 -H "User-Agent: $UA" -o "$WORKDIR/tmp.bin" "$(absurl "$su")" && [ -s "$WORKDIR/tmp.bin" ]; then
          cat "$WORKDIR/tmp.bin" >> "$OUTFILE"; echo "$KEY" >> "$SEEN"; ROUND_NEW=$((ROUND_NEW+1)); log "$track: +seg $idx"
        fi
        [ "$MAXSEG" -gt 0 ] && [ "$ROUND_NEW" -ge "$MAXSEG" ] && break
      done
    else
      INIT_T="$f5"; TS="${f6:-1}"; SN="${f7:-1}"; DUR="${f8:-0}"; MEDIA_T="$f9"; TL="$f10"
      KEY="INIT:$rid"
      if ! grep -qxF "$KEY" "$SEEN"; then
        IU="$(absurl "$(fmt_sub "$INIT_T" 0 0 "$rid" "$bw")")"
        if curl -sLf --max-time 30 -H "User-Agent: $UA" -o "$WORKDIR/tmp.bin" "$IU" && [ -s "$WORKDIR/tmp.bin" ]; then
          cat "$WORKDIR/tmp.bin" >> "$OUTFILE"; echo "$KEY" >> "$SEEN"; log "$track: init appended"
        fi
      fi
      # Build the list of available (number, time) pairs
      PAIRS=""
      if [ -n "$TL" ]; then
        # The manifest only publishes segments inside its window; the tail
        # is the live edge, so hold back the last --lag segments (dynamic
        # only) and let the seen-set + 404-skip handle the rest.
        tcur=0; num="$SN"; ALLP=""
        IFS=';' read -ra SARR <<< "$TL"
        for s in "${SARR[@]}"; do
          [ -n "$s" ] || continue
          st="${s%%:*}"; rest="${s#*:}"; sd="${rest%%:*}"; sr="${rest#*:}"
          [ -n "$st" ] && tcur="$st"
          cnt=$((sr + 1)); i=0
          while [ "$i" -lt "$cnt" ]; do
            ALLP="$ALLP $num:$tcur"
            tcur=$((tcur + sd)); num=$((num + 1)); i=$((i + 1))
          done
        done
        if [ "$TYPE" = "dynamic" ] && [ "$LAG" -gt 0 ]; then
          PAIRS="$(printf '%s' "$ALLP" | awk -v lag="$LAG" '{ n=split($0,a," "); for (i=1;i<=n-lag;i++) printf "%s ", a[i] }')"
        else
          PAIRS="$ALLP"
        fi
      elif [ -n "$DUR" ] && [ "$DUR" != "0" ]; then
        if [ "$TYPE" = "dynamic" ]; then
          # Join at the live edge: epoch-numbered streams would otherwise
          # crawl from segment zero forever. Only the recent window is
          # still on the server anyway; hold back --lag from the newest.
          newest=$(( SN + (NOW - AST) * TS / DUR - 1 ))
          first=$(( newest - 30 )); [ "$first" -lt "$SN" ] && first="$SN"
          last=$(( newest - LAG ))
          n="$first"
          while [ "$n" -le "$last" ]; do PAIRS="$PAIRS $n:0"; n=$((n + 1)); done
        else
          MPD_DUR="$(sed 's/></>\n</g' "$WORKDIR/mpd.xml" | grep -m1 '<MPD' | attr mediaPresentationDuration)"
          secs="$(iso_dur2secs "${MPD_DUR:-PT0S}")"
          last=$(( SN + secs * TS / DUR - 1 ))
          n="$SN"
          while [ "$n" -le "$last" ]; do PAIRS="$PAIRS $n:0"; n=$((n + 1)); done
        fi
      fi
      for pair in $PAIRS; do
        num="${pair%%:*}"; tim="${pair#*:}"
        KEY="SEG:$rid:$num"
        grep -qxF "$KEY" "$SEEN" && continue
        SU="$(absurl "$(fmt_sub "$MEDIA_T" "$num" "$tim" "$rid" "$bw")")"
        if curl -sLf --max-time 30 -H "User-Agent: $UA" -o "$WORKDIR/tmp.bin" "$SU" && [ -s "$WORKDIR/tmp.bin" ]; then
          cat "$WORKDIR/tmp.bin" >> "$OUTFILE"; echo "$KEY" >> "$SEEN"; ROUND_NEW=$((ROUND_NEW+1)); log "$track: +seg $num"
        else
          echo "$KEY" >> "$SEEN"; log "$track: seg $num unavailable (skipped)"
        fi
        [ "$MAXSEG" -gt 0 ] && [ $((TOTAL_NEW + ROUND_NEW)) -ge "$MAXSEG" ] && break
      done
    fi
    rm -f "$WORKDIR/tmp.bin"
  done < "$WORKDIR/plan.tsv"

  TOTAL_NEW=$((TOTAL_NEW + ROUND_NEW))
  [ "$ROUND_NEW" -gt 0 ] && LAST_NEW_EPOCH="$(date +%s)"
  if [ "$MAXSEG" -gt 0 ] && [ "$TOTAL_NEW" -ge "$MAXSEG" ]; then
    log "max-segments reached ($TOTAL_NEW). Done."; exit 0
  fi
  if [ "$TYPE" != "dynamic" ]; then
    log "static MPD fully processed. Done."
    for tr in video audio; do [ -f "${OUTBASE}-${tr}.mp4" ] && log "${OUTBASE}-${tr}.mp4: $(stat -c%s "${OUTBASE}-${tr}.mp4") bytes"; done
    exit 0
  fi
  if [ "$IDLE_EXIT" -gt 0 ] && [ $(( $(date +%s) - LAST_NEW_EPOCH )) -ge "$IDLE_EXIT" ]; then
    log "no new segments for ${IDLE_EXIT}s -- exiting."
    for tr in video audio; do [ -f "${OUTBASE}-${tr}.mp4" ] && log "${OUTBASE}-${tr}.mp4: $(stat -c%s "${OUTBASE}-${tr}.mp4") bytes"; done
    exit 0
  fi
  sleep "$POLL"
done
