#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# convert-to-av1 v3.3.0 — Batch video conversion to AV1 (SVT-AV1 via ffmpeg)
# ==============================================================================

VERSION="3.3.0"

# -- Colors (respects NO_COLOR: https://no-color.org/) -------------------------
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    RED='' GREEN='' ORANGE='' GRAY='' BOLD='' NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    ORANGE='\033[38;5;214m'
    GRAY='\033[38;5;8m'
    BOLD='\033[1;37m'
    NC='\033[0m'
fi

# -- Defaults ------------------------------------------------------------------
output_dir=""
in_place=false
input_args=()
remove_source=false
remove_if_bigger=false
keep_best_version=false
overwrite=""
max_res=""

# -- SVT-AV1 encoding parameters (decomposed for content-type presets) ---------
svt_preset=8
svt_crf=28
svt_film_grain=0
svt_film_grain_denoise=0
svt_tune=0
svt_pix_fmt="yuv420p10le"
svt_enable_overlays=1
svt_scd=1
content_type=""        # "", "cartoon", "tv", "movie"
speed_preset="default" # "fast", "default", "hq"
svtav1_options=""       # assembled by build_svtav1_options()

log_file=""
verbose=false
dry_run=false
sort_by_size=""
no_progress=false
early_abort=true
early_abort_threshold=8
merge_subs=true
recursive=false
audio_langs=""  # comma-separated language codes to keep (empty = keep all)
sub_langs=""    # comma-separated language codes to keep (empty = keep all)
copy_streams=false  # remux only (no re-encode), just strip/keep selected tracks
use_profiles=true   # honor per-directory .convert-profile files
audio_mode="auto"  # copy, opus, auto
audio_bitrate_threshold=200  # kb/s — auto mode re-encodes above this
min_size=0  # bytes — skip files smaller than this
exclude_patterns=()
skip_log_enabled=false  # persist quality-check failures and skip them on re-runs
skip_log_file=""        # path to the failure log (empty = default at -r root)
after_cmd=""
quality_check=false
quality_min_ssim=0.92  # minimum acceptable SSIM (0-1 scale)
quality_sample_secs=10 # seconds per sample segment for quality check
quality_samples=5      # number of evenly-spaced sample points for quality check

# -- Global state (for cleanup) ------------------------------------------------
CURRENT_TEMP_FILE=""
CURRENT_LOCK_FILE=""
CURRENT_STDERR_LOG=""
CURRENT_FFMPEG_PID=""
EARLY_ABORTED=false
SKIP_REQUESTED=false
SUMMARY_FILES=()
SUMMARY_STATUSES=()
SUMMARY_INPUT_SIZES=()
SUMMARY_OUTPUT_SIZES=()
SUMMARY_NOTES=()
FILES_PROCESSED=0
FILES_TOTAL=0
BATCH_SAVED_BYTES=0
BATCH_START_TIME=0

# Quality-failure skip log: abspath -> recorded source size (bytes)
declare -A SKIP_LOG_SIZES=()

# -- Per-directory profile state -----------------------------------------------
# Base (CLI) encoding config, snapshotted so per-file profiles start clean.
declare -A BASE_CFG=()
CURRENT_PROFILE_FILE=""   # path of the .convert-profile applied to current file
CURRENT_PROFILE_TOKENS="" # its raw tokens, for display

# ==============================================================================
# SVT-AV1 preset helpers
# ==============================================================================

# Apply content-type overlay on top of speed preset values
apply_content_type() {
    case "$content_type" in
        cartoon)
            svt_film_grain=0
            svt_crf=$(( svt_crf + 2 ))
            ;;
        tv)
            svt_film_grain=0
            svt_crf=$(( svt_crf + 1 ))
            # Boost speed: TV content doesn't need slow presets
            [[ "$svt_preset" -lt 10 ]] && svt_preset=10
            ;;
        movie)
            svt_film_grain_denoise=1
            svt_crf=$(( svt_crf - 2 ))
            case "$speed_preset" in
                fast)    svt_film_grain=8 ;;
                default) svt_film_grain=10 ;;
                hq)      svt_film_grain=10 ;;
            esac
            ;;
    esac
}

# Assemble decomposed variables into the svtav1_options string
build_svtav1_options() {
    local params="tune=${svt_tune}:film-grain=${svt_film_grain}:enable-overlays=${svt_enable_overlays}:scd=${svt_scd}"
    if [[ "$svt_film_grain_denoise" -eq 1 ]]; then
        params+=":film-grain-denoise=1"
    fi
    svtav1_options="-preset ${svt_preset} -crf ${svt_crf} -pix_fmt ${svt_pix_fmt} -svtav1-params ${params}"
}

# ==============================================================================
# Per-directory profiles (.convert-profile)
# ==============================================================================
#
# A ".convert-profile" file placed in a directory (or any parent) applies its
# encoding/quality/audio/track flags to files under it — e.g. a folder of
# grainy films gets "--movie", an animation folder gets "--cartoon". Resolved
# per file (each directory can differ); explicit flags in the profile override
# the CLI base for that file.

# The CLI-level encoding config that a profile may override. Captured once so
# each file's profile starts from the same clean base (no leakage between dirs).
PROFILE_VARS=(svt_preset svt_crf svt_film_grain svt_film_grain_denoise svt_tune
    svt_pix_fmt svt_enable_overlays svt_scd content_type speed_preset max_res
    audio_mode audio_bitrate_threshold audio_langs sub_langs copy_streams)

snapshot_base_config() {
    local v
    for v in "${PROFILE_VARS[@]}"; do
        BASE_CFG["$v"]="${!v}"
    done
}

restore_base_config() {
    local v
    for v in "${PROFILE_VARS[@]}"; do
        printf -v "$v" '%s' "${BASE_CFG[$v]}"
    done
}

# Walk up from a file's directory to the filesystem root; echo the first
# .convert-profile found (empty if none).
find_profile_file() {
    local dir
    dir=$(cd "$(dirname "$1")" 2>/dev/null && pwd) || return 0
    while [[ -n "$dir" ]]; do
        if [[ -f "$dir/.convert-profile" ]]; then
            echo "$dir/.convert-profile"
            return 0
        fi
        [[ "$dir" == "/" ]] && break
        dir=$(dirname "$dir")
    done
}

# Apply the subset of flags that make sense in a profile. Mirrors parse_args for
# encoding/quality/audio/track options; ignores (with a warning) anything else.
apply_profile_tokens() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sd|--fast)   svt_preset=10; svt_crf=32; svt_film_grain=0; speed_preset="fast"; shift ;;
            --hq)          svt_preset=4; svt_crf=28; svt_film_grain=8; speed_preset="hq"
                           [[ "$audio_mode" == "auto" ]] && audio_mode="copy"; shift ;;
            --cartoon)     content_type="cartoon"; shift ;;
            --tv)          content_type="tv"; shift ;;
            --movie)       content_type="movie"; shift ;;
            --max-res|--max-h|--max-height) max_res="$2"; shift 2 ;;
            --1080|--1080p) max_res="1080"; shift ;;
            --720|--720p)  max_res="720"; shift ;;
            --copy-audio)  audio_mode="copy"; shift ;;
            --opus)        audio_mode="opus"; shift ;;
            --auto-audio)  audio_mode="auto"; shift ;;
            --audio-threshold) audio_bitrate_threshold="$2"; audio_mode="auto"; shift 2 ;;
            --langs|--lang)          audio_langs="$2"; sub_langs="$2"; shift 2 ;;
            --audio-langs|--audio-lang) audio_langs="$2"; shift 2 ;;
            --sub-langs|--sub-lang)  sub_langs="$2"; shift 2 ;;
            --copy-streams|--remux)  copy_streams=true; shift ;;
            "")            shift ;;
            *)             warn "Ignoring unsupported profile option: $1"; shift ;;
        esac
    done
}

# Restore the CLI base, then overlay the file's .convert-profile (if any), and
# recompute the derived SVT options. Sets CURRENT_PROFILE_FILE/TOKENS.
resolve_file_profile() {
    local input_file="$1"
    restore_base_config
    CURRENT_PROFILE_FILE=""
    CURRENT_PROFILE_TOKENS=""

    if $use_profiles; then
        local pf
        pf=$(find_profile_file "$input_file")
        if [[ -n "$pf" ]]; then
            local -a toks=()
            local line
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"                 # strip comments
                [[ -z "${line// /}" ]] && continue
                local -a lt=()
                read -ra lt <<< "$line"
                toks+=("${lt[@]}")
            done < "$pf"
            CURRENT_PROFILE_FILE="$pf"
            CURRENT_PROFILE_TOKENS="${toks[*]-}"
            apply_profile_tokens "${toks[@]+"${toks[@]}"}"
        fi
    fi

    apply_content_type
    build_svtav1_options
}

# ==============================================================================
# Utility functions
# ==============================================================================

die() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit "${2:-1}"
}

warn() {
    echo -e "${ORANGE}WARN: $1${NC}" >&2
}

info() {
    echo -e "${GREEN}$1${NC}"
}

debug() {
    if $verbose; then
        echo -e "${GRAY}[debug] $1${NC}" >&2
    fi
}

human_size() {
    local bytes="${1:-0}"
    if [[ "$bytes" -eq 0 ]]; then
        echo "0B"
    else
        numfmt --to=iec "$bytes"
    fi
}

format_duration() {
    local secs="${1:-0}"
    printf "%02d:%02d:%02d" $((secs / 3600)) $(((secs % 3600) / 60)) $((secs % 60))
}

# Parse human-readable size (e.g., 100M, 1G, 500K) to bytes
parse_size() {
    local input="$1"
    local num unit
    num=$(echo "$input" | grep -oP '^[0-9]+(\.[0-9]+)?' || true)
    unit=$(echo "$input" | grep -oP '[A-Za-z]+$' || true)
    case "${unit^^}" in
        K|KB|KIB) echo $(( ${num%.*} * 1024 )) ;;
        M|MB|MIB) echo $(( ${num%.*} * 1024 * 1024 )) ;;
        G|GB|GIB) echo $(( ${num%.*} * 1024 * 1024 * 1024 )) ;;
        T|TB|TIB) echo $(( ${num%.*} * 1024 * 1024 * 1024 * 1024 )) ;;
        *)         echo "${num%.*}" ;;
    esac
}

# Check if a filename matches any exclude pattern
is_excluded() {
    local filename="$1"
    local base
    base=$(basename "$filename")
    for pattern in "${exclude_patterns[@]+"${exclude_patterns[@]}"}"; do
        # shellcheck disable=SC2254
        case "$base" in $pattern) return 0 ;; esac
    done
    return 1
}

add_result() {
    local file="$1" status="$2" input_sz="${3:-0}" output_sz="${4:-0}" note="${5:-}"
    SUMMARY_FILES+=("$file")
    SUMMARY_STATUSES+=("$status")
    SUMMARY_INPUT_SIZES+=("$input_sz")
    SUMMARY_OUTPUT_SIZES+=("$output_sz")
    SUMMARY_NOTES+=("$note")
}

# ==============================================================================
# Language matching (track filtering)
# ==============================================================================

