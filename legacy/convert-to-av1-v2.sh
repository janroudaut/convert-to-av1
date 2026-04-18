#!/bin/bash

# Options par défaut
output_dir=""
input_files=()
remove_source=false
remove_if_bigger=false
keep_best_version=false
overwrite=""
max_res=""
svtav1_options="-preset 6 -crf 30"
touch_timestamps=true
respect_no_color=${NO_COLOR:-""}
apply_maxres_even_if_av1=false
log_file=""

usage() {
    echo "Usage: $0 [options] -o /path/to/output-dir FILES[...]"
    echo
    echo "* -o, --output-dir FOLDER                  Store the converted files in the given FOLDER"
    echo
    echo "FILE MANAGEMENT OPTIONS"
    echo "  --smart, --keep-best-version             Sets --rm-src, --rm-if-bigger, and moves source in output folder if sz(src)<sz(dst)"
    echo "  --remove-source, --rm-source, --rm-src   Remove source file if output file size is smaller"
    echo "  --remove-if-bigger, --rm-if-bigger       Remove output file if it's bigger than the source"
    echo "  -y, --overwrite                          Overwrite target file if it already exists"
    echo
    echo "CONVERSION QUALITY OPTIONS"
    echo "  --max-h, --max-height, --max-res HEIGHT  Scale down to -2:HEIGHT_IN_PIXELS if the source height is higher"
    echo "  --sd, --fast                             Enable SVT-AV1 faster encoding options"
    echo "  --hq                                     Enable SVT-AV1 higher-quality options"
    echo
    echo "LOGGING OPTIONS"
    echo "  -l, --log FILE                           Log conversion details to FILE"
    echo
    echo "  -h, --help                               Show usage instructions (aka this text blob)..."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -o | --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --smart | --keep-best-version)
            keep_best_version=true
            remove_source=true
            remove_if_bigger=true
            shift
            ;;
        --remove-source | --rm-source | --rm-src)
            remove_source=true
            shift
            ;;
        --remove-if-bigger | --rm-if-bigger)
            remove_if_bigger=true
            shift
            ;;
        --max-res | --max-h | --max-height)
            max_res="$2"
            shift 2
            ;;
        --sd | --fast)
            svtav1_options="-preset 9 -crf 35"
            shift
            ;;
        --hq)
            svtav1_options="-preset 5 -crf 32 -pix_fmt yuv420p10le -svtav1-params tune=0:film-grain=8"
            shift
            ;;
        -y | --overwrite)
            overwrite="-y"
            shift
            ;;
        -l | --log)
            log_file="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            input_files+=("$1")
            shift
            ;;
    esac
done

