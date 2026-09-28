#!/usr/bin/env bash
#
# archive_youtube_video.sh - archive YouTube videos, playlists and channels
# with yt-dlp, keeping the original streams and as much metadata as possible.
#
# Run with -h for usage. The design is described in docs/SPEC.md.
# Targets bash 3.2 (macOS) and later.

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASES_URL="https://github.com/yt-dlp/yt-dlp/releases/latest"

# Output layout, relative to the output directory. The playlist folder and
# index prefix are empty for videos not downloaded as part of a playlist.
OUTPUT_NAME="%(channel,uploader|Unknown)s/%(playlist|)s/%(playlist_index&{:04d} - |)s%(title).150B [%(id)s]"
OUTPUT_TEMPLATE="$OUTPUT_NAME.%(ext)s"
# Auto-generated subtitles get ".auto" in their name: <name>.auto.<lang>.vtt
AUTO_SUBS_TEMPLATE="$OUTPUT_NAME.auto.%(ext)s"

# Defaults
OUTPUT_DIR="$HOME/Videos/YouTube Archive"
TEMP_DIR=""
AUDIO_ONLY=false
RESOLUTION=""
RETRIES=10
RATE_LIMIT=""
PACING=true
COMMENTS=1000
COOKIES_FILE=""
JS_RUNTIME=""
WINDOWS_FILENAMES=false
AUTO_SUBS=""

LOG_FILE=""

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

# Print a message to stderr, and to the log file once it exists.
log() {
    echo "$*" >&2
    if [ -n "$LOG_FILE" ]; then
        echo "$*" >> "$LOG_FILE"
    fi
}

warn() {
    log "WARNING: $*"
}

die() {
    log "Error: $*"
    exit 1
}

usage_error() {
    echo "$SCRIPT_NAME: $*" >&2
    echo "Try '$SCRIPT_NAME -h' for help." >&2
    exit 2
}

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [options] URL [URL...]

Archive YouTube videos, playlists and channels with yt-dlp. Streams are kept
exactly as YouTube serves them (never re-encoded); video is saved as MKV,
audio-only as .opus or .m4a. Thumbnails, human-made subtitles, metadata and
top comments are saved alongside and embedded where the container allows.

Accepts any number of video, playlist or channel URLs. Quote URLs that
contain "&". Downloading by playlist preserves the playlist structure.

