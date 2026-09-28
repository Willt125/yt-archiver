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
OUTPUT_TEMPLATE="%(channel,uploader|Unknown)s/%(playlist|)s/%(playlist_index&{:04d} - |)s%(title).150B [%(id)s].%(ext)s"

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

Output layout:
  DIR/<channel>/<playlist>/<index> - <title> [<id>].<ext>
  DIR/archive.txt             IDs already downloaded; they are skipped next time
  DIR/logs/<date-time>.log    Log of each run

  A video in several playlists is only saved under the first one downloaded.

Requirements:
  yt-dlp (preferably the latest release), ffmpeg and ffprobe. For full YouTube
  support yt-dlp also needs yt-dlp-ejs and a JavaScript runtime (deno >= 2.3,
  node >= 22, quickjs >= 2023-12-9, any quickjs-ng, or bun 1.2.11-1.3.14,
  which is deprecated). mutagen is needed to embed thumbnails in audio files.
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

Examples:
  $SCRIPT_NAME "https://www.youtube.com/playlist?list=..."
  $SCRIPT_NAME -a -o /mnt/data/Archive URL1 URL2
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
while getopts ":ho:t:ar:n:l:pC:c:j:w" opt; do
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

# ---------------------------------------------------------------------------
# Build the yt-dlp command
# ---------------------------------------------------------------------------

args=(
    --ignore-config
    --paths "home:$OUTPUT_DIR"
    --output "$OUTPUT_TEMPLATE"
    --download-archive "$OUTPUT_DIR/archive.txt"
    --write-info-json
    --embed-metadata
    --write-thumbnail
    --embed-thumbnail
    --write-subs
    --sub-langs "all,-live_chat"
    --retries "$RETRIES"
    --fragment-retries "$RETRIES"
    --retry-sleep "http:exp=1:60"
    --retry-sleep "fragment:exp=1:60"
    --progress-delta 2
)

if [ "$AUDIO_ONLY" = true ]; then
    # Extracting with "best" keeps the original codec: Opus lands in .opus,
    # AAC in .m4a. Audio containers can't hold subtitles, so they stay separate.
    args+=(--format "ba/b" --extract-audio --audio-format best)
else
    args+=(--format "bv*+ba/b" --merge-output-format mkv --embed-subs)
    if [ -n "$RESOLUTION" ]; then
        args+=(--format-sort "res:$RESOLUTION")
    fi
fi

case "$COMMENTS" in
    0) args+=(--no-write-comments) ;;
    all) args+=(--write-comments --extractor-args "youtube:comment_sort=top") ;;
    # At most $COMMENTS comments, of which at most 100 are replies.
    *) args+=(--write-comments --extractor-args "youtube:comment_sort=top;max_comments=$COMMENTS,all,100") ;;
esac

if [ "$PACING" = true ]; then
    args+=(--preset-alias sleep)
fi
if [ -n "$RATE_LIMIT" ]; then
    args+=(--limit-rate "$RATE_LIMIT")
fi
if [ -n "$TEMP_DIR" ]; then
    args+=(--paths "temp:$TEMP_DIR")
fi
if [ -n "$COOKIES_FILE" ]; then
    args+=(--cookies "$COOKIES_FILE")
fi
if [ "$WINDOWS_FILENAMES" = true ]; then
    args+=(--windows-filenames)
fi
args+=("${runtime_args[@]}")

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

log "Archiving $# URL(s) to $OUTPUT_DIR"
# "--" stops a video ID starting with "-" from being read as an option.
"$YT_DLP" "${args[@]}" -- "$@" 2>&1 | tee -a "$LOG_FILE"
status=${PIPESTATUS[0]}

if [ "$status" -eq 0 ]; then
    log "Done. Everything was archived to $OUTPUT_DIR"
else
    log "yt-dlp reported errors (exit code $status); some items may not have been archived."
    log "See $LOG_FILE. Re-running the same command retries only what is missing."
fi
exit "$status"