if [[ -z "$output_dir" || ${#input_files[@]} -eq 0 ]]; then
    usage
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[38;5;214m'
GRAY='\033[38;5;8m'
BOLD_WHITE='\033[1;37m'
NC='\033[0m'

echo "#"
echo -e "# ${BOLD_WHITE}OUTPUT_DIR: $output_dir${NC}"
echo -e "# ${BOLD_WHITE}SVT-AV1 OPTIONS: $svtav1_options${NC}"
[[ -n "$max_res" ]] && echo -e "# ${ORANGE}MAX_HEIGHT: ${max_res}px${NC}"
[[ -n "$overwrite" ]] && echo -e "# ${ORANGE}OVERWRITE_TARGET${NC}"
$keep_best_version && echo -e "# ${GREEN}SMART MODE${NC} [move source to output_dir if smaller]${NC}"
$remove_source && echo -e "# ${RED}REMOVE SOURCE${NC} [if size(in) > size(out)]${NC}"
$remove_if_bigger && echo -e "# ${RED}REMOVE CONV${NC} [if size(out) > size(in)]${NC}"
echo "#"

for file in "${input_files[@]}"; do
    if [[ -f "$file" ]]; then
        filename=$(basename -- "$file")
        output_file="$output_dir/${filename%.*}.mkv"
        input_size=$(stat -c %s "$file")

        echo
        echo -e "${BOLD_WHITE}<- SOURCE ($(numfmt --to=iec "$input_size")): '$file'${NC}"
        echo -e "${BOLD_WHITE}-> TARGET: '$output_file'${NC}"

        # Gérer si le fichier existe déjà et qu'on le remplace
        if [[ "$(realpath "$file")" == "$(realpath "$output_file")" ]]; then
            tmp_output="$(mktemp --suffix=.mkv)"
            output_is_temp=true
            echo -e "${ORANGE}🛈 OUTPUT = INPUT, using temp file: $tmp_output${NC}"
        else
            tmp_output="$output_file"
            output_is_temp=false
        fi

        # Appliquer la mise à l'échelle si nécessaire
        scale_option=""
        if [[ -n "$max_res" ]]; then
            height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 "$file")
            if [[ "$height" -gt "$max_res" ]]; then
                scale_option="-vf scale=-2:$max_res"
                echo -e "${ORANGE}⟱ Scaling down to ${max_res}p${NC}"
            fi
        fi

        # Obtenir la durée totale du fichier (en secondes)
        duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 "$file")
        duration=${duration%.*}  # arrondi pour ETA

        # Créer fichier lock
        lock_file="${file}.lock"
        echo "pid=$,start=$(date -Iseconds)" > "$lock_file"
        trap 'rm -f "$lock_file"; exit 130' INT TERM

        # Logfile optionnel
        logfile="${log_file:-/dev/null}"

        start_time=$(date +%s)

        # Lancer ffmpeg avec sortie progress
        {
            ffmpeg -hide_banner -i "$file" $scale_option $overwrite \
                -map 0 -map_metadata 0 -map_chapters 0 \
                -c:v libsvtav1 $svtav1_options -b:v 0 \
                -c:a copy -c:s copy -c:t copy -c:d copy \
                -progress pipe:1 -nostats "$tmp_output" \
                2> >(tee "$logfile" >&2)
        } | {
            progress=0
            last_time=0
            while IFS='=' read -r key val; do
                case "$key" in
                    out_time_us)
                        out_time_sec=$((val / 1000000))
                        now=$(date +%s)
                        elapsed=$((now - start_time))

                        # Assurez-vous que les valeurs sont numériques et non nulles
                        if [[ "$elapsed" -gt 0 && "$out_time_sec" -gt 0 && "$duration" -gt 0 ]]; then
                            speed=$(echo "$out_time_sec / $elapsed" | bc -l)
                            eta=$(echo "($duration - $out_time_sec) / $speed" | bc -l)
			                eta=$(printf "%.0f" "$eta")
                            fps=$(echo "$out_time_sec / $elapsed" | bc -l)
                            progress=$(( (out_time_sec * 100) / duration ))
                        else
                            speed=0
                            eta=0
                            fps=0
                            progress=0
                        fi

                        bar=$(printf "%-${progress}s" "#" | tr ' ' '#')
                        current_time=$(date -d@$(($out_time_sec)) -u +%H:%M:%S)
                        total_time=$(date -d@$(($duration)) -u +%H:%M:%S)

                        # Formatage de la sortie
                        printf "\r[%3d%%] [%-20s] %s / %s | elapsed: %ds | speed: %.2fx | ETA: ~%ds | fps: %.2f" \
                            "$progress" "$bar" "$current_time" "$total_time" "$elapsed" "$speed" "$eta" "$fps"
                        ;;
                    progress)
                        if [[ "$val" == "end" ]]; then
                            echo -e "\n${GREEN}✅ Conversion done.${NC}"
                        fi
                        ;;
                esac
            done
        }

        ffmpeg_exit_code=${PIPESTATUS[0]}
        rm -f "$lock_file"

        # Déplacer fichier temporaire si nécessaire
        if $output_is_temp && [[ $ffmpeg_exit_code -eq 0 ]]; then
            mv -f "$tmp_output" "$output_file"
        fi

        # Analyser la sortie de l'encodage pour le log et la gestion des fichiers
        if [[ -f "$output_file" ]]; then
            output_size=$(stat -c %s "$output_file")
        else
            output_size=0
        fi

        if [[ $ffmpeg_exit_code -eq 0 && "$output_size" -gt 0 ]]; then
            size_diff=$(((output_size - input_size) * 100 / input_size))
            if [ "$output_size" -gt "$input_size" ]; then
                size_info="Output size = $(numfmt --to=iec "$output_size"), Input size = $(numfmt --to=iec "$input_size"), Increase: +${size_diff}%"
                echo -e "${ORANGE}🫸 Output is larger. $size_info${NC}"
                echo "🫸 $size_info" >> "$logfile"

                if $keep_best_version; then
                    echo -e "${GREEN}Smart mode: Output is larger, removing it and moving source to destination.${NC}"
                    rm -f "$output_file"
                    mv -f "$file" "$output_dir/"
                elif $remove_if_bigger; then
                    echo -e "${RED}Removing larger output file: $output_file${NC}"
                    rm -f "$output_file"
                fi
            else
                size_info="Output size = $(numfmt --to=iec "$output_size"), Input size = $(numfmt --to=iec "$input_size"), Decrease: ${size_diff}%"
                echo -e "${GREEN}✅ Smaller output! $size_info${NC}"
                echo "✅ $size_info" >> "$logfile"

                if $remove_source; then # This is also true for keep_best_version
                    echo -e "${RED}Removing source file: $file${NC}"
                    rm -f "$file"
                fi
            fi
        elif [[ $ffmpeg_exit_code -ne 0 ]]; then
            error_msg="ERROR with conversion (code $ffmpeg_exit_code), see logs for details."
            echo -e "${RED}❌ $error_msg${NC}"
            echo "❌ $error_msg" >> "$logfile"
            # Nettoyer le fichier de sortie potentiellement corrompu
            if $output_is_temp; then rm -f "$tmp_output"; fi
            # Also remove the final output file if it was created
            [[ -f "$output_file" ]] && rm -f "$output_file"
        fi

    else
        echo -e "${RED}*** File not found: $file${NC}"
    fi
done


echo -e "${GREEN}☺ Batch conversion completed.${NC}"