Options:
  -h          Show this help and exit
  -o DIR      Output directory (default: ~/Videos/YouTube Archive)
  -t DIR      Temp directory for partial files (default: the output directory)
  -a          Audio only
  -r N        Cap video resolution at Np, measured on the short side
              (e.g. 1080). Falls back to the smallest available if none fit
  -n N        Retries per download and per fragment: a number or "infinite"
              (default: 10)
  -l RATE     Limit download bandwidth, e.g. 500K or 5M (default: no limit)
  -p          Turn off pacing (by default yt-dlp sleeps between requests and
              downloads to avoid YouTube's bot detection)
  -C N        Maximum comments per video: a number, "all", or 0 for none
              (default: 1000, most popular first)
  -c FILE     Cookies file in Netscape format (see COOKIES below)
  -j RUNTIME  JavaScript runtime for yt-dlp: node, quickjs or bun
              (default: deno, the recommended and sandboxed runtime)
  -w          Windows-safe filenames, for NTFS or exFAT drives
  -s LANGS    Also save YouTube's auto-generated subtitles (see AUTO SUBTITLES)

Output layout:
  DIR/<channel>/<playlist>/<index> - <title> [<id>].<ext>
  DIR/archive.txt             IDs already downloaded; they are skipped next time
  DIR/archive-autosubs.txt    The same, for auto-generated subtitles (-s)
  DIR/logs/<date-time>.log    Log of each run

  A video in several playlists is only saved under the first one downloaded.

Requirements:
  yt-dlp (preferably the latest release), ffmpeg and ffprobe. For full YouTube
  support yt-dlp also needs yt-dlp-ejs and a JavaScript runtime (deno >= 2.3,
  node >= 22, quickjs >= 2023-12-9, any quickjs-ng, or bun 1.2.11-1.3.14,
  which is deprecated). mutagen is needed to embed thumbnails in audio files.
  mkvmerge (MKVToolNix) is needed to embed auto-generated subtitles (-s).
  The official yt-dlp binaries and "pip install 'yt-dlp[default]'" include
  yt-dlp-ejs and mutagen.

  A yt-dlp executable placed next to this script is used in preference to one
  on your PATH. All yt-dlp configuration files are ignored, so runs behave the
  same everywhere.

COOKIES
  Cookies let yt-dlp act as your logged-in account. They are needed for your
  own private or unlisted videos, members-only videos and age-restricted
  videos. This script only reads a cookies file; creating it is up to you.

  A cookies file gives full access to the account it came from. Treat it
  like a password:
    - Keep it private (chmod 600 cookies.txt) and outside the archive folder.
    - Never share it or commit it to a repository.
    - Consider a secondary account for archiving other people's videos, since
      heavy downloading can get an account flagged.

  Recommended way to create it:
    1. Open a new private/incognito browser window and log in to YouTube.
    2. In the same tab, go to https://www.youtube.com/robots.txt
    3. Export the youtube.com cookies in Netscape format with a cookies.txt
       browser extension you trust.
    4. Close the private window without logging out. This stops YouTube from
       rotating the cookies you just exported.

  yt-dlp updates the file with refreshed cookies after each run.

AUTO SUBTITLES
  By default only human-made subtitles are saved. With -s, a second,
  subtitles-only pass also saves auto-generated ones, as separate files named
  <name>.auto.<lang>.vtt so they are never mistaken for human-made tracks.
  In MKV files they are also embedded as extra tracks titled
  "Auto-generated (<lang>)", which players show in their subtitle menus.
  Embedding needs mkvmerge from MKVToolNix.

  LANGS is "orig" for the transcript in the video's own language (recommended),
  or a comma-separated list of language codes or regular expressions passed to
  yt-dlp, e.g. "en-orig,es". Codes ending in "-orig" are original-language
  transcripts; plain codes like "es" are YouTube's machine translations.

  The extra pass looks up every video a second time, and pacing adds about 5
  seconds per subtitle file, so keep the list short. Videos already listed in
  archive-autosubs.txt are skipped; to fetch new languages for them, delete
  that file. -s also works on videos archived earlier without it.

Examples:
  $SCRIPT_NAME "https://www.youtube.com/playlist?list=..."
  $SCRIPT_NAME -a -o /mnt/data/Archive URL1 URL2
  $SCRIPT_NAME -s orig "https://www.youtube.com/playlist?list=..."
  $SCRIPT_NAME -r 1080 -l 5M -c ~/.secrets/cookies.txt "https://www.youtube.com/@channel/playlists"
EOF
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

# Use the yt-dlp next to this script if present, otherwise the one on PATH.
find_yt_dlp() {
    if [ -x "$SCRIPT_DIR/yt-dlp" ]; then
        YT_DLP="$SCRIPT_DIR/yt-dlp"
    elif command -v yt-dlp > /dev/null 2>&1; then
        YT_DLP="$(command -v yt-dlp)"
    else
        die "yt-dlp not found next to this script or on your PATH.
Get the latest release from https://github.com/yt-dlp/yt-dlp/releases"
    fi
}

# Turn a yt-dlp version (YYYY.MM.DD, optionally with a nightly suffix) into
# a number YYYYMMDD, or print nothing if it doesn't look like one.
version_number() {
    local number
    number="$(echo "$1" | cut -d. -f1-3 | tr -d '.')"
    case "$number" in
        '' | *[!0-9]*) ;;
        *) echo "$number" ;;
    esac
}

# Warn if a newer yt-dlp release is available on GitHub. Never fatal.
check_for_update() {
    local current latest

    current="$("$YT_DLP" --version 2>/dev/null)"
    if ! command -v curl > /dev/null 2>&1; then
        log "Note: curl not found; skipping the yt-dlp update check."
        return
    fi
    # GitHub redirects .../releases/latest to .../releases/tag/<version>.
    latest="$(curl -fsSI --max-time 5 "$RELEASES_URL" 2>/dev/null \
        | tr -d '\r' | sed -n 's|^[Ll]ocation:.*/tag/||p')"
    if [ -z "$(version_number "$current")" ] || [ -z "$(version_number "$latest")" ]; then
        log "Note: could not check GitHub for a newer yt-dlp; skipping."
        return
    fi

    if [ "$(version_number "$latest")" -gt "$(version_number "$current")" ]; then
        warn "A newer yt-dlp is available ($latest; you have $current at $YT_DLP).
Outdated versions often break on YouTube. Update it the way it was installed:
  standalone binary:  $YT_DLP -U
  pip:                python3 -m pip install -U \"yt-dlp[default]\"
  pipx:               pipx upgrade yt-dlp
  Homebrew:           brew upgrade yt-dlp
  distro packages:    usually lag behind; switch to one of the above."
    fi
}

