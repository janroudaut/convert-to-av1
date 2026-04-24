# convert-to-av1

Batch video converter to AV1 using FFmpeg and SVT-AV1. Designed to reduce storage for TV recordings, series, and movies with minimal effort.

## Features

- **In-place conversion** (default) or output to a separate directory
- **MPEG-TS fix** — auto-detects `.ts` containers and applies timestamp correction flags
- **Smart mode** — keeps the best version (source or output) based on file size
- **Early abort** — stops encoding at ~8% if the output is estimated to be larger than the source
- **Subtitle merging** — auto-detects adjacent `.srt`/`.vtt` files (including multi-language) and muxes them into the output MKV
- **Description embedding** — reads adjacent `.txt` files and embeds them as MKV `description` metadata
- **Audio re-encoding** — optional Opus re-encoding with automatic bitrate detection
- **Resolution scaling** — downscale to 1080p, 720p, or any custom height
- **Recursive mode** — process entire directory trees
- **Sort by size** — process smallest (or largest) files first
- **File filtering** — skip files below a minimum size, exclude by glob pattern
- **Clean progress bar** — real-time progress with speed, ETA, and fps
- **Detailed file info** — shows container, duration, bitrate, streams, and detected external files before each conversion
- **Graceful failures** — one failed file doesn't stop the batch; summary table at the end
- **Lock files** — prevents concurrent conversion of the same file
- **Post-batch command** — run a custom command after the batch completes
- **NO_COLOR support** — respects the [NO_COLOR](https://no-color.org/) standard
- **Dry run mode** — preview what would happen without converting
- **Dependency check** — verify all required tools are installed with `--check`

## Requirements

- `ffmpeg` and `ffprobe` (with `libsvtav1` support)
- `python3` (for file info display)
- Standard GNU utils: `bc`, `numfmt`, `stat`, `mktemp`

Verify your setup:

```bash
./convert-to-av1.sh --check
```

## Quick start

```bash
# Convert all videos in current directory (in-place, default settings)
./convert-to-av1.sh .

# Convert a single file
./convert-to-av1.sh video.mp4

# Smart mode: keep best version, remove source if smaller, abort early if not worth it
./convert-to-av1.sh --smart .

# Recursively convert an entire series folder
./convert-to-av1.sh --smart -r /path/to/series/

# Convert to a separate output directory
./convert-to-av1.sh -o /path/to/output/ *.ts

# Fast encoding for quick results
./convert-to-av1.sh --fast .

# High quality encoding
./convert-to-av1.sh --hq .

# Preview what would be done
./convert-to-av1.sh --dry-run --sort-by-size .
```

## Docker

### Build

```bash
docker build -t convert-to-av1 .
```

### Run

```bash
# Convert all videos in current directory
docker run --rm -v "$PWD:/media" --user "$(id -u):$(id -g)" convert-to-av1 .

# Smart mode on a specific folder
docker run --rm -v "/path/to/videos:/media" --user "$(id -u):$(id -g)" convert-to-av1 --smart .

# Interactive mode (progress bar, skip with ">", colors)
docker run --rm -it -v "$PWD:/media" --user "$(id -u):$(id -g)" convert-to-av1 --smart .

# Check dependencies inside the container
docker run --rm convert-to-av1 --check
```

- **`--user "$(id -u):$(id -g)"`** ensures output files are owned by your host user, not root
- **`-it`** enables the progress bar and colors (the script auto-detects TTY)
- **`-v`** bind-mounts the directory containing your videos to `/media`

### Wrapper

A convenience wrapper (`convert-to-av1-docker`) handles volume mounting, UID/GID mapping, and TTY detection automatically:

```bash
# Same usage as the native script
./convert-to-av1-docker --smart .
./convert-to-av1-docker --fast -r /path/to/videos/
./convert-to-av1-docker --check
```

## Usage

```
convert-to-av1 [options] FILES[...]
```

### Output

| Flag | Description |
|------|-------------|
| `-o, --output-dir DIR` | Store converted files in DIR (auto-created) |
| `--in-place` | Convert and replace in-place (default when no `-o`) |

### File management

| Flag | Description |
|------|-------------|
| `--smart, --keep-best-version` | Combines `--rm-src` + `--rm-if-bigger` + `--quality-check`; keeps the best version |
| `--rm-source, --rm-src` | Remove source if output is smaller |
| `--rm-if-bigger` | Remove output if it's larger than source |
| `-y, --overwrite` | Overwrite existing output file |

### Quality

| Flag | Description |
|------|-------------|
| `--max-res, --max-h HEIGHT` | Scale down to HEIGHT px if source is taller |
| `--1080, --1080p` | Alias for `--max-res 1080` |
| `--720, --720p` | Alias for `--max-res 720` |
| `--sd, --fast` | Fast encoding (preset 10, CRF 32) |
| `--hq` | High quality (preset 4, CRF 28, film-grain 8) |
| `--cartoon` | Optimised for animation (no grain, higher CRF) |
| `--tv` | Optimised for TV/broadcasts (no grain, faster preset) |
| `--movie` | Optimised for cinema (film-grain + denoise, lower CRF) |

Speed presets (`--fast`, default, `--hq`) and content presets (`--cartoon`, `--tv`, `--movie`) are combinable in any order: `--fast --cartoon`, `--hq --movie`, etc.

Default: preset 8, CRF 30, 10-bit, no film-grain.

#### Preset matrix

| | `--fast` | default | `--hq` |
|---|---|---|---|
| *(none)* | p10 crf32 | p8 crf30 | p4 crf28 grain=8 |
| `--cartoon` | p10 crf34 | p8 crf32 | p4 crf30 |
| `--tv` | p10 crf33 | p10 crf31 | p10 crf29 |
| `--movie` | p10 crf30 grain=8 denoise | p8 crf28 grain=10 denoise | p4 crf26 grain=10 denoise |

All presets use 10-bit encoding, enable-overlays, and scene-change detection. Film-grain synthesis is only enabled for `--hq` (alone) and `--movie` — it improves perceived quality for film content but has a significant performance cost (~3.5x slower). `--movie` also enables `film-grain-denoise` to preserve and re-synthesize grain from the source.

### Batch

| Flag | Description |
|------|-------------|
| `-r, --recursive` | Recurse into subdirectories |
| `--sort-by-size [asc\|desc]` | Sort files by size before processing (default: desc) |
| `--min-size SIZE` | Skip files smaller than SIZE (e.g., `100M`, `1G`) |
| `--exclude PATTERN` | Exclude files matching glob pattern (repeatable) |
| `--dry-run` | Show what would be done without converting |
| `--no-early-abort` | Disable early abort when output is estimated larger |
| `--early-abort-threshold PCT` | Progress % at which to evaluate (default: 8) |
| `--after CMD` | Run CMD after the batch completes |

### Audio

| Flag | Description |
|------|-------------|
| `--opus` | Re-encode audio to Opus (conservative bitrates) |
| `--auto-audio` | Re-encode to Opus only if source bitrate exceeds threshold |
| `--audio-threshold KB/S` | Bitrate threshold for `--auto-audio` (default: 200) |

### Subtitles

| Flag | Description |
|------|-------------|
| `--no-merge-subs` | Don't merge adjacent `.srt`/`.vtt` files into output |

When merging is enabled (default), the script finds all `.srt` and `.vtt` files matching the video filename (e.g., `video.srt`, `video.fr.srt`, `video.en.vtt`) and muxes them as subtitle tracks. Merged subtitle files are deleted when `--rm-source` is active.

Adjacent `.txt` files are embedded as MKV `description` metadata but are **never deleted**.

### Logging

| Flag | Description |
|------|-------------|
| `-l, --log FILE` | Log FFmpeg output to FILE |
| `-v, --verbose` | Verbose output |
| `--no-progress` | Disable progress bar |

### Other

| Flag | Description |
|------|-------------|
| `--check` | Check dependencies and exit |
| `-h, --help` | Show this help |
| `--version` | Show version |

## How it works

1. **Probe** — reads container format, streams, duration, and codec info
2. **Skip** — if the video is already AV1, skip it
3. **MPEG-TS fix** — if the container is MPEG-TS, applies `-fflags +genpts+igndts -avoid_negative_ts make_zero`
4. **Merge** — detects and includes adjacent subtitle/description files
5. **Encode** — runs FFmpeg with SVT-AV1, piping progress to a real-time monitor
6. **Early abort** — at the configured threshold (default 8%), estimates final output size; aborts if it would be larger than input (only when `--smart` or `--rm-if-bigger`)
7. **Post-process** — handles smart mode logic, source removal, in-place file swap; detects corrupt outputs (< 1 KiB)
8. **Summary** — prints a table of all results with sizes and savings

## Example output

```
<- SOURCE (2.5G): 'recording.ts'
-> TARGET: 'recording.mkv'
  container: mpegts  duration: 01:03:58  bitrate: 5281 kb/s
    #0 video: h264 1920x1080
  #1 audio: aac 2ch 48000Hz 97kb/s
  +sub: recording.fr.srt
  +desc: recording.txt
  [ 45%] [#############-----------------] 00:28:47/01:03:58 | 1.2x | ETA: 1770s | fps: 30.1
```

```
File                                               Status          Input     Output     Gain  Note
-------------------------------------------------- ---------- ---------- ---------- --------  ----
recording.ts                                       OK               2.4G       1.1G     -54%  -54%
episode_s01e01.mp4                                 OK               1.8G       890M     -51%  -51%
already_av1.mkv                                    SKIPPED          500M        ---      ---  already AV1
broken_file.avi                                    FAILED           200M        ---      ---  ffmpeg exit 1

Total converted: 4.2G -> 2.0G (-52%)
OK: 2 | Skip: 1 | Abort: 0 | Fail: 1 | Total: 4
```

## Supported formats

Input: `mp4`, `mkv`, `avi`, `mov`, `wmv`, `flv`, `ts`, `m2ts`, `mts`, `m4v`, `webm`, `mpg`, `mpeg`

Output: MKV (Matroska) — chosen for its broad codec and subtitle support.

## License

MIT
