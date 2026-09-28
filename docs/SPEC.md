# yt-archiver specification

Status: implemented in `archive_youtube_video.sh`.

## Purpose

A general-purpose bash wrapper around yt-dlp for archiving YouTube media:

1. **Recovering your own uploads.** Google Takeout is the source for original
   masters where it can provide them. This script covers what Takeout does not:
   YouTube's best available encodes, metadata, subtitles, thumbnails and
   playlist structure.
2. **Preserving other videos** of informational, educational, historical or
   cultural value, as video or audio only.

Guiding principles:

- **Never re-encode.** YouTube's streams are already lossy; keep the best
  available streams bit-for-bit and only change containers where needed.
- **Output must play in mpv and VLC.**
- **Works out of the box** for anyone with a correctly installed yt-dlp, on
  Linux and macOS. Windows users should use WSL.
- **Readable and maintainable** over clever. Avoid bash magic and feature creep.

## Usage

```
archive_youtube_video.sh [options] URL [URL...]
```

Multiple URLs are accepted (videos, playlists, channel tabs). Grabbing by
playlist is the expected workflow, to preserve archive structure.

| Flag | Meaning | Default |
|---|---|---|
| `-h` | Help, including cookie setup guidance | |
| `-o DIR` | Output directory | `~/Videos/YouTube Archive` |
| `-t DIR` | Temp directory for partial/intermediate files | same as output |
| `-a` | Audio only (native codec) | off |
| `-r N` | Resolution cap, measured on the short side | none |
| `-n N` | Retries (a number or `infinite`) | `10` |
| `-l RATE` | Bandwidth limit, e.g. `5M` | none |
| `-p` | Turn pacing off | pacing on |
| `-C N` | Comment cap: `N`, `all` or `0` (none) | `1000` (top) |
| `-c FILE` | Cookies file (Netscape format) | none |
| `-j RT` | JS runtime: `node`, `quickjs` or `bun` | Deno (yt-dlp default) |
| `-w` | Windows/exFAT-safe filenames | off |

Bandwidth (`-l`) and pacing (`-p`) are deliberately separate: `-l` protects
household bandwidth, pacing reduces request frequency, which is what YouTube's
bot detection reacts to.

## Pre-flight checks

The script warns but never refuses, except when a required tool is missing.

1. **Locate yt-dlp:** the executable next to the script first, then `PATH`.
2. **Required tools:** `ffmpeg` and `ffprobe` must exist.
3. **Update check:** read the latest release tag from the redirect of
   `https://github.com/yt-dlp/yt-dlp/releases/latest` (one `curl -sI` with a
   short timeout). Compare `YYYY.MM.DD` versions numerically. If upstream is
   newer, warn and list update commands per install method:
   - standalone binary: `yt-dlp -U`
   - pip: `pip install -U "yt-dlp[default]"` (`[default]` brings yt-dlp-ejs and mutagen)
   - pipx: `pipx upgrade yt-dlp`
   - Homebrew: `brew upgrade yt-dlp`
   - distro package manager: switch to one of the above

   If the check fails (offline, timeout), skip it and note that in the log.
4. **Optional components:** yt-dlp-ejs, mutagen and the JS runtime are checked
   by yt-dlp itself; the script surfaces yt-dlp's verbose report rather than
   reimplementing version checks.
5. **Config warning:** one line stating that *all* yt-dlp config files are
   ignored (user, system and portable `yt-dlp.conf` next to the binary).

### JS runtime

Deno is yt-dlp's only runtime enabled by default, and the recommended one
because it sandboxes the code it runs. Others are opt-in via `-j`, which passes
`--js-runtimes RT`. Version requirements (from yt-dlp-ejs), enforced by yt-dlp:

| Runtime | Required version |
|---|---|
| deno | >= 2.3 |
| node | >= 22 |
| quickjs | >= 2023-12-9 |
| quickjs-ng | any |
| bun (deprecated) | >= 1.2.11, <= 1.3.14 |

## yt-dlp invocation

- **Config:** `--ignore-config`.
- **Paths:** `-P "home:$OUT"` and `-P "temp:$TMP"` with a *relative* `-o`
  template (`-P` is ignored when `-o` is absolute).
- **Video:** `-f "bv*+ba/b"`, plus `-S "res:N"` when `-r` is given;
  `--merge-output-format mkv`.
