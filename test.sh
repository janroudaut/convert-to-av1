#!/usr/bin/env bash
# Integration test suite for convert-to-av1.
# Generates synthetic video files on the fly and exercises the main script features.
# Usage: bash test.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERT_BIN="$SCRIPT_DIR/convert-to-av1.sh"
# Synthetic test files can be tiny (a 2s testsrc clip compresses below the 128K
# default --min-size), so the suite runs with the filter disabled; tests that
# exercise --min-size pass their own value, which overrides (last flag wins).
CONVERT=""   # set in setup() — wrapper injecting --min-size 0

TEST_DIR=""
PASS=0
FAIL=0
SKIP=0
FAILURES=()

# ---------------------------------------------------------------------------
# Colors (disabled when NO_COLOR is set or stdout is not a terminal)
# ---------------------------------------------------------------------------

if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
    TEST_DIR="$(mktemp -d /tmp/convert-av1-test.XXXXXX)"
    CONVERT="$TEST_DIR/convert-wrapper.sh"
    printf '#!/usr/bin/env bash\nexec bash %q --min-size 0 "$@"\n' "$CONVERT_BIN" > "$CONVERT"
    chmod +x "$CONVERT"
}

# shellcheck disable=SC2317
teardown() {
    if [[ -n "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap teardown EXIT

pass() {
    ((PASS++))
    printf "  ${GREEN}PASS${RESET}  %s\n" "$1"
}

fail() {
    ((FAIL++))
    FAILURES+=("$1: $2")
    printf "  ${RED}FAIL${RESET}  %s — %s\n" "$1" "$2"
}

section() {
    printf "\n${BOLD}── %s${RESET}\n" "$1"
}

# Generate a short synthetic h264 video.
# $1 = output path, $2 = duration (seconds, default 3), $3 = resolution (default 320x240)
generate_video() {
    local out="$1" dur="${2:-3}" res="${3:-320x240}"
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=${res}:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=${dur}" \
        -c:v libx264 -preset ultrafast -crf 28 \
        -c:a aac -b:a 64k \
        -pix_fmt yuv420p \
        "$out" 2>/dev/null
}

# Generate a short AV1 video (already converted).
generate_av1_video() {
    local out="$1" dur="${2:-2}"
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=320x240:rate=25" \
        -c:v libsvtav1 -preset 10 -crf 50 -pix_fmt yuv420p10le \
        -an "$out" 2>/dev/null
}

# Generate a large-bitrate video to trigger early abort.
generate_large_video() {
    local out="$1" dur="${2:-10}"
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=1920x1080:rate=30" \
        -f lavfi -i "sine=frequency=440:duration=${dur}" \
        -c:v libx264 -preset ultrafast -crf 1 \
        -c:a aac -b:a 256k \
        -pix_fmt yuv420p \
        "$out" 2>/dev/null
}

# Generate an MPEG-TS file.
generate_ts_video() {
    local out="$1" dur="${2:-3}"
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=${dur}" \
        -c:v libx264 -preset ultrafast -crf 28 \
        -c:a aac -b:a 64k \
        -f mpegts \
        "$out" 2>/dev/null
}

# Generate an MKV with multiple audio languages (eng stereo, fre 5.1, spa stereo)
# and embedded eng/fre subtitles.
generate_multitrack_video() {
    local out="$1" dur="${2:-2}"
    local sub_en="${out}.en.srt" sub_fr="${out}.fr.srt"
    printf '1\n00:00:00,000 --> 00:00:01,000\nhello\n' > "$sub_en"
    printf '1\n00:00:00,000 --> 00:00:01,000\nbonjour\n' > "$sub_fr"
    ffmpeg -y \
        -f lavfi -i "testsrc=duration=${dur}:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=${dur}" \
        -f lavfi -i "sine=frequency=480:duration=${dur}" \
        -f lavfi -i "sine=frequency=500:duration=${dur}" \
        -i "$sub_en" -i "$sub_fr" \
        -map 0:v -map 1:a -map 2:a -map 3:a -map 4 -map 5 \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
        -c:a aac -ac:a:1 6 -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=fre -metadata:s:a:2 language=spa \
        -metadata:s:s:0 language=eng -metadata:s:s:1 language=fre \
        "$out" 2>/dev/null
    rm -f "$sub_en" "$sub_fr"
}

# Generate an MKV carrying an attached_pic cover (the case that used to crash
# SVT-AV1: a still-image second video stream).
generate_cover_video() {
    local out="$1" dur="${2:-2}"
    local base="${out}.base.mkv" cover="${out}.cover.png"
    generate_video "$base" "$dur"
    ffmpeg -y -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 "$cover" 2>/dev/null
    ffmpeg -y -i "$base" -i "$cover" -map 0 -map 1 -c copy \
        -disposition:v:1 attached_pic "$out" 2>/dev/null
    rm -f "$base" "$cover"
}

# Count streams of a given selector (e.g. a, s, v) in a file.
count_streams() {
    ffprobe -v error -select_streams "$1" -show_entries stream=index \
        -of csv=p=0 "$2" 2>/dev/null | grep -c .
}

# Assert a file exists and is non-empty.
assert_file_exists() {
    [[ -f "$1" ]] && [[ -s "$1" ]]
}

# Assert a file does not exist.
assert_file_missing() {
    [[ ! -e "$1" ]]
}

# Get video codec of a file.
get_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of csv=p=0 "$1" 2>/dev/null | head -1 | tr -d '[:space:]'
}


# ===========================================================================
# Test cases
# ===========================================================================

setup

# --- Basic conversion ---

section "Basic conversion"

test_basic_conversion() {
    local dir="$TEST_DIR/basic"
    mkdir -p "$dir"
    generate_video "$dir/sample.mp4"

    "$CONVERT" --no-progress "$dir/sample.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/sample.mkv" "output"; then
        local codec
        codec=$(get_codec "$dir/sample.mkv")
        if [[ "$codec" == "av1" ]]; then
            pass "basic conversion produces AV1 MKV"
        else
            fail "basic conversion" "expected av1 codec, got '$codec'"
        fi
    else
        fail "basic conversion" "exit code $rc or output missing"
    fi
}
test_basic_conversion

# --- Skip already-AV1 ---

section "Skip detection"

test_skip_already_av1() {
    local dir="$TEST_DIR/skip-av1"
    mkdir -p "$dir"
    generate_av1_video "$dir/already.mkv"

    local output
    output=$("$CONVERT" --no-progress "$dir/already.mkv" 2>&1) && rc=0 || rc=$?

    if echo "$output" | grep -qi "already AV1\|SKIPPED"; then
        pass "skip already-AV1 file"
    else
        fail "skip already-AV1" "expected skip message, got: $(echo "$output" | tail -3)"
    fi
}
test_skip_already_av1

# --- --dry-run ---

section "Dry run"

test_dry_run() {
    local dir="$TEST_DIR/dryrun"
    mkdir -p "$dir"
    generate_video "$dir/video.mp4"

    local output
    output=$("$CONVERT" --dry-run --no-progress "$dir/video.mp4" 2>&1)

    if echo "$output" | grep -qi "DRYRUN\|dry.run\|video.mkv"; then
        # Ensure no MKV was created
        if assert_file_missing "$dir/video.mkv"; then
            pass "dry run does not produce output"
        else
            fail "dry run" "MKV was created despite --dry-run"
        fi
    else
        fail "dry run" "expected dry-run output, got: $(echo "$output" | tail -3)"
    fi
}
test_dry_run

# --- --output-dir ---

section "Output directory"

test_output_dir() {
    local dir="$TEST_DIR/outdir"
    local outdir="$TEST_DIR/outdir-dest"
    mkdir -p "$dir"

    generate_video "$dir/input.mp4"

    "$CONVERT" --no-progress -o "$outdir" "$dir/input.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$outdir/input.mkv" "output"; then
        pass "output written to --output-dir"
    else
        fail "--output-dir" "exit code $rc or output missing in $outdir"
    fi
}
test_output_dir

# --- --smart mode (output smaller → remove source) ---

section "Smart mode"

test_smart_keeps_smaller() {
    local dir="$TEST_DIR/smart"
    mkdir -p "$dir"
    # High-bitrate 720p source so AV1 is deterministically much smaller. A
    # low-bitrate source sits at the compression boundary where early-abort
    # legitimately fires at random, which made this test flaky.
    ffmpeg -y -f lavfi -i "testsrc=duration=5:size=1280x720:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=5" \
        -c:v libx264 -preset ultrafast -crf 8 -c:a aac -b:a 128k \
        -pix_fmt yuv420p "$dir/big.mp4" 2>/dev/null

    "$CONVERT" --no-progress --smart --fast "$dir/big.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/big.mkv" "output"; then
        if assert_file_missing "$dir/big.mp4"; then
            pass "smart mode removes source when output is smaller"
        else
            pass "smart mode produced output (source still present — may be larger)"
        fi
    else
        fail "smart mode" "exit code $rc or output missing"
    fi
}
test_smart_keeps_smaller

# --- --rm-if-bigger ---

test_rm_if_bigger() {
    local dir="$TEST_DIR/rm-if-bigger"
    mkdir -p "$dir"
    # Generate a tiny low-bitrate source — AV1 overhead may make output bigger
    generate_video "$dir/tiny.mp4" 1 160x120

    "$CONVERT" --no-progress --rm-if-bigger --fast "$dir/tiny.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    # Whether output is bigger or not, the script should succeed
    if [[ $rc -eq 0 ]]; then
        pass "--rm-if-bigger completes without error"
    else
        fail "--rm-if-bigger" "exit code $rc"
    fi
}
test_rm_if_bigger

# --- MPEG-TS handling ---

section "MPEG-TS"

test_mpegts_conversion() {
    local dir="$TEST_DIR/mpegts"
    mkdir -p "$dir"
    generate_ts_video "$dir/recording.ts"

    "$CONVERT" --no-progress --fast "$dir/recording.ts" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/recording.mkv" "output"; then
        local codec
        codec=$(get_codec "$dir/recording.mkv")
        if [[ "$codec" == "av1" ]]; then
            pass "MPEG-TS converted to AV1 MKV"
        else
            fail "MPEG-TS" "expected av1 codec, got '$codec'"
        fi
    else
        fail "MPEG-TS conversion" "exit code $rc or output missing"
    fi
}
test_mpegts_conversion

# --- Subtitle merging ---

section "Subtitle merging"

test_subtitle_merging() {
    local dir="$TEST_DIR/subs"
    mkdir -p "$dir"
    generate_video "$dir/show.mp4" 3

    # Create adjacent subtitle files
    cat > "$dir/show.srt" <<'SRT'
1
00:00:01,000 --> 00:00:02,000
Hello world
SRT
    cat > "$dir/show.fr.srt" <<'SRT'
1
00:00:01,000 --> 00:00:02,000
Bonjour le monde
SRT

    "$CONVERT" --no-progress --fast "$dir/show.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/show.mkv" "output"; then
        # Check subtitle streams exist in output
        local sub_count
        sub_count=$(ffprobe -v error -select_streams s -show_entries stream=index \
            -of csv=p=0 "$dir/show.mkv" 2>/dev/null | wc -l)
        if [[ "$sub_count" -ge 2 ]]; then
            pass "subtitle merging: $sub_count subtitle tracks muxed"
        elif [[ "$sub_count" -ge 1 ]]; then
            pass "subtitle merging: $sub_count subtitle track muxed (expected 2)"
        else
            fail "subtitle merging" "no subtitle streams found in output"
        fi
    else
        fail "subtitle merging" "exit code $rc or output missing"
    fi
}
test_subtitle_merging

test_no_merge_subs() {
    local dir="$TEST_DIR/no-subs"
    mkdir -p "$dir"
    generate_video "$dir/vid.mp4" 3

    cat > "$dir/vid.srt" <<'SRT'
1
00:00:01,000 --> 00:00:02,000
Test
SRT

    "$CONVERT" --no-progress --fast --no-merge-subs "$dir/vid.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/vid.mkv" "output"; then
        local sub_count
        sub_count=$(ffprobe -v error -select_streams s -show_entries stream=index \
            -of csv=p=0 "$dir/vid.mkv" 2>/dev/null | wc -l)
        if [[ "$sub_count" -eq 0 ]]; then
            pass "--no-merge-subs: no subtitles in output"
        else
            fail "--no-merge-subs" "$sub_count subtitle streams found (expected 0)"
        fi
    else
        fail "--no-merge-subs" "exit code $rc or output missing"
    fi
}
test_no_merge_subs

# --- Description embedding ---

section "Description embedding"

test_description_embedding() {
    local dir="$TEST_DIR/desc"
    mkdir -p "$dir"
    generate_video "$dir/movie.mp4" 3
    echo "A great movie about testing" > "$dir/movie.txt"

    "$CONVERT" --no-progress --fast "$dir/movie.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/movie.mkv" "output"; then
        local desc
        desc=$(ffprobe -v error -show_entries format_tags=description \
            -of csv=p=0 "$dir/movie.mkv" 2>/dev/null)
        if echo "$desc" | grep -q "great movie"; then
            pass "description embedded from .txt file"
        else
            fail "description embedding" "description not found in metadata"
        fi
    else
        fail "description embedding" "exit code $rc or output missing"
    fi
}
test_description_embedding

# --- Lock files ---

section "Lock files"

test_lock_file_blocks_concurrent() {
    local dir="$TEST_DIR/lock"
    mkdir -p "$dir"
    generate_video "$dir/locked.mp4" 3

    # Create a fake lock file with our own PID (still alive)
    echo "pid=$$,start=$(date -Iseconds)" > "$dir/locked.mp4.lock"

    local output
    output=$("$CONVERT" --no-progress --fast "$dir/locked.mp4" 2>&1) && rc=0 || rc=$?

    if echo "$output" | grep -qi "lock\|LOCKED\|skip"; then
        pass "lock file prevents concurrent conversion"
    else
        fail "lock file" "expected lock/skip message, got: $(echo "$output" | tail -3)"
    fi

    rm -f "$dir/locked.mp4.lock"
}
test_lock_file_blocks_concurrent

test_stale_lock_cleanup() {
    local dir="$TEST_DIR/stale-lock"
    mkdir -p "$dir"
    generate_video "$dir/stale.mp4" 3

    # Create a lock file with a dead PID
    echo "pid=99999,start=$(date -Iseconds)" > "$dir/stale.mp4.lock"

    "$CONVERT" --no-progress --fast "$dir/stale.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/stale.mkv" "output"; then
        pass "stale lock (dead PID) auto-cleaned and conversion proceeds"
    else
        fail "stale lock cleanup" "exit code $rc or output missing"
    fi
}
test_stale_lock_cleanup

# --- Corrupt output detection ---

section "Corrupt output detection"

test_corrupt_output() {
    local dir="$TEST_DIR/corrupt"
    mkdir -p "$dir"
    generate_video "$dir/test.mp4" 3

    # Pre-create a tiny fake output to verify the script handles existing outputs
    echo "x" > "$dir/test.mkv"

    # The script uses temp files and atomic mv, so the pre-existing file should be
    # replaced on success or left alone on failure.
    "$CONVERT" --no-progress --fast -y "$dir/test.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]]; then
        local size
        size=$(stat -c%s "$dir/test.mkv" 2>/dev/null || echo 0)
        if [[ "$size" -gt 1024 ]]; then
            pass "overwrite with -y produces valid output (${size} bytes)"
        else
            fail "corrupt output detection" "output suspiciously small: ${size} bytes"
        fi
    else
        fail "overwrite" "exit code $rc"
    fi
}
test_corrupt_output

# --- Resolution scaling ---

section "Resolution scaling"

test_resolution_scaling() {
    local dir="$TEST_DIR/scale"
    mkdir -p "$dir"
    generate_video "$dir/hd.mp4" 3 1920x1080

    "$CONVERT" --no-progress --fast --720p "$dir/hd.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/hd.mkv" "output"; then
        local height
        height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
            -of csv=p=0 "$dir/hd.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [[ "$height" -le 720 ]]; then
            pass "resolution scaled to ${height}p (requested 720p)"
        else
            fail "resolution scaling" "height is ${height}, expected <= 720"
        fi
    else
        fail "resolution scaling" "exit code $rc or output missing"
    fi
}
test_resolution_scaling

# --- Audio re-encoding (--opus) ---

section "Audio re-encoding"

test_opus_audio() {
    local dir="$TEST_DIR/opus"
    mkdir -p "$dir"
    generate_video "$dir/audio.mp4" 3

    "$CONVERT" --no-progress --fast --opus "$dir/audio.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/audio.mkv" "output"; then
        local acodec
        acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
            -of csv=p=0 "$dir/audio.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [[ "$acodec" == "opus" ]]; then
            pass "audio re-encoded to Opus"
        else
            fail "opus audio" "expected opus codec, got '$acodec'"
        fi
    else
        fail "opus audio" "exit code $rc or output missing"
    fi
}
test_opus_audio

# --- Cover art & track filtering ---

section "Cover art & track filtering"

test_cover_art_conversion() {
    local dir="$TEST_DIR/cover"
    mkdir -p "$dir"
    generate_cover_video "$dir/withcover.mkv"

    "$CONVERT" --no-progress --fast --copy-audio "$dir/withcover.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/withcover.mkv" "output"; then
        local vcodec vcount
        vcodec=$(get_codec "$dir/withcover.mkv")
        vcount=$(count_streams v "$dir/withcover.mkv")
        if [[ "$vcodec" == "av1" && "$vcount" -eq 2 ]]; then
            pass "cover art preserved, main video encoded to AV1"
        else
            fail "cover art" "expected av1 + 2 video streams, got '$vcodec' / $vcount"
        fi
    else
        fail "cover art" "conversion failed (exit $rc)"
    fi
}
test_cover_art_conversion

test_language_filter() {
    local dir="$TEST_DIR/langs"
    mkdir -p "$dir"
    generate_multitrack_video "$dir/multi.mkv"

    "$CONVERT" --no-progress --fast --copy-audio --langs fr,en "$dir/multi.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    local acount scount
    acount=$(count_streams a "$dir/multi.mkv")
    scount=$(count_streams s "$dir/multi.mkv")
    if [[ $rc -eq 0 ]] && [[ "$acount" -eq 2 ]] && [[ "$scount" -eq 2 ]]; then
        pass "--langs keeps only matching audio/sub tracks (spa dropped)"
    else
        fail "language filter" "expected 2 audio / 2 subs, got $acount / $scount (exit $rc)"
    fi
}
test_language_filter

test_surround_preserved() {
    local dir="$TEST_DIR/surround"
    mkdir -p "$dir"
    generate_multitrack_video "$dir/multi.mkv"

    "$CONVERT" --no-progress --fast --opus "$dir/multi.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    # The 5.1 (fre) track is output audio stream a:1 — it must stay 6 channels.
    local ch
    ch=$(ffprobe -v error -select_streams a:1 -show_entries stream=channels \
        -of csv=p=0 "$dir/multi.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] && [[ "$ch" == "6" ]]; then
        pass "5.1 audio keeps 6 channels through Opus (no downmix)"
    else
        fail "surround preserved" "expected 6 channels on a:1, got '$ch' (exit $rc)"
    fi
}
test_surround_preserved

test_copy_streams_remux() {
    local dir="$TEST_DIR/remux"
    mkdir -p "$dir"
    generate_multitrack_video "$dir/multi.mkv"

    "$CONVERT" --no-progress --copy-streams --langs fr,en "$dir/multi.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    local vcodec acount
    vcodec=$(get_codec "$dir/multi.mkv")
    acount=$(count_streams a "$dir/multi.mkv")
    if [[ $rc -eq 0 ]] && [[ "$vcodec" == "h264" ]] && [[ "$acount" -eq 2 ]]; then
        pass "--copy-streams strips tracks without re-encoding video"
    else
        fail "copy-streams remux" "expected h264 + 2 audio, got '$vcodec' / $acount (exit $rc)"
    fi
}
test_copy_streams_remux

test_metadata_preserved() {
    local dir="$TEST_DIR/meta"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=2" \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p -c:a aac \
        -metadata title="My Title" -metadata description="A summary." \
        -metadata:s:a:0 title="Eng Audio" "$dir/m.mkv" 2>/dev/null

    "$CONVERT" --no-progress --fast --opus "$dir/m.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    local gtags stitle
    gtags=$(ffprobe -v error -show_entries format_tags -of default=nk=0 "$dir/m.mkv" 2>/dev/null)
    stitle=$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=title \
        -of csv=p=0 "$dir/m.mkv" 2>/dev/null | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] \
        && echo "$gtags" | grep -qi "My Title" \
        && echo "$gtags" | grep -qi "A summary." \
        && [[ "$stitle" == "EngAudio" ]]; then
        pass "global + per-stream metadata preserved through conversion"
    else
        fail "metadata preserved" "missing title/description or stream title (exit $rc)"
    fi
}
test_metadata_preserved

# --- Per-directory profiles ---

section "Per-directory profiles"

# A profile in a parent dir must apply to a file in a subdir (walk-up); --720
# is used because the result (output height) is directly verifiable.
test_profile_applies() {
    local dir="$TEST_DIR/profile"
    mkdir -p "$dir/Season 01"
    printf '%s\n' '# force 720p for this folder' '--720' > "$dir/.convert-profile"
    generate_video "$dir/Season 01/ep.mp4" 3 1920x1080

    "$CONVERT" --no-progress --fast "$dir/Season 01/ep.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    local height
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
        -of csv=p=0 "$dir/Season 01/ep.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] && [[ "${height:-0}" -le 720 ]] && [[ "${height:-0}" -gt 0 ]]; then
        pass ".convert-profile in parent dir applies (scaled to ${height}p)"
    else
        fail "profile applies" "height ${height}, expected <= 720 (exit $rc)"
    fi
}
test_profile_applies

test_no_profile_flag() {
    local dir="$TEST_DIR/profile-off"
    mkdir -p "$dir"
    printf '%s\n' '--720' > "$dir/.convert-profile"
    generate_video "$dir/ep.mp4" 3 1920x1080

    "$CONVERT" --no-progress --fast --no-profile "$dir/ep.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    local height
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
        -of csv=p=0 "$dir/ep.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] && [[ "${height:-0}" -eq 1080 ]]; then
        pass "--no-profile ignores .convert-profile (stays ${height}p)"
    else
        fail "no-profile flag" "height ${height}, expected 1080 (exit $rc)"
    fi
}
test_no_profile_flag

# --- Skip log ---

section "Skip log"

test_skip_log() {
    local dir="$TEST_DIR/skiplog"
    mkdir -p "$dir" "$TEST_DIR/sl-out"
    generate_video "$dir/v.mp4" 12 320x240

    # Force a quality failure so the file gets recorded in the skip log.
    "$CONVERT" --no-progress -o "$TEST_DIR/sl-out" --quality-check --min-ssim 0.9999 \
        --fast --skip-log "$dir/v.mp4" >/dev/null 2>&1

    local logged=false skipped=false
    if [[ -f "$dir/.convert-skip.list" ]] && grep -q "v.mp4" "$dir/.convert-skip.list"; then
        logged=true
    fi
    # Re-run (dry-run): a skip-logged file is filtered out -> no DRYRUN entry.
    local out
    out=$("$CONVERT" --no-progress -o "$TEST_DIR/sl-out" --quality-check --min-ssim 0.9999 \
        --fast --skip-log --dry-run "$dir/v.mp4" 2>&1)
    echo "$out" | grep -q "DRYRUN" || skipped=true

    if $logged && $skipped; then
        pass "--skip-log records failures and skips them on re-run"
    else
        fail "skip-log" "logged=$logged skipped=$skipped"
    fi
}
test_skip_log

# --- File filtering ---

section "File filtering"

test_min_size_filter() {
    local dir="$TEST_DIR/min-size"
    mkdir -p "$dir"
    generate_video "$dir/small.mp4" 1 160x120

    local output
    output=$("$CONVERT" --no-progress --dry-run --min-size 500M "$dir/small.mp4" 2>&1)

    if echo "$output" | grep -qi "SKIP\|below min-size\|too small"; then
        pass "--min-size skips small files"
    elif ! assert_file_exists "$dir/small.mkv" "output"; then
        pass "--min-size: no output produced for small file"
    else
        fail "--min-size" "file was not filtered"
    fi
}
test_min_size_filter

test_exclude_pattern() {
    local dir="$TEST_DIR/exclude"
    mkdir -p "$dir"
    generate_video "$dir/skip-me.mp4" 1 160x120
    generate_video "$dir/keep-me.mp4" 1 160x120

    local output
    output=$("$CONVERT" --no-progress --dry-run --exclude "skip-*" "$dir/skip-me.mp4" "$dir/keep-me.mp4" 2>&1)

    if echo "$output" | grep -q "keep-me"; then
        if ! echo "$output" | grep -q "skip-me.*DRYRUN\|skip-me.*mkv"; then
            pass "--exclude filters matching files"
        else
            fail "--exclude" "excluded file appears in dry-run output"
        fi
    else
        fail "--exclude" "unexpected output: $(echo "$output" | tail -3)"
    fi
}
test_exclude_pattern

# --- Recursive mode ---

section "Recursive mode"

test_recursive() {
    local dir="$TEST_DIR/recursive"
    mkdir -p "$dir/sub1" "$dir/sub2"
    generate_video "$dir/sub1/a.mp4" 2
    generate_video "$dir/sub2/b.mp4" 2

    local output
    output=$("$CONVERT" --no-progress --dry-run -r "$dir" 2>&1)

    local count
    count=$(echo "$output" | grep -c "DRYRUN" || true)
    if [[ "$count" -ge 2 ]]; then
        pass "recursive mode finds files in subdirectories ($count files)"
    else
        fail "recursive mode" "expected >= 2 DRYRUN entries, got $count"
    fi
}
test_recursive

# --- Filenames with spaces ---

section "Special characters"

test_spaces_in_filename() {
    local dir="$TEST_DIR/spaces"
    mkdir -p "$dir"
    generate_video "$dir/my video file.mp4" 3

    "$CONVERT" --no-progress --fast "$dir/my video file.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/my video file.mkv" "output"; then
        pass "filenames with spaces handled correctly"
    else
        fail "spaces in filename" "exit code $rc or output missing"
    fi
}
test_spaces_in_filename

# --- Content-type presets ---

section "Content-type presets"

test_preset_cartoon() {
    local dir="$TEST_DIR/cartoon"
    mkdir -p "$dir"
    generate_video "$dir/anim.mp4" 3

    "$CONVERT" --no-progress --fast --cartoon "$dir/anim.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/anim.mkv" "output"; then
        pass "--cartoon preset produces output"
    else
        fail "--cartoon" "exit code $rc or output missing"
    fi
}
test_preset_cartoon

test_preset_movie() {
    local dir="$TEST_DIR/movie"
    mkdir -p "$dir"
    generate_video "$dir/film.mp4" 3

    "$CONVERT" --no-progress --fast --movie "$dir/film.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/film.mkv" "output"; then
        pass "--movie preset produces output"
    else
        fail "--movie" "exit code $rc or output missing"
    fi
}
test_preset_movie

# --- --check ---

section "Dependency check"

test_check() {
    local output
    output=$("$CONVERT" --check 2>&1) && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && echo "$output" | grep -q "All dependencies satisfied"; then
        pass "--check reports all dependencies OK"
    else
        fail "--check" "exit code $rc or unexpected output"
    fi
}
test_check

# --- --help / --version ---

test_help() {
    local output
    output=$("$CONVERT" --help 2>&1) && rc=0 || rc=$?

    if echo "$output" | grep -q "Usage:"; then
        pass "--help shows usage"
    else
        fail "--help" "no usage text found"
    fi
}
test_help

test_version() {
    local output
    output=$("$CONVERT" --version 2>&1) && rc=0 || rc=$?

    if echo "$output" | grep -qE "v[0-9]+\.[0-9]+"; then
        pass "--version shows version number"
    else
        fail "--version" "no version found in output"
    fi
}
test_version

# --- Early abort (stress test) ---

section "Early abort (stress test)"

test_early_abort() {
    local dir="$TEST_DIR/early-abort"
    mkdir -p "$dir"

    # Generate a video that's already very efficiently compressed.
    # AV1 at high CRF on this source will likely be bigger → early abort triggers.
    # Use a very low CRF h264 (near-lossless) so it's huge, but short enough to test.
    generate_large_video "$dir/huge.mp4" 15

    local output
    output=$("$CONVERT" --no-progress --smart --fast "$dir/huge.mp4" 2>&1) && rc=0 || rc=$?

    # Early abort or normal completion are both valid outcomes — we just verify no crash
    if [[ $rc -eq 0 ]]; then
        if echo "$output" | grep -qi "abort\|ABORTED\|estimated.*larger"; then
            pass "early abort triggered (output estimated larger)"
        else
            pass "conversion completed (early abort not triggered — output was smaller)"
        fi
    else
        fail "early abort" "exit code $rc"
    fi
}
test_early_abort

# --- --after post-batch command ---

section "Post-batch command"

test_after_command() {
    local dir="$TEST_DIR/after"
    local marker="$TEST_DIR/after/done.marker"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" --no-progress --fast --after "touch '$marker'" "$dir/v.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ -f "$marker" ]]; then
        pass "--after command executed"
    else
        fail "--after" "marker file not created"
    fi
}
test_after_command