# Canonicalise a language code to its ISO 639-2/B 3-letter form when known.
# Unknown codes are returned lowercased and unchanged (allows exact-tag matching).
canon_lang() {
    local c="${1,,}"
    case "$c" in
        fr|fre|fra)     echo "fre" ;;
        en|eng)         echo "eng" ;;
        de|ger|deu)     echo "ger" ;;
        es|spa)         echo "spa" ;;
        it|ita)         echo "ita" ;;
        pt|por)         echo "por" ;;
        ja|jpn)         echo "jpn" ;;
        zh|chi|zho)     echo "chi" ;;
        ru|rus)         echo "rus" ;;
        nl|dut|nld)     echo "dut" ;;
        pl|pol)         echo "pol" ;;
        sv|swe)         echo "swe" ;;
        no|nor)         echo "nor" ;;
        da|dan)         echo "dan" ;;
        fi|fin)         echo "fin" ;;
        ko|kor)         echo "kor" ;;
        ar|ara)         echo "ara" ;;
        tr|tur)         echo "tur" ;;
        cs|cze|ces)     echo "cze" ;;
        el|gre|ell)     echo "gre" ;;
        hu|hun)         echo "hun" ;;
        he|heb)         echo "heb" ;;
        hi|hin)         echo "hin" ;;
        *)              echo "$c" ;;
    esac
}

# Return 0 if a stream's language tag matches any code in a comma-separated list.
# Undefined/missing languages ("", "und") always match (kept as a safety net).
lang_matches() {
    local stream_lang="${1,,}"
    local requested_csv="$2"

    if [[ -z "$stream_lang" || "$stream_lang" == "und" ]]; then
        return 0
    fi

    local stream_canon
    stream_canon=$(canon_lang "$stream_lang")

    local IFS=','
    local token
    for token in $requested_csv; do
        token="${token// /}"
        [[ -z "$token" ]] && continue
        [[ "$(canon_lang "$token")" == "$stream_canon" ]] && return 0
    done
    return 1
}

# ==============================================================================
# Quality-failure skip log
# ==============================================================================
#
# Records files that were converted but not worth keeping (SSIM below target, or
# output larger than source). On a later batch over the same tree they are
# skipped instead of re-encoded. Paths are stored relative to the log's own
# directory so the log stays valid if the tree is moved/mounted elsewhere; a
# recorded source size acts as a safety net (a changed file is re-tried).

SKIP_LOG_DIR=""  # absolute dir of the skip log (paths are relative to it)

# Absolute path without resolving symlinks (realpath may be absent).
abspath() {
    local p="$1"
    if [[ -d "$p" ]]; then
        (cd "$p" 2>/dev/null && pwd)
    else
        local d
        d=$(cd "$(dirname "$p")" 2>/dev/null && pwd) || { echo "$p"; return; }
        echo "${d%/}/$(basename "$p")"
    fi
}

# Key under which a file is stored: path relative to the log dir when the file
# is under it, otherwise its absolute path.
skip_key() {
    local af
    af=$(abspath "$1")
    if [[ -n "$SKIP_LOG_DIR" && "$af" == "$SKIP_LOG_DIR"/* ]]; then
        echo "${af#"$SKIP_LOG_DIR"/}"
    else
        echo "$af"
    fi
}

load_skip_log() {
    SKIP_LOG_DIR=$(abspath "$(dirname "$skip_log_file")")
    [[ -f "$skip_log_file" ]] || return 0
    local size path
    # Line format: <size>\t<relpath>\t<date>\t<reason>  (reason/date ignored here)
    while IFS=$'\t' read -r size path _; do
        [[ -z "$path" || "$size" == \#* ]] && continue
        [[ "$size" =~ ^[0-9]+$ ]] || continue
        SKIP_LOG_SIZES["$path"]="$size"
    done < "$skip_log_file"
}

# True if the file previously failed and is unchanged (same size = same file).
is_skip_logged() {
    $skip_log_enabled || return 1
    local key rec
    key=$(skip_key "$1")
    rec="${SKIP_LOG_SIZES[$key]:-}"
    [[ -n "$rec" ]] || return 1
    [[ "$(get_file_size "$1")" == "$rec" ]]
}

# Record a file as not worth converting (quality/size failure).
# Line format: <size>\t<relpath>\t<source mtime>\t<reason>. The mtime is the
# source's (identifies the file version that failed), not the log-write time.
append_skip_log() {
    $skip_log_enabled || return 0
    local file="$1" size="$2" reason="$3"
    local key
    key=$(skip_key "$file")
    [[ "${SKIP_LOG_SIZES[$key]:-}" == "$size" ]] && return 0   # already recorded
    SKIP_LOG_SIZES["$key"]="$size"
    local mt src_mtime="?"
    mt=$(stat -c %Y "$file" 2>/dev/null)
    [[ -n "$mt" ]] && src_mtime=$(date -d "@$mt" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "?")
    printf '%s\t%s\t%s\t%s\n' "$size" "$key" "$src_mtime" "$reason" \
        >> "$skip_log_file" 2>/dev/null || warn "Could not write skip-log: $skip_log_file"
}

# ==============================================================================
# Probe functions (ffprobe)
# ==============================================================================

# Per-file probe cache. One ffprobe + one python3 parse replaces the ~10 separate
# ffprobe spawns previously done per file (codec, format, duration, frame count,
# color space, track selection). Each spawn is a fork plus a file open — costly
# on slow mounts (WSL /mnt). Keyed by path; re-runs only when the file changes.
PROBE_FILE=""
PROBE_FORMAT_NAME=""
PROBE_DURATION="0"
PROBE_V0_CODEC=""
PROBE_V0_WIDTH="0"
PROBE_V0_HEIGHT="0"
PROBE_V0_NB_FRAMES="0"
PROBE_V0_AVG_FRAME_RATE=""
PROBE_V0_COLOR_SPACE=""
PROBE_FORMAT_BITRATE=""
PROBE_JSON=""          # raw ffprobe JSON, reused by print_file_info
PROBE_STREAMS_TSV=""   # one row per stream: index<TAB>type<TAB>attached_pic<TAB>lang<TAB>channels<TAB>bitrate

probe_load() {
    local file="$1"
    [[ "$file" == "$PROBE_FILE" ]] && return 0

    # Reset to safe defaults (used if the probe fails / non-media file)
    PROBE_FILE="$file"
    PROBE_FORMAT_NAME=""; PROBE_DURATION="0"
    PROBE_V0_CODEC=""; PROBE_V0_WIDTH="0"; PROBE_V0_HEIGHT="0"
    PROBE_V0_NB_FRAMES="0"; PROBE_V0_AVG_FRAME_RATE=""; PROBE_V0_COLOR_SPACE=""
    PROBE_FORMAT_BITRATE=""; PROBE_JSON=""; PROBE_STREAMS_TSV=""

    local json
    json=$(ffprobe -v error -show_format -show_streams -of json "$file" 2>/dev/null) || return 0
    [[ -z "$json" ]] && return 0
    PROBE_JSON="$json"

    local parsed
    parsed=$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
fmt = d.get("format", {}) or {}
streams = d.get("streams", []) or []
def g(o, k, default=""):
    v = o.get(k, default)
    return "" if v is None else str(v)
v0 = next((s for s in streams if s.get("codec_type") == "video"), {})
print("\t".join([
    g(fmt, "format_name"),
    g(fmt, "duration", "0"),
    g(v0, "codec_name"),
    g(v0, "width", "0"),
    g(v0, "height", "0"),
    g(v0, "nb_frames", "0"),
    g(v0, "avg_frame_rate"),
    g(v0, "color_space"),
    g(fmt, "bit_rate"),
]))
for s in streams:
    disp = s.get("disposition", {}) or {}
    tags = s.get("tags", {}) or {}
    print("\t".join([
        g(s, "index"), g(s, "codec_type"),
        str(disp.get("attached_pic", 0)),
        (tags.get("language", "") or ""),
        g(s, "channels"), g(s, "bit_rate"),
    ]))
') || return 0
    [[ -z "$parsed" ]] && return 0

    # First line = scalars; remaining lines = per-stream TSV.
    local first_line
    IFS= read -r first_line <<< "$parsed"
    IFS=$'\t' read -r PROBE_FORMAT_NAME PROBE_DURATION PROBE_V0_CODEC \
        PROBE_V0_WIDTH PROBE_V0_HEIGHT PROBE_V0_NB_FRAMES \
        PROBE_V0_AVG_FRAME_RATE PROBE_V0_COLOR_SPACE PROBE_FORMAT_BITRATE <<< "$first_line"
    PROBE_STREAMS_TSV=$(printf '%s\n' "$parsed" | tail -n +2)
    return 0
}

is_av1() {
    probe_load "$1"
    [[ "$PROBE_V0_CODEC" == "av1" ]]
}

is_mpeg_ts() {
    probe_load "$1"
    [[ "$PROBE_FORMAT_NAME" == *mpegts* ]]
}

get_video_height() {
    probe_load "$1"
    local h="${PROBE_V0_HEIGHT//[!0-9]/}"
    echo "${h:-0}"
}

get_duration_secs() {
    probe_load "$1"
    local dur="${PROBE_DURATION%%,*}"
    dur="${dur//[!0-9.]/}"
    printf "%.0f" "${dur:-0}" 2>/dev/null || echo "0"
}

# Estimate the primary video stream's total frame count (duration * fps).
# Used to drive the progress bar in stream-copy mode (out_time reports N/A).
get_total_frames() {
    probe_load "$1"
    local duration="${2:-0}"
    # Prefer the container's frame count tag when present (exact, no math)
    local nb="${PROBE_V0_NB_FRAMES//[!0-9]/}"
    if [[ -n "$nb" && "$nb" -gt 0 ]]; then
        echo "$nb"
        return
    fi
    # Fall back to duration * average frame rate
    local rfr="${PROBE_V0_AVG_FRAME_RATE%%,*}"
    if [[ "$rfr" == */* && "$duration" -gt 0 ]]; then
        local num den
        num="${rfr%/*}"; den="${rfr#*/}"
        if [[ "$num" =~ ^[0-9]+$ && "$den" =~ ^[0-9]+$ && "$den" -gt 0 ]]; then
            echo $(( duration * num / den ))
            return
        fi
    fi
    echo "0"
}

# Determine opus bitrate based on channel layout
# Conservative bitrates — audio quality is prioritized over video savings
get_opus_bitrate() {
    local channels="$1"
    case "$channels" in
        1) echo "64k" ;;
        2) echo "128k" ;;
        6) echo "256k" ;;   # 5.1
        8) echo "320k" ;;   # 7.1
        *) echo "192k" ;;   # safe default
    esac
}

# Canonical channel layout for a channel count. libopus rejects non-standard
# layouts like "5.1(side)"; normalising to a standard layout (via aformat)
# fixes "Could not open encoder" while preserving all surround channels.
# Empty output = no normalisation needed (mono/stereo or unknown count).
opus_channel_layout() {
    case "$1" in
        6) echo "5.1" ;;
        8) echo "7.1" ;;
        *) echo "" ;;
    esac
}

get_file_size() {
    stat -c %s "$1" 2>/dev/null || echo "0"
}