# Ask yt-dlp which dependencies it can find. Its verbose header lists
# ffmpeg/ffprobe, optional libraries and the JavaScript runtime in use.
check_dependencies() {
    local header exe_line libs_line js_line

    # With no URL, yt-dlp prints the header and exits with a usage error.
    header="$("$YT_DLP" --ignore-config --verbose "${runtime_args[@]}" 2>&1)"
    echo "$header" | grep '^\[debug\]' >> "$LOG_FILE"

    exe_line="$(echo "$header" | grep 'exe versions:')"
    libs_line="$(echo "$header" | grep 'Optional libraries:')"
    js_line="$(echo "$header" | grep 'JS runtimes:')"

    case "$exe_line" in
        *ffmpeg*) ;;
        *) die "ffmpeg not found. Install ffmpeg (which includes ffprobe) and try again." ;;
    esac
    case "$exe_line" in
        *ffprobe*) ;;
        *) die "ffprobe not found. It normally comes with ffmpeg." ;;
    esac

    case "$libs_line" in
        *yt_dlp_ejs*) ;;
        *) warn "yt-dlp-ejs not found; YouTube may only offer limited formats.
Use an official yt-dlp binary or install with: pip install -U \"yt-dlp[default]\"" ;;
    esac
    case "$libs_line" in
        *mutagen*) ;;
        *) warn "mutagen not found; thumbnails can't be embedded in audio files." ;;
    esac

    case "$js_line" in
        '' | *none* | *unsupported*)
            warn "No supported JavaScript runtime found (${js_line#*JS runtimes: }).
YouTube may only offer limited formats. Install deno >= 2.3, or choose
another installed runtime with -j (see -h for supported versions)." ;;
    esac
}

# ---------------------------------------------------------------------------
# Auto-generated subtitles
# ---------------------------------------------------------------------------

# Convert a YouTube auto-generated WebVTT file to plain SRT for embedding.
# YouTube's "rolling" auto captions use inline word timings, positioning
# settings and 10 ms transition cues, which some player and ffmpeg versions
# mishandle once embedded. This keeps each cue's text, drops the tags,
# settings, whitespace-only lines and cues of 20 ms or less. Times are
# parsed with integer arithmetic only, since some awks read decimals using
# the locale's decimal separator.
vtt_to_srt() {
    # Carriage returns are removed first: awk's blank-line record separator
    # doesn't treat "\r" lines as blank.
    tr -d '\r' < "$1" | awk '
        function ms(t,    parts, n, secs) {
            n = split(t, parts, ":")
            split(parts[n], secs, ".")
            return (((n == 3 ? parts[1] : 0) * 60 + parts[n - 1]) * 60 + secs[1]) * 1000 + secs[2]
        }
        function srt_time(x) {
            return sprintf("%02d:%02d:%02d,%03d", int(x / 3600000), int(x / 60000) % 60, int(x / 1000) % 60, x % 1000)
        }
        BEGIN { RS = ""; FS = "\n"; count = 0 }
        {
            timing = 0
            for (i = 1; i <= NF; i++) {
                if (!timing && index($i, "-->")) timing = i
            }
            if (!timing) next
            split($timing, t, /[ \t]+/)
            start = ms(t[1]); end = ms(t[3])
            if (end - start <= 20) next

            text = ""
            for (i = timing + 1; i <= NF; i++) {
                line = $i
                gsub(/<[^>]*>/, "", line)
                gsub(/&nbsp;/, " ", line); gsub(/&lt;/, "<", line)
                gsub(/&gt;/, ">", line); gsub(/&amp;/, "\\&", line)
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line != "") text = text (text == "" ? "" : "\n") line
            }
            if (text == "") next
            printf "%d\n%s --> %s\n%s\n\n", ++count, srt_time(start), srt_time(end), text
        }
    '
}

