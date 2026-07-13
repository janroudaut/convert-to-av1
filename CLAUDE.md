# CLAUDE.md

## Project
Single bash script (`convert-to-av1.sh`) for batch video conversion to AV1 via SVT-AV1/ffmpeg.

## Commands
```bash
bash -n convert-to-av1.sh              # Syntax check
shellcheck convert-to-av1.sh           # Lint (static analysis)
bash convert-to-av1.sh --help           # Show usage
bash convert-to-av1.sh --dry-run .      # Test run (no conversion)
bash test.sh                            # Integration suite (38 tests, synthetic files)
bash test.sh --docker                   # Same, through the Docker wrapper
```

Both checks run automatically on pre-commit via lefthook (`lefthook.yml`).

## Dependencies
ffmpeg (with libsvtav1), ffprobe, python3, bc, numfmt, stat, mktemp

## Architecture
- `convert-to-av1.sh` — main script (all logic in one file)
- Output is always MKV container

## Gotchas
- Early abort only triggers when `--rm-if-bigger` or `--smart` is active
- MPEG-TS inputs auto-get timestamp fix flags (`+genpts+igndts`)
- Adjacent .srt/.vtt files are muxed in by default; deleted with `--rm-source`
- Adjacent .txt files are embedded as MKV description metadata but never deleted
- Lock files use atomic noclobber; stale locks (dead PID) are auto-cleaned
- `NO_COLOR` env var and non-TTY stdout both disable colors
- Only the first video stream is encoded to AV1; extra video streams (cover art /
  attached_pic, even when the disposition flag is missing) are copied verbatim —
  SVT-AV1 cannot encode still-image covers
- Audio codec is decided per-stream (`-c:a:N`); no global `-ac`, so multichannel
  layouts (5.1/7.1) keep their native channels. Non-standard layouts like
  `5.1(side)` are normalised via a per-stream `aformat` filter (libopus rejects them)
- `--langs`/`--audio-langs`/`--sub-langs` filter tracks by language (via ffprobe
  index enumeration, since `-map 0:a:m:language:` is unreliable across ffmpeg builds);
  untagged/`und` tracks are always kept; a safety net keeps all audio if none match
- `--copy-streams`/`--remux`: pure remux (`-c copy`), no re-encode; bypasses the
  already-AV1 skip so AV1 files can still be cleaned. In `-c copy` mode ffmpeg
  reports `out_time=N/A`, so the progress bar falls back to muxed-frame count
  (`get_total_frames`); early-abort stays gated on real timestamps only (encode)
- SSIM quality check MUST use explicit `[0:v:0][1:v:0]ssim` pads — a bare `ssim`
  filter mis-selects streams and returns N/A when a cover/attached_pic second
  video stream is present (silently disabling the check). SSIM is I/O-bound: ~1s
  per 10s sample on ext4 vs 24–105s on WSL `/mnt` (drvfs seeks) — the phase is
  fast unless the files live on a slow mount
- SSIM ffmpeg runs inside a command substitution (deep grandchild), so cleanup
  uses `kill_descendants` (recursive) — `pkill -P $$` alone left it running on Ctrl-C
- `post_process` validates size + runs the SSIM check on the temp output
  *before* the atomic `mv` to the destination — so a rejected encode never
  overwrites the source (in-place `.mkv`) and the check compares against the
  still-intact source, not the output-vs-itself
- `--skip-log[=FILE]`: records files not worth converting (SSIM < min, or output
  larger than source when rejected via `--smart`/`--rm-if-bigger`/early-abort) and
  skips them on later runs (filtered in `collect_and_sort_files`). Default file
  `.convert-skip.list` at the input root; paths stored **relative to the log dir**
  (`skip_key`, portable) with the source size as a safety net (changed file =
  retried). Line format: `size\trelpath\tsource-mtime\treason`
- Per-directory `.convert-profile`: encoding/quality/audio/track flags applied
  per file by walking up from its dir (`resolve_file_profile`). CLI config is
  snapshotted (`snapshot_base_config`/`BASE_CFG`) and restored per file so
  profiles don't leak between directories. `--no-profile` disables. Auto content
  detection was tried and rejected — grain confounds with detail AND motion
  (Die Hard 1988 scored like clean digital), so profiles are the deliberate,
  reliable alternative

## Code Style
- All code, comments, CLI output, and docs must be in English
- Bash with `set -euo pipefail`