# Print detailed info about a media file (reuses the per-file probe cache).
print_file_info() {
    local file="$1"
    probe_load "$file"
    local probe="$PROBE_JSON"
    [[ -z "$probe" ]] && return

    # Format info (from cached scalars)
    local dur_fmt=""
    if [[ "$PROBE_DURATION" != "0" && -n "$PROBE_DURATION" ]]; then
        local dur_int
        dur_int=$(printf "%.0f" "$PROBE_DURATION" 2>/dev/null || echo "0")
        dur_fmt=$(format_duration "$dur_int")
    fi
    local bitrate_fmt=""
    if [[ -n "$PROBE_FORMAT_BITRATE" && "$PROBE_FORMAT_BITRATE" != "N/A" && "$PROBE_FORMAT_BITRATE" =~ ^[0-9]+$ ]]; then
        bitrate_fmt="$(( PROBE_FORMAT_BITRATE / 1000 )) kb/s"
    fi

    echo -e "  ${GRAY}container: ${PROBE_FORMAT_NAME}  duration: ${dur_fmt}  bitrate: ${bitrate_fmt}${NC}"

    # Streams
    local stream_json
    stream_json=$(echo "$probe" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('streams', []):
    idx = s.get('index', '?')
    ct = s.get('codec_type', '?')
    cn = s.get('codec_name', '?')
    lang = s.get('tags', {}).get('language', '')
    title = s.get('tags', {}).get('title', '')
    extra = ''
    if ct == 'video':
        w = s.get('width', '?')
        h = s.get('height', '?')
        rfr = s.get('r_frame_rate', '')
        fps_str = ''
        if rfr and '/' in rfr:
            num, den = rfr.split('/')
            if int(den) > 0:
                fps_str = f' {int(num)/int(den):.2f}fps'
        extra = f'{w}x{h}{fps_str}'
    elif ct == 'audio':
        sr = s.get('sample_rate', '?')
        ch = s.get('channels', '?')
        br = s.get('bit_rate', '')
        br_str = f' {int(br)//1000}kb/s' if br and br != 'N/A' else ''
        extra = f'{ch}ch {sr}Hz{br_str}'
    elif ct == 'subtitle':
        extra = title if title else ''
    tag = f' [{lang}]' if lang else ''
    print(f'  #{idx} {ct}: {cn}{tag} {extra}')
" 2>/dev/null) || return

    echo -e "  ${GRAY}${stream_json}${NC}"
}

# Find adjacent subtitle files (.srt, .vtt) for a given video file
find_subtitle_files() {
    local input_file="$1"
    local input_dir input_noext
    input_dir=$(dirname "$input_file")
    input_noext="${input_file%.*}"

    local subs=()
    for ext in srt vtt; do
        # Exact match: video.srt
        if [[ -f "${input_noext}.${ext}" ]]; then
            subs+=("${input_noext}.${ext}")
        fi
        # Language-tagged: video.en.srt, video.fr.vtt, etc.
        for sub_file in "${input_noext}".*."${ext}"; do
            if [[ -f "$sub_file" ]]; then
                # Avoid duplicates
                local already=false
                for s in "${subs[@]+"${subs[@]}"}"; do
                    [[ "$s" == "$sub_file" ]] && already=true
                done
                $already || subs+=("$sub_file")
            fi
        done
    done

    printf '%s\n' "${subs[@]+"${subs[@]}"}"
}

# Find adjacent .txt description file for a given video file
find_description_file() {
    local input_file="$1"
    local input_noext="${input_file%.*}"

    if [[ -f "${input_noext}.txt" ]]; then
        echo "${input_noext}.txt"
    fi
}

# ==============================================================================
# Lock files
# ==============================================================================

acquire_lock() {
    local file="$1"
    local lock_file="${file}.lock"

    # Atomic lock creation using noclobber (set -C)
    if ! ( set -C; echo "pid=$$,start=$(date -Iseconds)" > "$lock_file" ) 2>/dev/null; then
        # Lock exists — check if owning PID is still alive
        local existing_pid
        existing_pid=$(grep -oP 'pid=\K[0-9]+' "$lock_file" 2>/dev/null || echo "")
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            warn "File locked by PID $existing_pid: $file"
            return 1
        fi
        # Stale lock — remove and retry once
        warn "Stale lock removed: $lock_file"
        rm -f "$lock_file"
        if ! ( set -C; echo "pid=$$,start=$(date -Iseconds)" > "$lock_file" ) 2>/dev/null; then
            warn "Failed to acquire lock (race): $file"
            return 1
        fi
    fi

    CURRENT_LOCK_FILE="$lock_file"
    return 0
}

release_lock() {
    local file="$1"
    local lock_file="${file}.lock"
    rm -f "$lock_file"
    if [[ "$CURRENT_LOCK_FILE" == "$lock_file" ]]; then
        CURRENT_LOCK_FILE=""
    fi
}

# ==============================================================================
# Cleanup (trap)
# ==============================================================================

# Recursively kill a process and all its descendants. Needed because the SSIM
# quality-check ffmpeg runs inside a command substitution, so it is a deep
# grandchild of $$ — pkill -P $$ (direct children only) would miss it, which is
# why Ctrl-C during the quality-check phase used to leave ffmpeg running.
kill_descendants() {
    local parent="$1" child
    for child in $(pgrep -P "$parent" 2>/dev/null); do
        kill_descendants "$child"
    done
    if [[ "$parent" != "$$" ]]; then
        kill -9 "$parent" 2>/dev/null || true
    fi
}

cleanup() {
    local exit_code=$?

    # Restore terminal settings (in case we were interrupted during conversion)
    { stty sane < /dev/tty; } 2>/dev/null || true

    # On interrupt, print a newline to clear the progress bar
    if [[ "$exit_code" -ne 0 ]]; then
        echo ""
        info "Interrupted — cleaning up..."
    fi

    # On abnormal exit (interrupt/error), kill the whole descendant tree — the
    # main ffmpeg, key reader, AND the SSIM ffmpeg which runs inside a command
    # substitution (a deep grandchild that pkill -P $$ would miss). Skipped on a
    # clean exit, where nothing is left running.
    if [[ "$exit_code" -ne 0 ]] && [[ -n "$(pgrep -P $$ 2>/dev/null)" ]]; then
        kill_descendants $$
        info "  Killed child processes"
        wait 2>/dev/null || true
    fi
    # Fallback: kill ffmpeg by PID file if still running
    local ffmpeg_pid_to_kill="$CURRENT_FFMPEG_PID"
    if [[ -z "$ffmpeg_pid_to_kill" ]]; then
        local pf
        for pf in "${TMPDIR:-/tmp}/convert-${$}-pid-"*; do
            [[ -f "$pf" ]] && ffmpeg_pid_to_kill=$(cat "$pf" 2>/dev/null || echo "") && break
        done
    fi
    if [[ -n "$ffmpeg_pid_to_kill" ]] && kill -0 "$ffmpeg_pid_to_kill" 2>/dev/null; then
        info "  Killing ffmpeg (PID $ffmpeg_pid_to_kill)"
        kill -9 "$ffmpeg_pid_to_kill" 2>/dev/null || true
    fi

    # Clean up this process's temp files (PID-namespaced)
    rm -f "${TMPDIR:-/tmp}/convert-${$}-"* 2>/dev/null || true

    # Remove temp file
    if [[ -n "$CURRENT_TEMP_FILE" && -f "$CURRENT_TEMP_FILE" ]]; then
        info "  Removing temp file: $CURRENT_TEMP_FILE"
        rm -f "$CURRENT_TEMP_FILE"
    fi

    # Remove stderr log
    if [[ -n "$CURRENT_STDERR_LOG" && -f "$CURRENT_STDERR_LOG" ]]; then
        info "  Removing stderr log: $CURRENT_STDERR_LOG"
        rm -f "$CURRENT_STDERR_LOG"
    fi

    # Release lock
    if [[ -n "$CURRENT_LOCK_FILE" && -f "$CURRENT_LOCK_FILE" ]]; then
        info "  Removing lock: $CURRENT_LOCK_FILE"
        rm -f "$CURRENT_LOCK_FILE"
    fi

    # Print summary if at least one file was processed
    if [[ $FILES_PROCESSED -gt 0 ]]; then
        echo ""
        print_summary
    fi

    exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# ==============================================================================
# Dependency check
# ==============================================================================

REQUIRED_DEPS=(ffmpeg ffprobe python3 numfmt stat mktemp bc)

check_dependencies() {
    local missing=()

    for dep in "${REQUIRED_DEPS[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}"
    fi

    debug "ffmpeg: $(ffmpeg -version | head -1)"
}

# Verbose dependency check for --check flag
check_dependencies_verbose() {
    local all_ok=true

    echo "convert-to-av1 v$VERSION — dependency check"
    echo ""

    for dep in "${REQUIRED_DEPS[@]}"; do
        local path version_info
        if path=$(command -v "$dep" 2>/dev/null); then
            version_info=""
            case "$dep" in
                ffmpeg)  version_info=$(ffmpeg -version 2>/dev/null | head -1) ;;
                ffprobe) version_info=$(ffprobe -version 2>/dev/null | head -1) ;;
                python3) version_info=$(python3 --version 2>/dev/null) ;;
                bc)      version_info=$(bc --version 2>/dev/null | head -1) ;;
            esac
            printf "  %-10s OK    %s" "$dep" "$path"
            [[ -n "$version_info" ]] && printf "  (%s)" "$version_info"
            printf "\n"
        else
            printf "  %-10s MISSING\n" "$dep"
            all_ok=false
        fi
    done

    # Check for SVT-AV1 encoder support in ffmpeg
    echo ""
    local encoders
    encoders=$(ffmpeg -encoders 2>/dev/null || true)
    if echo "$encoders" | grep -q libsvtav1; then
        echo "  libsvtav1  OK    (SVT-AV1 encoder available)"
    else
        echo "  libsvtav1  MISSING (ffmpeg was built without SVT-AV1 support)"
        all_ok=false
    fi

    echo ""
    if $all_ok; then
        echo "All dependencies satisfied."
    else
        echo "Some dependencies are missing. Install them before running conversions."
        exit 1
    fi
}

# ==============================================================================
# Usage
# ==============================================================================