# Embed the <name>.auto.<lang>.vtt files next to an MKV as extra subtitle
# tracks titled "Auto-generated (<lang>)", replacing any embedded by an
# earlier run. Human-made tracks, attachments and chapters are kept.
#
# This uses mkvmerge rather than ffmpeg: yt-dlp's own embedding drops the
# existing subtitle tracks, and adding tracks with some ffmpeg builds produced
# subtitles that stopped after the first line. The tracks are embedded as SRT
# converted by vtt_to_srt, which every player supports (mkvmerge's WebVTT
# format isn't recognised by older ffmpeg-based players); the .vtt files stay
# as downloaded.
embed_auto_subs() {
    local video="$1" name tmp line sub lang srt status=0
    local drop="" drop_args=() sub_args=() srt_files=()

    name="${video%.mkv}"
    tmp="$name.embedding.mkv"

    # Existing subtitle tracks, one "index,title" line each. For Matroska,
    # ffprobe's stream index equals mkvmerge's track ID. Tracks added by an
    # earlier run are dropped so they can be replaced.
    while IFS= read -r line; do
        case "${line#*,}" in
            "Auto-generated ("*) drop="$drop${drop:+,}${line%%,*}" ;;
        esac
    done << EOF
$(ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=title -of csv=p=0 "$video")
EOF

    for sub in "$name".auto.*.vtt; do
        [ -e "$sub" ] || continue
        lang="${sub#"$name.auto."}"
        lang="${lang%.vtt}"
        srt="$name.embedding.$lang.srt"
        srt_files+=("$srt")
        vtt_to_srt "$sub" > "$srt" || status=1
        sub_args+=(--language "0:${lang%-orig}"
                   --track-name "0:Auto-generated ($lang)"
                   --default-track-flag 0:no
                   "$srt")
    done

    if [ "$status" -eq 0 ] && [ ${#sub_args[@]} -gt 0 ]; then
        # Write a new file next to the original, then replace it, keeping its
        # modification time. mkvmerge exits with 1 for warnings, 2 for errors.
        if [ -n "$drop" ]; then
            drop_args=(--subtitle-tracks "!$drop")
        fi
        run_mkvmerge -q -o "$tmp" "${drop_args[@]}" "$video" "${sub_args[@]}"
        if [ $? -le 1 ]; then
            touch -r "$video" "$tmp"
            mv -f "$tmp" "$video"
        else
            rm -f "$tmp"
            status=1
        fi
    fi
    if [ ${#srt_files[@]} -gt 0 ]; then
        rm -f "${srt_files[@]}"
    fi
    return "$status"
}

# mkvmerge decodes file names using the locale, so under the POSIX locale
# (common for cron jobs and minimal shells) it can't open names with
# non-ASCII characters, which yt-dlp's filename sanitising often produces.
# MKVMERGE_LOCALE is set to a UTF-8 locale in that case.
run_mkvmerge() {
    if [ -n "$MKVMERGE_LOCALE" ]; then
        LC_ALL="$MKVMERGE_LOCALE" mkvmerge "$@"
    else
        mkvmerge "$@"
    fi
}

# Embed auto-generated subtitles into the MKVs of the given video IDs.
# Returns non-zero if any video failed.
embed_auto_subs_for_ids() {
    local id video embedded=0 failed=0

    for id in "$@"; do
        while IFS= read -r video; do
            [ -n "$video" ] || continue
            if embed_auto_subs "$video"; then
                embedded=$((embedded + 1))
            else
                warn "could not embed auto-generated subtitles into $video
The .vtt files next to it are kept. To retry, remove the line for $id
from archive-autosubs.txt and run again."
                failed=$((failed + 1))
            fi
        done << EOF
$(find "$OUTPUT_DIR" -name "*\[$id\].mkv")
EOF
    done

    log "Embedded auto-generated subtitles into $embedded video(s)."
    [ "$failed" -eq 0 ]
}

# Warn if the cookies file is readable by other users.
check_cookies_file() {
    [ -r "$COOKIES_FILE" ] || die "cannot read cookies file: $COOKIES_FILE"
    if [ -n "$(find "$COOKIES_FILE" \( -perm -004 -o -perm -040 \) -print)" ]; then
        warn "$COOKIES_FILE is readable by other users. Consider: chmod 600 \"$COOKIES_FILE\""
    fi
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

# The leading ":" lets us report option errors ourselves.
while getopts ":ho:t:ar:n:l:pC:c:j:ws:" opt; do
    case $opt in
        h) show_help; exit 0 ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        t) TEMP_DIR="$OPTARG" ;;
        a) AUDIO_ONLY=true ;;
        r) RESOLUTION="$OPTARG" ;;
        n) RETRIES="$OPTARG" ;;
        l) RATE_LIMIT="$OPTARG" ;;
        p) PACING=false ;;
        C) COMMENTS="$OPTARG" ;;
        c) COOKIES_FILE="$OPTARG" ;;
        j) JS_RUNTIME="$OPTARG" ;;
        w) WINDOWS_FILENAMES=true ;;
        s) AUTO_SUBS="$OPTARG"
           [ -n "$AUTO_SUBS" ] || usage_error "-s expects \"orig\" or a list of languages" ;;
        :) usage_error "option -$OPTARG requires an argument" ;;
        *) usage_error "invalid option -$OPTARG" ;;
    esac