- **Audio only:** `-f "ba/b" -x --audio-format best` (no re-encode; Opus
  streams land in `.opus`, AAC in `.m4a`).
- **Thumbnails:** `--write-thumbnail --embed-thumbnail`, no conversion.
- **Subtitles:** human-made tracks only, kept as VTT:
  `--write-subs --sub-langs "all,-live_chat" --embed-subs`.
- **Metadata:** `--write-info-json --embed-metadata` (for MKV this also embeds
  chapters and the info JSON).
- **Comments:** `--write-comments` with
  `--extractor-args "youtube:comment_sort=top;max_comments=1000,all,100"`
  (1,000 comments, at most 100 of them replies). `-C` overrides the cap;
  `-C 0` omits comments.
- **Archive:** `--download-archive "$OUT/archive.txt"`.
- **Retries:** `--retries N --fragment-retries N`, with exponential
  `--retry-sleep` for both `http` and `fragment`.
- **Pacing:** `-t sleep` unless `-p`.
- **Bandwidth:** `--limit-rate RATE` when `-l` is given.
- **Filenames:** `--windows-filenames` when `-w` is given.
- **Removed from the old script:** `--throttled-rate` (conflicts with low
  `--limit-rate`), `--compat-options filename-sanitization`,
  `--convert-thumbnails`, `--convert-subs`, `--write-auto-subs`, and the
  redundant `--no-abort-on-error` and `--embed-chapters`.

## Output layout

```
OUT/<channel>/<playlist>/<index> - <title> [<id>].<ext>
OUT/archive.txt
OUT/logs/YYYYmmdd-HHMMSS.log
```

- Channel falls back to uploader, then `Unknown`.
- The playlist folder and index prefix appear only for playlist downloads.
  The index is zero-padded to 4 digits so files sort in playlist order.
  The playlist's own info JSON is saved in its folder as `0000 - <playlist> [<id>].info.json`.
- Titles are trimmed to about 150 bytes to stay under filesystem limits.

## Logging

yt-dlp output is piped through `tee` into the per-run log; the exit status is
taken from `${PIPESTATUS[0]}`. `--progress-delta` keeps progress lines from
flooding the log. A non-zero exit means *some* items failed, not all; the
final message says so and points to the log.

## Portability

Target bash 3.2 (macOS). Avoid: `date -d`, `readlink -f`, `sed -i`, `mapfile`,
`declare -A`, and expanding empty arrays under `set -u`.

## Repository

- Delete `archive_youtube_video.ps1`.
- Add a README once the implementation is in (point Windows users to WSL).
- Add a shellcheck GitHub Action.

## Known limitations and deferred work

- **Playlist gaps:** `--download-archive` records video IDs, so a video in
  several playlists is stored only under the first one reached. Each
  playlist's info JSON still lists all entries. *Possible later change:* store
  each video once per channel and generate `.m3u` playlists.
- **Auto-generated subtitles** are not downloaded; videos with only auto
  captions get no transcript. To be revisited in a later commit (the
  original-language ASR track only, not machine translations).
- **Config escape hatch:** if needed later, `--config-locations FILE` still
  works under `--ignore-config`.

## Verified during implementation

Tested offline against yt-dlp 2026.08.19 with generated media:

- yt-dlp's verbose header reports `exe versions:` (ffmpeg, ffprobe),
  `Optional libraries:` (`yt_dlp_ejs`, `mutagen`) and `JS runtimes:`
  (`none`, or a version marked `(unsupported)`); the script parses these lines.
- `%(playlist_index&...)s` is not padded automatically, so the template pads
  explicitly with `{:04d}`.
- A `/` inside a `&` replacement is sanitized, so the playlist folder is
  written as `%(playlist|)s/`; for single videos the empty segment collapses.
- Thumbnails embed without conversion in MKV (as a WebP attachment), `.opus`
  and `.m4a` (yt-dlp converts internally where required).
- MKV output carries VTT subtitle tracks, chapters and the info JSON attachment;
  `live_chat` is excluded; the archive file skips already-downloaded IDs.

Still unverified: whether `quickjs-ng` is picked up via `-j quickjs`, and
behaviour on bash 3.2 (reviewed by hand; no bash 3.2 was available to test).