usage() {
    cat <<'USAGE'
Usage: convert-to-av1 [options] FILES[...]

OUTPUT:
  -o, --output-dir DIR          Store converted files in DIR (auto-created)
  --in-place                    Convert and replace in-place (default if no -o)

FILE MANAGEMENT:
  --smart, --keep-best-version  rm-src + rm-if-bigger + quality-check + best version
  --rm-source, --rm-src         Remove source if output is smaller
  --rm-if-bigger                Remove output if larger than source
  -y, --overwrite               Overwrite existing output file

QUALITY:
  --max-res, --max-h HEIGHT     Scale down to HEIGHT px if source is taller
  --1080, --1080p               Alias for --max-res 1080
  --720, --720p                 Alias for --max-res 720
  --sd, --fast                  Fast encoding (preset 10, crf 32)
  --hq                          High quality (preset 4, crf 28, 10-bit, film-grain 8)
  --cartoon                     Optimised for animation (no grain, higher CRF)
  --tv                          Optimised for TV/broadcasts (moderate grain, higher CRF)
  --movie                       Optimised for cinema (preserve grain, lower CRF)
  --quality-check               SSIM check after conversion; reject if below threshold
  --min-ssim VALUE              Minimum SSIM score 0-1 (default: 0.92)
  --ssim-samples N              Evenly-spaced sample points for the check (default: 5)

BATCH:
  --sort-by-size [asc|desc]     Sort files by size before processing (default: desc)
  --dry-run                     Show what would be done without converting
  -r, --recursive               Recurse into subdirectories
  --min-size SIZE               Skip files smaller than SIZE (e.g., 100M, 1G)
  --exclude PATTERN             Exclude files matching glob PATTERN (repeatable)
  --skip-log[=FILE]             Log files not worth converting (low SSIM / output
                                larger) and skip them on re-runs. Default FILE:
                                .convert-skip.list at the input root
  --no-early-abort              Don't abort if output is estimated larger
  --early-abort-threshold PCT   Progress % at which to evaluate (default: 8)
  --after CMD                   Run CMD after the batch completes

AUDIO:
  --copy-audio                  Keep original audio (no re-encoding)
  --opus                        Re-encode audio to Opus (conservative bitrates)
  --auto-audio                  Re-encode to Opus only if source bitrate > threshold (default)
  --audio-threshold KB/S        Bitrate threshold for auto mode (default: 200)

TRACKS (keep only selected languages; default keeps all):
  --langs LIST                  Keep only these languages for audio AND subs (e.g. fr,en)
  --audio-langs LIST            Keep only these audio languages (e.g. fr,en)
  --sub-langs LIST              Keep only these subtitle languages (e.g. fr,en)
                                Untagged/undefined tracks are always kept.
  --copy-streams, --remux       Don't re-encode: just remux and keep selected
                                tracks (fast cleanup; pairs with --langs)

PROFILES:
  A '.convert-profile' file in a directory (or any parent) applies its flags
  to files under it — e.g. put '--movie' in a grainy-films folder, '--cartoon'
  in an animation folder. Resolved per file; one flag per line or space-separated;
  '#' starts a comment. Supports encoding/quality/audio/track flags.
  --no-profile                  Ignore all .convert-profile files

SUBTITLES:
  --no-merge-subs               Don't merge adjacent .srt/.vtt files into output

LOGGING:
  -l, --log FILE                Log conversion details to FILE
  -v, --verbose                 Verbose output
  --no-progress                 Disable progress bar

OTHER:
  --check                        Check dependencies and exit
  -h, --help                    Show this help
  --version                     Show version
USAGE
}

