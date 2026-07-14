#!/usr/bin/env bash
set -euo pipefail

# Decimal handling (printf %.0f, awk float math, bc comparisons) must not
# depend on the user's locale — under e.g. fr_FR a decimal point is a comma
# and printf/strtod silently misparse "123.456". LC_NUMERIC only: LC_ALL=C
# would also break UTF-8 output from the embedded python (table symbols).
export LC_NUMERIC=C

# ==============================================================================
# convert-to-av1 v3.4.0 — Batch video conversion to AV1 (SVT-AV1 via ffmpeg)
# ==============================================================================

VERSION="3.4.0"

# -- Colors (respects the NO_COLOR convention) ---------------------------------
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
svt_preset_explicit=false  # --preset N given: content-type presets keep hands off
svt_crf_explicit=false     # --crf N given: content-type presets keep hands off
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
# Progress % at which the size estimate is trusted. Early savings are often
# misleading (title cards, credits, dark intros compress atypically) and real
# gains frequently only show past ~10% — 15% leaves a safety margin beyond that.
early_abort_threshold=15
merge_subs=true
recursive=false
audio_langs=""  # comma-separated language codes to keep (empty = keep all)
sub_langs=""    # comma-separated language codes to keep (empty = keep all)
copy_streams=false  # remux only (no re-encode), just strip/keep selected tracks
use_profiles=true   # honor per-directory .convert-profile files
audio_mode="auto"  # copy, opus, auto
audio_bitrate_threshold=200  # kb/s — auto mode re-encodes above this
# Unified "too small to be real video" threshold (bytes, --min-size, 0 disables).
# Drives three guards: inputs below it are skipped, an output below
# min(min_size, input/10) is treated as corrupt, and an output below it gets a
# forced full-decode verification (near-free at that size).
min_size=131072  # 128K
exclude_patterns=()
skip_log_enabled=false  # persist quality-check failures and skip them on re-runs
skip_log_file=""        # path to the failure log (empty = default at -r root)
after_cmd=""
verify_output=false  # full-decode check of the output before it replaces anything
quality_check=false
quality_min_ssim=0.92  # minimum acceptable SSIM (0-1 scale)
quality_sample_secs=10 # seconds per sample segment for quality check
quality_samples=5      # number of evenly-spaced sample points for quality check

# -- Global state (for cleanup) ------------------------------------------------
CURRENT_TEMP_FILE=""
CURRENT_LOCK_FILE=""
CURRENT_STDERR_LOG=""
CURRENT_FFMPEG_PID=""
LAST_ENCODE_SECS=0        # wall time of the last file's ffmpeg run (for --log)
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
BATCH_TOTAL_BYTES=0       # sum of all input sizes in the batch (for the ETA)
BATCH_DONE_BYTES=0        # input bytes fully handled so far (for the ETA)
LAST_INPUT_SIZE=0         # input size of the last convert_file call (ETA accounting)
LAST_SSIM=""              # SSIM score of the last successful quality check

# Output-name collision guard: final path -> the source that claimed it.
# foo.mp4 and foo.avi both target foo.mkv; with -o, same-named files from
# different subdirs collide too — the second one is skipped with a warning.
declare -A CLAIMED_OUTPUTS=()

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

# Apply content-type overlay on top of speed preset values. An explicit
# --crf/--preset always wins: content types only adjust the derived values.
apply_content_type() {
    case "$content_type" in
        cartoon)
            svt_film_grain=0
            $svt_crf_explicit || svt_crf=$(( svt_crf + 2 ))
            ;;
        tv)
            svt_film_grain=0
            $svt_crf_explicit || svt_crf=$(( svt_crf + 1 ))
            # Boost speed: TV content doesn't need slow presets
            if ! $svt_preset_explicit && [[ "$svt_preset" -lt 10 ]]; then
                svt_preset=10
            fi
            ;;
        movie)
            svt_film_grain_denoise=1
            $svt_crf_explicit || svt_crf=$(( svt_crf - 2 ))
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
PROFILE_VARS=(svt_preset svt_crf svt_preset_explicit svt_crf_explicit
    svt_film_grain svt_film_grain_denoise svt_tune
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

# Profile variant of the CLI validators: a bad value in a .convert-profile must
# not kill a whole batch, so it warns and gets ignored instead of dying.
profile_uint() {
    [[ "${2:-}" =~ ^[0-9]+$ ]] && return 0
    warn "Profile option $1 expects a whole number, got: ${2:-<missing>} — ignored"
    return 1
}
profile_str() {
    [[ -n "${2:-}" ]] && return 0
    warn "Profile option $1 needs a value — ignored"
    return 1
}

# Apply the subset of flags that make sense in a profile. Mirrors parse_args for
# encoding/quality/audio/track options; ignores (with a warning) anything else.
# Value-taking options consume 2 tokens when the value is present, 1 otherwise.
apply_profile_tokens() {
    local n
    while [[ $# -gt 0 ]]; do
        n=1; [[ $# -ge 2 ]] && n=2
        case "$1" in
            --sd|--fast)   svt_preset=10; svt_crf=32; svt_film_grain=0; speed_preset="fast"
                           svt_preset_explicit=false; svt_crf_explicit=false; shift ;;
            --hq)          svt_preset=4; svt_crf=28; svt_film_grain=8; speed_preset="hq"
                           svt_preset_explicit=false; svt_crf_explicit=false
                           [[ "$audio_mode" == "auto" ]] && audio_mode="copy"; shift ;;
            --cartoon)     content_type="cartoon"; shift ;;
            --tv)          content_type="tv"; shift ;;
            --movie)       content_type="movie"; shift ;;
            --crf)         profile_uint "$1" "${2:-}" && { svt_crf="$2"; svt_crf_explicit=true; }; shift "$n" ;;
            --preset)      profile_uint "$1" "${2:-}" && { svt_preset="$2"; svt_preset_explicit=true; }; shift "$n" ;;
            --max-res|--max-h|--max-height)
                           profile_uint "$1" "${2:-}" && max_res="$2"; shift "$n" ;;
            --1080|--1080p) max_res="1080"; shift ;;
            --720|--720p)  max_res="720"; shift ;;
            --copy-audio)  audio_mode="copy"; shift ;;
            --opus)        audio_mode="opus"; shift ;;
            --auto-audio)  audio_mode="auto"; shift ;;
            --audio-threshold)
                           profile_uint "$1" "${2:-}" && { audio_bitrate_threshold="$2"; audio_mode="auto"; }; shift "$n" ;;
            --langs|--lang)
                           profile_str "$1" "${2:-}" && { audio_langs="$2"; sub_langs="$2"; }; shift "$n" ;;
            --audio-langs|--audio-lang)
                           profile_str "$1" "${2:-}" && audio_langs="$2"; shift "$n" ;;
            --sub-langs|--sub-lang)
                           profile_str "$1" "${2:-}" && sub_langs="$2"; shift "$n" ;;
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

# Erase the current terminal line (progress bar) and park the cursor at column 0.
# Uses ANSI "clear to end of line" so it works regardless of the bar's width —
# a fixed-width blank (e.g. %-80s) left the tail of longer bars on screen.
# Pass "err" to clear on stderr (where the SSIM phase draws its feedback).
clear_line() {
    $no_progress && return
    if [[ "${1:-}" == "err" ]]; then
        printf '\r\033[K' >&2
    else
        printf '\r\033[K'
    fi
}

