#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# convert-to-av1 v3.0.0 — Batch video conversion to AV1 (SVT-AV1 via ffmpeg)
# ==============================================================================

VERSION="3.0.0"

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
svtav1_options="-preset 6 -crf 30 -pix_fmt yuv420p10le -svtav1-params tune=0:film-grain=6:enable-overlays=1:scd=1"
log_file=""
verbose=false
dry_run=false
sort_by_size=""
no_progress=false
early_abort=true
early_abort_threshold=8
merge_subs=true
recursive=false
audio_mode="copy"  # copy, opus, auto
audio_bitrate_threshold=200  # kb/s — auto mode re-encodes above this
min_size=0  # bytes — skip files smaller than this
exclude_patterns=()
after_cmd=""

# -- Global state (for cleanup) ------------------------------------------------
CURRENT_TEMP_FILE=""
CURRENT_LOCK_FILE=""
CURRENT_STDERR_LOG=""
CURRENT_FFMPEG_PID=""
EARLY_ABORTED=false
SUMMARY_FILES=()
SUMMARY_STATUSES=()
SUMMARY_INPUT_SIZES=()
SUMMARY_OUTPUT_SIZES=()
SUMMARY_NOTES=()
FILES_PROCESSED=0
FILES_TOTAL=0
BATCH_SAVED_BYTES=0
BATCH_START_TIME=0

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
    num=$(echo "$input" | grep -oP '^[0-9]+(\.[0-9]+)?')
    unit=$(echo "$input" | grep -oP '[A-Za-z]+$')
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
# Probe functions (ffprobe)
# ==============================================================================

is_av1() {
    local codec
    codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name -of csv=p=0 "$1" 2>/dev/null | head -1) || return 1
    [[ "$codec" == "av1" ]]
}

is_mpeg_ts() {
    local fmt
    fmt=$(ffprobe -v error -show_entries format=format_name \
        -of csv=p=0 "$1" 2>/dev/null) || return 1
    [[ "$fmt" == *mpegts* ]]
}

get_video_height() {
    local h
    h=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=height -of csv=p=0 "$1" 2>/dev/null | head -1 || echo "0")
    # Strip commas, carriage returns, newlines, whitespace — keep only digits
    h=$(echo "$h" | tr -cd '0-9')
    echo "${h:-0}"
}

get_duration_secs() {
    local dur
    dur=$(ffprobe -v error -show_entries format=duration \
        -of csv=p=0 "$1" 2>/dev/null | head -1) || { echo "0"; return; }
    dur="${dur%%,*}"
    dur=$(echo "$dur" | tr -cd '0-9.')
    printf "%.0f" "${dur:-0}" 2>/dev/null || echo "0"
}

# Get audio bitrate in kb/s for the first audio stream
get_audio_bitrate_kbps() {
    local br
    br=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=bit_rate -of csv=p=0 "$1" 2>/dev/null | head -1)
    # Strip trailing commas, carriage returns, whitespace
    br="${br//$'\r'/}"
    br="${br%%,*}"
    br="${br// /}"
    if [[ -n "$br" && "$br" != "N/A" && "$br" =~ ^[0-9]+$ ]]; then
        echo $(( br / 1000 ))
    else
        echo "0"
    fi
}

# Get audio channel count
get_audio_channels() {
    local ch
    ch=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=channels -of csv=p=0 "$1" 2>/dev/null | head -1)
    ch="${ch//$'\r'/}"
    ch="${ch%%,*}"
    ch="${ch// /}"
    if [[ -n "$ch" && "$ch" =~ ^[0-9]+$ ]]; then
        echo "$ch"
    else
        echo "2"
    fi
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

get_file_size() {
    stat -c %s "$1" 2>/dev/null || echo "0"
}