# ==============================================================================
# Argument parsing
# ==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output-dir)
                output_dir="$2"
                shift 2
                ;;
            --in-place)
                in_place=true
                shift
                ;;
            --smart|--keep-best-version)
                keep_best_version=true
                remove_source=true
                remove_if_bigger=true
                quality_check=true
                shift
                ;;
            --remove-source|--rm-source|--rm-src)
                remove_source=true
                shift
                ;;
            --remove-if-bigger|--rm-if-bigger)
                remove_if_bigger=true
                shift
                ;;
            --max-res|--max-h|--max-height)
                max_res="$2"
                shift 2
                ;;
            --1080|--1080p)
                max_res="1080"
                shift
                ;;
            --720|--720p)
                max_res="720"
                shift
                ;;
            --sd|--fast)
                svt_preset=10; svt_crf=32; svt_film_grain=0
                speed_preset="fast"
                shift
                ;;
            --hq)
                svt_preset=4; svt_crf=28; svt_film_grain=8
                speed_preset="hq"
                [[ "$audio_mode" == "auto" ]] && audio_mode="copy"
                shift
                ;;
            --cartoon)
                content_type="cartoon"
                shift
                ;;
            --tv)
                content_type="tv"
                shift
                ;;
            --movie)
                content_type="movie"
                shift
                ;;
            --quality-check)
                quality_check=true
                shift
                ;;
            --min-ssim)
                quality_check=true
                quality_min_ssim="$2"
                shift 2
                ;;
            --ssim-samples)
                quality_check=true
                quality_samples="$2"
                shift 2
                ;;
            -y|--overwrite)
                overwrite="-y"
                shift
                ;;
            --sort-by-size)
                if [[ "${2:-}" == "asc" || "${2:-}" == "desc" ]]; then
                    sort_by_size="$2"
                    shift 2
                else
                    sort_by_size="desc"
                    shift
                fi
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            -r|--recursive)
                recursive=true
                shift
                ;;
            --min-size)
                min_size=$(parse_size "$2")
                shift 2
                ;;
            --exclude)
                exclude_patterns+=("$2")
                shift 2
                ;;
            --skip-log)
                skip_log_enabled=true
                shift
                ;;
            --skip-log=*)
                skip_log_enabled=true
                skip_log_file="${1#*=}"
                shift
                ;;
            --after)
                after_cmd="$2"
                shift 2
                ;;
            --no-early-abort)
                early_abort=false
                shift
                ;;
            --early-abort-threshold)
                early_abort_threshold="$2"
                shift 2
                ;;
            --copy-audio)
                audio_mode="copy"
                shift
                ;;
            --opus)
                audio_mode="opus"
                shift
                ;;
            --auto-audio)
                audio_mode="auto"
                shift
                ;;
            --audio-threshold)
                audio_bitrate_threshold="$2"
                audio_mode="auto"
                shift 2
                ;;
            --no-merge-subs)
                merge_subs=false
                shift
                ;;
            --langs|--lang)
                # Shortcut: apply to both audio and subtitles (unless already set)
                [[ -z "$audio_langs" ]] && audio_langs="$2"
                [[ -z "$sub_langs" ]] && sub_langs="$2"
                shift 2
                ;;
            --audio-langs|--audio-lang)
                audio_langs="$2"
                shift 2
                ;;
            --sub-langs|--sub-lang)
                sub_langs="$2"
                shift 2
                ;;
            --copy-streams|--remux)
                copy_streams=true
                shift
                ;;
            --no-profile)
                use_profiles=false
                shift
                ;;
            -l|--log)
                log_file="$2"
                shift 2
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            --no-progress)
                no_progress=true
                shift
                ;;
            --check)
                check_dependencies_verbose
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                echo "convert-to-av1 v$VERSION"
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                input_args+=("$1")
                shift
                ;;
        esac
    done

    # Validation
    if [[ -n "$output_dir" && "$in_place" == true ]]; then
        die "--in-place and --output-dir are mutually exclusive"
    fi

    # Default mode: in-place when no -o
    if [[ -z "$output_dir" ]]; then
        in_place=true
    fi

    if [[ ${#input_args[@]} -eq 0 ]]; then
        usage
        exit 1
    fi

    # Create output directory if needed
    if [[ -n "$output_dir" ]]; then
        mkdir -p "$output_dir"
    fi

    # Resolve the default skip-log location: .convert-skip.list at the root of
    # the first input (the -r directory), unless an explicit path was given.
    if $skip_log_enabled && [[ -z "$skip_log_file" ]]; then
        local root="${input_args[0]}"
        if [[ -d "$root" ]]; then
            skip_log_file="${root%/}/.convert-skip.list"
        else
            skip_log_file="$(dirname "$root")/.convert-skip.list"
        fi
    fi
}

# ==============================================================================
# File collection and sorting
# ==============================================================================

collect_and_sort_files() {
    local -n _result=$1
    local video_extensions="mp4|mkv|avi|mov|wmv|flv|ts|m2ts|mts|m4v|webm|mpg|mpeg"
    local collected=()

    for arg in "${input_args[@]}"; do
        if [[ -d "$arg" ]]; then
            local -a find_opts=("$arg")
            $recursive || find_opts+=(-maxdepth 1)
            find_opts+=(-type f -regextype posix-extended
                -iregex ".*\\.($video_extensions)" -print0)
            while IFS= read -r -d '' f; do
                collected+=("$f")
            done < <(find "${find_opts[@]}" 2>/dev/null)
        elif [[ -f "$arg" ]]; then
            collected+=("$arg")
        else
            warn "Not found: $arg"
            add_result "$arg" "NOTFOUND" 0 0 ""
        fi
    done

    # Apply filters (min-size, exclude patterns)
    local filtered=()
    for f in "${collected[@]}"; do
        if is_excluded "$f"; then
            debug "Excluded by pattern: $f"
            add_result "$f" "SKIPPED" 0 0 "excluded"
            continue
        fi
        if is_skip_logged "$f"; then
            debug "In skip-log (previously not worth converting): $f"
            add_result "$f" "SKIPPED" "$(get_file_size "$f")" 0 "in skip-log"
            continue
        fi
        if [[ "$min_size" -gt 0 ]]; then
            local fsz
            fsz=$(get_file_size "$f")
            if [[ "$fsz" -lt "$min_size" ]]; then
                debug "Skipped (too small: $(human_size "$fsz") < $(human_size "$min_size")): $f"
                add_result "$f" "SKIPPED" "$fsz" 0 "below min-size"
                continue
            fi
        fi
        filtered+=("$f")
    done
    collected=("${filtered[@]+"${filtered[@]}"}")

    # Sort by size if requested
    if [[ -n "$sort_by_size" && ${#collected[@]} -gt 0 ]]; then
        local sort_flag="-n"
        [[ "$sort_by_size" == "desc" ]] && sort_flag="-rn"

        local sized_list=""
        for f in "${collected[@]}"; do
            local sz
            sz=$(get_file_size "$f")
            sized_list+="${sz} ${f}"$'\n'
        done

        _result=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _result+=("${line#* }")
        done < <(echo -n "$sized_list" | sort "$sort_flag")
    else
        _result=("${collected[@]}")
    fi
}

# ==============================================================================
# Output path resolution
# ==============================================================================

# Return variables (avoids subshells)
RESOLVED_FINAL=""
RESOLVED_TEMP=""
RESOLVED_IS_TEMP=false

resolve_output_path() {
    local input_file="$1"
    local input_dir input_basename input_noext

    input_dir=$(dirname "$input_file")
    input_basename=$(basename "$input_file")
    input_noext="${input_basename%.*}"

    if $in_place; then
        RESOLVED_FINAL="${input_dir}/${input_noext}.mkv"
    else
        RESOLVED_FINAL="${output_dir}/${input_noext}.mkv"
    fi

    # Always use a temp file for atomicity — write to temp, then mv on success.
    # Temp is created in the same dir as final output (same filesystem for atomic mv).
    local temp_dir
    if $in_place; then
        temp_dir="$input_dir"
    else
        temp_dir="$output_dir"
    fi
    RESOLVED_TEMP=$(mktemp "${temp_dir}/.convert-XXXXXX.mkv")
    RESOLVED_IS_TEMP=true
}

# ==============================================================================
# Track selection (mapping + language filtering)
# ==============================================================================

# Populated by compute_track_selection()
TRACKSEL_MAP_ARGS=()
TRACKSEL_COVER_POS=()   # output video-stream positions to copy verbatim (cover art)
TRACKSEL_AUDIO_IDX=()   # input indices of kept audio streams, in output order
declare -A TRACKSEL_AUDIO_CH=()   # input index -> channel count
declare -A TRACKSEL_AUDIO_BR=()   # input index -> bitrate (bit/s)
TRACKSEL_A_TOTAL=0
TRACKSEL_A_KEPT=0
TRACKSEL_S_TOTAL=0
TRACKSEL_S_KEPT=0
TRACKSEL_AUDIO_FALLBACK=false

# Decide which streams to map and which video streams are attached_pic covers.
# Without a language filter, keeps everything (-map 0). With a filter, builds
# explicit maps that preserve video/attachments/data and keep only the audio
# and subtitle tracks whose language matches (undefined/und always kept).
compute_track_selection() {
    local input="$1"

    TRACKSEL_MAP_ARGS=()
    TRACKSEL_COVER_POS=()
    TRACKSEL_AUDIO_IDX=()
    TRACKSEL_AUDIO_CH=()
    TRACKSEL_AUDIO_BR=()
    TRACKSEL_A_TOTAL=0 TRACKSEL_A_KEPT=0 TRACKSEL_S_TOTAL=0 TRACKSEL_S_KEPT=0
    TRACKSEL_AUDIO_FALLBACK=false

    local filtering=false
    [[ -n "$audio_langs" || -n "$sub_langs" ]] && filtering=true

    # Single cached probe drives both track selection and per-audio channels/
    # bitrate (TSV columns: index, type, attached_pic, lang, channels, bit_rate).
    probe_load "$input"

    local -a kept_audio=() kept_sub=() all_audio=()
    local vpos=0
    local idx ctype lang ach abr
    while IFS=$'\t' read -r idx ctype _ lang ach abr; do
        [[ -z "$idx" ]] && continue
        case "$ctype" in
            video)
                # Only the first video stream is the feature; any additional
                # video stream is a cover/thumbnail (attached_pic often, but not
                # always, flagged) — copy it rather than feed it to SVT-AV1.
                [[ "$vpos" -ge 1 ]] && TRACKSEL_COVER_POS+=("$vpos")
                vpos=$((vpos + 1))
                ;;
            audio)
                TRACKSEL_A_TOTAL=$((TRACKSEL_A_TOTAL + 1))
                all_audio+=("$idx")
                if [[ -z "$audio_langs" ]] || lang_matches "$lang" "$audio_langs"; then
                    kept_audio+=("$idx")
                    TRACKSEL_A_KEPT=$((TRACKSEL_A_KEPT + 1))
                fi
                # Per-stream channels/bitrate (bit_rate may be absent -> 0).
                [[ "$ach" =~ ^[0-9]+$ ]] || ach=2
                abr="${abr//[!0-9]/}"
                TRACKSEL_AUDIO_CH[$idx]="$ach"
                TRACKSEL_AUDIO_BR[$idx]="${abr:-0}"
                ;;
            subtitle)
                TRACKSEL_S_TOTAL=$((TRACKSEL_S_TOTAL + 1))
                if [[ -z "$sub_langs" ]] || lang_matches "$lang" "$sub_langs"; then
                    kept_sub+=("$idx")
                    TRACKSEL_S_KEPT=$((TRACKSEL_S_KEPT + 1))
                fi
                ;;
        esac
    done <<< "$PROBE_STREAMS_TSV"

    if ! $filtering; then
        TRACKSEL_MAP_ARGS=(-map 0)
        TRACKSEL_AUDIO_IDX=("${all_audio[@]+"${all_audio[@]}"}")
        return
    fi

    # Explicit mapping: keep all video (main + covers), attachments and data.
    TRACKSEL_MAP_ARGS=(-map 0:v)

    # Audio
    if [[ -n "$audio_langs" ]]; then
        if [[ "$TRACKSEL_A_TOTAL" -gt 0 && "$TRACKSEL_A_KEPT" -eq 0 ]]; then
            # Safety net: never produce a file with no audio
            TRACKSEL_AUDIO_FALLBACK=true
            TRACKSEL_A_KEPT="$TRACKSEL_A_TOTAL"
            TRACKSEL_MAP_ARGS+=(-map "0:a?")
            TRACKSEL_AUDIO_IDX=("${all_audio[@]+"${all_audio[@]}"}")
        else
            local i
            for i in "${kept_audio[@]+"${kept_audio[@]}"}"; do
                TRACKSEL_MAP_ARGS+=(-map "0:$i")
            done
            TRACKSEL_AUDIO_IDX=("${kept_audio[@]+"${kept_audio[@]}"}")
        fi
    else
        TRACKSEL_MAP_ARGS+=(-map "0:a?")
        TRACKSEL_AUDIO_IDX=("${all_audio[@]+"${all_audio[@]}"}")
    fi

    # Subtitles
    if [[ -n "$sub_langs" ]]; then
        local i
        for i in "${kept_sub[@]+"${kept_sub[@]}"}"; do
            TRACKSEL_MAP_ARGS+=(-map "0:$i")
        done
    else
        TRACKSEL_MAP_ARGS+=(-map "0:s?")
    fi

    # Keep attachments (subtitle fonts) and data streams
    TRACKSEL_MAP_ARGS+=(-map "0:t?" -map "0:d?")
}

# ==============================================================================
# Build ffmpeg command
# ==============================================================================

build_ffmpeg_cmd() {
    local input="$1"
    local output="$2"
    local -n _cmd=$3

    _cmd=(ffmpeg -hide_banner)

    # MPEG-TS: fix timestamps and tolerate corrupt packets
    if is_mpeg_ts "$input"; then
        _cmd+=(-fflags +genpts+igndts+discardcorrupt -avoid_negative_ts make_zero -err_detect ignore_err)
        debug "MPEG-TS detected, applying timestamp fix flags"
    fi

    _cmd+=(-i "$input")

    # Merge adjacent subtitle files
    if $merge_subs; then
        local sub_files
        sub_files=$(find_subtitle_files "$input")
        local sub_count=0
        while IFS= read -r sub_file; do
            [[ -z "$sub_file" ]] && continue
            _cmd+=(-i "$sub_file")
            sub_count=$((sub_count + 1))
            debug "Merging subtitle: $sub_file"
        done <<< "$sub_files"
    fi

    # Always overwrite at ffmpeg level — the script handles output-exists logic
    # at a higher level. The temp file from mktemp must be overwritable.
    _cmd+=(-y)

    # Mapping: compute which streams to keep (all by default; filtered by
    # language when --langs/--audio-langs/--sub-langs is set). Also identifies
    # attached_pic cover streams so they are copied instead of re-encoded.
    compute_track_selection "$input"
    if $TRACKSEL_AUDIO_FALLBACK; then
        warn "No audio track matched languages [${audio_langs}] — keeping all audio: $(basename "$input")"
    fi
    _cmd+=("${TRACKSEL_MAP_ARGS[@]}" -map_metadata 0 -map_chapters 0)

    # Map subtitle inputs
    if $merge_subs && [[ "${sub_count:-0}" -gt 0 ]]; then
        for ((si = 1; si <= sub_count; si++)); do
            _cmd+=(-map "$si")
        done
    fi

    # Embed description from adjacent .txt file
    local desc_file
    desc_file=$(find_description_file "$input")
    if [[ -n "$desc_file" ]]; then
        local desc_content
        desc_content=$(cat "$desc_file")
        _cmd+=(-metadata "description=${desc_content}")
        debug "Embedding description from: $desc_file"
    fi

    # Remux-only mode: copy every stream verbatim (just strip unwanted tracks).
    if $copy_streams; then
        [[ -n "$max_res" ]] && warn "--copy-streams ignores --max-res (no video re-encode)"
        _cmd+=(-c copy)
        info "  Remux only: copying all kept streams (no re-encode)"
        _cmd+=(-max_muxing_queue_size 4096 -progress pipe:1 -nostats "$output")
        return
    fi

    # Fix invalid color metadata that SVT-AV1 rejects
    probe_load "$input"
    local color_matrix="${PROBE_V0_COLOR_SPACE%%,*}"
    if [[ -z "$color_matrix" || "$color_matrix" == "unknown" || "$color_matrix" == "reserved" || "$color_matrix" == "gbr" ]]; then
        _cmd+=(-colorspace bt709 -color_primaries bt709 -color_trc bt709)
        debug "Fixing invalid/missing color metadata -> BT.709"
    fi

    # Video codec — encode the main video stream to AV1; copy any attached_pic
    # cover streams verbatim (SVT-AV1 cannot encode a single-frame cover).
    local -a svt_opts
    read -ra svt_opts <<< "$svtav1_options"
    _cmd+=(-c:v libsvtav1 "${svt_opts[@]}" -b:v 0)
    local cpos
    for cpos in "${TRACKSEL_COVER_POS[@]+"${TRACKSEL_COVER_POS[@]}"}"; do
        _cmd+=(-c:v:"$cpos" copy)
        debug "Copying cover art (output video stream $cpos) instead of encoding"
    done

    # Scaling — only the main video stream (v:0), never the cover art
    if [[ -n "$max_res" ]]; then
        local height
        height=$(get_video_height "$input")
        if [[ "$height" -gt "$max_res" ]]; then
            _cmd+=(-filter:v:0 "scale=-2:${max_res}")
            info "  Scaling: ${height}p -> ${max_res}p"
        fi
    fi

    # Audio codec — decided per stream so multichannel layouts (5.1/7.1) keep
    # their native channel count. No -ac is set, so libopus never downmixes.
    local aj=0 opus_count=0 copy_count=0
    local a_idx a_ch a_br a_kbps this_opus opus_br
    for a_idx in "${TRACKSEL_AUDIO_IDX[@]+"${TRACKSEL_AUDIO_IDX[@]}"}"; do
        a_ch="${TRACKSEL_AUDIO_CH[$a_idx]:-2}"
        a_br="${TRACKSEL_AUDIO_BR[$a_idx]:-0}"
        a_kbps=$(( a_br / 1000 ))
        this_opus=false
        case "$audio_mode" in
            opus) this_opus=true ;;
            auto) [[ "$a_kbps" -gt "$audio_bitrate_threshold" ]] && this_opus=true ;;
        esac
        if $this_opus; then
            opus_br=$(get_opus_bitrate "$a_ch")
            _cmd+=(-c:a:"$aj" libopus -b:a:"$aj" "$opus_br")
            # Normalise non-standard surround layouts (e.g. 5.1(side)) so libopus
            # accepts them; channel count is preserved (no downmix).
            local a_layout
            a_layout=$(opus_channel_layout "$a_ch")
            [[ -n "$a_layout" ]] && _cmd+=(-filter:a:"$aj" "aformat=channel_layouts=$a_layout")
            opus_count=$((opus_count + 1))
        else
            _cmd+=(-c:a:"$aj" copy)
            copy_count=$((copy_count + 1))
        fi
        aj=$((aj + 1))
    done
    if [[ "$opus_count" -gt 0 ]]; then
        info "  Audio: ${opus_count} track(s) -> Opus (native channels preserved), ${copy_count} copied"
    elif [[ "$aj" -gt 0 ]]; then
        info "  Audio: ${copy_count} track(s) copied as-is"
    fi

    # Copy other non-audio/video streams
    _cmd+=(-c:s copy)

    # Safety for problematic containers
    _cmd+=(-max_muxing_queue_size 4096)

    # Progress output
    _cmd+=(-progress pipe:1 -nostats)

    _cmd+=("$output")
}

# ==============================================================================
# Progress monitor + early abort
# ==============================================================================

