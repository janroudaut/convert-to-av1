# convert-to-av1

Batch video converter to AV1 using FFmpeg and SVT-AV1. Designed to reduce storage for TV recordings, series, and movies with minimal effort.

## Features

- **In-place conversion** (default) or output to a separate directory
- **MPEG-TS fix** — auto-detects `.ts` containers and applies timestamp correction flags
- **Smart mode** — keeps the best version (source or output) based on file size
- **Early abort** — stops encoding at ~8% if the output is estimated to be larger than the source
- **Subtitle merging** — auto-detects adjacent `.srt`/`.vtt` files (including multi-language) and muxes them into the output MKV
- **Description embedding** — reads adjacent `.txt` files and embeds them as MKV `description` metadata
- **Audio re-encoding** — optional Opus re-encoding with automatic bitrate detection; decided **per stream**, so 5.1/7.1 tracks keep their native channels (no downmix)
- **Language track filtering** — keep only selected audio/subtitle languages (e.g. `fr,en`) to strip unwanted tracks
- **Remux / cleanup mode** — `--copy-streams` strips tracks without re-encoding (fast)
- **Per-directory profiles** — a `.convert-profile` file applies folder-specific flags (e.g. `--movie` for grainy films, `--cartoon` for animation)
- **Cover art safe** — attached_pic covers/thumbnails are preserved (copied), never fed to the encoder
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

# Keep only French and English audio + subtitles (drop the rest)
./convert-to-av1.sh --smart --langs fr,en -r /path/to/series/

# Just clean up an existing file: strip unwanted tracks, no re-encoding
./convert-to-av1.sh --copy-streams --langs fr,en video.mkv

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

Default: preset 8, CRF 28, 10-bit, no film-grain.

#### Preset matrix

| | `--fast` | default | `--hq` |
|---|---|---|---|
| *(none)* | p10 crf32 | p8 crf28 | p4 crf28 grain=8 |
| `--cartoon` | p10 crf34 | p8 crf30 | p4 crf30 |
| `--tv` | p10 crf33 | p10 crf29 | p10 crf29 |
| `--movie` | p10 crf30 grain=8 denoise | p8 crf26 grain=10 denoise | p4 crf26 grain=10 denoise |

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
| `--copy-audio` | Keep original audio (no re-encoding) |
| `--opus` | Re-encode audio to Opus (conservative bitrates) |
| `--auto-audio` | Re-encode to Opus only if source bitrate exceeds threshold (default) |
| `--audio-threshold KB/S` | Bitrate threshold for `--auto-audio` (default: 200) |

The audio codec is chosen **per stream**: no global channel remapping is applied, so multichannel tracks (5.1/7.1) keep their native channel count — Opus re-encoding never downmixes surround to stereo. Non-standard channel layouts (e.g. `5.1(side)`) are normalised so `libopus` accepts them.

### Tracks (language filtering)

Keep only tracks in the languages you care about. By default **all tracks are kept**. Filtering is opt-in and identifies tracks by their language tag (accepts 2- or 3-letter codes: `fr` matches `fre`/`fra`, `en` matches `eng`).

| Flag | Description |
|------|-------------|
| `--langs LIST` | Keep only these languages for **both** audio and subtitles (e.g. `fr,en`) |
| `--audio-langs LIST` | Keep only these audio languages |
| `--sub-langs LIST` | Keep only these subtitle languages |
| `--copy-streams, --remux` | Don't re-encode: just remux and keep selected tracks (fast cleanup) |

- **Untagged / `und` tracks are always kept** (safety against dropping audio).
- If no audio track matches, **all audio is kept** and a warning is printed (a file is never left without sound).
- All tracks in a matching language are kept (default, forced, commentary, etc.).
- Video (including cover art), attachments/fonts, chapters, and metadata are always preserved.

`--copy-streams` performs a pure remux (`-c copy`) — no video or audio re-encoding — which is ideal for stripping unwanted tracks from an existing file in seconds. It also works on files that are already AV1 (which normal conversion would skip).

```bash
# Strip everything except French/English audio and subtitles, re-encode video to AV1
./convert-to-av1.sh --langs fr,en video.mkv

# Fine-grained: keep only French audio, but French + English subtitles
./convert-to-av1.sh --audio-langs fr --sub-langs fr,en video.mkv

# Clean an existing file without re-encoding (fast)
./convert-to-av1.sh --copy-streams --langs fr,en video.mkv
```

### Per-directory profiles