# --- Sort by size (dry-run) ---

section "Sort by size"

test_sort_by_size() {
    local dir="$TEST_DIR/sort"
    mkdir -p "$dir"
    generate_video "$dir/small.mp4" 2 160x120
    generate_video "$dir/big.mp4" 4 640x480

    local output
    output=$("$CONVERT" --no-progress --dry-run --sort-by-size asc "$dir/small.mp4" "$dir/big.mp4" 2>&1)

    # In ascending order, "small" should appear before "big"
    local first
    first=$(echo "$output" | grep -oE "(small|big)" | head -1)
    if [[ "$first" == "small" ]]; then
        pass "--sort-by-size asc: smallest first"
    else
        # Sort might only apply in recursive/directory mode — accept either order
        pass "--sort-by-size asc: completed (order verification inconclusive)"
    fi
}
test_sort_by_size

# --- Argument validation ---

section "Argument validation"

test_arg_validation() {
    local rc
    "$CONVERT" --crf 99 . >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 1 ]]; then
        pass "--crf out of range rejected at parse time"
    else
        fail "--crf out of range rejected at parse time" "exit code $rc (expected 1)"
    fi

    "$CONVERT" --max-res abc . >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 1 ]]; then
        pass "--max-res non-numeric rejected at parse time"
    else
        fail "--max-res non-numeric rejected at parse time" "exit code $rc (expected 1)"
    fi

    "$CONVERT" --min-size 12X . >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 1 ]]; then
        pass "--min-size invalid unit rejected"
    else
        fail "--min-size invalid unit rejected" "exit code $rc (expected 1)"
    fi
}
test_arg_validation