# Live one-line status for the initial file scan (drawn on stderr, interactive
# only — redirected/non-TTY runs and --no-progress stay clean).
scan_tick() {
    { $no_progress || [[ ! -t 2 ]]; } && return
    printf '\r\033[K  %s' "$1" >&2
}
scan_done() {
    { $no_progress || [[ ! -t 2 ]]; } && return
    printf '\r\033[K' >&2
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

# -- CLI argument validators (fail fast at parse time, not mid-batch) ----------
need_arg() {   # need_arg <flag> <value>
    [[ -n "${2:-}" ]] || die "Option $1 requires a value"
}
need_uint() {  # need_uint <flag> <value>
    need_arg "$1" "${2:-}"
    [[ "$2" =~ ^[0-9]+$ ]] || die "Option $1 expects a whole number, got: $2"
}
need_ssim() {  # need_ssim <flag> <value>  (0-1, dot decimals)
    need_arg "$1" "${2:-}"
    [[ "$2" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] \
        || die "Option $1 expects a value between 0 and 1 (e.g. 0.92), got: $2"
}

# Parse human-readable size (e.g., 100M, 1.5G, 500K) to bytes.
# Decimals are supported; an unparsable value is a fatal usage error.
parse_size() {
    local input="$1" num unit mult=1
    [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)([A-Za-z]*)$ ]] \
        || die "Invalid size: $input (expected e.g. 500K, 100M, 1.5G)"
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]^^}"
    case "$unit" in
        ""|B)     mult=1 ;;
        K|KB|KIB) mult=1024 ;;
        M|MB|MIB) mult=$(( 1024 ** 2 )) ;;
        G|GB|GIB) mult=$(( 1024 ** 3 )) ;;
        T|TB|TIB) mult=$(( 1024 ** 4 )) ;;
        *)        die "Invalid size unit: $input (use K, M, G or T)" ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f", n * m }'
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

# Append one synthetic, greppable line per file to --log (tab-separated, no ANSI,
# no progress bar): timestamp, status, sizes, saved %, note, path.
write_log_line() {
    local file="$1" status="$2" in_sz="${3:-0}" out_sz="${4:-0}" note="${5:-}"
    local ts saved="-" out_disp="-" took="-"
    ts=$(date -Iseconds)
    [[ "$out_sz" -gt 0 ]] && out_disp=$(human_size "$out_sz")
    if [[ "$in_sz" -gt 0 && "$out_sz" -gt 0 ]]; then
        saved="$(( (in_sz - out_sz) * 100 / in_sz ))%"
    fi
    [[ "$LAST_ENCODE_SECS" -gt 0 ]] && took=$(format_duration "$LAST_ENCODE_SECS")
    # Profile flags vary per file — the session banner only carries the CLI base
    [[ -n "$CURRENT_PROFILE_TOKENS" ]] && note="${note:+$note }[${CURRENT_PROFILE_TOKENS}]"
    printf '%s\t%-8s\tin=%s\tout=%s\tsaved=%s\ttook=%s\t%s\t%s\n' \
        "$ts" "$status" "$(human_size "$in_sz")" "$out_disp" "$saved" \
        "$took" "${note:-}" "$file" >> "$log_file" 2>/dev/null \
        || warn "Could not write log: $log_file"
}