Drop a `.convert-profile` file into a directory (or any parent) and its flags are applied to every video under it — so you can set the right profile per content type without passing flags each time. This is more reliable than trying to auto-detect content: you know a folder is animation or grainy film, a heuristic doesn't.

| Flag | Description |
|------|-------------|
| `--no-profile` | Ignore all `.convert-profile` files |

- Resolved **per file**: the tool walks up from each file's directory and uses the first `.convert-profile` it finds.
- One flag per line or space-separated; `#` starts a comment.
- Supports the encoding/quality/audio/track flags (`--movie`, `--cartoon`, `--tv`, `--hq`, `--fast`, `--1080`, `--opus`, `--langs`, `--copy-streams`, …). Batch/output flags (`-o`, `-r`, `--smart`, …) are ignored in profiles.
- Profile flags override the CLI base for that file.

```bash
# /mnt/videos/Movies/Die Hard (1988)/.convert-profile
--movie

# /mnt/videos/Series/South Park/.convert-profile   (applies to all seasons below)
# 2D animation: no grain, a touch higher CRF
--cartoon

# Then just run the batch — each folder gets its own profile automatically:
./convert-to-av1.sh --smart -r /mnt/videos/
```

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
2. **Skip** — if the video is already AV1, skip it (unless `--copy-streams`, which can still clean it)
3. **MPEG-TS fix** — if the container is MPEG-TS, applies `-fflags +genpts+igndts -avoid_negative_ts make_zero`
4. **Merge** — detects and includes adjacent subtitle/description files
5. **Select tracks** — keeps all streams by default, or filters audio/subtitles by language; only the first video stream is encoded to AV1 while cover-art/thumbnail streams are copied verbatim
6. **Encode** — runs FFmpeg with SVT-AV1 (per-stream audio codec), piping progress to a real-time monitor
7. **Early abort** — at the configured threshold (default 8%), estimates final output size; aborts if it would be larger than input (only when `--smart` or `--rm-if-bigger`)
8. **Post-process** — handles smart mode logic, source removal, in-place file swap; detects corrupt outputs (< 1 KiB)
9. **Summary** — prints a table of all results with sizes and savings

## Example output

Per-file, while converting (here with `--langs fr,en`, so only French/English tracks are kept):

```
<- SOURCE (7.2G): 'S01E05 - Got Milk.mkv'
-> TARGET: 'S01E05 - Got Milk.mkv'
  container: matroska,webm  duration: 00:56:28  bitrate: 22287 kb/s
    #0 video: hevc [eng] 1920x1080 23.98fps
  #3 audio: eac3 [eng] 6ch 48000Hz 768kb/s
  #9 audio: eac3 [fre] 6ch 48000Hz 768kb/s
  #43 subtitle: subrip [fre]
  #50 subtitle: subrip [eng]
  Audio: 6 track(s) -> Opus (native channels preserved), 0 copied
  [ 45%] [#############-----------------] 00:25:24/00:56:28 | fps: 42.1 1.9x | ETA: 00:16:20 | 2870kb/s saved=61%
  Conversion done.
  saved=4.4G (61%): 7.2G -> 2.8G
```

End-of-batch summary table:

```
File                                               Status          Input     Output    Saved  Note
-------------------------------------------------- ---------- ---------- ---------- --------  ----
S01E05 - Got Milk.mkv                              OK               7.2G       2.8G      61%  saved 61% (4.4G)
already_av1.mkv                                    SKIPPED          500M        ---      ---  already AV1
broken_file.avi                                    FAILED           200M        ---      ---  ffmpeg exit 1

Total: 7.9G -> 2.8G | saved=5.1G (65%)
OK: 1 | Skip: 1 | Abort: 0 | Fail: 1 | Total: 3 | elapsed: 00:48:12
```

## Supported formats

Input: `mp4`, `mkv`, `avi`, `mov`, `wmv`, `flv`, `ts`, `m2ts`, `mts`, `m4v`, `webm`, `mpg`, `mpeg`

Output: MKV (Matroska) — chosen for its broad codec and subtitle support.

## Acknowledgements

First and foremost, to the **FFmpeg** developers, and to the **assembly masters**
whose hand-written SIMD makes real-time video possible — the people optimizing
dav1d, SVT-AV1, x264/x265 and countless codecs one instruction at a time. This
tool is just a shell script standing on those giants' shoulders.

```
virtualdub-grade artistry: not found.
bytes shaved: yes. verdict: watchable.
with respect to those who did it properly.
```

## License

MIT
