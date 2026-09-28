# yt-archiver

A bash wrapper around [yt-dlp](https://github.com/yt-dlp/yt-dlp) for archiving
YouTube videos, playlists and channels, whether that's backing up your own
uploads or preserving videos worth keeping.

- **No re-encoding.** YouTube's best available streams are kept exactly as
  served: video in MKV, audio-only in `.opus` or `.m4a`. Everything plays in
  mpv and VLC.
- **Metadata is kept alongside:** thumbnail, human-made subtitles (VTT),
  chapters, the full info JSON and the top comments. Where the container
  allows, they are also embedded in the file.
- **Incremental.** An archive file records what has been downloaded, so
  re-running the same command only fetches what's new or previously failed.
- **Polite by default.** Pauses between requests reduce the chance of YouTube's
  bot detection blocking you; a separate option limits bandwidth.

## Requirements

- bash (3.2 or later; the macOS default works). Linux and macOS are supported.
  On Windows, use [WSL](https://learn.microsoft.com/windows/wsl/).
- **yt-dlp**, kept up to date. The script checks GitHub for a newer release on
  each run and tells you how to update.
- **ffmpeg** and **ffprobe**.
- For full YouTube support, yt-dlp also needs **yt-dlp-ejs** and a
  **JavaScript runtime** (deno >= 2.3 recommended). **mutagen** is needed to
  embed thumbnails in audio files. The official yt-dlp binaries include
  yt-dlp-ejs and mutagen; with pip, install `yt-dlp[default]`.

The script reports anything missing before it starts.

### Installing

Download `archive_youtube_video.sh` and make it executable:

```sh
chmod +x archive_youtube_video.sh
```

If you put a yt-dlp executable named `yt-dlp` in the same folder, the script
uses it in preference to one on your `PATH`. This is an easy way to always run
the latest release: download it from the
[yt-dlp releases page](https://github.com/yt-dlp/yt-dlp/releases) and update
it with `./yt-dlp -U`.

## Usage

```
archive_youtube_video.sh [options] URL [URL...]
```

| Option | Meaning | Default |
|---|---|---|
| `-h` | Show help, including cookie setup | |
| `-o DIR` | Output directory | `~/Videos/YouTube Archive` |
| `-t DIR` | Temp directory for partial files | the output directory |
| `-a` | Audio only | off |
| `-r N` | Cap resolution at Np, measured on the short side | none |
| `-n N` | Retries per download and fragment, or `infinite` | `10` |
| `-l RATE` | Limit bandwidth, e.g. `500K` or `5M` | no limit |
| `-p` | Turn off pacing between requests | pacing on |
| `-C N` | Max comments per video: a number, `all`, or `0` | `1000` (most popular) |
| `-c FILE` | Cookies file (Netscape format) | none |
| `-j RUNTIME` | JavaScript runtime: `node`, `quickjs` or `bun` | deno |
| `-w` | Windows-safe filenames, for NTFS or exFAT drives | off |
| `-s LANGS` | Also save auto-generated subtitles, e.g. `orig` | off |

Quote URLs that contain `&`.

### Examples

```sh
# A playlist, into the default folder
./archive_youtube_video.sh "https://www.youtube.com/playlist?list=..."

# Every playlist on a channel, capped at 1080p, onto a data drive
./archive_youtube_video.sh -r 1080 -o /mnt/data/Archive "https://www.youtube.com/@channel/playlists"

# Also save the auto-generated transcript in each video's own language
./archive_youtube_video.sh -s orig "https://www.youtube.com/playlist?list=..."

# Audio only, several videos at once
./archive_youtube_video.sh -a URL1 URL2 URL3

# Your own private and unlisted uploads, with limited bandwidth
./archive_youtube_video.sh -c ~/.secrets/cookies.txt -l 5M "https://www.youtube.com/@yourchannel/videos"
```

## Output

```
DIR/<channel>/<playlist>/<index> - <title> [<id>].mkv    (plus .info.json, .webp, .<lang>.vtt)
DIR/<channel>/<title> [<id>].mkv                         (videos not downloaded from a playlist)
DIR/<channel>/.../<title> [<id>].auto.<lang>.vtt         (auto-generated subtitles, with -s)
DIR/archive.txt                                          (IDs already downloaded)
DIR/archive-autosubs.txt                                 (the same, for -s)
DIR/logs/<date-time>.log                                 (one log per run)
```

If yt-dlp reports errors, some items may not have been saved. Check the log,
then re-run the same command: anything already archived is skipped.

## Auto-generated subtitles

Only human-made subtitles are saved by default. With `-s LANGS`, a second,
subtitles-only pass also saves YouTube's auto-generated subtitles as separate
`.auto.<lang>.vtt` files, so they can't be mistaken for human-made ones.

- `-s orig` saves the transcript in each video's own language (recommended).
- Other values are passed to yt-dlp as a language list, e.g. `-s "en-orig,es"`.
  Codes without `-orig` are YouTube's machine translations.

The extra pass looks every video up a second time, so it is slower and makes
more requests. It also works on videos you archived earlier without `-s`. To
fetch new languages for videos already done, delete `archive-autosubs.txt`.

## Cookies

Cookies let yt-dlp download as your logged-in account. You need them for your
own private or unlisted videos, and for members-only or age-restricted videos.
The script only reads a cookies file; creating it is up to you. Run
`archive_youtube_video.sh -h` for step-by-step guidance.

A cookies file gives full access to your account. Keep it private
(`chmod 600`), outside the archive folder, and never commit or share it.

## Archiving your own channel

YouTube re-encodes every upload, so yt-dlp downloads YouTube's best encode,
not your original file. To recover originals, use
[Google Takeout](https://takeout.google.com/), which can export your uploads
as originals where available. This script complements Takeout with the
metadata, subtitles, thumbnails and playlist structure.

## Known limitations

- A video that appears in several playlists is saved only under the first
  playlist downloaded, because the archive file tracks video IDs. Each
  playlist's info JSON still lists all its entries.
- Auto-generated subtitles (`-s`) are saved as separate files only; they are
  not embedded in the video.
- All yt-dlp configuration files are ignored, so every run behaves the same.
- Pacing makes large downloads slow, especially for videos with many subtitle
  languages. Use `-p` to turn it off at your own risk.

See [docs/SPEC.md](docs/SPEC.md) for the design and the reasoning behind it.

## License

[CC0 1.0 Universal](LICENSE): public domain.
