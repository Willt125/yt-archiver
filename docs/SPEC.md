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
| `-s LANGS` | Also save auto-generated subtitles (see below) | off |

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

## Auto-generated subtitles (`-s`)

yt-dlp selects human subtitles and auto captions from one pool with one
`--sub-langs` filter, and both use plain language codes (`de` is both a human
track and YouTube's machine translation into German). A single pass therefore
cannot express "all human tracks plus these auto languages", and an auto track
saved as `.de.vtt` would be indistinguishable from a human one.

So `-s` adds a **second, subtitles-only pass** over the same URLs:

- `--skip-download --write-auto-subs --sub-langs LANGS` (no `--write-subs`,
  so only auto captions are candidates).
- **Main** output template with `.auto` before the extension, so files are
  `<name>.auto.<lang>.vtt`. A separate `subtitle:` template must *not* be
  used: yt-dlp writes to the normal subtitle name first and then moves the
  file, overwriting a human track of the same language.
- Not embedded by yt-dlp: its embedding re-muxes the file and drops the
  existing (human) subtitle streams. Instead the script embeds them itself
  (see below).
- Own archive, `archive-autosubs.txt`, with `--force-write-archive` (a
  `--skip-download` pass does not record IDs otherwise). This also lets `-s`
  add transcripts to videos archived earlier.
- Auto tracks are fetched even when a human track exists in that language.

**Embedding.** After the pass, the script embeds the auto sidecars into the MKV
of each video the pass processed (the IDs it appended to
`archive-autosubs.txt`), using **mkvmerge** (MKVToolNix):

- Why mkvmerge: yt-dlp's embedding drops the existing subtitle tracks, and
  adding tracks with ffmpeg failed with a recent ffmpeg development build
  (N-126136): even a plain `ffmpeg -i video.mkv -i sub.vtt -map 0 -map 1
  -c copy` produced a track that mpv 0.37 showed only the first caption of,
  and at first VLC 3.0.20 showed a black picture. ffmpeg 6.1 and 7.0 were
  fine, so the problem is specific to that ffmpeg version.
- mkvmerge is optional: without it, `-s` still saves the `.vtt` files and
  warns once that they are not embedded.
- mkvmerge copies every existing track, attachment, chapter and global tag.
  Tracks titled `Auto-generated (...)` from an earlier run are dropped
  (`--subtitle-tracks !IDs`; for Matroska, ffprobe's stream index equals
  mkvmerge's track ID) and every `<name>.auto.<lang>.vtt` next to the video
  is added, so re-embedding replaces rather than duplicates.
- Each new track gets the name `Auto-generated (<lang>)` (the yt-dlp code,
  e.g. `en-orig`), the language `<lang without -orig>` (mkvmerge writes the
  proper ISO 639-2 and BCP 47 codes) and is never the default track.
- The tracks are embedded as **SRT**, converted by the script (`vtt_to_srt`,
  POSIX awk), not as the raw VTT: mkvmerge stores WebVTT as `S_TEXT/WEBVTT`,
  which ffmpeg 6.1 (and players built on it) doesn't recognise, while SRT
  works everywhere. The conversion drops the inline word timings
  (`<00:00:00.320><c> word</c>`), cue settings (`align:start position:0%`),
  whitespace-only lines and the 10 ms transition cues of YouTube's rolling
  captions, keeping plain two-line captions. ffmpeg's own VTT-to-SRT
  conversion lost the first caption, so it isn't used. The `.vtt` sidecars
  stay exactly as downloaded.
- mkvmerge decodes file names using the locale and can't open non-ASCII names
  under the POSIX locale (cron jobs, minimal shells); `--command-line-charset`
  doesn't help. When the locale isn't UTF-8, mkvmerge runs with `LC_ALL` set
  to an available `C.UTF-8` or `en_US.UTF-8` locale.
- Written to `<name>.embedding.mkv`, then moved over the original with its
  modification time preserved. mkvmerge exit code 1 (warnings) counts as
  success. On failure the original is untouched, the sidecars are kept, and
  the run exits non-zero.
- Audio-only files are skipped (their containers can't hold subtitles).

`LANGS`: `orig` is a shortcut for `.*-orig`, the transcript in the video's own
language (recommended). Anything else is passed to yt-dlp as-is, e.g.
`en-orig,es`; codes without `-orig` are machine translations.

Costs: each video is extracted twice (more requests), pacing adds about 5 s per
auto subtitle file, and changing `LANGS` later does not revisit videos already
in `archive-autosubs.txt` (delete it to refetch).

## Output layout

```
OUT/<channel>/<playlist>/<index> - <title> [<id>].<ext>
OUT/archive.txt
OUT/archive-autosubs.txt   (only with -s)
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
- README.md (points Windows users to WSL).
- Add a shellcheck GitHub Action.

## Known limitations and deferred work

- **Playlist gaps:** `--download-archive` records video IDs, so a video in
  several playlists is stored only under the first one reached. Each
  playlist's info JSON still lists all entries. *Possible later change:* store
  each video once per channel and generate `.m3u` playlists.
- **Auto-generated subtitles** are only embedded for videos processed by the
  current run. Sidecars saved by earlier versions (before embedding existed)
  are embedded once `archive-autosubs.txt` is deleted and `-s` is run again.
- Auto sidecars are written into the folder of the URL being processed. If
  `-s` is run later through a different URL (e.g. another playlist), they land
  in that folder, away from the video, and are not embedded.
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