done
shift $((OPTIND - 1))

[ $# -gt 0 ] || usage_error "no URL given"

case "$RESOLUTION" in
    '') ;;
    *[!0-9]*) usage_error "-r expects a number, e.g. 1080" ;;
esac
case "$RETRIES" in
    infinite) ;;
    '' | *[!0-9]*) usage_error "-n expects a number or \"infinite\"" ;;
esac
case "$COMMENTS" in
    all) ;;
    '' | *[!0-9]*) usage_error "-C expects a number, \"all\" or 0" ;;
esac
if [ "$AUTO_SUBS" = orig ]; then
    AUTO_SUBS=".*-orig"
fi

case "$JS_RUNTIME" in
    '' | deno | node | quickjs | bun) ;;
    *) usage_error "-j expects one of: deno, node, quickjs, bun" ;;
esac

# Deno has the highest priority, so it must be disabled to use another runtime.
runtime_args=()
if [ -n "$JS_RUNTIME" ]; then
    runtime_args=(--no-js-runtimes --js-runtimes "$JS_RUNTIME")
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

find_yt_dlp

mkdir -p "$OUTPUT_DIR/logs" || die "cannot create output directory: $OUTPUT_DIR"
if [ -n "$TEMP_DIR" ]; then
    mkdir -p "$TEMP_DIR" || die "cannot create temp directory: $TEMP_DIR"
fi
LOG_FILE="$OUTPUT_DIR/logs/$(date +%Y%m%d-%H%M%S).log"
log "Logging to $LOG_FILE"

check_dependencies
check_for_update
if [ -n "$COOKIES_FILE" ]; then
    check_cookies_file
fi
log "Note: all yt-dlp configuration files are ignored (user, system and portable)."

# Embedding auto-generated subtitles (-s) needs mkvmerge; without it they are
# still saved as .vtt files.
EMBED_AUTO_SUBS=false
MKVMERGE_LOCALE=""
if [ -n "$AUTO_SUBS" ]; then
    if command -v mkvmerge > /dev/null 2>&1; then
        EMBED_AUTO_SUBS=true
        if [ "$(locale charmap 2>/dev/null)" != UTF-8 ]; then
            MKVMERGE_LOCALE="$(locale -a 2>/dev/null | grep -i -m 1 -E '^(C|en_US)\.utf-?8$')"
            if [ -z "$MKVMERGE_LOCALE" ]; then
                warn "no UTF-8 locale found; embedding may fail for file names
with non-ASCII characters."
            fi
        fi
    else
        warn "mkvmerge not found; auto-generated subtitles will be saved as .vtt
files but not embedded. Install MKVToolNix to embed them."
    fi
fi

# ---------------------------------------------------------------------------
# Build the yt-dlp commands
# ---------------------------------------------------------------------------

# Options shared by the main pass and the auto-subtitles pass.
common_args=(
    --ignore-config
    --paths "home:$OUTPUT_DIR"
    --retries "$RETRIES"
    --fragment-retries "$RETRIES"
    --retry-sleep "http:exp=1:60"
    --retry-sleep "fragment:exp=1:60"
    --progress-delta 2
)
if [ "$PACING" = true ]; then
    common_args+=(--preset-alias sleep)
fi
if [ -n "$RATE_LIMIT" ]; then
    common_args+=(--limit-rate "$RATE_LIMIT")