# Write a per-session banner into --log as "# ..." comment lines: date,
# version, effective config, queue size. Written before the first encode so
# the log exists (and is tail -f-able) from the very start of the batch.
# Spaces and pipes only — never tabs, so print_log_stats keeps skipping these
# lines via its NF filter.
write_log_session_header() {
    local enc audio
    if $copy_streams; then
        enc="remux only (no re-encode)"
    else
        enc=$(format_svtav1_options)
        [[ -n "$content_type" ]] && enc+=" content=${content_type}"
    fi
    case "$audio_mode" in
        opus) audio="opus (always)" ;;
        auto) audio="auto > ${audio_bitrate_threshold} kb/s" ;;
        *)    audio="copy" ;;
    esac

    local line3="" flags=()
    $keep_best_version && flags+=("smart")
    $remove_source && flags+=("rm-source")
    $remove_if_bigger && flags+=("rm-if-bigger")
    $recursive && flags+=("recursive")
    [[ -n "$overwrite" ]] && flags+=("overwrite")
    $quality_check && flags+=("quality-check>=${quality_min_ssim}")
    $verify_output && flags+=("verify")
    if [[ ${#flags[@]} -gt 0 ]]; then
        local flag_str
        flag_str=$(printf '%s, ' "${flags[@]}")
        line3+="flags: ${flag_str%, }"
    fi
    if [[ -n "$audio_langs" || -n "$sub_langs" ]]; then
        line3+="${line3:+ | }langs: audio=${audio_langs:-all} subs=${sub_langs:-all}"
    fi
    if $early_abort && { $remove_if_bigger || $keep_best_version; }; then
        line3+="${line3:+ | }early-abort: ${early_abort_threshold}%"
    fi
    $use_profiles && line3+="${line3:+ | }profiles: per-dir"

    {
        printf '# ── session %s — convert-to-av1 v%s\n' "$(date -Iseconds)" "$VERSION"
        printf '# output: %s | encoder: %s | audio: %s\n' \
            "$($in_place && echo "in-place" || echo "$output_dir")" "$enc" "$audio"
        [[ -n "$line3" ]] && printf '# %s\n' "$line3"
        printf '# files: %s queued (%s)\n' "$FILES_TOTAL" "$(human_size "$BATCH_TOTAL_BYTES")"
    } >> "$log_file" 2>/dev/null || warn "Could not write log: $log_file"
}

# Summarise a --log TSV (see write_log_line for the format) and exit.
# Everything is derived from the log alone, so it works across many runs.
print_log_stats() {
    local f="$1"
    [[ -f "$f" ]] || die "Log file not found: $f"
    echo -e "${BOLD}convert-to-av1 v${VERSION} — stats for ${f}${NC}"
    echo ""
    awk -F'\t' '
        # human size -> bytes ("in=1.2M" / "out=637K" / "-")
        function hb(s,    n, u) {
            sub(/^(in|out)=/, "", s)
            if (s == "-" || s == "") return 0
            n = s + 0
            u = substr(s, length(s), 1)
            if      (u == "K") n *= 1024
            else if (u == "M") n *= 1048576
            else if (u == "G") n *= 1073741824
            else if (u == "T") n *= 1099511627776
            return n
        }
        # bytes -> human size
        function hs(b) {
            if (b >= 1099511627776) return sprintf("%.1fT", b / 1099511627776)
            if (b >= 1073741824)    return sprintf("%.1fG", b / 1073741824)
            if (b >= 1048576)       return sprintf("%.0fM", b / 1048576)
            if (b >= 1024)          return sprintf("%.0fK", b / 1024)
            return sprintf("%dB", b)
        }
        # "took=HH:MM:SS" -> seconds
        function tsec(s,    a) {
            sub(/^took=/, "", s)
            if (split(s, a, ":") != 3) return 0
            return a[1] * 3600 + a[2] * 60 + a[3]
        }
        function dur(sec) {
            return sprintf("%02dh%02dm", sec / 3600, (sec % 3600) / 60)
        }
        NF >= 8 {
            st = $2; gsub(/ +$/, "", st)
            cnt[st]++; total++
            if (st == "OK") {
                tin  += hb($3); tout += hb($4)
                sec = tsec($6); tsecs += sec
                if (sec > 0) timed++
                if (match($7, /ssim=[0-9.]+/)) {
                    v = substr($7, RSTART + 5, RLENGTH - 5) + 0
                    ssum += v; sn++
                    if (smin == "" || v < smin) smin = v
                }
            }
        }
        END {
            if (!total) { print "  (empty log)"; exit }
            for (st in cnt) printf "  %-10s %d\n", st, cnt[st]
            printf "  %-10s %d\n", "total", total
            print ""
            if (tin > 0) {
                printf "  converted ......... %s -> %s (saved %s, %d%%)\n",
                       hs(tin), hs(tout), hs(tin - tout), (tin - tout) * 100 / tin
                if (tsecs > 0) {
                    printf "  encode time ....... %s total", dur(tsecs)
                    if (timed > 0) printf ", avg %dm/file", tsecs / timed / 60
                    printf ", %.1f MB/s\n", tin / tsecs / 1048576
                }
                if (sn > 0)
                    printf "  ssim .............. min %.4f, avg %.4f (%d checked)\n",
                           smin, ssum / sn, sn
            }
        }
    ' "$f"
}

add_result() {
    local file="$1" status="$2" input_sz="${3:-0}" output_sz="${4:-0}" note="${5:-}"
    SUMMARY_FILES+=("$file")
    SUMMARY_STATUSES+=("$status")
    SUMMARY_INPUT_SIZES+=("$input_sz")
    SUMMARY_OUTPUT_SIZES+=("$output_sz")
    SUMMARY_NOTES+=("$note")

    # Synthetic per-file log entry (dry runs are not recorded).
    if [[ -n "$log_file" && "$status" != "DRYRUN" ]]; then
        write_log_line "$file" "$status" "$input_sz" "$output_sz" "$note"
    fi
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
# on slow mounts (/mnt/slow-nas). Keyed by path; re-runs only when the file changes.
PROBE_FILE=""
PROBE_FORMAT_NAME=""
PROBE_DURATION="0"
PROBE_V0_CODEC=""
PROBE_V0_HEIGHT="0"
PROBE_V0_NB_FRAMES="0"
PROBE_V0_AVG_FRAME_RATE=""
PROBE_V0_COLOR_SPACE=""
PROBE_V0_COLOR_TRC=""
PROBE_V0_COLOR_PRIMARIES=""
PROBE_JSON=""          # raw ffprobe JSON, reused by print_file_info
PROBE_STREAMS_TSV=""   # one row per stream: index / type / attached_pic / lang /
                       # channels / bitrate (stream bit_rate, else BPS tag) / codec

probe_load() {
    local file="$1"
    [[ "$file" == "$PROBE_FILE" ]] && return 0

    # Reset to safe defaults (used if the probe fails / non-media file)
    PROBE_FILE="$file"
    PROBE_FORMAT_NAME=""; PROBE_DURATION="0"
    PROBE_V0_CODEC=""; PROBE_V0_HEIGHT="0"
    PROBE_V0_NB_FRAMES="0"; PROBE_V0_AVG_FRAME_RATE=""; PROBE_V0_COLOR_SPACE=""
    PROBE_V0_COLOR_TRC=""; PROBE_V0_COLOR_PRIMARIES=""
    PROBE_JSON=""; PROBE_STREAMS_TSV=""

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
# Empty fields are emitted as "-" — bash reads this TSV with IFS=tab, and tab
# is IFS *whitespace*, so consecutive tabs would collapse and shift every
# following column into the wrong variable. probe_load maps "-" back to "".
def f(v):
    return v if v != "" else "-"
v0 = next((s for s in streams if s.get("codec_type") == "video"), {})
print("\t".join(f(x) for x in [
    g(fmt, "format_name"),
    g(fmt, "duration", "0"),
    g(v0, "codec_name"),
    g(v0, "height", "0"),
    g(v0, "nb_frames", "0"),
    g(v0, "avg_frame_rate"),
    g(v0, "color_space"),
    g(v0, "color_transfer"),
    g(v0, "color_primaries"),
]))
for s in streams:
    disp = s.get("disposition", {}) or {}
    tags = s.get("tags", {}) or {}
    # bit_rate is often absent for audio in MKV; mkvmerge stores it as a BPS tag
    br = g(s, "bit_rate") or (tags.get("BPS", "") or tags.get("BPS-eng", "") or "")
    print("\t".join(f(x) for x in [
        g(s, "index"), g(s, "codec_type"),
        str(disp.get("attached_pic", 0)),
        (tags.get("language", "") or ""),
        g(s, "channels"), str(br), g(s, "codec_name"),
    ]))
') || return 0
    [[ -z "$parsed" ]] && return 0

    # First line = scalars; remaining lines = per-stream TSV.
    local first_line
    IFS= read -r first_line <<< "$parsed"
    IFS=$'\t' read -r PROBE_FORMAT_NAME PROBE_DURATION PROBE_V0_CODEC \
        PROBE_V0_HEIGHT PROBE_V0_NB_FRAMES \
        PROBE_V0_AVG_FRAME_RATE PROBE_V0_COLOR_SPACE \
        PROBE_V0_COLOR_TRC PROBE_V0_COLOR_PRIMARIES <<< "$first_line"
    # Decode the "-" empty-field placeholder (see the python emitter above).
    local v
    for v in PROBE_FORMAT_NAME PROBE_DURATION PROBE_V0_CODEC PROBE_V0_HEIGHT \
             PROBE_V0_NB_FRAMES PROBE_V0_AVG_FRAME_RATE PROBE_V0_COLOR_SPACE \
             PROBE_V0_COLOR_TRC PROBE_V0_COLOR_PRIMARIES; do
        [[ "${!v}" == "-" ]] && printf -v "$v" ''
    done
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

# Free bytes on the filesystem holding DIR (empty output = could not tell,
# in which case callers must not block the conversion).
get_free_space() {
    df -PB1 "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Estimate audio bitrates by demuxing (not decoding) ~20s of packets.
# Needed because MKV often carries no per-stream bit_rate at all (no header
# field, no BPS tag on ffmpeg-muxed files) — without this, --auto-audio would
# see 0 kb/s and wrongly copy e.g. a 640k AAC track. ONE extra ffprobe per
# file covers every audio stream at once (packets carry their stream_index);
# results are cached, so multi-track files never re-spawn.
ABR_ESTIMATE_FILE=""          # file the cache below belongs to
declare -A ABR_ESTIMATE_CACHE=()   # stream index -> estimated bits/sec

estimate_audio_bitrates() {
    local file="$1"
    [[ "$file" == "$ABR_ESTIMATE_FILE" ]] && return 0
    ABR_ESTIMATE_FILE="$file"
    ABR_ESTIMATE_CACHE=()
    # Sample away from the head (intros/credits are not representative) unless
    # the file is too short for that.
    local start=60
    [[ "$(get_duration_secs "$file")" -lt 90 ]] && start=0
    local sidx est
    while read -r sidx est; do
        [[ "$sidx" =~ ^[0-9]+$ && "$est" =~ ^[0-9]+$ ]] || continue
        ABR_ESTIMATE_CACHE[$sidx]="$est"
    done < <(ffprobe -v error -select_streams a \
        -read_intervals "${start}%+20" \
        -show_entries packet=stream_index,pts_time,size -of csv=p=0 "$file" 2>/dev/null \
        | awk -F, '
            $2 != "N/A" && $3 != "" {
                i = $1; p = $2 + 0; sz[i] += $3 + 0
                if (!(i in n) || p < mn[i]) mn[i] = p
                if (!(i in n) || p > mx[i]) mx[i] = p
                n[i]++
            }
            END {
                for (i in n)
                    if (n[i] > 1 && mx[i] > mn[i])
                        printf "%s %.0f\n", i, sz[i] * 8 / (mx[i] - mn[i])
            }
        ') || true
}

# Cached per-stream estimate (bits/sec, 0 if it cannot be told).
estimate_stream_bitrate() {
    estimate_audio_bitrates "$1"
    echo "${ABR_ESTIMATE_CACHE[$2]:-0}"
}

# Single source of truth for the per-track audio decision (opus or copy).
# Used by both the header table (stream_dispositions) and build_ffmpeg_cmd so
# what is shown is always what is done. Already-Opus tracks are never
# re-encoded (generation loss for no gain), whatever the mode.
audio_stream_action() {
    local idx="$1"
    local codec="${TRACKSEL_AUDIO_CODEC[$idx]:-}"
    if [[ "$codec" == "opus" ]]; then
        echo "copy"
        return
    fi
    case "$audio_mode" in
        copy) echo "copy"; return ;;
        opus) echo "opus"; return ;;
    esac
    # auto mode: re-encode above the bitrate threshold
    local kbps=$(( ${TRACKSEL_AUDIO_BR[$idx]:-0} / 1000 ))
    if [[ "$kbps" -gt 0 ]]; then
        if [[ "$kbps" -gt "$audio_bitrate_threshold" ]]; then echo "opus"; else echo "copy"; fi
        return
    fi
    # Bitrate genuinely unknown (probe + BPS tag + packet estimate all failed):
    # lossless/high-bitrate codecs always exceed any sane threshold; for the
    # rest, copying is the safe default.
    case "$codec" in
        flac|alac|dts|truehd|mlp|pcm_*|wmalossless) echo "opus" ;;
        *) echo "copy" ;;
    esac
}

# Emit "index=state" pairs (comma-separated) describing what will happen to every
# stream under the current selection: video -> av1 (or copy in remux mode), audio
# -> opus/copy/skip, subtitle -> copy/skip, covers/data -> copy. Requires
# compute_track_selection to have already run for the file.
stream_dispositions() {
    local -A kept_a=() kept_s=()
    local x
    for x in "${TRACKSEL_AUDIO_IDX[@]+"${TRACKSEL_AUDIO_IDX[@]}"}"; do kept_a[$x]=1; done
    for x in "${TRACKSEL_SUB_IDX[@]+"${TRACKSEL_SUB_IDX[@]}"}"; do kept_s[$x]=1; done

    local pairs=() idx ctype state vseen=0
    while IFS=$'\t' read -r idx ctype _ _ _ _ _; do
        [[ -z "$idx" ]] && continue
        case "$ctype" in
            video)
                if [[ "$vseen" -eq 0 ]]; then
                    vseen=1
                    $copy_streams && state="copy" || state="av1"
                else
                    state="copy"   # cover art / thumbnail
                fi ;;
            audio)
                if [[ -z "${kept_a[$idx]:-}" ]]; then
                    state="skip"
                elif $copy_streams; then
                    state="copy"
                else
                    state=$(audio_stream_action "$idx")
                    # Packet-sampled bitrate: pass it along (":~NNNk") so the
                    # table can fill an otherwise-empty rate cell.
                    if [[ -n "${TRACKSEL_AUDIO_BR_EST[$idx]:-}" && "${TRACKSEL_AUDIO_BR[$idx]:-0}" -gt 0 ]]; then
                        state+=":~$(( TRACKSEL_AUDIO_BR[$idx] / 1000 ))k"
                    fi
                fi ;;
            subtitle)
                if [[ -n "$sub_langs" && -z "${kept_s[$idx]:-}" ]]; then state="skip"; else state="copy"; fi ;;
            *)  state="copy" ;;
        esac
        pairs+=("${idx}=${state}")
    done <<< "$PROBE_STREAMS_TSV"
    local IFS=,
    echo "${pairs[*]}"
}

