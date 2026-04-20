# CLAUDE.md

## Project
Single bash script (`convert-to-av1.sh`) for batch video conversion to AV1 via SVT-AV1/ffmpeg.

## Commands
```bash
bash -n convert-to-av1.sh              # Syntax check
shellcheck convert-to-av1.sh           # Lint (static analysis)
bash convert-to-av1.sh --help           # Show usage
bash convert-to-av1.sh --dry-run .      # Test run (no conversion)
```

Both checks run automatically on pre-commit via lefthook (`lefthook.yml`).

## Dependencies
ffmpeg (with libsvtav1), ffprobe, python3, bc, numfmt, stat, mktemp

## Architecture
- `convert-to-av1.sh` — main script (all logic in one file)
- `legacy/` — previous version (v2) kept for reference
- Output is always MKV container

## Gotchas
- Early abort only triggers when `--rm-if-bigger` or `--smart` is active
- MPEG-TS inputs auto-get timestamp fix flags (`+genpts+igndts`)
- Adjacent .srt/.vtt files are muxed in by default; deleted with `--rm-source`
- Adjacent .txt files are embedded as MKV description metadata but never deleted
- Lock files use atomic noclobber; stale locks (dead PID) are auto-cleaned
- `NO_COLOR` env var and non-TTY stdout both disable colors

## Code Style
- All code, comments, CLI output, and docs must be in English
- Bash with `set -euo pipefail`
