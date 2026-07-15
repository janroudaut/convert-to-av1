# CLAUDE.md

## Project
Single bash script (`convert-to-av1.sh`) for batch video conversion to AV1 via SVT-AV1/ffmpeg.

## Commands
```bash
bash -n convert-to-av1.sh              # Syntax check
shellcheck convert-to-av1.sh           # Lint (static analysis)
bash convert-to-av1.sh --help           # Show usage
bash convert-to-av1.sh --dry-run .      # Test run (no conversion)
bash test.sh                            # Integration suite (55 tests, synthetic files)
                                        # (runs via a wrapper injecting --min-size 0:
                                        #  synthetic clips are below the 128K default)
```

Both checks run automatically on pre-commit via lefthook (`lefthook.yml`).
CI (GitHub Actions, `.github/workflows/ci.yml`) runs lint + the full suite on push/PR.

## Dependencies
ffmpeg (with libsvtav1), ffprobe, python3, awk, bc, numfmt, stat, mktemp
(`df` is used opportunistically for the disk-space guard — its absence never blocks)

## Architecture
- `convert-to-av1.sh` — main script (all logic in one file)
- Output is always MKV container

## Gotchas
- Media metadata comes from a single cached probe per file: `probe_load` runs one
  `ffprobe -show_format -show_streams -of json` + one python3 parse, keyed by path
  (`PROBE_*` globals + `PROBE_STREAMS_TSV`). The probe helpers (`is_av1`,
  `is_mpeg_ts`, `get_video_height`, `get_duration_secs`, `get_total_frames`),
  `compute_track_selection` and `print_file_info` all read from it — never spawn a
  fresh ffprobe for a field that's already in the cache (was ~9 spawns/file → 1)
- `PROBE_STREAMS_TSV` columns: index/type/attached_pic/lang/channels/bitrate/codec.
  Empty fields are emitted as `-` by the python side and decoded back to "" in
  bash — tab is IFS *whitespace*, so consecutive tabs collapse and silently shift
  every following column into the wrong variable (bit us: opus codec landed in
  the channels var). Same placeholder scheme on the scalar first line
- Audio bitrate lookup is 3-tier: stream `bit_rate` → mkvmerge `BPS`/`BPS-eng`
  tag → packet-sampling estimate (`estimate_audio_bitrates`: ONE ~20s demux-only
  ffprobe per file covers ALL audio streams at once, cached; triggered for kept
  tracks in auto mode). MKV usually reports NO audio bitrate — without the
  estimate, auto mode saw 0 kb/s and copied everything. Estimated rates show as
  `~256k` in the header table
- `export LC_NUMERIC=C` at the top is load-bearing: printf %.0f / awk floats
  break under comma-decimal locales. Do NOT widen to LC_ALL=C — it kills the
  UTF-8 table symbols the embedded python prints
- HDR10/HLG sources (`PROBE_V0_COLOR_TRC` = smpte2084/arib-std-b67) get their
  colour metadata forwarded explicitly in build_ffmpeg_cmd — ffmpeg does not
  reliably tag libsvtav1 output, and untagged HDR plays back washed-out. The
  BT.709 fix only applies to SDR with invalid/missing metadata
- `min_size` (128K default, `--min-size`, 0 disables) is the ONE "too small to
  be real video" threshold: input filter, corrupt-output floor
  (`min(min_size, input/10)`, hard floor 1K) and forced-verify trigger
- `--verify` full-decodes the temp output (with `-xerror`) after SSIM and
  before the atomic mv; forced automatically on outputs below `min_size`
  (near-free at that size, and the size tripwire alone cannot tell a legit
  tiny clip from garbage). `--stats FILE` (print_log_stats) is a standalone
  mode like `--check`; `--stats-live` wraps it in a mtime-poll redraw loop
  (print_log_stats_live, `trap 'exit 0' INT` so Ctrl-C leaves silently). Disk-space guard: skip when df free < input size
  (unknown free space never blocks)
- The per-track opus/copy decision lives in ONE place: `audio_stream_action`
  (used by both `stream_dispositions` and `build_ffmpeg_cmd`, so display ==
  reality). Already-opus tracks are never re-encoded, even with `--opus`
- Per-file header (`print_file_header` → `print_file_info`) renders fixed-width,
  truncated, aligned columns (type / disposition / codec / specs / rate /
  lang-title), main video row first regardless of container stream order. The
  disposition column (av1/opus/copy/skip, colour + symbol) comes from
  `stream_dispositions` (needs `compute_track_selection` run first; it also
  exposes `TRACKSEL_SUB_IDX`). Colours/symbols are passed into the python3 block
  as argv — never put apostrophes inside that block, it's wrapped in bash single
  quotes (use double quotes / temp vars). `--dry-run` shares the same header