# Print a media file's streams (reuses the per-file probe cache) as fixed-width,
# aligned columns scannable at a glance:
#   type  disposition  codec  specs(res/layout)  rate(fps/bitrate)  lang/title
# Disposition (from stream_dispositions, passed as $2 "idx=state,...") shows, per
# stream and colour-coded, what will happen: av1/opus re-encode, copy, or skip.
# Fields are truncated to their column width so long codec/resolution names on
# real files never break the alignment.
print_file_info() {
    local file="$1"
    local decisions="${2:-}"
    local sidecars="${3:-}"   # extra muxed-in files: "sub\tname" / "txt\tname" per line
    probe_load "$file"
    [[ -z "$PROBE_JSON" ]] && return

    local rendered
    rendered=$(printf '%s' "$PROBE_JSON" | python3 -c '
import sys, json
args = (sys.argv + [""] * 8)[1:9]
GRAY, ORANGE, BOLD, NC, GREEN, RED, decs, sidecars = args
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
streams = data.get("streams", []) or []
fmt = data.get("format", {}) or {}

dec = {}
for p in decs.split(","):
    if "=" in p:
        k, v = p.split("=", 1)
        dec[k] = v

# A decision value is "state" or "state:extra" — extra carries a packet-sampled
# bitrate ("~256k") for streams whose container reports none.
def dec_parts(idx):
    raw = dec.get(str(idx), "")
    state, _, extra = raw.partition(":")
    return state, extra

# state -> (colour, symbol+word). av1/opus are re-encodes (orange), copy/mux/embed
# keep data as-is (green), skip is dropped (red).
STATE = {
    "av1":   (ORANGE, "↻ av1"),
    "opus":  (ORANGE, "↻ opus"),
    "copy":  (GREEN,  "✓ copy"),
    "mux":   (GREEN,  "✓ mux"),
    "embed": (GREEN,  "✓ embed"),
    "skip":  (RED,    "✗ skip"),
}
SW = 7  # visible width of the disposition column

def cell(word):
    if word not in STATE:
        return " " * SW
    color, w = STATE[word]
    return f"{color}{w}{NC}" + " " * max(0, SW - len(w))

def state_cell(idx):
    return cell(dec_parts(idx)[0])

def trunc(s, w):
    return s if len(s) <= w else s[:w - 1] + "…"

def layout(ch):
    return {1: "mono", 2: "stereo", 6: "5.1", 8: "7.1"}.get(ch, f"{ch}ch" if ch else "")

def fps(rfr):
    if rfr and "/" in rfr:
        try:
            n, d = rfr.split("/")
            d = int(d)
            if d > 0:
                v = int(n) / d
                # Only collapse to an integer for a truly whole rate (24/25/30/60);
                # 24000/1001 = 23.976 must stay 23.98fps, not be rounded to 24.
                return f"{v:.0f}fps" if abs(v - round(v)) < 0.001 else f"{v:.2f}fps"
        except Exception:
            pass
    return ""

def dur_fmt(sec):
    try:
        sec = int(float(sec))
    except Exception:
        return ""
    h, m, s = sec // 3600, (sec % 3600) // 60, sec % 60
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"

def kbits(br):
    return f"{int(br)//1000}k" if (br and str(br).isdigit()) else ""

def row(label, sidx, codec, specs, rate, tail):
    return ("  "
            + f"{GRAY}{label:<8}{NC}  "
            + state_cell(sidx) + "  "
            + f"{BOLD}{trunc(codec, 9):<9}{NC}  "
            + f"{trunc(specs, 11):<11}  "
            + f"{rate:<8}  "
            + tail).rstrip()

prim = next((i for i, s in enumerate(streams) if s.get("codec_type") == "video"), None)

# Display order: main video first, then audio, subtitles, covers, the rest —
# regardless of the container stream order (some files put audio first).
def prio(i, s):
    ct = s.get("codec_type", "")
    if ct == "video":
        return 0 if i == prim else 3
    return {"audio": 1, "subtitle": 2}.get(ct, 4)

out = []
for i, s in sorted(enumerate(streams), key=lambda t: (prio(t[0], t[1]), t[0])):
    ct = s.get("codec_type", "?")
    cn = s.get("codec_name", "?")
    sidx = s.get("index", i)
    tags = s.get("tags", {}) or {}
    lang, title = tags.get("language", "") or "", tags.get("title", "") or ""
    tag = ""
    if lang:
        tag += f"{ORANGE}[{lang}]{NC}"
    if title:
        tag += (" " if lang else "") + f"{GRAY}{title}{NC}"
    if ct == "video" and i == prim:
        w, h = s.get("width", "?"), s.get("height", "?")
        specs = f"{w}×{h}" if w != "?" else ""
        # File/overall bitrate goes in the same (rate) column as audio bitrates;
        # duration, fps and container are grouped in the trailing column.
        file_br = kbits(fmt.get("bit_rate", ""))
        d = dur_fmt(fmt.get("duration", ""))
        f = fps(s.get("r_frame_rate", ""))
        container = fmt.get("format_name", "").split(",")[0]
        meta = f"{d} @ {f}" if (d and f) else (d or f)
        if container:
            meta = (meta + " " if meta else "") + f"({container})"
        vtail = f"{GRAY}{meta}{NC}" if meta else ""
        out.append(row("video", sidx, cn, specs, file_br, vtail))
    elif ct == "video":
        w, h = s.get("width", "?"), s.get("height", "?")
        out.append(row("cover", sidx, cn, f"{w}×{h}", "", tag))
    elif ct == "audio":
        try:
            ch = int(s.get("channels") or 0)
        except Exception:
            ch = 0
        # Rate: stream bit_rate, else the mkvmerge BPS tag, else the
        # packet-sampled estimate carried in the decision ("~256k").
        rate = kbits(s.get("bit_rate", "") or tags.get("BPS", "") or tags.get("BPS-eng", ""))
        if not rate:
            rate = dec_parts(sidx)[1]
        out.append(row("audio", sidx, cn, layout(ch), rate, tag))
    elif ct == "subtitle":
        out.append(row("subtitle", sidx, cn, "", "", tag))
    else:
        out.append(row(ct, sidx, cn, "", "", tag))

# Sidecar files muxed in from disk (external .srt/.vtt subs, .txt description),
# appended as table rows at the end. Name lives in the trailing column (untruncated).
LABELS = {"sub": "+sub", "txt": "+txt"}
STATES = {"sub": "mux", "txt": "embed"}
for line in sidecars.split("\n"):
    if not line.strip():
        continue
    parts = line.split("\t")
    kind = parts[0]
    name = parts[1] if len(parts) > 1 else ""
    label = LABELS.get(kind) or ("+" + kind)
    out.append("  "
               + f"{GRAY}{label:<8}{NC}  "
               + cell(STATES.get(kind, "copy")) + "  "
               + f"{name} {GRAY}(sidecar){NC}")

print("\n".join(out))
' "$GRAY" "$ORANGE" "$BOLD" "$NC" "$GREEN" "$RED" "$decisions" "$sidecars") || return
    [[ -n "$rendered" ]] && echo -e "$rendered"
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

    # Only treat signal-triggered exits (Ctrl-C = 130, TERM = 143, ...) as an
    # interruption. Plain error exits (usage error, failed --check) exit 1 with
    # nothing running, so they get a silent cleanup — no "Interrupted" banner.
    if [[ "$exit_code" -ge 128 ]]; then
        echo ""
        info "Interrupted — cleaning up..."
        # Kill the whole descendant tree — the main ffmpeg, key reader, AND the
        # SSIM ffmpeg which runs inside a command substitution (a deep grandchild
        # that pkill -P $$ would miss).
        kill_descendants $$
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

REQUIRED_DEPS=(ffmpeg ffprobe python3 numfmt stat mktemp bc awk)

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
        # Grab the library version from a 1-frame null encode (the only place
        # SVT-AV1 reports it) — useful when comparing encode speeds across hosts.
        local svt_ver
        svt_ver=$(ffmpeg -hide_banner -f lavfi -i "color=black:s=64x64:d=0.1" \
            -frames:v 1 -c:v libsvtav1 -f null - 2>&1 \
            | grep -oP 'SVT-AV1 Encoder Lib v?\K[0-9][0-9a-z.-]*' | head -1) || true
        echo "  libsvtav1  OK    (SVT-AV1 encoder available${svt_ver:+, lib v$svt_ver})"
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
  -y, --overwrite               Overwrite an existing output file
                                (default: skip it — makes re-runs resumable)

QUALITY:
  --max-res, --max-h HEIGHT     Scale down to HEIGHT px if source is taller
  --1080, --1080p               Alias for --max-res 1080
  --720, --720p                 Alias for --max-res 720
  --sd, --fast                  Fast encoding (preset 10, crf 32)
  --hq                          High quality (preset 4, crf 28, 10-bit, film-grain 8)
  --cartoon                     Optimised for animation (no grain, higher CRF)
  --tv                          Optimised for TV/broadcasts (moderate grain, higher CRF)
  --movie                       Optimised for cinema (preserve grain, lower CRF)
  --crf N                       CRF 0-63, lower = better quality (overrides presets)
  --preset N                    SVT-AV1 preset 0-13, lower = slower (overrides presets)
  --quality-check               SSIM check after conversion; reject if below threshold
  --min-ssim VALUE              Minimum SSIM score 0-1 (default: 0.92)
  --ssim-samples N              Evenly-spaced sample points for the check (default: 5)
  --verify                      Fully decode the output before accepting it
                                (catches corrupt bitstreams; costs one decode)

BATCH:
  --sort-by-size [asc|desc]     Sort files by size before processing (default: desc)
  --dry-run                     Show what would be done without converting
  -r, --recursive               Recurse into subdirectories
  --min-size SIZE               Minimum plausible video size (default: 128K;
                                0 disables). Smaller inputs are skipped; smaller
                                outputs are decode-verified or flagged corrupt
  --exclude PATTERN             Exclude files matching glob PATTERN (repeatable)
  --skip-log[=FILE]             Log files not worth converting (low SSIM / output
                                larger) and skip them on re-runs. Default FILE:
                                .convert-skip.list at the input root
  --no-early-abort              Don't abort if output is estimated larger
  --early-abort-threshold PCT   Progress % at which to evaluate (default: 15)
  --after CMD                   Run CMD after the batch completes

AUDIO:
  --copy-audio                  Keep original audio (no re-encoding)
  --opus                        Re-encode audio to Opus (conservative bitrates)
  --auto-audio                  Re-encode to Opus only if source bitrate > threshold (default)
  --audio-threshold KB/S        Bitrate threshold for auto mode (default: 200)
                                Already-Opus tracks are never re-encoded.

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
  -l, --log FILE                Append a synthetic, greppable per-file log to FILE
                                (tab-separated: time, status, sizes, saved%, took, note)
  --stats FILE                  Summarise a --log file (counts, totals, SSIM) and exit
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
                need_arg "$1" "${2:-}"
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
                need_uint "$1" "${2:-}"
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
                svt_preset_explicit=false; svt_crf_explicit=false
                shift
                ;;
            --hq)
                svt_preset=4; svt_crf=28; svt_film_grain=8
                speed_preset="hq"
                svt_preset_explicit=false; svt_crf_explicit=false
                [[ "$audio_mode" == "auto" ]] && audio_mode="copy"
                shift
                ;;
            --crf)
                need_uint "$1" "${2:-}"
                [[ "$2" -le 63 ]] || die "Option --crf expects 0-63, got: $2"
                svt_crf="$2"; svt_crf_explicit=true
                shift 2
                ;;
            --preset)
                need_uint "$1" "${2:-}"
                [[ "$2" -le 13 ]] || die "Option --preset expects 0-13, got: $2"
                svt_preset="$2"; svt_preset_explicit=true
                shift 2
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
            --verify)
                verify_output=true
                shift
                ;;
            --min-ssim)
                need_ssim "$1" "${2:-}"
                quality_check=true
                quality_min_ssim="$2"
                shift 2
                ;;
            --ssim-samples)
                need_uint "$1" "${2:-}"
                [[ "$2" -ge 1 ]] || die "Option --ssim-samples expects at least 1, got: $2"
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
                need_arg "$1" "${2:-}"
                min_size=$(parse_size "$2")
                shift 2
                ;;
            --exclude)
                need_arg "$1" "${2:-}"
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
                need_arg "$1" "${2:-}"
                after_cmd="$2"
                shift 2
                ;;
            --no-early-abort)
                early_abort=false
                shift
                ;;
            --early-abort-threshold)
                need_uint "$1" "${2:-}"
                [[ "$2" -ge 1 && "$2" -le 99 ]] \
                    || die "Option --early-abort-threshold expects 1-99, got: $2"
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
                need_uint "$1" "${2:-}"
                audio_bitrate_threshold="$2"
                audio_mode="auto"
                shift 2
                ;;
            --no-merge-subs)
                merge_subs=false
                shift
                ;;
            --langs|--lang)
                need_arg "$1" "${2:-}"
                # Shortcut: apply to both audio and subtitles (unless already set)
                [[ -z "$audio_langs" ]] && audio_langs="$2"
                [[ -z "$sub_langs" ]] && sub_langs="$2"
                shift 2
                ;;
            --audio-langs|--audio-lang)
                need_arg "$1" "${2:-}"
                audio_langs="$2"
                shift 2
                ;;
            --sub-langs|--sub-lang)
                need_arg "$1" "${2:-}"
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
                need_arg "$1" "${2:-}"
                log_file="$2"
                shift 2
                ;;
            --stats)
                need_arg "$1" "${2:-}"
                print_log_stats "$2"
                exit 0
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
                (( ${#collected[@]} % 20 == 0 )) && scan_tick "scanning… ${#collected[@]} files found"
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
    local total_c=${#collected[@]} i=0
    for f in "${collected[@]+"${collected[@]}"}"; do
        i=$((i + 1))
        (( i % 20 == 0 || i == total_c )) && scan_tick "checking… ${i}/${total_c}"
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
    scan_done
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
TRACKSEL_SUB_IDX=()     # input indices of kept subtitle streams
declare -A TRACKSEL_AUDIO_CH=()    # input index -> channel count
declare -A TRACKSEL_AUDIO_BR=()    # input index -> bitrate (bit/s)
declare -A TRACKSEL_AUDIO_CODEC=() # input index -> codec name
declare -A TRACKSEL_AUDIO_BR_EST=() # input index -> 1 if bitrate is packet-sampled
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
    TRACKSEL_SUB_IDX=()
    TRACKSEL_AUDIO_CH=()
    TRACKSEL_AUDIO_BR=()
    TRACKSEL_AUDIO_CODEC=()
    TRACKSEL_AUDIO_BR_EST=()
    TRACKSEL_A_TOTAL=0 TRACKSEL_A_KEPT=0 TRACKSEL_S_TOTAL=0 TRACKSEL_S_KEPT=0
    TRACKSEL_AUDIO_FALLBACK=false

    local filtering=false
    [[ -n "$audio_langs" || -n "$sub_langs" ]] && filtering=true

    # Single cached probe drives both track selection and per-audio channels/
    # bitrate (TSV columns: index, type, attached_pic, lang, channels, bit_rate).
    probe_load "$input"

    local -a kept_audio=() kept_sub=() all_audio=()
    local vpos=0
    local idx ctype lang ach abr acodec this_kept
    while IFS=$'\t' read -r idx ctype _ lang ach abr acodec; do
        [[ -z "$idx" ]] && continue
        # "-" is the TSV empty-field placeholder (tabs collapse under IFS=tab)
        [[ "$lang"   == "-" ]] && lang=""
        [[ "$acodec" == "-" ]] && acodec=""
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
                this_kept=false
                if [[ -z "$audio_langs" ]] || lang_matches "$lang" "$audio_langs"; then
                    kept_audio+=("$idx")
                    TRACKSEL_A_KEPT=$((TRACKSEL_A_KEPT + 1))
                    this_kept=true
                fi
                # Per-stream channels/bitrate (bit_rate may be absent -> 0).
                [[ "$ach" =~ ^[0-9]+$ ]] || ach=2
                abr="${abr//[!0-9]/}"
                # MKV frequently reports no audio bitrate at all; the auto mode
                # decision needs one, so sample real packets (demux-only, cached)
                # for kept tracks rather than silently treating them as 0 kb/s.
                if [[ -z "$abr" || "$abr" -eq 0 ]] && $this_kept \
                   && [[ "$audio_mode" == "auto" ]] && ! $copy_streams; then
                    abr=$(estimate_stream_bitrate "$input" "$idx")
                    [[ "$abr" -gt 0 ]] && TRACKSEL_AUDIO_BR_EST[$idx]=1
                fi
                TRACKSEL_AUDIO_CH[$idx]="$ach"
                TRACKSEL_AUDIO_BR[$idx]="${abr:-0}"
                TRACKSEL_AUDIO_CODEC[$idx]="$acodec"
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

    TRACKSEL_SUB_IDX=("${kept_sub[@]+"${kept_sub[@]}"}")

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

    # Colour metadata. HDR sources (HDR10 = smpte2084/PQ, HLG = arib-std-b67)
    # must carry their transfer/primaries/matrix through to the AV1 stream —
    # ffmpeg does not reliably tag them on the libsvtav1 output, and an
    # untagged HDR encode plays back washed-out. SDR sources with invalid or
    # missing metadata get the BT.709 fix SVT-AV1 requires.
    probe_load "$input"
    local color_matrix="${PROBE_V0_COLOR_SPACE%%,*}"
    local color_trc="${PROBE_V0_COLOR_TRC%%,*}"
    if [[ "$color_trc" == "smpte2084" || "$color_trc" == "arib-std-b67" ]]; then
        _cmd+=(-colorspace "${color_matrix:-bt2020nc}" \
               -color_primaries "${PROBE_V0_COLOR_PRIMARIES:-bt2020}" \
               -color_trc "$color_trc")
        info "  HDR source (${color_trc}) — colour metadata preserved"
    elif [[ -z "$color_matrix" || "$color_matrix" == "unknown" || "$color_matrix" == "reserved" || "$color_matrix" == "gbr" ]]; then
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
    # The decision comes from audio_stream_action — the same one the header
    # table shows — so display and encode can never disagree.
    local aj=0
    local a_idx a_ch opus_br
    for a_idx in "${TRACKSEL_AUDIO_IDX[@]+"${TRACKSEL_AUDIO_IDX[@]}"}"; do
        a_ch="${TRACKSEL_AUDIO_CH[$a_idx]:-2}"
        if [[ "$(audio_stream_action "$a_idx")" == "opus" ]]; then
            opus_br=$(get_opus_bitrate "$a_ch")
            _cmd+=(-c:a:"$aj" libopus -b:a:"$aj" "$opus_br")
            # Normalise non-standard surround layouts (e.g. 5.1(side)) so libopus
            # accepts them; channel count is preserved (no downmix).
            local a_layout
            a_layout=$(opus_channel_layout "$a_ch")
            [[ -n "$a_layout" ]] && _cmd+=(-filter:a:"$aj" "aformat=channel_layouts=$a_layout")
        else
            _cmd+=(-c:a:"$aj" copy)
        fi
        aj=$((aj + 1))
    done

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
                    clear_line
                    local done_secs=$(( $(date +%s) - start_time ))
                    if [[ "$done_secs" -gt 0 && "$duration" -gt 0 ]]; then
                        # Wall time + average throughput: frames/s over the whole
                        # run (cur_frame = last frame count ffmpeg reported) and
                        # realtime speed factor, both in tenths.
                        local sp10=$(( duration * 10 / done_secs )) fps_avg=""
                        if [[ "$cur_frame" -gt 0 ]]; then
                            local fa10=$(( cur_frame * 10 / done_secs ))
                            fps_avg="avg $((fa10 / 10)).$((fa10 % 10)) fps, "
                        fi
                        info "  Conversion done in $(format_duration "$done_secs") (${fps_avg}$((sp10 / 10)).$((sp10 % 10))x)."
                    else
                        info "  Conversion done."
                    fi
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

        # Pure bash fixed-point (tenths) — this redraws every second, and two
        # bc spawns per tick add up on long encodes.
        local speed_t=$(( pos_sec * 10 / elapsed ))
        speed_x="$((speed_t / 10)).$((speed_t % 10))"
        progress_pct=$(( (pos_sec * 100) / duration ))
        [[ "$progress_pct" -gt 100 ]] && progress_pct=100

        local eta_str="?"
        if [[ "$pos_sec" -gt 0 && "$duration" -gt "$pos_sec" ]]; then
            eta_str=$(format_duration $(( (duration - pos_sec) * elapsed / pos_sec )))
        elif [[ "$pos_sec" -ge "$duration" ]]; then
            eta_str=$(format_duration 0)
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
                        clear_line
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

            printf "\r  [%3d%%] [%s] %s/%s | fps: %s %sx | ETA: %s%b  " \
                "$progress_pct" "$bar" "$current_time" "$total_time" \
                "$fps_val" "$speed_x" "$eta_str" "$extra_str"
        fi

    done
}

# ==============================================================================
# Per-file header
# ==============================================================================

# Print the per-file block: "▸ [n/N] dir/name  SIZE  [profile]", the stream
# table with per-track dispositions, sidecar rows, and the target path.
# Shared by real conversions and --dry-run so both show the same picture.
# Runs compute_track_selection (required by stream_dispositions) as a side effect.
print_file_header() {
    local input_file="$1" input_size="$2" final_output="$3"
    local input_dir_h input_basename_h
    input_dir_h=$(dirname "$input_file")
    input_basename_h=$(basename "$input_file")

    local ctr="" src_disp prof=""
    [[ "$FILES_TOTAL" -gt 1 ]] && ctr="${GRAY}[${FILES_PROCESSED}/${FILES_TOTAL}]${NC} "
    if [[ "$input_dir_h" == "." ]]; then
        src_disp="${BOLD}${input_basename_h}${NC}"
    else
        src_disp="${GRAY}${input_dir_h}/${NC}${BOLD}${input_basename_h}${NC}"
    fi
    # Profile info sits inline behind the name — no dedicated line.
    [[ -n "$CURRENT_PROFILE_FILE" ]] && prof="  ${ORANGE}[${CURRENT_PROFILE_TOKENS}]${NC}"
    # Size is the headline figure — bold + coloured so it pops.
    echo -e "${GREEN}▸${NC} ${ctr}${src_disp}   ${BOLD}${ORANGE}$(human_size "$input_size")${NC}${prof}"

    # Sidecar files muxed in from disk (external subs + .txt description),
    # rendered as rows at the end of the stream table.
    local sidecars=""
    if $merge_subs; then
        local ext_subs sf
        ext_subs=$(find_subtitle_files "$input_file")
        while IFS= read -r sf; do
            [[ -z "$sf" ]] && continue
            sidecars+="sub"$'\t'"$(basename "$sf")"$'\n'
        done <<< "$ext_subs"
    fi
    local ext_desc
    ext_desc=$(find_description_file "$input_file")
    [[ -n "$ext_desc" ]] && sidecars+="txt"$'\t'"$(basename "$ext_desc")"$'\n'

    # Track selection drives the per-stream disposition (av1/opus/copy/skip).
    compute_track_selection "$input_file"
    print_file_info "$input_file" "$(stream_dispositions)" "$sidecars"
    echo -e "  ${GRAY}→${NC} ${final_output}"
}

# ==============================================================================
# Convert a single file
# ==============================================================================

convert_file() {
    local input_file="$1"

    FILES_PROCESSED=$((FILES_PROCESSED + 1))
    LAST_ENCODE_SECS=0   # only set once ffmpeg actually runs for this file
    LAST_SSIM=""         # only set when the quality check runs and passes
    LAST_INPUT_SIZE=0    # exported to main for byte-based batch ETA accounting

    # -- Pre-checks ------------------------------------------------------------
    if [[ ! -f "$input_file" ]]; then
        warn "File not found: $input_file"
        add_result "$input_file" "NOTFOUND" 0 0 ""
        return 0
    fi

    local input_size
    input_size=$(get_file_size "$input_file")
    LAST_INPUT_SIZE="$input_size"
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

    # -- Output-name collision guard --------------------------------------------
    # foo.mp4 + foo.avi both target foo.mkv; with -o, same-named files from
    # different subdirs collide too — the first claimant wins, the rest skip.
    local claimant="${CLAIMED_OUTPUTS[$final_output]:-}"
    if [[ -n "$claimant" && "$claimant" != "$input_file" ]]; then
        warn "Output collision: $final_output already produced from $claimant — skipping: $input_file"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "output name collision"
        return 0
    fi
    CLAIMED_OUTPUTS[$final_output]="$input_file"

    # An existing output is only overwritten with -y (in-place .mkv -> .mkv
    # replacement targets the source itself and is always allowed). Without -y
    # a re-run of the same batch resumes where it left off. The source path is
    # rebuilt from its dirname/basename so the comparison is canonical
    # ("rich.mkv" and "./rich.mkv" are the same file).
    local input_canon="${input_dir_r}/${input_basename_r}"
    local output_exists=false
    if [[ -f "$final_output" && "$final_output" != "$input_canon" && -z "$overwrite" ]]; then
        output_exists=true
    fi

    # -- Dry run ---------------------------------------------------------------
    # Same header block as a real conversion (stream table incl. per-track
    # dispositions), plus one note line for anything the table cannot express.
    if $dry_run; then
        echo ""
        print_file_header "$input_file" "$input_size" "$final_output"
        local notes=""
        is_mpeg_ts "$input_file" && notes+=" [MPEG-TS fix]"
        if [[ -n "$max_res" ]]; then
            local h_dr
            h_dr=$(get_video_height "$input_file")
            [[ "$h_dr" -gt "$max_res" ]] && notes+=" [scale ${h_dr}p -> ${max_res}p]"
        fi
        $copy_streams && notes+=" [remux]"
        $TRACKSEL_AUDIO_FALLBACK && notes+=" [no audio matched '${audio_langs}' — keeping all]"
        $output_exists && notes+=" [target exists — will be skipped without -y]"
        [[ -n "$notes" ]] && echo -e "  ${ORANGE}${notes# }${NC}"
        add_result "$input_file" "DRYRUN" "$input_size" 0 ""
        return 0
    fi

    if $output_exists; then
        info "  Output exists, skipping (use -y to overwrite): $final_output"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "output exists (no -y)"
        return 0
    fi

    # -- Disk space guard --------------------------------------------------------
    # The temp output lives in the destination dir and can grow to roughly the
    # input size before an early abort kicks in; failing here beats ffmpeg
    # dying on ENOSPC an hour into an encode. Unknown free space never blocks.
    local dest_dir free_bytes
    $in_place && dest_dir="$input_dir_r" || dest_dir="$output_dir"
    free_bytes=$(get_free_space "$dest_dir")
    if [[ -n "$free_bytes" && "$free_bytes" -lt "$input_size" ]]; then
        warn "Insufficient free space on target (need ~$(human_size "$input_size"), have $(human_size "$free_bytes")): skipping $input_file"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "insufficient disk space"
        return 0
    fi

    # -- Lock ------------------------------------------------------------------
    if ! acquire_lock "$input_file"; then
        add_result "$input_file" "LOCKED" "$input_size" 0 "locked"
        return 0
    fi

    # -- Header ----------------------------------------------------------------
    echo ""
    # Batch progress sits above the file header so it reads as a batch-level
    # note, not as part of the next file's block. The remaining-time estimate
    # is byte-based (bytes handled vs total), so it firms up as the batch runs.
    if [[ "$FILES_TOTAL" -gt 1 && "$FILES_PROCESSED" -gt 1 ]]; then
        local bline="batch: $((FILES_PROCESSED - 1))/${FILES_TOTAL} done"
        [[ "$BATCH_SAVED_BYTES" -ne 0 ]] && bline+=" | saved $(human_size "$BATCH_SAVED_BYTES")"
        if [[ "$BATCH_DONE_BYTES" -gt 0 && "$BATCH_TOTAL_BYTES" -gt "$BATCH_DONE_BYTES" ]]; then
            local b_elapsed=$(( $(date +%s) - BATCH_START_TIME ))
            if [[ "$b_elapsed" -ge 5 ]]; then
                bline+=" | ~$(format_duration $(( (BATCH_TOTAL_BYTES - BATCH_DONE_BYTES) * b_elapsed / BATCH_DONE_BYTES ))) left"
            fi
        fi
        echo -e "${GRAY}${bline}${NC}"
        echo ""
    fi
    print_file_header "$input_file" "$input_size" "$final_output"

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
        clear_line
        info "  Skipped by user."
    fi
    rm -f "$pid_file"

    # ffmpeg's own stderr is captured but not shown live. On a hard failure
    # (not an interrupt/early-abort/user-skip) surface the tail so the reason
    # isn't lost — the --log file stays synthetic (one line per file, written by
    # add_result), so raw ffmpeg output no longer pollutes it.
    if [[ "$ffmpeg_exit" -ne 0 && "$ffmpeg_exit" -ne 130 ]] \
       && ! $EARLY_ABORTED && ! $SKIP_REQUESTED && [[ -s "$stderr_log" ]]; then
        warn "ffmpeg failed (exit $ffmpeg_exit); last lines:"
        while IFS= read -r _l; do echo -e "  ${GRAY}${_l}${NC}" >&2; done \
            < <(tail -n 5 "$stderr_log")
    fi
    rm -f "$stderr_log"
    CURRENT_STDERR_LOG=""

    # Wall time of the ffmpeg run — recorded per file in --log via add_result.
    LAST_ENCODE_SECS=$(( $(date +%s) - start_time ))

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
    clear_line err

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

    # A valid video output must be larger than just a container header (an MKV
    # header alone is ~200-350 bytes). Anything under the unified min_size is
    # corrupt for real content — capped at a tenth of the source so
    # tiny-but-valid clips (short samples, test files) are not misflagged.
    local min_output_size=$(( input_size / 10 ))
    [[ "$min_output_size" -gt "$min_size" ]] && min_output_size="$min_size"
    [[ "$min_output_size" -lt 1024 ]] && min_output_size=1024
    if [[ "$output_size" -lt "$min_output_size" ]]; then
        warn "Output too small (${output_size} bytes), likely corrupt: $final_output"
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "FAILED" "$input_size" 0 "corrupt output (${output_size} bytes)"
        return 0
    fi

    # Quality check (SSIM sampling) — done on the temp before writing to the
    # destination, so a rejected encode never touches the (possibly slow) target.
    # Pointless in remux mode (streams are copied verbatim), so skipped there.
    if $quality_check && ! $copy_streams && [[ -f "$input_file" ]]; then
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
            LAST_SSIM="$ssim_score"   # recorded in the --log note for calibration
        fi
    fi

    # Full-decode verification (--verify) — run on the temp before it can
    # replace anything, and after the cheaper checks above. -xerror makes
    # ffmpeg fail on the first decode error instead of soldiering on.
    # Also forced on suspiciously small outputs (below the unified min_size):
    # they passed the size tripwire but are cheap to decode in full, so prove
    # they are real video.
    local force_verify=false
    [[ "$min_size" -gt 0 && "$output_size" -lt "$min_size" ]] && force_verify=true
    if $verify_output || $force_verify; then
        if $force_verify && ! $verify_output; then
            info "  Output is small ($(human_size "$output_size")) — verifying (full decode)..."
        else
            info "  Verifying output (full decode)..."
        fi
        local verify_err=""
        if ! verify_err=$(ffmpeg -v error -xerror -i "$temp_output" \
                -f null - 2>&1); then
            warn "Output failed decode verification: $final_output"
            [[ -n "$verify_err" ]] && warn "  $(echo "$verify_err" | tail -n 2)"
            rm -f "$temp_output"
            CURRENT_TEMP_FILE=""
            add_result "$input_file" "FAILED" "$input_size" "$output_size" "verify: decode errors"
            return 0
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

        add_result "$input_file" "OK" "$input_size" "$output_size" \
            "saved ${saved_pct}% ($(human_size "$saved_bytes"))${LAST_SSIM:+ ssim=$LAST_SSIM}"
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
        # Keep the path (left-truncated) rather than the bare basename — with -r,
        # two same-named episodes from different seasons must stay tellable apart.
        file="${SUMMARY_FILES[$i]#./}"
        status="${SUMMARY_STATUSES[$i]}"
        in_sz="${SUMMARY_INPUT_SIZES[$i]}"
        out_sz="${SUMMARY_OUTPUT_SIZES[$i]}"
        note="${SUMMARY_NOTES[$i]}"

        # Truncate from the left if too long (the tail is the discriminating part)
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
    $verify_output && banner_line "verify" "full decode of each output"

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

    print_banner

    local sorted_files=()
    collect_and_sort_files sorted_files

    if [[ ${#sorted_files[@]} -eq 0 ]]; then
        warn "No video files found."
        exit 0
    fi

    FILES_TOTAL=${#sorted_files[@]}
    BATCH_START_TIME=$(date +%s)

    # Total input size, captured up front: denominator of the byte-based batch
    # ETA (sources may shrink or vanish as the batch runs).
    for file in "${sorted_files[@]}"; do
        BATCH_TOTAL_BYTES=$((BATCH_TOTAL_BYTES + $(get_file_size "$file")))
    done

    # Session banner into --log before the first encode (dry runs are never
    # logged, so they get no header either).
    if [[ -n "$log_file" ]] && ! $dry_run; then
        write_log_session_header
    fi

    for file in "${sorted_files[@]}"; do
        convert_file "$file" || true
        # convert_file exports the size it measured — no second stat per file.
        BATCH_DONE_BYTES=$((BATCH_DONE_BYTES + LAST_INPUT_SIZE))
    done

    # Run --after command if specified
    if [[ -n "$after_cmd" ]]; then
        info "Running --after command: $after_cmd"
        eval "$after_cmd" || warn "--after command failed (exit $?)"
    fi

    # Summary is printed by the EXIT trap via cleanup
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