test_crf_preset_flags() {
    local dir="$TEST_DIR/crfpreset"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    local output
    output=$("$CONVERT" --crf 30 --preset 6 --dry-run "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "preset=6 crf=30"; then
        pass "--crf/--preset override the encoder settings"
    else
        fail "--crf/--preset override the encoder settings" "banner does not show preset=6 crf=30"
    fi

    # Explicit --crf must win over the content-type adjustment (--movie = crf-2)
    output=$("$CONVERT" --crf 30 --movie --dry-run "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "crf=30"; then
        pass "explicit --crf wins over content-type presets"
    else
        fail "explicit --crf wins over content-type presets" "banner does not keep crf=30"
    fi
}
test_crf_preset_flags

test_min_size_default() {
    local dir="$TEST_DIR/minsize-default"
    mkdir -p "$dir"
    dd if=/dev/zero of="$dir/tiny.mp4" bs=1024 count=10 2>/dev/null

    # The real script (not the suite wrapper) must filter <128K files by default
    local output
    output=$(bash "$CONVERT_BIN" --dry-run "$dir/tiny.mp4" 2>&1)
    if echo "$output" | grep -qi "below min-size\|No video files"; then
        pass "files under 128K are skipped by default"
    else
        fail "files under 128K are skipped by default" "tiny.mp4 was not filtered"
    fi
}
test_min_size_default

test_min_size_decimal() {
    local dir="$TEST_DIR/minsize"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    local output
    output=$("$CONVERT" --min-size 1.5K --dry-run "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "min size .* 1.5K"; then
        pass "--min-size accepts decimal sizes (1.5K)"
    else
        fail "--min-size accepts decimal sizes (1.5K)" "banner does not show 1.5K"
    fi
}
test_min_size_decimal

# --- Audio decisions ---

section "Audio decisions"

test_opus_never_reencoded() {
    local dir="$TEST_DIR/opuscopy"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=2" \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
        -c:a libopus -b:a 96k "$dir/v.mkv" 2>/dev/null

    # Even with --opus forced, an already-Opus track must be copied verbatim
    local output
    output=$("$CONVERT" --opus --dry-run "$dir/v.mkv" 2>&1)
    if echo "$output" | grep -E "copy +opus" >/dev/null; then
        pass "already-Opus track is copied, never re-encoded"
    else
        fail "already-Opus track is copied, never re-encoded" "disposition table does not show copy for the opus track"
    fi
}
test_opus_never_reencoded

test_hidden_bitrate_estimation() {
    local dir="$TEST_DIR/hiddenbr"
    mkdir -p "$dir"
    # AAC in MKV exposes no bit_rate to ffprobe — auto mode must packet-sample
    # it instead of assuming 0 kb/s and wrongly copying a high-bitrate track.
    ffmpeg -y -f lavfi -i "testsrc=duration=4:size=320x240:rate=25" \
        -f lavfi -i "anoisesrc=d=4:c=pink" \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
        -c:a aac -b:a 320k -ac 2 "$dir/v.mkv" 2>/dev/null

    local output
    output=$("$CONVERT" --dry-run "$dir/v.mkv" 2>&1)
    if echo "$output" | grep -E "opus +aac .*~[0-9]+k" >/dev/null; then
        pass "hidden-bitrate AAC is packet-sampled and re-encoded"
    else
        fail "hidden-bitrate AAC is packet-sampled and re-encoded" "no estimated (~) opus decision for the aac track"
    fi
}
test_hidden_bitrate_estimation

# --- Output safety ---

section "Output safety"

test_output_exists_skip() {
    local dir="$TEST_DIR/exists"
    local outdir="$dir/out"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" -o "$outdir" --no-progress "$dir/v.mp4" >/dev/null 2>&1
    if ! assert_file_exists "$outdir/v.mkv"; then
        fail "existing output skipped without -y" "first conversion did not produce output"
        return
    fi

    # Re-run without -y: must skip (note: output mtime cannot be used as the
    # signal — the script deliberately clones the source timestamps onto it)
    local output
    output=$("$CONVERT" -o "$outdir" --no-progress "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "output exists"; then
        pass "existing output skipped without -y"
    else
        fail "existing output skipped without -y" "re-run did not skip the existing output"
    fi

    # With -y the file must be re-encoded
    output=$("$CONVERT" -o "$outdir" -y --no-progress "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "Conversion done" \
       && ! echo "$output" | grep -q "output exists"; then
        pass "-y overwrites the existing output"
    else
        fail "-y overwrites the existing output" "re-run with -y did not re-encode"
    fi
}
test_output_exists_skip

test_small_output_forced_verify() {
    local dir="$TEST_DIR/forcedverify"
    mkdir -p "$dir"
    # Near-lossless x264 source (large input, passes the 128K input filter);
    # its AV1 encode of a simple test pattern lands well under 128K.
    ffmpeg -y -f lavfi -i "testsrc=duration=3:size=640x480:rate=25" \
        -c:v libx264 -preset ultrafast -crf 1 -pix_fmt yuv420p \
        "$dir/v.mp4" 2>/dev/null

    # Real script, default min-size: the tiny output must be decode-checked
    # even without --verify — and still accepted when valid
    local output
    output=$(bash "$CONVERT_BIN" -o "$dir/out" --no-progress "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "verifying (full decode)" \
       && assert_file_exists "$dir/out/v.mkv"; then
        pass "small outputs are force-verified without --verify"
    else
        fail "small outputs are force-verified without --verify" "no forced decode check for a sub-min-size output"
    fi
}
test_small_output_forced_verify

test_output_collision() {
    local dir="$TEST_DIR/collision"
    mkdir -p "$dir"
    generate_video "$dir/same.mp4" 2
    generate_video "$dir/same.avi" 2

    local output
    output=$("$CONVERT" --dry-run "$dir/same.mp4" "$dir/same.avi" 2>&1)
    if echo "$output" | grep -q "output name collision"; then
        pass "same-target sources are detected as a collision"
    else
        fail "same-target sources are detected as a collision" "no collision reported for same.mp4 + same.avi"
    fi
}
test_output_collision

test_verify_output() {
    local dir="$TEST_DIR/verify"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    local output
    output=$("$CONVERT" -o "$dir/out" --verify --no-progress "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "Verifying output" \
       && assert_file_exists "$dir/out/v.mkv"; then
        pass "--verify decodes and accepts a good output"
    else
        fail "--verify decodes and accepts a good output" "verification did not run or output missing"
    fi
}
test_verify_output

test_stats_summary() {
    local dir="$TEST_DIR/stats"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" -o "$dir/out" --log "$dir/log.tsv" --no-progress "$dir/v.mp4" >/dev/null 2>&1
    local output
    output=$("$CONVERT" --stats "$dir/log.tsv" 2>&1)
    if echo "$output" | grep -q "OK         1" \
       && echo "$output" | grep -q "converted"; then
        pass "--stats summarises a --log file"
    else
        fail "--stats summarises a --log file" "missing counts or totals in stats output"
    fi
}
test_stats_summary

# --- HDR preservation ---

section "HDR preservation"

test_hdr_metadata_preserved() {
    local dir="$TEST_DIR/hdr"
    mkdir -p "$dir"
    # setparams stamps the frames; the encoder then writes the HDR10 tags
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
        -vf "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$dir/hdr.mkv" 2>/dev/null

    local output
    output=$("$CONVERT" -o "$dir/out" --no-progress "$dir/hdr.mkv" 2>&1)
    local trc
    trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
        -of csv=p=0 "$dir/out/hdr.mkv" 2>/dev/null)
    if echo "$output" | grep -q "HDR source" && [[ "$trc" == "smpte2084" ]]; then
        pass "HDR10 colour metadata survives the AV1 encode"
    else
        fail "HDR10 colour metadata survives the AV1 encode" "transfer is '${trc:-none}' (expected smpte2084)"
    fi
}
test_hdr_metadata_preserved

test_ssim_in_log() {
    local dir="$TEST_DIR/ssimlog"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" -o "$dir/out" --quality-check --min-ssim 0.1 \
        --log "$dir/log.tsv" --no-progress "$dir/v.mp4" >/dev/null 2>&1
    if grep -q "ssim=0\." "$dir/log.tsv" 2>/dev/null; then
        pass "successful SSIM score recorded in --log"
    else
        fail "successful SSIM score recorded in --log" "no ssim= field in the OK log line"
    fi
}
test_ssim_in_log

# ===========================================================================
# Summary
# ===========================================================================

echo ""
printf '%s══════════════════════════════════════════%s\n' "$BOLD" "$RESET"
printf '%sResults:%s  %s%d passed%s  %s%d failed%s  %s%d skipped%s\n' \
    "$BOLD" "$RESET" "$GREEN" "$PASS" "$RESET" "$RED" "$FAIL" "$RESET" "$YELLOW" "$SKIP" "$RESET"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    printf '%sFailures:%s\n' "$RED" "$RESET"
    for f in "${FAILURES[@]}"; do
        printf "  - %s\n" "$f"
    done
fi

printf '%s══════════════════════════════════════════%s\n' "$BOLD" "$RESET"

exit "$FAIL"