- Without `-y`, an existing output is skipped (resume semantics; in-place
  mkv→mkv replacement always allowed — compare against the *canonical* source
  path, "./x.mkv" vs "x.mkv"). `CLAIMED_OUTPUTS` catches two sources mapping to
  the same output name (foo.mp4+foo.avi, or same basename across subdirs with -o)
- Progress/scan lines are erased with `clear_line` (ANSI `\r\033[K`, width-agnostic
  — a fixed `%-80s` blank left the tail of longer bars). `scan_tick`/`scan_done`
  draw the initial file-scan counter on stderr, interactive-only
- `--log FILE` is a synthetic, greppable per-file TSV written by `add_result`
  (time, status, sizes, saved%, took, note, path) — NOT raw ffmpeg stderr. ffmpeg
  errors surface to the terminal on hard failure instead. Wall time comes from
  `LAST_ENCODE_SECS`, the passing SSIM score from `LAST_SSIM` (both reset per
  file in `convert_file`). Each session opens with a `# ...` comment banner
  (`write_log_session_header`, called in `main` before the first encode; never
  in dry-run). Header lines must stay tab-free — `print_log_stats` skips them
  via its `NF >= 8` awk filter
- Batch progress line ("batch: 3/12 done | saved … | ~… left") prints above each
  file header; its ETA is byte-based: `BATCH_TOTAL_BYTES` is snapshotted in
  `main` before the loop (sources may shrink/vanish), `BATCH_DONE_BYTES`
  accumulates `LAST_INPUT_SIZE` exported by each `convert_file` (no re-stat)
- Cleanup only prints "Interrupted…" / kills descendants on signal exits
  (`exit_code >= 128`) — usage errors / failed `--check` exit 1 and clean silently
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
  (`get_total_frames`); early-abort stays gated on real timestamps only (encode);
  the SSIM quality check is skipped (copied streams are bit-identical)
- `--crf`/`--preset` set `svt_crf_explicit`/`svt_preset_explicit`; content types
  (`apply_content_type`) leave explicit values alone; `--sd`/`--hq` reset the
  flags (last-wins). Both flags work in `.convert-profile` too (bad profile
  values warn + are ignored — a profile must never kill a batch, see
  `profile_uint`/`profile_str`)
- All numeric CLI args are validated at parse time (`need_arg`/`need_uint`/
  `need_ssim`, `parse_size` supports decimals like `1.5G` and dies on garbage)
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
  retried). Line format: `size\trelpath\tsource-mtime\treason`. Profiles can
  activate their own list mid-batch, so `SKIP_LOG_SIZES` keys are namespaced
  `abs-list-path\tentry` (`activate_skip_log`: idempotent per list, re-pointed
  per file from `resolve_file_profile`); profile lists are enforced by a second
  `is_skip_logged` check in `convert_file` — collection-time filtering only ever
  sees the CLI list
- Per-directory `.convert-profile`: encoding/quality/audio/track flags applied
  per file by walking up from its dir (`resolve_file_profile`). CLI config is
  snapshotted (`snapshot_base_config`/`BASE_CFG`) and restored per file so
  profiles don't leak between directories. `--no-profile` disables. Auto content
  detection was tried and rejected — grain confounds with detail AND motion
  (Die Hard 1988 scored like clean digital), so profiles are the deliberate,
  reliable alternative. Also allowed: quality-check/verify/early-abort flags and
  `--log`/`--skip-log` (relative paths anchor to the profile's dir via
  `profile_path`; the session banner is written lazily per log file,
  `LOG_HEADER_WRITTEN`). `--exclude` (APPENDS to CLI patterns — array
  snapshotted apart in `BASE_EXCLUDES`) and `--min-size` work per file: the
  collection filter loop resolves each candidate's profile before testing.
  `--sort-by-size`/`--sort-by-date` come from the FIRST input root's profile
  only (ordering is batch-global). Destructive flags are deliberately NOT
  accepted — a dotfile must never delete files

## Code Style
- All code, comments, CLI output, and docs must be in English
- Bash with `set -euo pipefail`
- Comments: "senior" minimalism — only when necessary/tricky, stating a
  constraint or invariant the code cannot show (1-2 dense lines). Never
  narrate obvious code, paraphrase the condition below, or record change
  history inline (that belongs here in CLAUDE.md)
