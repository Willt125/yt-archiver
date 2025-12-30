#!/bin/bash

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Set YT_DLP to the local yt-dlp if it exists, otherwise use the system-wide one
if [ -x "./yt-dlp" ]; then
    YT_DLP="./yt-dlp"
elif command -v yt-dlp &> /dev/null; then
    YT_DLP="yt-dlp"
    echo "WARNING: Falling back to system-installed yt-dlp."
    echo "The version of yt-dlp available on APT is ALMOST ALWAYS"
    echo "outdated and will probably cause issues."
    echo "STRONGLY consider using the latest version of yt-dlp available on Github."
    echo "Place it in the same directory as this script, and ensure the execute bit is set."
    sleep 3  # Pause to give the user time to read the warning
else
    echo "yt-dlp is required but was not found in the current directory or in PATH."
    echo "Download it from Github and place it in the same directory as this script,"
    echo "and ensure the execute bit is set."
    echo "Using the version from APT is NOT RECOMMENDED."
    exit 1
fi

# Check for required tools: ffmpeg, jq
if ! command -v ffmpeg &> /dev/null || ! command -v jq &> /dev/null; then
    error_exit "This script requires ffmpeg and jq. Please install them first."
fi

# Check for URL input
if [ -z "$1" ]; then
    error_exit "Usage: $0 <youtube_video_url> [output_directory]"
fi

# Variables
URL=$1
TEMP_DIR=$(mktemp -d /tmp/yt_archive.XXXXXX) || error_exit "Failed to create temporary directory."
FINAL_DIR="${2:-$HOME/Videos/Youtube Videos}"

trap 'rm -rf "$TEMP_DIR"' EXIT

# Step 1: Download the video, thumbnail, subtitles, and metadata
$YT_DLP \
    --format "bestvideo+bestaudio/best" \
    --merge-output-format mkv \
    --write-thumbnail \
    --write-sub \
    --sub-langs "all" \
    --write-info-json \
    --compat-options filename-sanitization \
    --output "$TEMP_DIR/%(uploader)s/%(id)s/%(title)s [%(id)s].%(ext)s" \
    "$URL" || error_exit "yt-dlp failed to download the video."

# Process each video in the temp directory
for video_dir in "$TEMP_DIR"/*/*; do
    if [ ! -d "$video_dir" ]; then
        error_exit "No videos found to process in $TEMP_DIR."
    fi

    find "$video_dir" -type f -name "*.mkv" | while read -r mkv_file; do
        BASENAME=$(basename "$mkv_file" .mkv)
        VIDEO_FILE="$video_dir/$BASENAME.mkv"
        THUMBNAIL_WEBP="$video_dir/$BASENAME.webp"
        INFO_JSON="$video_dir/$BASENAME.info.json"
        CHAPTERS_FILE="$video_dir/${BASENAME}_chapters.txt"
        THUMBNAIL_PNG="$video_dir/$BASENAME.png"
        UPLOADER=$(basename "$(dirname "$video_dir")")
        FINAL_OUTPUT_DIR="${FINAL_DIR}/${UPLOADER}/$BASENAME.mkv"

        mkdir -p "$FINAL_DIR/$UPLOADER" || error_exit "mkdir failed to create the final directory!"

        # Step 2: Convert thumbnail to png, subtitles to srt, and extract chapters

        # Convert thumbnail to png
        if [ -f "$THUMBNAIL_WEBP" ]; then
            ffmpeg -i "$THUMBNAIL_WEBP" -frames:v 1 "$THUMBNAIL_PNG" || error_exit "ffmpeg failed to convert the thumbnail."
        fi

        # Extract chapters from info.json and save as ffmetadata format
        if [ -f "$INFO_JSON" ]; then
            jq -r '.chapters | to_entries | map("[CHAPTER]\nTIMEBASE=1/1\nSTART=" + (.value.start_time | tostring) + "\nEND=" + (.value.end_time | tostring) + "\nTITLE=" + .value.title) | .[]' "$INFO_JSON" > "$CHAPTERS_FILE"

            # Not all videos will have chapters.
            if [ ! -s "$CHAPTERS_FILE" ]; then
                rm "$CHAPTERS_FILE"
            fi
        fi

        # Extract metadata from info.json
        title=$(jq -r .title "$INFO_JSON") || error_exit "jq failed to extract the video title."
        author=$(jq -r .uploader "$INFO_JSON") || error_exit "jq failed to extract the video author."
        description=$(jq -r .description "$INFO_JSON") || error_exit "jq failed to extract the video description."
        comment=$(jq -r .webpage_url "$INFO_JSON") || error_exit "jq failed to extract the video url."

        # Step 3: Convert all .vtt subtitle files to .srt and prepare ffmpeg subtitle inputs
        subtitle_inputs=()
        subtitle_mappings=()
        subtitle_index=2 # Start from stream index 2, since 0 is video, 1 is audio

        for vtt_file in "$video_dir"/*.vtt; do
            if [ -f "$vtt_file" ]; then
                # Convert .vtt to .srt
                srt_file="${vtt_file%.vtt}.srt"
                ffmpeg -i "$vtt_file" "$srt_file" || error_exit "ffmpeg failed to convert the subtitles."

                # Get language code (last part of the filename, e.g., "en" for "video.en.vtt")
                lang_code=$(basename "$vtt_file" | grep -oP "(?<=\.)\w+(?=\.vtt)")

                # Add subtitle input and mapping for ffmpeg
                subtitle_inputs+=("-i" "$srt_file")
                subtitle_mappings+=("-map" "$subtitle_index" "-c:s:$((subtitle_index-2))" "srt" "-metadata:s:s:$((subtitle_index-2))" "language=$lang_code")

                # Increment index for the next subtitle stream
                subtitle_index=$((subtitle_index + 1))
            fi
        done

        # Step 4: Use ffmpeg to embed thumbnail, subtitles, chapters, and metadata into the final video
        if [ -f "$CHAPTERS_FILE" ]; then
            ffmpeg -i "$VIDEO_FILE" \
                -i "$THUMBNAIL_PNG" \
                "${subtitle_inputs[@]}" \
                -i "$CHAPTERS_FILE" \
                -map 0:v -map 0:a -map 1 \
                "${subtitle_mappings[@]}" \
                -c:v copy -c:a copy -c:s srt \
                -metadata:s:v:1 title="Thumbnail" \
                -metadata title="$title" \
                -metadata author="$author" \
                -metadata description="$description" \
                -metadata comment="$comment" \
                -map_metadata "$subtitle_index" \
                "$FINAL_OUTPUT_DIR"  || error_exit "ffmpeg failed to create the final video."
        else
            ffmpeg -i "$VIDEO_FILE" \
                -i "$THUMBNAIL_PNG" \
                "${subtitle_inputs[@]}" \
                -map 0:v -map 0:a -map 1 \
                "${subtitle_mappings[@]}" \
                -c:v copy -c:a copy -c:s srt \
                -metadata:s:v:1 title="Thumbnail" \
                -metadata title="$title" \
                -metadata author="$author" \
                -metadata description="$description" \
                -metadata comment="$comment" \
                "$FINAL_OUTPUT_DIR"  || error_exit "ffmpeg failed to create the final video."
        fi
        echo "Archived video created at $FINAL_OUTPUT_DIR"
    done
done

# Cleanup temporary files

echo "All videos have been processed and saved in $FINAL_DIR."
exit 0