fi
if [ -n "$TEMP_DIR" ]; then
    common_args+=(--paths "temp:$TEMP_DIR")
fi
if [ -n "$COOKIES_FILE" ]; then
    common_args+=(--cookies "$COOKIES_FILE")
fi
if [ "$WINDOWS_FILENAMES" = true ]; then
    common_args+=(--windows-filenames)
fi
common_args+=("${runtime_args[@]}")

# Main pass: media, human-made subtitles, thumbnail, metadata and comments.
main_args=(
    --output "$OUTPUT_TEMPLATE"
    --download-archive "$OUTPUT_DIR/archive.txt"
    --write-info-json
    --embed-metadata
    --write-thumbnail
    --embed-thumbnail
    --write-subs
    --sub-langs "all,-live_chat"
)

if [ "$AUDIO_ONLY" = true ]; then
    # Extracting with "best" keeps the original codec: Opus lands in .opus,
    # AAC in .m4a. Audio containers can't hold subtitles, so they stay separate.
    main_args+=(--format "ba/b" --extract-audio --audio-format best)
else
    main_args+=(--format "bv*+ba/b" --merge-output-format mkv --embed-subs)
    if [ -n "$RESOLUTION" ]; then
        main_args+=(--format-sort "res:$RESOLUTION")
    fi
fi

case "$COMMENTS" in
    0) main_args+=(--no-write-comments) ;;
    all) main_args+=(--write-comments --extractor-args "youtube:comment_sort=top") ;;
    # At most $COMMENTS comments, of which at most 100 are replies.
    *) main_args+=(--write-comments --extractor-args "youtube:comment_sort=top;max_comments=$COMMENTS,all,100") ;;
esac

# Auto-subtitles pass (-s): subtitles only, auto-generated captions only.
# Human and auto tracks share language codes, so this can't be done in the
# main pass without either pulling in every machine translation or mixing
# the two up. Notes, all verified against yt-dlp:
#   - The ".auto" name must come from the main template. With a separate
#     "subtitle:" template yt-dlp writes to the normal subtitle name first,
#     overwriting a human track of the same language.
#   - No embedding by yt-dlp: it re-muxes the file and drops the human
#     tracks. embed_auto_subs adds them afterwards with ffmpeg instead.
#   - --skip-download doesn't record IDs in the archive without
#     --force-write-archive.
auto_subs_args=(
    --output "$AUTO_SUBS_TEMPLATE"
    --download-archive "$OUTPUT_DIR/archive-autosubs.txt"
    --force-write-archive
    --skip-download
    --write-auto-subs
    --sub-langs "$AUTO_SUBS"
)

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Run yt-dlp with the given options on the URLs, logging its output.
# "--" stops a video ID starting with "-" from being read as an option.
run_yt_dlp() {
    "$YT_DLP" "$@" -- "${URLS[@]}" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}
URLS=("$@")

log "Archiving ${#URLS[@]} URL(s) to $OUTPUT_DIR"
run_yt_dlp "${common_args[@]}" "${main_args[@]}"
status=$?

if [ -n "$AUTO_SUBS" ]; then
    # Videos processed by this pass are the IDs it appends to its archive.
    auto_archive="$OUTPUT_DIR/archive-autosubs.txt"
    archived_before=0
    if [ -f "$auto_archive" ]; then
        archived_before=$(wc -l < "$auto_archive")
    fi

    log "Saving auto-generated subtitles ($AUTO_SUBS)"
    run_yt_dlp "${common_args[@]}" "${auto_subs_args[@]}"
    auto_subs_status=$?

    if [ "$EMBED_AUTO_SUBS" = true ] && [ -f "$auto_archive" ]; then
        # Archive lines are "<extractor> <id>".
        # shellcheck disable=SC2046 # IDs contain no spaces or glob characters
        embed_auto_subs_for_ids $(tail -n +$((archived_before + 1)) "$auto_archive" | awk '{print $2}') \
            || auto_subs_status=1
    fi
    if [ "$status" -eq 0 ]; then
        status=$auto_subs_status
    fi
fi

if [ "$status" -eq 0 ]; then
    log "Done. Everything was archived to $OUTPUT_DIR"
else
    log "Finished with errors (exit code $status); some items may not have been archived."
    log "See $LOG_FILE. Re-running the same command retries only what is missing."
fi
exit "$status"
