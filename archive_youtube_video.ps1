# Error handling function
function ErrorExit($message) {
    Write-Error $message
    exit 1
}

param (
    [Parameter(Mandatory)]
    [string]$URL,                                                        # YouTube video URL
    [string]$OutputDirectory = "$env:USERPROFILE\Videos\YouTube Videos", # Default output directory
    [string]$Browser,                                                    # Browser to use for cookies (e.g., "firefox", "chrome")
    [string]$UserAgent                                                   # Custom user-agent string
)

# Check for yt-dlp, ffmpeg
$Local_YT_DLP= ".\yt-dlp.exe"
if (Test-Path $Local_YT_DLP) {
    $YT_DLP = New-Object System.Collections.ArrayList
    $YT_DLP.Add($Local_YT_DLP) | Out-Null
} elseif (Get-Command yt-dlp -ErrorAction SilentlyContinue) {
    $YT_DLP = New-Object System.Collections.ArrayList
    $YT_DLP.Add("yt-dlp") | Out-Null
    Write-Warning "Using system-wide yt-dlp. Ensure it's up to date."
} else {
    ErrorExit("yt-dlp not found. Download the latest version from Github and place it in this directory.")
}

if (-Not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    ErrorExit "ffmpeg is required but not installed. Please install it and ensure it's available in PATH."
}

# Create temporary directory
$TEMP_DIR = Join-Path $env:TEMP ("yt_archive_" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $TEMP_DIR | Out-Null

# Cleanup on exit
$Cleanup = {
    if (Test-Path $TEMP_DIR) {
        Remove-Item -Recurse -Force $TEMP_DIR
    }
}
Register-EngineEvent PowerShell.Exiting -Action $Cleanup

if ($Browser) {
    $YT_DLP.Add("--cookies-from-browser") | Out-Null
    $YT_DLP.Add($Browser) | Out-Null
}
if ($UserAgent) {
    $YT_DLP.Add("--user-agent") | Out-Null
    $YT_DLP.Add($UserAgent) | Out-Null
}

# Add core arguments
$YT_DLP.AddRange(@(
    "--format" "bestvideo+bestaudio/best",
    "--merge-output-format" "mkv",
    "--write-thumbnail",
    "--write-sub",
    "--sub-langs" "all",
    "--write-info-json",
    "--compat-options" "filename-sanitization",
    "--output" "$TEMP_DIR\%(uploader)s\%(id)s\%(title)s [%(id)s].%(ext)s",
    $URL
)) | Out-Null

Write-Host "Executing yt-dlp with the following command:"
Write-Host "$($YT_DLP -join ' ')"
Try {
    & $YT_DLP 2>&1 | Write-Host
} Catch {
    ErrorExit "yt-dlp encountered an error: $($_.Exception.Message)"
}

# Process downloaded files
Get-ChildItem -Path $TEMP_DIR -Directory | ForEach-Object {
    $UploaderDir = $_
    Get-ChildItem -Path $UploaderDir.FullName -Directory | ForEach-Object {
        $VideoDir = $_
        $Files = Get-ChildItem -Path $VideoDir.FullName
        $VideoFile = $Files | Where-Object { $_.Extension -eq ".mkv" }
        $InfoJson = $Files | Where-Object { $_.Extension -eq ".info.json" }

        if (-not $VideoFile -or -not $InfoJson) {
            ErrorExit "Required files not found in $VideoDir."
        }

        # Extract metadata
        Try {
            $Metadata = Get-Content $InfoJson.FullName | ConvertFrom-Json
        } Catch {
            ErrorExit "Failed to parse metadata: $($InfoJson.FullName)"
        }
        $Title = $Metadata.title
        $Uploader = $Metadata.uploader
        $Description = $Metadata.description
        $URL = $Metadata.webpage_url

        # Extract chapters if they exist
        $ChaptersFile = Join-Path $VideoDir.FullName "chapters.txt"
        if ($Metadata.chapters) {
            $Metadata.chapters | ForEach-Object {
@"
[CHAPTER]
TIMEBASE=1/1
START=$([math]::Round($_.start_time))
END=$([math]::Round($_.end_time))
TITLE=$($_.title)
"@ | Out-File -Append -FilePath $ChaptersFile
            }
        }

    # Convert all .vtt subtitle files to .srt
    $SubtitleInputs = @()
    $SubtitleMappings = @()
    $SubtitleIndex = 2

    Get-ChildItem -Path $VideoDir.FullName -Filter "*.vtt" | ForEach-Object {
        $VttFile = $_
        $SrtFile = $VttFile.FullName -replace "\.vtt$", ".srt"
        & ffmpeg -i $VttFile.FullName $SrtFile
        if ($LASTEXITCODE -ne 0) {
            ErrorExit "Failed to convert subtitles: $($VttFile.FullName)"
        }

        # Extract language code from file name
        $LangCode = $VttFile.BaseName -replace ".*\.", ""
        $SubtitleInputs += @("-i", $SrtFile)
        $SubtitleMappings += @("-map", $SubtitleIndex, "-c:s:$($SubtitleIndex-2)", "srt", "-metadata:s:s:$($SubtitleIndex-2)", "language=$LangCode")
        $SubtitleIndex++
    }

        # Use ffmpeg to combine everything into the final video
        $FinalOutputDir = $OutputDirectory
        if (-not (Test-Path $FinalOutputDir)) {
            New-Item -ItemType Directory -Path $FinalOutputDir | Out-Null
        }
        $FinalOutput = Join-Path $FinalOutputDir ($VideoFile.BaseName + ".mkv")

        #construct arguments
        $FfmpegArgs = @(
            "-i", $VideoFile.FullName,
            "-c:v", "copy", "-c:a", "copy",
            "-metadata", "title=$Title",
            "-metadata", "author=$Uploader",
            "-metadata", "description=$Description",
            "-metadata", "comment=$VideoURL"
        )

        # Add chapters if they exist
        if (Test-Path $ChaptersFile) {
            $FfmpegArgs += @("-i", $ChaptersFile, "-map_metadata", $SubtitleIndex)
        }

        # Add subtitles if they exist
        if ($SubtitleInputs.Count -gt 0) {
            $FfmpegArgs += $SubtitleInputs
            $FfmpegArgs += $SubtitleMappings
        }

        $FfmpegArgs += @($FinalOutput)

        # Execute ffmpeg
        Write-Host "Executing FFmpeg to create final video:"
        Write-Host "$($FfmpegArgs -join ' ')"
        & ffmpeg @FfmpegArgs
        if ($LASTEXITCODE -ne 0) {
            ErrorExit "Failed to create final video: $FinalOutput"
        }
        Write-Output "Archived video created at $FinalOutput"
    }
}

# Cleanup
Write-Output "All videos have been processed and saved in $OutputDirectory."