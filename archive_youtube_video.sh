#!/usr/bin/env bash

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

usage() {
    echo "Usage: $(basename "$0") <youtube_video_url> [output_directory]" >&2
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

# Check for URL input
if [ -z "$1" ]; then
    usage
fi

# Variables
URL="$1"

FINAL_DIR="${2:-$HOME/Videos/Youtube Videos}"

# Step 1: Download the video, thumbnail, subtitles, and metadata
"$YT_DLP" \
    --format "bestvideo+bestaudio/best" \
    --merge-output-format mkv \
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
    --compat-options filename-sanitization \
    --output "$FINAL_DIR/%(uploader)s/%(id)s/%(title)s [%(id)s].%(ext)s" \
    "$URL" || error_exit "yt-dlp failed to download the video."

echo "All videos have been processed and saved in $FINAL_DIR."
exit 0