run_progress_monitor() {
    local duration="$1"
    local start_time="$2"
    local temp_file="$3"
    local input_size="$4"
    local pid_file="${5:-}"
    local abort_signal="${6:-}"
    local total_frames="${7:-0}"
    local abort_checked=false

    local out_time_sec=0 fps_val=0 cur_frame=0

    if ! $no_progress; then
        printf "\r  [  0%%] [------------------------------] working..."
    fi

    while IFS='=' read -r key val; do
        case "$key" in
            out_time_us)
                [[ -n "$val" && "$val" != "N/A" ]] && out_time_sec=$((val / 1000000))
                ;;
            frame)
                [[ "$val" =~ ^[0-9]+$ ]] && cur_frame="$val"
                ;;
            fps)
                fps_val="${val:-0}"
                ;;
            progress)
                if [[ "$val" == "end" ]]; then
                    if ! $no_progress; then
                        printf "\r%-80s\r" " "
                    fi
                    info "  Conversion done."
                fi
                continue
                ;;
            *)
                continue
                ;;
        esac

        # Redraw on a timestamp update (encode) or a frame update (stream copy,
        # where ffmpeg reports out_time as N/A but still counts muxed frames).
        [[ "$key" != "out_time_us" && "$key" != "frame" ]] && continue

        # Current position in seconds: prefer real out_time; fall back to the
        # muxed-frame fraction of the total duration for stream-copy remux.
        local pos_sec=0
        if [[ "$out_time_sec" -gt 0 ]]; then
            pos_sec="$out_time_sec"
        elif [[ "$total_frames" -gt 0 && "$cur_frame" -gt 0 ]]; then
            pos_sec=$(( cur_frame * duration / total_frames ))
        fi
        [[ "$duration" -le 0 || "$pos_sec" -le 0 ]] && continue

        local now elapsed speed_x progress_pct
        now=$(date +%s)
        elapsed=$((now - start_time))
        [[ "$elapsed" -le 0 ]] && continue

        speed_x=$(echo "scale=2; $pos_sec / $elapsed" | bc -l 2>/dev/null || echo "0")
        # bc omits leading zero: .33 -> 0.33
        [[ "$speed_x" == .* ]] && speed_x="0${speed_x}"
        progress_pct=$(( (pos_sec * 100) / duration ))
        [[ "$progress_pct" -gt 100 ]] && progress_pct=100

        local eta_str="?"
        if [[ "$pos_sec" -gt 0 && "$elapsed" -gt 0 ]]; then
            local eta_secs
            eta_secs=$(echo "scale=0; ($duration - $pos_sec) * $elapsed / $pos_sec" | bc 2>/dev/null || echo "0")
            if [[ "$eta_secs" =~ ^[0-9]+$ ]]; then
                eta_str=$(format_duration "$eta_secs")
            fi
        fi

        # -- Early abort check (at threshold, retries if temp file not yet written)
        # Gated on the real-timestamp progress only (never the frame-count
        # fallback), so the size estimate below is taken at a reliable point.
        local time_pct=0
        [[ "$out_time_sec" -gt 0 ]] && time_pct=$(( out_time_sec * 100 / duration ))
        if $early_abort && ! $abort_checked && \
           [[ "$time_pct" -ge "$early_abort_threshold" ]] && \
           ($remove_if_bigger || $keep_best_version); then

            local current_output_size estimated_final_size

            if [[ -f "$temp_file" ]]; then
                current_output_size=$(get_file_size "$temp_file")
                # Skip check if temp file is empty (ffmpeg hasn't flushed yet)
                if [[ "$current_output_size" -le 0 ]]; then
                    : # retry on next progress update
                elif [[ "$out_time_sec" -gt 0 ]]; then
                    # Early abort is an encode-only decision; base the size
                    # estimate on real timestamps, never the frame-count fallback.
                    abort_checked=true
                    estimated_final_size=$(( current_output_size * duration / out_time_sec ))
                    if [[ "$estimated_final_size" -ge "$input_size" ]]; then
                        if ! $no_progress; then
                            printf "\r%-80s\r" " "
                        fi
                        warn "Early abort: estimated output $(human_size "$estimated_final_size") >= input $(human_size "$input_size") (at ${progress_pct}%)"
                        # Signal abort to parent via file
                        [[ -n "$abort_signal" ]] && touch "$abort_signal"
                        # Kill ffmpeg directly
                        if [[ -n "$pid_file" && -f "$pid_file" ]]; then
                            local ffmpeg_pid
                            ffmpeg_pid=$(cat "$pid_file" 2>/dev/null || echo "")
                            if [[ -n "$ffmpeg_pid" ]]; then kill "$ffmpeg_pid" 2>/dev/null || true; fi
                        fi

                        return 0
                    fi
                fi
            fi
        fi

        # -- Progress bar -----------------------------------------------------
        if ! $no_progress; then
            local filled empty bar current_time total_time
            filled=$(( progress_pct * 30 / 100 ))
            empty=$(( 30 - filled ))
            bar=$(printf "%${filled}s" | tr ' ' '#')$(printf "%${empty}s" | tr ' ' '-')

            current_time=$(format_duration "$pos_sec")
            total_time=$(format_duration "$duration")

            # Output bitrate and estimated gain from temp file size
            local extra_str=""
            if [[ -f "$temp_file" && "$pos_sec" -gt 0 ]]; then
                local cur_sz out_br_kbps
                cur_sz=$(stat -c %s "$temp_file" 2>/dev/null || echo 0)
                out_br_kbps=$(( cur_sz * 8 / pos_sec / 1000 ))
                extra_str=" | ${out_br_kbps}kb/s"
                if [[ "$input_size" -gt 0 ]]; then
                    local est_sz saving_pct cmp_color
                    est_sz=$(( cur_sz * duration / pos_sec ))
                    saving_pct=$(( (input_size - est_sz) * 100 / input_size ))
                    if [[ "$saving_pct" -ge 0 ]]; then
                        cmp_color="$GREEN"
                    else
                        cmp_color="$RED"
                    fi
                    extra_str+=" ${cmp_color}saved=${saving_pct}%${NC}"
                fi
            fi

            printf "\r  [%3d%%] [%s] %s/%s | fps: %s %.1fx | ETA: %s%b  " \
                "$progress_pct" "$bar" "$current_time" "$total_time" \
                "$fps_val" "$speed_x" "$eta_str" "$extra_str"
        fi

    done
}

# ==============================================================================
# Convert a single file
# ==============================================================================

convert_file() {
    local input_file="$1"

    FILES_PROCESSED=$((FILES_PROCESSED + 1))

    # -- Pre-checks ------------------------------------------------------------
    if [[ ! -f "$input_file" ]]; then
        warn "File not found: $input_file"
        add_result "$input_file" "NOTFOUND" 0 0 ""
        return 0
    fi

    local input_size
    input_size=$(get_file_size "$input_file")
    if [[ "$input_size" -eq 0 ]]; then
        warn "Empty file: $input_file"
        add_result "$input_file" "SKIPPED" 0 0 "empty file"
        return 0
    fi

    # Resolve this file's encoding config (CLI base + any .convert-profile).
    # Done before the AV1 skip so a profile can enable --copy-streams cleanup.
    resolve_file_profile "$input_file"

    # In remux mode we may want to clean an already-AV1 file, so don't skip it.
    if ! $copy_streams && is_av1 "$input_file"; then
        info "  Already AV1, skipping: $input_file"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "already AV1"
        return 0
    fi

    # -- Compute final output path (without creating temp files) ---------------
    local input_dir_r input_basename_r input_noext_r final_output
    input_dir_r=$(dirname "$input_file")
    input_basename_r=$(basename "$input_file")
    input_noext_r="${input_basename_r%.*}"
    if $in_place; then
        final_output="${input_dir_r}/${input_noext_r}.mkv"
    else
        final_output="${output_dir}/${input_noext_r}.mkv"
    fi

    # -- Dry run ---------------------------------------------------------------
    if $dry_run; then
        local codec_info="" res_info="" ts_info="" scale_info="" sub_info=""
        probe_load "$input_file"
        codec_info="${PROBE_V0_CODEC:-?}"
        local w h
        w="${PROBE_V0_WIDTH%%,*}"
        h=$(get_video_height "$input_file")
        [[ -n "$w" && -n "$h" && "$w" != "0" ]] && res_info=" ${w}x${h}"
        is_mpeg_ts "$input_file" && ts_info=" [MPEG-TS fix]"
        if [[ -n "$max_res" ]]; then
            [[ "$h" -gt "$max_res" ]] && scale_info=" [scale: ${h}p->${max_res}p]"
        fi
        if $merge_subs; then
            local subs
            subs=$(find_subtitle_files "$input_file")
            [[ -n "$subs" ]] && sub_info=" [+subs]"
        fi
        local track_info=""
        if [[ -n "$audio_langs" || -n "$sub_langs" ]]; then
            compute_track_selection "$input_file"
            local fb=""
            $TRACKSEL_AUDIO_FALLBACK && fb="!"
            track_info=" [audio ${TRACKSEL_A_KEPT}${fb}/${TRACKSEL_A_TOTAL}, subs ${TRACKSEL_S_KEPT}/${TRACKSEL_S_TOTAL}]"
        fi
        $copy_streams && track_info+=" [remux]"
        [[ -n "$CURRENT_PROFILE_FILE" ]] && track_info+=" [profile: ${CURRENT_PROFILE_TOKENS}]"
        printf "  %-50s %8s  %-4s%s%s%s%s%s -> %s\n" \
            "$input_file" "$(human_size "$input_size")" "$codec_info" \
            "$res_info" "$ts_info" "$scale_info" "$sub_info" "$track_info" "$final_output"
        add_result "$input_file" "DRYRUN" "$input_size" 0 ""
        return 0
    fi

    # Note: no overwrite check here — is_av1() already skips AV1 files,
    # and in-place mode uses temp files for safe atomic replacement.

    # -- Lock ------------------------------------------------------------------
    if ! acquire_lock "$input_file"; then
        add_result "$input_file" "LOCKED" "$input_size" 0 "locked"
        return 0
    fi

    # -- Header ----------------------------------------------------------------
    local batch_info=""
    if [[ "$FILES_TOTAL" -gt 1 ]]; then
        batch_info="[${FILES_PROCESSED}/${FILES_TOTAL}] "
        if [[ "$BATCH_SAVED_BYTES" -ne 0 ]]; then
            batch_info+="(batch saved: $(human_size "$BATCH_SAVED_BYTES")) "
        fi
    fi
    echo ""
    echo -e "${BOLD}${batch_info}<- SOURCE ($(human_size "$input_size")): '${input_file}'${NC}"
    echo -e "${BOLD}-> TARGET: '${final_output}'${NC}"
    if [[ -n "$CURRENT_PROFILE_FILE" ]]; then
        echo -e "  ${ORANGE}profile: ${CURRENT_PROFILE_TOKENS} (from $(basename "$(dirname "$CURRENT_PROFILE_FILE")")/.convert-profile)${NC}"
    fi
    print_file_info "$input_file"
    if $merge_subs; then
        local ext_subs
        ext_subs=$(find_subtitle_files "$input_file")
        if [[ -n "$ext_subs" ]]; then
            while IFS= read -r sf; do
                [[ -z "$sf" ]] && continue
                echo -e "  ${GRAY}+sub: $(basename "$sf")${NC}"
            done <<< "$ext_subs"
        fi
    fi
    local ext_desc
    ext_desc=$(find_description_file "$input_file")
    [[ -n "$ext_desc" ]] && echo -e "  ${GRAY}+desc: $(basename "$ext_desc")${NC}"

    # -- Resolve output path (creates temp files for atomicity) ----------------
    resolve_output_path "$input_file"
    final_output="$RESOLVED_FINAL"
    local temp_output="$RESOLVED_TEMP"
    local is_temp="$RESOLVED_IS_TEMP"

    # -- Build ffmpeg command --------------------------------------------------
    local -a cmd
    build_ffmpeg_cmd "$input_file" "$temp_output" cmd

    debug "CMD: ${cmd[*]}"

    # -- Save source timestamps before conversion (for in-place where mv overwrites) --
    local ts_ref=""
    ts_ref=$(mktemp "${TMPDIR:-/tmp}/convert-${$}-tsref-XXXXXX") || true
    touch -r "$input_file" "$ts_ref" 2>/dev/null || true

    # -- Run conversion --------------------------------------------------------
    local duration
    duration=$(get_duration_secs "$input_file")
    # Estimate total video frames (duration * fps) — used for the progress bar
    # in stream-copy mode, where ffmpeg reports out_time as N/A.
    local total_frames
    total_frames=$(get_total_frames "$input_file" "$duration")
    local start_time
    start_time=$(date +%s)

    CURRENT_TEMP_FILE="$temp_output"
    EARLY_ABORTED=false
    SKIP_REQUESTED=false

    local stderr_log=""
    stderr_log=$(mktemp "${TMPDIR:-/tmp}/convert-${$}-stderr-XXXXXX.log") || true
    CURRENT_STDERR_LOG="$stderr_log"

    # Run ffmpeg piped to progress monitor.
    # Use temp files for PID tracking and abort/skip signaling (subshell can't set parent vars).
    local pid_file="" abort_signal="" skip_signal=""
    pid_file=$(mktemp "${TMPDIR:-/tmp}/convert-${$}-pid-XXXXXX") || true
    abort_signal=$(mktemp -u "${TMPDIR:-/tmp}/convert-${$}-abort-XXXXXX")
    skip_signal=$(mktemp -u "${TMPDIR:-/tmp}/convert-${$}-skip-XXXXXX")

    # Start background key reader for skip support (main shell, not in pipe subshell)
    local key_reader_pid=""
    if [[ -t 2 ]] && ! $no_progress; then
        local tty_saved
        tty_saved=$(stty -g < /dev/tty 2>/dev/null || true)
        stty -icanon -echo < /dev/tty 2>/dev/null || true
        (
            trap 'exit 0' TERM
            while true; do
                local ch=""
                if IFS= read -rsn1 ch < /dev/tty 2>/dev/null; then
                    if [[ "$ch" == ">" ]]; then
                        touch "$skip_signal"
                        # Kill ffmpeg
                        local fpid
                        fpid=$(cat "$pid_file" 2>/dev/null || echo "")
                        if [[ -n "$fpid" ]]; then kill "$fpid" 2>/dev/null || true; fi
                        exit 0
                    fi
                fi
            done
        ) &
        key_reader_pid=$!
    fi

    local ffmpeg_exit=0
    { "${cmd[@]}" 2>"$stderr_log" & echo $! > "$pid_file"; wait $!; } \
        | run_progress_monitor "$duration" "$start_time" "$temp_output" "$input_size" "$pid_file" "$abort_signal" "$total_frames" \
        || ffmpeg_exit="${PIPESTATUS[0]}"

    # Stop key reader and restore terminal
    if [[ -n "$key_reader_pid" ]]; then
        kill "$key_reader_pid" 2>/dev/null || true
        wait "$key_reader_pid" 2>/dev/null || true
        stty "$tty_saved" < /dev/tty 2>/dev/null || true
    fi

    # Read ffmpeg PID from file (for cleanup trap)
    CURRENT_FFMPEG_PID=$(cat "$pid_file" 2>/dev/null || echo "")

    # Check if early abort or skip was signaled
    if [[ -f "$abort_signal" ]]; then
        EARLY_ABORTED=true
        rm -f "$abort_signal"
    fi
    if [[ -f "$skip_signal" ]]; then
        SKIP_REQUESTED=true
        rm -f "$skip_signal"
        if ! $no_progress; then
            printf "\r%-80s\r" " "
        fi
        info "  Skipped by user."
    fi
    rm -f "$pid_file"

    # Append stderr to user log file if defined
    if [[ -n "$log_file" && -f "$stderr_log" ]]; then
        {
            echo "=== $(date -Iseconds) | $input_file ==="
            cat "$stderr_log"
            echo ""
        } >> "$log_file"
    fi
    rm -f "$stderr_log"
    CURRENT_STDERR_LOG=""

    # -- Post-process ----------------------------------------------------------
    post_process "$input_file" "$final_output" "$temp_output" "$ffmpeg_exit" \
        "$is_temp" "$input_size" "$ts_ref"

    rm -f "$ts_ref"

    # -- Release lock ----------------------------------------------------------
    release_lock "$input_file"

    return 0
}

