# TikTok, or: The Door That Reads Knockers

`kurl-tt.sh` records TikTok Live. It took one guitarist, one very patient test subject, and every client we own getting thrown out of the same door to figure out how.

## The door that reads knockers

TikTok Live serves two doors:

- **The HLS door** hands its playlist to *anyone* — anonymous curl, no login, HTTP 200, help yourself. Then it refuses the actual video segments to **everyone**: curl got 404s. ffmpeg skipped segment after segment. Cookies didn't help. A Referer didn't help. Speed didn't help — we grabbed a playlist and reached for its segments *in the same second* and still got 404s. Even yt-dlp's own downloader, extractor and puller in one body, got its segments refused.

  The lesson: that door doesn't check what you're carrying. It checks **who is knocking**. A photocopy of the playlist makes you a stranger, and strangers get segments the way strangers get into a speakeasy — not at all.

- **The FLV door** is a hose. FLV — Flash Video, a format old enough to have grandchildren — is one continuous stream on one connection. No playlist. No segments. No rotating window of names expiring every few seconds. *Nothing for a guard to stand in front of.* Hand plain curl a fresh FLV address and it drinks at full stream rate. We measured: 2.78 MB in an 18-second sip, zero drama.

## Power of attorney

So `kurl-tt` does not dress curl up as yt-dlp (it's Halloween somewhere, but kurl's whole virtue is being *lighter* than the thing it would be impersonating). Instead, kurl grants yt-dlp **power of attorney for the address only**:

1. yt-dlp knocks in plain clothes — home IP, browser user-agent, the anonymous guest pass TikTok mints for every visitor, no account anywhere — and asks the desk where the hose is.
2. It hands kurl the address and goes home.
3. curl pulls the stream in its own tongue, under its own name, and kurl does the parts it was always good at: appending safely, surviving drops (fresh address, keep going), sealing the file when the live ends.

The attorney makes the introduction. The lightweight does the work.

## Usage

```bash
./kurl-tt.sh --tiktok @somestreamer -o some-live.flv
ffmpeg -i some-live.flv -c copy some-live.mp4   # remux when done
```

Restarting with the same `-o` resumes appending to the same partial file. A sealed recording is never overwritten — the script refuses, on principle.

## Credits, in the order the universe provided them

- **Irina — [@irene.blaire](https://www.tiktok.com/@irene.blaire)** — the inspiration. Her live streams (Oct 6–7, 2026) were captured while HLS was busy 403-ing us: the FLV route worked *then*, clear-screen, full streams, remuxed and verified. Today's doctrine is just her door, finally understood.
- **Yulia — [@yuliaalexeeva02](https://www.tiktok.com/@yuliaalexeeva02)** — the test subject. Her marathon live (Oct 20, 2026) absorbed the full afternoon of failed knocks — curl 404s, ffmpeg skips, a power-of-attorney HLS attempt that failed in the attorney's own hands — and then recorded clean through the FLV hose the moment we asked the right door. She just sat there and kept the stream going. Wear whatever you want; that's the whole job, and she did it perfectly.

## License

[ soaꓘKontrolled TS ] 2026 — **Forking Required / Lockdown Forbidden**. See [LICENSE.md](LICENSE.md).

*Throw a rainbow at it — but check which door is a hose first.*