# Print detailed info about a media file
print_file_info() {
    local file="$1"
    local probe
    probe=$(ffprobe -v error \
        -show_entries format=duration,bit_rate,format_name \
        -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,bit_rate,channels,sample_rate \
        -show_entries stream_tags=language,title \
        -of json "$file" 2>/dev/null) || return

    # Format info
    local fmt dur_s bitrate_s
    fmt=$(echo "$probe" | grep -oP '"format_name"\s*:\s*"\K[^"]+' | head -1)
    dur_s=$(echo "$probe" | grep -oP '"duration"\s*:\s*"\K[^"]+' | head -1)
    bitrate_s=$(echo "$probe" | grep -oP '"bit_rate"\s*:\s*"\K[^"]+' | tail -1)

    local dur_fmt=""
    if [[ -n "$dur_s" ]]; then
        local dur_int
        dur_int=$(printf "%.0f" "$dur_s" 2>/dev/null || echo "0")
        dur_fmt=$(format_duration "$dur_int")
    fi
    local bitrate_fmt=""
    if [[ -n "$bitrate_s" && "$bitrate_s" != "N/A" && "$bitrate_s" =~ ^[0-9]+$ ]]; then
        bitrate_fmt="$(( bitrate_s / 1000 )) kb/s"
    fi

    echo -e "  ${GRAY}container: ${fmt}  duration: ${dur_fmt}  bitrate: ${bitrate_fmt}${NC}"

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

cleanup() {
    local exit_code=$?

    # On interrupt, print a newline to clear the progress bar
    if [[ "$exit_code" -ne 0 ]]; then
        echo ""
        info "Interrupted — cleaning up..."
    fi

    # Kill ffmpeg if still running
    if [[ -n "$CURRENT_FFMPEG_PID" ]] && kill -0 "$CURRENT_FFMPEG_PID" 2>/dev/null; then
        info "  Killing ffmpeg (PID $CURRENT_FFMPEG_PID)"
        kill "$CURRENT_FFMPEG_PID" 2>/dev/null || true
        wait "$CURRENT_FFMPEG_PID" 2>/dev/null || true
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

check_dependencies() {
    local missing=()
    local deps=(ffmpeg ffprobe python3 numfmt stat mktemp bc)

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}"
    fi

    debug "ffmpeg: $(ffmpeg -version | head -1)"
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
  --smart, --keep-best-version  rm-src + rm-if-bigger + keep the best version
  --rm-source, --rm-src         Remove source if output is smaller
  --rm-if-bigger                Remove output if larger than source
  -y, --overwrite               Overwrite existing output file

QUALITY:
  --max-res, --max-h HEIGHT     Scale down to HEIGHT px if source is taller
  --1080, --1080p               Alias for --max-res 1080
  --720, --720p                 Alias for --max-res 720
  --sd, --fast                  Fast encoding (preset 10, crf 32, tune VQ)
  --hq                          High quality (preset 4, crf 28, 10-bit, film-grain 8)

BATCH:
  --sort-by-size [asc|desc]     Sort files by size before processing (default: desc)
  --dry-run                     Show what would be done without converting
  -r, --recursive               Recurse into subdirectories
  --min-size SIZE               Skip files smaller than SIZE (e.g., 100M, 1G)
  --exclude PATTERN             Exclude files matching glob PATTERN (repeatable)
  --no-early-abort              Don't abort if output is estimated larger
  --early-abort-threshold PCT   Progress % at which to evaluate (default: 8)
  --after CMD                   Run CMD after the batch completes

AUDIO:
  --opus                        Re-encode audio to Opus (conservative bitrates)
  --auto-audio                  Re-encode to Opus only if source bitrate > threshold
  --audio-threshold KB/S        Bitrate threshold for auto mode (default: 200)

SUBTITLES:
  --no-merge-subs               Don't merge adjacent .srt/.vtt files into output

LOGGING:
  -l, --log FILE                Log conversion details to FILE
  -v, --verbose                 Verbose output
  --no-progress                 Disable progress bar

OTHER:
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
                [[ "$audio_mode" == "copy" ]] && audio_mode="auto"
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
                svtav1_options="-preset 10 -crf 32 -svtav1-params tune=0"
                shift
                ;;
            --hq)
                svtav1_options="-preset 4 -crf 28 -pix_fmt yuv420p10le -svtav1-params tune=0:film-grain=8:enable-overlays=1:scd=1"
                shift
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
# Build ffmpeg command
# ==============================================================================

build_ffmpeg_cmd() {
    local input="$1"
    local output="$2"
    local -n _cmd=$3

    _cmd=(ffmpeg -hide_banner)

    # MPEG-TS: fix timestamps
    if is_mpeg_ts "$input"; then
        _cmd+=(-fflags +genpts+igndts -avoid_negative_ts make_zero)
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

    # Mapping: map all streams from the main input
    _cmd+=(-map 0 -map_metadata 0 -map_chapters 0)

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

    # Fix invalid color metadata that SVT-AV1 rejects
    local color_matrix
    color_matrix=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_space -of csv=p=0 "$input" 2>/dev/null | head -1)
    color_matrix="${color_matrix%%,*}"
    if [[ -z "$color_matrix" || "$color_matrix" == "unknown" || "$color_matrix" == "reserved" || "$color_matrix" == "gbr" ]]; then
        _cmd+=(-colorspace bt709 -color_primaries bt709 -color_trc bt709)
        debug "Fixing invalid/missing color metadata -> BT.709"
    fi

    # Video codec
    local -a svt_opts
    read -ra svt_opts <<< "$svtav1_options"
    _cmd+=(-c:v libsvtav1 "${svt_opts[@]}" -b:v 0)

    # Scaling
    if [[ -n "$max_res" ]]; then
        local height
        height=$(get_video_height "$input")
        if [[ "$height" -gt "$max_res" ]]; then
            _cmd+=(-vf "scale=-2:${max_res}")
            info "  Scaling: ${height}p -> ${max_res}p"
        fi
    fi

    # Audio codec
    local do_opus=false
    if [[ "$audio_mode" == "opus" ]]; then
        do_opus=true
    elif [[ "$audio_mode" == "auto" ]]; then
        local src_audio_br
        src_audio_br=$(get_audio_bitrate_kbps "$input")
        if [[ "$src_audio_br" -gt "$audio_bitrate_threshold" ]]; then
            do_opus=true
            debug "Audio bitrate ${src_audio_br} kb/s > threshold ${audio_bitrate_threshold} kb/s, re-encoding to Opus"
        else
            debug "Audio bitrate ${src_audio_br} kb/s <= threshold, copying as-is"
        fi
    fi

    if $do_opus; then
        local channels opus_br
        channels=$(get_audio_channels "$input")
        opus_br=$(get_opus_bitrate "$channels")
        _cmd+=(-c:a libopus -b:a "$opus_br" -ac "$channels")
        info "  Audio: re-encoding to Opus ${opus_br} (${channels}ch)"
    else
        _cmd+=(-c:a copy)
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
    local abort_checked=false

    local out_time_sec=0 fps_val=0

    if ! $no_progress; then
        printf "\r  [  0%%] [------------------------------] encoding..."
    fi

    while IFS='=' read -r key val; do
        case "$key" in
            out_time_us)
                [[ -z "$val" || "$val" == "N/A" ]] && continue
                out_time_sec=$((val / 1000000))
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

        # Only update display on out_time_us
        [[ "$key" != "out_time_us" ]] && continue
        [[ "$duration" -le 0 || "$out_time_sec" -le 0 ]] && continue

        local now elapsed speed_x progress_pct
        now=$(date +%s)
        elapsed=$((now - start_time))
        [[ "$elapsed" -le 0 ]] && continue

        speed_x=$(echo "scale=2; $out_time_sec / $elapsed" | bc -l 2>/dev/null || echo "0")
        # bc omits leading zero: .33 -> 0.33
        [[ "$speed_x" == .* ]] && speed_x="0${speed_x}"
        progress_pct=$(( (out_time_sec * 100) / duration ))
        [[ "$progress_pct" -gt 100 ]] && progress_pct=100

        local eta_str="?"
        if [[ "$out_time_sec" -gt 0 && "$elapsed" -gt 0 ]]; then
            local eta_secs
            eta_secs=$(echo "scale=0; ($duration - $out_time_sec) * $elapsed / $out_time_sec" | bc 2>/dev/null || echo "0")
            if [[ "$eta_secs" =~ ^[0-9]+$ ]]; then
                eta_str=$(format_duration "$eta_secs")
            fi
        fi

        # -- Early abort check (at threshold, retries if temp file not yet written)
        if $early_abort && ! $abort_checked && \
           [[ "$progress_pct" -ge "$early_abort_threshold" ]] && \
           ($remove_if_bigger || $keep_best_version); then

            local current_output_size estimated_final_size

            if [[ -f "$temp_file" ]]; then
                current_output_size=$(get_file_size "$temp_file")
                # Skip check if temp file is empty (ffmpeg hasn't flushed yet)
                if [[ "$current_output_size" -le 0 ]]; then
                    : # retry on next progress update
                elif [[ "$out_time_sec" -gt 0 ]]; then
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

            current_time=$(format_duration "$out_time_sec")
            total_time=$(format_duration "$duration")

            # Output bitrate and estimated gain from temp file size
            local extra_str=""
            if [[ -f "$temp_file" && "$out_time_sec" -gt 0 ]]; then
                local cur_sz out_br_kbps
                cur_sz=$(stat -c %s "$temp_file" 2>/dev/null || echo 0)
                out_br_kbps=$(( cur_sz * 8 / out_time_sec / 1000 ))
                extra_str=" | ${out_br_kbps}kb/s"
                if [[ "$input_size" -gt 0 ]]; then
                    local est_sz saving_pct cmp_color
                    est_sz=$(( cur_sz * duration / out_time_sec ))
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

    if is_av1 "$input_file"; then
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
        codec_info=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name -of csv=p=0 "$input_file" 2>/dev/null | head -1 || echo "?")
        codec_info="${codec_info//$'\r'/}"
        local w h
        w=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=width -of csv=p=0 "$input_file" 2>/dev/null | head -1)
        w="${w//$'\r'/}"; w="${w%%,*}"
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
        printf "  %-50s %8s  %-4s%s%s%s%s -> %s\n" \
            "$input_file" "$(human_size "$input_size")" "$codec_info" \
            "$res_info" "$ts_info" "$scale_info" "$sub_info" "$final_output"
        add_result "$input_file" "DRYRUN" "$input_size" 0 ""
        return 0
    fi

    # Note: no overwrite check here — is_av1() already skips AV1 files,
    # and in-place mode uses temp files for safe atomic replacement.

    # -- Resolve output path (creates temp files for atomicity) ----------------
    resolve_output_path "$input_file"
    final_output="$RESOLVED_FINAL"
    local temp_output="$RESOLVED_TEMP"
    local is_temp="$RESOLVED_IS_TEMP"

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

    # -- Lock ------------------------------------------------------------------
    if ! acquire_lock "$input_file"; then
        add_result "$input_file" "LOCKED" "$input_size" 0 "locked"
        return 0
    fi

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
    local start_time
    start_time=$(date +%s)

    CURRENT_TEMP_FILE="$temp_output"
    EARLY_ABORTED=false

    local stderr_log=""
    stderr_log=$(mktemp "${TMPDIR:-/tmp}/convert-${$}-stderr-XXXXXX.log") || true
    CURRENT_STDERR_LOG="$stderr_log"

    # Run ffmpeg piped to progress monitor.
    # Use temp files for PID tracking and abort signaling (subshell can't set parent vars).
    local pid_file="" abort_signal=""
    pid_file=$(mktemp "${TMPDIR:-/tmp}/convert-${$}-pid-XXXXXX") || true
    abort_signal=$(mktemp -u "${TMPDIR:-/tmp}/convert-${$}-abort-XXXXXX")

    { "${cmd[@]}" 2>"$stderr_log" & echo $! > "$pid_file"; wait $!; } \
        | run_progress_monitor "$duration" "$start_time" "$temp_output" "$input_size" "$pid_file" "$abort_signal" \
        || true
    local ffmpeg_exit=${PIPESTATUS[0]}

    # Read ffmpeg PID from file (for cleanup trap)
    CURRENT_FFMPEG_PID=$(cat "$pid_file" 2>/dev/null || echo "")

    # Check if early abort was signaled from the subshell
    if [[ -f "$abort_signal" ]]; then
        EARLY_ABORTED=true
        rm -f "$abort_signal"
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
    post_process "$input_file" "$final_output" "$temp_output" "$ffmpeg_exit" "$is_temp" "$input_size" "$ts_ref"

    rm -f "$ts_ref"

    # -- Release lock ----------------------------------------------------------
    release_lock "$input_file"

    return 0
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

        add_result "$input_file" "ABORTED" "$input_size" 0 "estimated output larger"
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

    # Move temp file to final destination
    if [[ "$is_temp" == true ]]; then
        mv -f "$temp_output" "$final_output"
    fi
    CURRENT_TEMP_FILE=""

    # Preserve source filesystem timestamps (mtime/atime)
    if [[ -n "$ts_ref" && -f "$ts_ref" ]]; then
        touch -r "$ts_ref" "$final_output" 2>/dev/null || true
    fi

    # Compute sizes
    local output_size=0
    if [[ -f "$final_output" ]]; then
        output_size=$(get_file_size "$final_output")
    fi

    if [[ "$output_size" -eq 0 ]]; then
        warn "Output file empty or missing: $final_output"
        add_result "$input_file" "FAILED" "$input_size" 0 "empty output"
        return 0
    fi

    # Size saved
    local saved_pct=0 saved_bytes=0
    if [[ "$input_size" -gt 0 ]]; then
        saved_pct=$(( (input_size - output_size) * 100 / input_size ))
        saved_bytes=$(( input_size - output_size ))
    fi

    if [[ "$output_size" -gt "$input_size" ]]; then
        warn "Output larger: $(human_size "$output_size") vs $(human_size "$input_size") (saved=${saved_pct}%)"

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
    local opts="$svtav1_options"
    local parts=()

    local preset crf
    preset=$(echo "$opts" | grep -oP '(?<=-preset )\S+' || true)
    crf=$(echo "$opts" | grep -oP '(?<=-crf )\S+' || true)
    [[ -n "$preset" ]] && parts+=("preset=${preset}")
    [[ -n "$crf" ]] && parts+=("crf=${crf}")
    [[ "$opts" == *"yuv420p10le"* ]] && parts+=("10-bit")

    local grain
    grain=$(echo "$opts" | grep -oP 'film-grain=\K[0-9]+' || true)
    [[ -n "$grain" && "$grain" != "0" ]] && parts+=("grain=${grain}")

    if [[ ${#parts[@]} -gt 0 ]]; then
        echo "SVT-AV1 ${parts[*]}"
    else
        echo "SVT-AV1 (default)"
    fi
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
    banner_line "encoder" "$(format_svtav1_options)"

    # Audio
    case "$audio_mode" in
        opus) banner_line "audio" "Opus (always)" ;;
        auto) banner_line "audio" "Opus if > ${audio_bitrate_threshold} kb/s" ;;
        *)    banner_line "audio" "copy" ;;
    esac

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

    # Subtitles (conditional — only shown if enabled)
    $merge_subs && banner_line "subtitles" "merge .srt/.vtt"

    # Batch options (conditional)
    [[ -n "$sort_by_size" ]] && banner_line "sort" "$sort_by_size"
    [[ "$min_size" -gt 0 ]] && banner_line "min size" "$(human_size "$min_size")"
    [[ ${#exclude_patterns[@]} -gt 0 ]] && banner_line "exclude" "${exclude_patterns[*]}"
    [[ -n "$after_cmd" ]] && banner_line "after" "$after_cmd"

    echo -e "${GRAY}${sep}${NC}"
}

# ==============================================================================
# Entry point
# ==============================================================================

main() {
    parse_args "$@"
    check_dependencies

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
