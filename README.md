# convert-to-av1

Batch video converter to AV1 using FFmpeg and SVT-AV1. Designed to reduce storage for TV recordings, series, and movies with minimal effort.

## Features

- **In-place conversion** (default) or output to a separate directory
- **MPEG-TS fix** — auto-detects `.ts` containers and applies timestamp correction flags
- **Smart mode** — keeps the best version (source or output) based on file size
- **Early abort** — stops encoding at ~8% if the output is estimated to be larger than the source
- **Subtitle merging** — auto-detects adjacent `.srt`/`.vtt` files (including multi-language) and muxes them into the output MKV
- **Description embedding** — reads adjacent `.txt` files and embeds them as MKV `description` metadata
- **Recursive mode** — process entire directory trees
- **Sort by size** — process smallest (or largest) files first
- **Clean progress bar** — real-time progress with speed, ETA, and fps
- **Detailed file info** — shows container, duration, bitrate, streams, and detected external files before each conversion
- **Graceful failures** — one failed file doesn't stop the batch; summary table at the end
- **Lock files** — prevents concurrent conversion of the same file
- **NO_COLOR support** — respects the [NO_COLOR](https://no-color.org/) standard
- **Dry run mode** — preview what would happen without converting

## Requirements

- `ffmpeg` and `ffprobe` (with `libsvtav1` support)
- `python3` (for file info display)
- Standard GNU utils: `bc`, `numfmt`, `stat`, `mktemp`

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

# Preview what would be done
./convert-to-av1.sh --dry-run --sort-by-size .
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
| `--smart, --keep-best-version` | Combines `--rm-src` + `--rm-if-bigger`; keeps the best version |
| `--rm-source, --rm-src` | Remove source if output is smaller |
| `--rm-if-bigger` | Remove output if it's larger than source |
| `-y, --overwrite` | Overwrite existing output file |

### Quality

| Flag | Description |
|------|-------------|
| `--max-res, --max-h HEIGHT` | Scale down to HEIGHT px if source is taller |
| `--sd, --fast` | Fast encoding (SVT-AV1 preset 9, CRF 35) |
| `--hq` | High quality (preset 5, CRF 32, 10-bit, film grain synthesis) |

Default: preset 6, CRF 30.

### Batch

| Flag | Description |
|------|-------------|
| `-r, --recursive` | Recurse into subdirectories |
| `--sort-by-size [asc\|desc]` | Sort files by size before processing (default: asc) |
| `--dry-run` | Show what would be done without converting |
| `--no-early-abort` | Disable early abort when output is estimated larger |
| `--early-abort-threshold PCT` | Progress % at which to evaluate (default: 8) |

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

## How it works

1. **Probe** — reads container format, streams, duration, and codec info
2. **Skip** — if the video is already AV1, skip it
3. **MPEG-TS fix** — if the container is MPEG-TS, applies `-fflags +genpts+igndts -avoid_negative_ts make_zero`
4. **Merge** — detects and includes adjacent subtitle/description files
5. **Encode** — runs FFmpeg with SVT-AV1, piping progress to a real-time monitor
6. **Early abort** — at the configured threshold (default 8%), estimates final output size; aborts if it would be larger than input (only when `--smart` or `--rm-if-bigger`)
7. **Post-process** — handles smart mode logic, source removal, in-place file swap
8. **Summary** — prints a table of all results with sizes and savings

## Example output

```
<- SOURCE (2.5M): 'recording.ts'
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