# ==============================================================================
# Quality check (SSIM sampling)
# ==============================================================================

# Compute SSIM between source and output using sampled segments.
# Samples 3 segments (10s each at 10%, 50%, 90% of the duration) for speed.
# Returns the mean SSIM on stdout, or "N/A" on failure.
compute_ssim_sampled() {
    local source="$1"
    local output="$2"

    local dur
    dur=$(get_duration_secs "$source")
    if [[ "$dur" -lt 10 ]]; then
        # Short file: compare the whole thing. Explicit [0:v:0][1:v:0] pads are
        # required — a bare "ssim" picks streams wrongly when a cover/attached_pic
        # second video stream is present (returns N/A otherwise).
        local result
        result=$(ffmpeg -hide_banner -i "$source" -i "$output" \
            -filter_complex "[0:v:0][1:v:0]ssim" -f null /dev/null 2>&1 \
            | grep -oP 'All:\K[0-9.]+' | tail -1) || true
        echo "${result:-N/A}"
        return
    fi

    # Sample at N evenly-spaced points spanning 10%..90% of the duration
    # (e.g. 3 -> 10/50/90%, 5 -> 10/30/50/70/90%). More points = more robust.
    local positions=()
    local n_samp="$quality_samples"
    [[ "$n_samp" -lt 1 ]] && n_samp=1
    if [[ "$n_samp" -eq 1 ]]; then
        positions+=( $(( dur * 50 / 100 )) )
    else
        local si pct
        for (( si = 0; si < n_samp; si++ )); do
            pct=$(( 10 + si * 80 / (n_samp - 1) ))
            positions+=( $(( dur * pct / 100 )) )
        done
    fi

    local total=0 count=0 i=0 n=${#positions[@]}
    for pos in "${positions[@]}"; do
        i=$((i + 1))
        # Feedback on stderr (stdout carries the score) — this phase decodes
        # both 1080p/4K streams and can run for a while with no other output.
        if ! $no_progress; then
            printf "\r  SSIM sampling %d/%d (@%s)...        " \
                "$i" "$n" "$(format_duration "$pos")" >&2
        fi
        local ssim_val
        ssim_val=$(ffmpeg -hide_banner \
            -ss "$pos" -t "$quality_sample_secs" -i "$source" \
            -ss "$pos" -t "$quality_sample_secs" -i "$output" \
            -filter_complex "[0:v:0][1:v:0]ssim" -f null /dev/null 2>&1 \
            | grep -oP 'All:\K[0-9.]+' | tail -1) || true
        if [[ -n "$ssim_val" && "$ssim_val" != "0" ]]; then
            total=$(echo "$total + $ssim_val" | bc -l)
            count=$((count + 1))
        fi
    done
    if ! $no_progress; then
        printf "\r%-60s\r" " " >&2
    fi

    if [[ "$count" -eq 0 ]]; then
        echo "N/A"
        return
    fi

    local mean
    mean=$(echo "scale=6; $total / $count" | bc -l)
    # bc omits leading zero
    [[ "$mean" == .* ]] && mean="0${mean}"
    echo "$mean"
}

# ==============================================================================
# Post-processing
# ==============================================================================

post_process() {
    local input_file="$1"
    local final_output="$2"
    local temp_output="$3"
    local ffmpeg_exit="$4"
    local is_temp="$5"
    local input_size="$6"
    local ts_ref="${7:-}"

    # Early abort case
    if $EARLY_ABORTED; then
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""

        if $keep_best_version && $in_place; then
            info "  Early abort: source kept as-is."
        elif $keep_best_version && [[ -n "$output_dir" ]]; then
            local dest_path
            dest_path="${output_dir}/$(basename "$input_file")"
            if [[ -f "$dest_path" ]]; then
                warn "Destination already exists, not overwriting: $dest_path"
            else
                info "  Early abort: copying source to output directory."
                cp -f "$input_file" "$dest_path"
            fi
        fi

        append_skip_log "$input_file" "$input_size" "early-abort: estimated output larger"
        add_result "$input_file" "ABORTED" "$input_size" 0 "estimated output larger"
        return 0
    fi

    # User skip case
    if $SKIP_REQUESTED; then
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "SKIPPED" "$input_size" 0 "skipped by user"
        return 0
    fi

    # ffmpeg error case
    if [[ "$ffmpeg_exit" -ne 0 ]]; then
        warn "Conversion failed (code $ffmpeg_exit): $input_file"
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "FAILED" "$input_size" 0 "ffmpeg exit $ffmpeg_exit"
        return 0
    fi

    # Validate the freshly written temp output before placing it at the
    # destination.
    local output_size=0
    [[ -f "$temp_output" ]] && output_size=$(get_file_size "$temp_output")

    if [[ "$output_size" -eq 0 ]]; then
        warn "Output file empty or missing: $final_output"
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "FAILED" "$input_size" 0 "empty output"
        return 0
    fi

    # A valid video file must be larger than just a container header.
    # MKV headers alone are ~200-350 bytes — treat anything under 1 KiB as corrupt.
    local min_output_size=1024
    if [[ "$output_size" -lt "$min_output_size" ]]; then
        warn "Output too small (${output_size} bytes), likely corrupt: $final_output"
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "FAILED" "$input_size" 0 "corrupt output (${output_size} bytes)"
        return 0
    fi

    # Quality check (SSIM sampling) — done on the temp before writing to the
    # destination, so a rejected encode never touches the (possibly slow) target.
    if $quality_check && [[ -f "$input_file" ]]; then
        info "  Quality check (SSIM sampling)..."
        local ssim_score
        ssim_score=$(compute_ssim_sampled "$input_file" "$temp_output")
        if [[ "$ssim_score" == "N/A" ]]; then
            warn "Quality check failed (could not compute SSIM): $final_output"
        else
            local ssim_ok
            ssim_ok=$(echo "$ssim_score >= $quality_min_ssim" | bc -l 2>/dev/null || echo "1")
            if [[ "$ssim_ok" -eq 0 ]]; then
                warn "Quality too low (SSIM=${ssim_score}, min=${quality_min_ssim}): $final_output"
                append_skip_log "$input_file" "$input_size" "SSIM ${ssim_score} < ${quality_min_ssim}"
                rm -f "$temp_output"
                CURRENT_TEMP_FILE=""
                add_result "$input_file" "FAILED" "$input_size" "$output_size" "SSIM ${ssim_score} < ${quality_min_ssim}"
                return 0
            fi
            info "  SSIM: ${ssim_score} (min: ${quality_min_ssim})"
        fi
    fi

    # Place the validated output at its final destination (atomic mv on the
    # same filesystem — the temp lives in the destination dir).
    if [[ "$is_temp" == true ]]; then
        mv -f "$temp_output" "$final_output"
    fi
    CURRENT_TEMP_FILE=""

    # Preserve source filesystem timestamps (mtime/atime)
    if [[ -n "$ts_ref" && -f "$ts_ref" ]]; then
        touch -r "$ts_ref" "$final_output" 2>/dev/null || true
    fi

    # Size saved
    local saved_pct=0 saved_bytes=0
    if [[ "$input_size" -gt 0 ]]; then
        saved_pct=$(( (input_size - output_size) * 100 / input_size ))
        saved_bytes=$(( input_size - output_size ))
    fi

    if [[ "$output_size" -gt "$input_size" ]]; then
        warn "Output larger: $(human_size "$output_size") vs $(human_size "$input_size") (saved=${saved_pct}%)"

        # Record when the output is rejected for being larger (re-encoding it
        # again is pointless). Logged before any source move so the path is right.
        if $keep_best_version || $remove_if_bigger; then
            append_skip_log "$input_file" "$input_size" "output larger than source"
        fi

        if $keep_best_version; then
            info "  Smart: output larger, removing it and keeping source."
            rm -f "$final_output"
            if [[ -n "$output_dir" ]]; then
                local dest_path
                dest_path="${output_dir}/$(basename "$input_file")"
                if [[ -f "$dest_path" ]]; then
                    warn "Destination already exists, not overwriting: $dest_path"
                else
                    mv -f "$input_file" "$dest_path"
                fi
            fi
            add_result "$input_file" "KEPT_SRC" "$input_size" "$output_size" "smart: source kept"
        elif $remove_if_bigger; then
            info "  Removing larger output."
            rm -f "$final_output"
            add_result "$input_file" "RM_OUT" "$input_size" "$output_size" "output removed"
        else
            add_result "$input_file" "OK" "$input_size" "$output_size" ""
        fi
    else
        info "  saved=$(human_size "$saved_bytes") (${saved_pct}%): $(human_size "$input_size") -> $(human_size "$output_size")"
        BATCH_SAVED_BYTES=$((BATCH_SAVED_BYTES + saved_bytes))

        if $remove_source; then
            if $in_place; then
                # In-place: remove original only if extension differs from .mkv
                local input_ext="${input_file##*.}"
                if [[ "${input_ext,,}" != "mkv" ]]; then
                    debug "  Removing source (different extension): $input_file"
                    rm -f "$input_file"
                fi
            else
                debug "  Removing source: $input_file"
                rm -f "$input_file"
            fi

            # Clean up merged subtitle and description files
            if $merge_subs; then
                local sub_files
                sub_files=$(find_subtitle_files "$input_file")
                while IFS= read -r sf; do
                    [[ -z "$sf" ]] && continue
                    debug "  Removing merged subtitle: $sf"
                    rm -f "$sf"
                done <<< "$sub_files"
            fi
            # Note: .txt description files are NOT removed (kept for reference)
        fi

        add_result "$input_file" "OK" "$input_size" "$output_size" "saved ${saved_pct}% ($(human_size "$saved_bytes"))"
    fi
}

# ==============================================================================
# Summary
# ==============================================================================

print_summary() {
    local count=${#SUMMARY_FILES[@]}
    [[ "$count" -eq 0 ]] && return

    echo ""
    printf "${BOLD}%-50s %-10s %10s %10s %8s  %s${NC}\n" \
        "File" "Status" "Input" "Output" "Saved" "Note"
    printf "%-50s %-10s %10s %10s %8s  %s\n" \
        "$(printf '%0.s-' {1..50})" "----------" "----------" "----------" "--------" "----"

    local total_input=0 total_output=0
    local count_ok=0 count_skip=0 count_fail=0 count_abort=0

    for ((i = 0; i < count; i++)); do
        local file status in_sz out_sz note
        file=$(basename "${SUMMARY_FILES[$i]}")
        status="${SUMMARY_STATUSES[$i]}"
        in_sz="${SUMMARY_INPUT_SIZES[$i]}"
        out_sz="${SUMMARY_OUTPUT_SIZES[$i]}"
        note="${SUMMARY_NOTES[$i]}"

        # Truncate filename if too long
        if [[ ${#file} -gt 48 ]]; then
            file="..${file: -46}"
        fi

        local in_h out_h gain_str color
        in_h=$(human_size "$in_sz")
        color="$NC"

        case "$status" in
            OK)
                out_h=$(human_size "$out_sz")
                if [[ "$in_sz" -gt 0 ]]; then
                    local saved_pct=$(( (in_sz - out_sz) * 100 / in_sz ))
                    gain_str="${saved_pct}%"
                else
                    gain_str="---"
                fi
                color="$GREEN"
                total_input=$((total_input + in_sz))
                total_output=$((total_output + out_sz))
                count_ok=$((count_ok + 1))
                ;;
            KEPT_SRC|RM_OUT)
                out_h="---"
                gain_str="---"
                color="$ORANGE"
                count_ok=$((count_ok + 1))
                ;;
            SKIPPED|DRYRUN|NOTFOUND|LOCKED)
                out_h="---"
                gain_str="---"
                color="$GRAY"
                count_skip=$((count_skip + 1))
                ;;
            ABORTED)
                out_h="---"
                gain_str="---"
                color="$ORANGE"
                count_abort=$((count_abort + 1))
                ;;
            FAILED)
                out_h="---"
                gain_str="---"
                color="$RED"
                count_fail=$((count_fail + 1))
                ;;
        esac

        printf "${color}%-50s %-10s %10s %10s %8s  %s${NC}\n" \
            "$file" "$status" "$in_h" "$out_h" "$gain_str" "$note"
    done

    # Totals
    echo ""
    if [[ "$total_input" -gt 0 ]]; then
        local total_saved=$(( (total_input - total_output) * 100 / total_input ))
        local total_saved_bytes=$(( total_input - total_output ))
        echo -e "${BOLD}Total: $(human_size "$total_input") -> $(human_size "$total_output") | saved=$(human_size "$total_saved_bytes") (${total_saved}%)${NC}"
    fi
    if [[ "$BATCH_START_TIME" -gt 0 ]]; then
        local batch_elapsed=$(( $(date +%s) - BATCH_START_TIME ))
        echo -e "${BOLD}OK: ${count_ok} | Skip: ${count_skip} | Abort: ${count_abort} | Fail: ${count_fail} | Total: ${count} | elapsed: $(format_duration "$batch_elapsed")${NC}"
    else
        echo -e "${BOLD}OK: ${count_ok} | Skip: ${count_skip} | Abort: ${count_abort} | Fail: ${count_fail} | Total: ${count}${NC}"
    fi
}

