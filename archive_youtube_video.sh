#!/usr/bin/env bash

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

usage() {
    cat >&2 << EOF
Usage: $(basename "$0") [OPTIONS] <url> [output_directory]

Options:
  -a          Audio only (best audio stream, no video)
  -r RATE     Limit download rate (e.g. 10M, 500K)
EOF
    exit 1
}

# Set YT_DLP to the local yt-dlp if it exists, otherwise use the system-wide one
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/yt-dlp" ]; then
    YT_DLP="$SCRIPT_DIR/yt-dlp"
elif command -v yt-dlp &> /dev/null; then
    YT_DLP="yt-dlp"
    cat >&2 << 'EOF'
WARNING: Falling back to system-installed yt-dlp.
The version of yt-dlp available on APT is ALMOST ALWAYS
outdated and will probably cause issues.
STRONGLY consider using the latest version of yt-dlp available on Github.
Place it in the same directory as this script, and ensure the execute bit is set.
EOF
    sleep 3  # Pause to give the user time to read the warning
else
    cat >&2 << 'EOF'
yt-dlp is required but was not found in the script directory or in PATH.
Download it from Github and place it in the same directory as this script,
and ensure the execute bit is set.
Using the version from APT is NOT RECOMMENDED.
EOF
    exit 1
fi

AUDIO_ONLY=false
RATE_LIMIT=""

while getopts "ar:" opt; do
    case $opt in
        a) AUDIO_ONLY=true ;;
        r) RATE_LIMIT="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# Variables
URL="$1"

FINAL_DIR="${2:-$HOME/Videos/Youtube Videos}"

if [ -z "$URL" ]; then
    usage
fi

rate_args=()
[ -n "$RATE_LIMIT" ] && rate_args+=("--limit-rate" "$RATE_LIMIT")

if [ "$AUDIO_ONLY" = true ]; then
    format_args=(
        --format "bestaudio/best"
        --remux-video "m4a>m4a/ogg>ogg/bestaudio"
    )
else
    format_args=(
        --format "bestvideo+bestaudio/best"
        --merge-output-format mkv
    )
fi

"$YT_DLP" \
    "${format_args[@]}" \
    --write-thumbnail \
    --embed-thumbnail \
    --convert-thumbnails png \
    --write-subs --write-auto-subs \
    --sub-langs "all" \
    --embed-subs \
    --convert-subs srt \
    --write-info-json \
    --embed-metadata \
    --embed-chapters \
    --no-abort-on-error \
    --retries infinite \
    --fragment-retries infinite \
    --retry-sleep exp=1:60:2 \
    --throttled-rate 100K \
    "${rate_args[@]}" \
    --compat-options filename-sanitization \
    --output "$FINAL_DIR/%(uploader)s/%(id)s/%(title)s [%(id)s].%(ext)s" \
    "$URL" || error_exit "yt-dlp failed to download the video."

echo "All videos have been processed and saved in $FINAL_DIR."
exit 0
