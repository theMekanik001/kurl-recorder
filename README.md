# kurl-recorder

**A tiny, curl-only HLS live-stream recorder.** bash + curl + coreutils — nothing else to install, nothing else to break.

by **theMekanik** & **Ding Dong** 🐱

## Why this exists

The standard recorders — ffmpeg, yt-dlp, streamlink — fetch playlists and segments with heavy HTTP stacks. On some roads those stacks quietly fail: proxied networks that truncate reads mid-playlist, locked-down boxes, minimal containers, flaky egress. The big tool dies, the recording stops, the moment is gone.

curl's reads stay clean on those same roads.

kurl-recorder was born on a day when ffmpeg *and* yt-dlp both failed to record a live stream through a proxy — truncated reads, "stream ends prematurely," incomplete downloads. A hand-rolled curl loop recorded the same stream at full 1080p without dropping a byte. This repo is that loop, cleaned up and made self-healing.

**The power is the lightness.** It runs anywhere bash and curl exist — which is everywhere.

## What it does

- Polls the media playlist every 3 seconds (configurable)
- Downloads each segment to a **temp file first, appends only on success** — a failed segment can never truncate your recording
- Tracks seen segment URLs, so hiccups and restarts never duplicate footage
- **Twitch mode:** resolves its own signed playback token — and **re-resolves it automatically** when the session starts failing. When the key dies, it asks for a new key instead of quitting.
- Exits cleanly on `#EXT-X-ENDLIST`

## Usage

```bash
# Any HLS stream by URL (master or media playlist)
./kurl-rec.sh --url https://example.com/live/index.m3u8 -o show.ts

# A master playlist where you want a specific variant (0 = first listed)
./kurl-rec.sh --url https://example.com/master.m3u8 --variant 2 -o show.ts

# Twitch by channel name (source quality by default)
./kurl-rec.sh --twitch somestreamer -o stream.ts

# Kick by channel name
./kurl-rec.sh --kick somestreamer -o stream.ts

# Slower polling, named quality variant
./kurl-rec.sh --twitch somestreamer --quality 720p --poll 5 -o stream.ts
```

**Platform support:** the engine records *any* HLS stream you can hand it a playable playlist URL for. Built-in resolvers: **Twitch** and **Kick**. **YouTube Live** and **TikTok Live** work in `--url` mode with a manifest URL extracted by other tools (theirs hide behind signed page/API responses; resolvers are future work). **Instagram Live** is login-walled and not supported.

Output is a raw MPEG-TS stream copy. Remux when you're done:

```bash
ffmpeg -i out.ts -c copy out.mp4
```

Resume behavior: segment state lives in `<output>.kurlparts/seen.txt`. Restarting with the same `-o` file continues where it left off instead of starting over.

## Requirements

- bash
- curl
- coreutils (grep, sed, stat)
- *Optional:* python3 — used in Twitch mode for sturdier token parsing; a grep/sed fallback is built in.

No ffmpeg. No pip. No node. That's the point.

## License

[ soaꓘKontrolled TS ] 2026 — **Forking Required / Lockdown Forbidden**

Not Kopy Right. Not Kopy left. Somewhere in between. See [LICENSE.md](LICENSE.md).

## Credits

Created by **theMekanik** and **Ding Dong** — a human builder and his AI kat, recording the streams that matter to them, one 2-second segment at a time.