# ==============================================================================
# Config banner
# ==============================================================================

# Print a banner line: "  key ......... value"
banner_line() {
    local key="$1" value="$2" color="${3:-$NC}"
    local dots
    dots=$(printf '%*s' $(( 17 - ${#key} )) '' | tr ' ' '.')
    echo -e "  ${GRAY}${key} ${dots}${NC} ${color}${value}${NC}"
}

# Parse svtav1_options into a human-readable string
format_svtav1_options() {
    local parts=()

    parts+=("preset=${svt_preset}")
    parts+=("crf=${svt_crf}")
    [[ "$svt_pix_fmt" == *"10le" ]] && parts+=("10-bit")

    if [[ "$svt_film_grain" -eq 0 ]]; then
        parts+=("grain=off")
    else
        parts+=("grain=${svt_film_grain}")
    fi

    [[ "$svt_film_grain_denoise" -eq 1 ]] && parts+=("denoise")

    echo "SVT-AV1 ${parts[*]}"
}

print_banner() {
    local sep
    sep=$(printf '─%.0s' {1..48})

    echo -e "${GRAY}──${NC} ${BOLD}convert-to-av1 v${VERSION}${NC} ${GRAY}${sep:0:$((48 - 20 - ${#VERSION}))}${NC}"

    # Output mode
    if $in_place; then
        banner_line "output" "in-place"
    else
        banner_line "output" "$output_dir"
    fi

    # Encoder
    if $copy_streams; then
        banner_line "encoder" "remux only (no re-encode)" "$ORANGE"
    else
        banner_line "encoder" "$(format_svtav1_options)"
        [[ -n "$content_type" ]] && banner_line "content" "$content_type"
    fi

    # Audio
    if $copy_streams; then
        banner_line "audio" "copy"
    else
        case "$audio_mode" in
            opus) banner_line "audio" "Opus (always)" ;;
            auto) banner_line "audio" "Opus if > ${audio_bitrate_threshold} kb/s" ;;
            *)    banner_line "audio" "copy" ;;
        esac
    fi

    # Language filtering (conditional)
    if [[ -n "$audio_langs" || -n "$sub_langs" ]]; then
        banner_line "keep langs" "audio: ${audio_langs:-all} | subs: ${sub_langs:-all}" "$ORANGE"
    fi

    # Max height (conditional)
    [[ -n "$max_res" ]] && banner_line "max height" "${max_res}p" "$ORANGE"

    # Flags — destructive flags in red, others in orange
    local flags=()
    $keep_best_version && flags+=("smart")
    $remove_source && flags+=("${RED}rm-source${NC}")
    $remove_if_bigger && flags+=("${RED}rm-if-bigger${NC}")
    $recursive && flags+=("recursive")
    [[ -n "$overwrite" ]] && flags+=("${RED}overwrite${NC}")
    $dry_run && flags+=("dry-run")
    if [[ ${#flags[@]} -gt 0 ]]; then
        local flag_str
        flag_str=$(printf '%s, ' "${flags[@]}")
        banner_line "flags" "${flag_str%, }" "$ORANGE"
    fi

    # Early abort (conditional)
    if $early_abort && ($remove_if_bigger || $keep_best_version); then
        banner_line "early abort" "${early_abort_threshold}%"
    fi

    # Quality check (conditional)
    $quality_check && banner_line "quality check" "SSIM >= ${quality_min_ssim} (${quality_samples} samples)"

    # Subtitles (conditional — only shown if enabled)
    $merge_subs && banner_line "subtitles" "merge .srt/.vtt"

    # Per-directory profiles (shown unless disabled)
    $use_profiles && banner_line "profiles" ".convert-profile (per dir)"

    # Batch options (conditional)
    [[ -n "$sort_by_size" ]] && banner_line "sort" "$sort_by_size"
    [[ "$min_size" -gt 0 ]] && banner_line "min size" "$(human_size "$min_size")"
    [[ ${#exclude_patterns[@]} -gt 0 ]] && banner_line "exclude" "${exclude_patterns[*]}"
    $skip_log_enabled && banner_line "skip-log" "$skip_log_file"
    [[ -n "$after_cmd" ]] && banner_line "after" "$after_cmd"

    echo -e "${GRAY}${sep}${NC}"
    if [[ -t 2 ]] && ! $no_progress; then
        echo -e "${GRAY}  Press > to skip the current file${NC}"
    fi
}

# ==============================================================================
# Entry point
# ==============================================================================

main() {
    parse_args "$@"
    # Snapshot the CLI encoding config before deriving options, so per-file
    # .convert-profile resolution always starts from a clean base.
    snapshot_base_config
    apply_content_type
    build_svtav1_options
    check_dependencies
    $skip_log_enabled && load_skip_log

    local sorted_files=()
    collect_and_sort_files sorted_files

    if [[ ${#sorted_files[@]} -eq 0 ]]; then
        warn "No video files found."
        exit 0
    fi

    FILES_TOTAL=${#sorted_files[@]}
    BATCH_START_TIME=$(date +%s)

    print_banner

    for file in "${sorted_files[@]}"; do
        convert_file "$file" || true
    done

    # Run --after command if specified
    if [[ -n "$after_cmd" ]]; then
        info "Running --after command: $after_cmd"
        eval "$after_cmd" || warn "--after command failed (exit $?)"
    fi

    # Summary is printed by the EXIT trap via cleanup
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
