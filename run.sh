#!/usr/bin/env bash
#
# Compare a Codec2-mod branch against vanilla Codec2 (3200 mode) with ViSQOL,
# including cross-coding between the two.
#
# Usage: ./run.sh [num_files|all] [seed]
#   num_files : how many WAV files to test (default 20), or "all"
#   seed      : selection seed (default 1); same seed => same file list
#
# Environment:
#   MOD   Codec2-mod branch to test (default main); uses ./codec2_mod-$MOD
#   JOBS  files processed in parallel (default: number of CPU cores)
#
# Column naming: X-Y = encoded with X, decoded with Y.
#   dMOS     = mod-mod - ref-ref  (total change)
#   dMOS-dec = ref-mod - ref-ref  (decoder effect: same vanilla bits)
#   dMOS-enc = mod-ref - ref-ref  (encoder effect: same vanilla decoder)
#
set -euo pipefail
export LC_ALL=C
trap 'echo "FATAL: unexpected error at line $LINENO" >&2' ERR

# ---------------- CONFIG ----------------
MOD=${MOD:-main}
JOBS=${JOBS:-$(nproc)}
WAV_DIR=${WAV_DIR:-"wav_files"}
WORK_DIR=${WORK_DIR:-"work"}
REF_BIN=${REF_BIN:-"./codec2_ref"}
MOD_BIN=${MOD_BIN:-"./codec2_mod-$MOD"}
MOD_DIR=${MOD_DIR:-"Codec2-mod-$MOD"}
VISQOL_MODEL=${VISQOL_MODEL:-"/usr/local/share/visqol/lattice_tcditugenmeetpackhref_ls2_nl60_lr12_bs2048_learn.005_ep2400_train1_7_raw.tflite"}

VISQOL_RATE=16000       # ViSQOL speech mode expects 16 kHz
TIE_EPS=0.0005          # |dMOS| below this counts as a tie

NUM_FILES=${1:-20}
SEED=${2:-1}

# ---------------- ARGUMENT CHECKS ----------------
if ! [[ $NUM_FILES == all || $NUM_FILES =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 [num_files|all] [seed]" >&2
    echo "  num_files must be a positive integer or 'all'" >&2
    exit 1
fi
if ! [[ $SEED =~ ^[0-9]+$ ]]; then
    echo "ERROR: seed must be a non-negative integer" >&2
    exit 1
fi
if ! [[ $JOBS =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: JOBS must be a positive integer" >&2
    exit 1
fi

for cmd in visqol sox awk cmp sort stat md5sum xargs nproc flock; do
    command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done
for bin in "$REF_BIN" "$MOD_BIN"; do
    [[ -x $bin ]] || { echo "ERROR: codec binary not executable: $bin (run 'make MOD=$MOD')" >&2; exit 1; }
done
[[ -f $VISQOL_MODEL ]] || { echo "ERROR: ViSQOL model not found: $VISQOL_MODEL" >&2; exit 1; }

FILES_DIR="$WORK_DIR/files"   # per-file intermediates: work/files/<name>/
ROWS_DIR="$WORK_DIR/rows"     # per-file results, merged at the end
LOG="$WORK_DIR/errors.log"
CSV="$WORK_DIR/results.csv"

mkdir -p "$WORK_DIR"

# ---------------- COLOR SETUP ----------------
if [ -t 1 ]; then
    BOLD="\033[1m"; RESET="\033[0m"; RED="\033[31m"; GREEN="\033[32m"; GRAY="\033[90m"
else
    BOLD=""; RESET=""; RED=""; GREEN=""; GRAY=""
fi

# ---------------- TABLE LAYOUT ----------------
# # | File | ref-ref | mod-mod | dMOS | Bit-diff | ref-mod | mod-ref | dMOS-dec | dMOS-enc
hr() {
    local d8; d8=$(printf '%.0s-' {1..8})
    printf "%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s\n" \
        "$(printf '%*s' "$NUM_W" '' | tr ' ' '-')" "$(printf '%.0s-' {1..40})" "$d8" "$d8" "$d8" "$d8" "$d8" "$d8" "$d8" "$d8"
}

# ---------------- PER-FILE WORKER ----------------
# Runs in parallel (one process per file). Writes its result to
# $ROWS_DIR/<name>.csv, or the reason for skipping to $ROWS_DIR/<name>.fail,
# and prints its table row. Always returns 0 so xargs keeps going.

is_number() { [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

# Colour for a MOS delta: green = better, red = worse, gray = tie.
delta_color() {  # delta
    awk -v d="$1" -v e="$TIE_EPS" -v g="$GREEN" -v r="$RED" -v z="$GRAY" \
        'BEGIN { print (d > e) ? g : (d < -e) ? r : z }'
}

# Print "<mismatched bits> <total bits>". Bits present in only one of the
# files (length mismatch) count as mismatched.
bit_diff() {  # a b
    local a=$1 b=$2 sa sb short long diff
    sa=$(stat -c %s "$a"); sb=$(stat -c %s "$b")
    if (( sa < sb )); then short=$sa; long=$sb; else short=$sb; long=$sa; fi
    if cmp -s "$a" "$b"; then
        echo "0 $(( long * 8 ))"
        return
    fi
    # cmp -l prints: offset, byte in a (octal), byte in b (octal)
    diff=$({ cmp -l "$a" "$b" 2>/dev/null || true; } | awk '
        function oct(s,   i, v) { v = 0; for (i = 1; i <= length(s); i++) v = v * 8 + substr(s, i, 1); return v }
        {
            x = oct($2); y = oct($3)
            for (k = 0; k < 8; k++) { if ((x % 2) != (y % 2)) n++; x = int(x / 2); y = int(y / 2) }
        }
        END { print n + 0 }')
    echo "$(( diff + (long - short) * 8 )) $(( long * 8 ))"
}

# Print the MOS-LQO for (reference, degraded); fail if ViSQOL fails or
# doesn't produce a number.
visqol_mos() {  # ref deg log
    local out mos
    out=$(visqol \
            --reference_file "$1" \
            --degraded_file "$2" \
            --use_speech_mode \
            --similarity_to_quality_model "$VISQOL_MODEL" 2>>"$3") || return 1
    mos=$(awk '/MOS-LQO/ {print $NF; exit}' <<<"$out")
    is_number "$mos" || return 1
    echo "$mos"
}

# Next row number, in completion order. The lock keeps parallel workers
# from getting the same number.
next_number() {
    flock "$COUNTER.lock" bash -c 'n=$(( $(cat "$0") + 1 )); echo "$n" > "$0"; echo "$n"' "$COUNTER"
}

worker_fail() {  # name reason
    echo "$2" > "$ROWS_DIR/${1%.wav}.fail"
    printf "%*d | %-40.40s | %bSKIP: %s%b\n" "$NUM_W" "$(next_number)" "$1" "$RED" "$2" "$RESET" >&2
}

process_file() {  # wav
    local wav=$1 name base dir log bd bt p
    local rr mm rm mr delta dcolor ddec denc decolor encolor
    name=$(basename "$wav")
    base=${name%.wav}
    dir="$FILES_DIR/$base"
    log="$ROWS_DIR/$base.log"
    mkdir -p "$dir"

    # ---- encode with both codecs ----
    "$REF_BIN" enc "$wav" "$dir/ref.bin" 2>>"$log" || { worker_fail "$name" "ref encoder failed"; return 0; }
    "$MOD_BIN" enc "$wav" "$dir/mod.bin" 2>>"$log" || { worker_fail "$name" "mod encoder failed"; return 0; }

    # ---- decode every encoder/decoder pair (file name = <enc>-<dec>) ----
    "$REF_BIN" dec "$dir/ref.bin" "$dir/ref-ref.wav" 2>>"$log" || { worker_fail "$name" "ref decoder failed (ref bits)"; return 0; }
    "$MOD_BIN" dec "$dir/mod.bin" "$dir/mod-mod.wav" 2>>"$log" || { worker_fail "$name" "mod decoder failed (mod bits)"; return 0; }
    "$MOD_BIN" dec "$dir/ref.bin" "$dir/ref-mod.wav" 2>>"$log" || { worker_fail "$name" "mod decoder failed (ref bits)"; return 0; }
    "$REF_BIN" dec "$dir/mod.bin" "$dir/mod-ref.wav" 2>>"$log" || { worker_fail "$name" "ref decoder failed (mod bits)"; return 0; }

    for p in ref-ref mod-mod ref-mod mod-ref; do
        [[ -s $dir/$p.wav ]] || { worker_fail "$name" "empty output ($p)"; return 0; }
    done

    # ---- bitstream comparison ----
    read -r bd bt < <(bit_diff "$dir/ref.bin" "$dir/mod.bin")

    # ---- resample everything to 16 kHz for ViSQOL (same resampler for all) ----
    sox "$wav" "$dir/orig.16k.wav" rate -v "$VISQOL_RATE" 2>>"$log" \
        || { worker_fail "$name" "resampling failed (original)"; return 0; }
    for p in ref-ref mod-mod ref-mod mod-ref; do
        sox "$dir/$p.wav" "$dir/$p.16k.wav" rate -v "$VISQOL_RATE" 2>>"$log" \
            || { worker_fail "$name" "resampling failed ($p)"; return 0; }
    done

    # ---- ViSQOL ----
    rr=$(visqol_mos "$dir/orig.16k.wav" "$dir/ref-ref.16k.wav" "$log") || { worker_fail "$name" "ViSQOL failed (ref-ref)"; return 0; }
    mm=$(visqol_mos "$dir/orig.16k.wav" "$dir/mod-mod.16k.wav" "$log") || { worker_fail "$name" "ViSQOL failed (mod-mod)"; return 0; }
    rm=$(visqol_mos "$dir/orig.16k.wav" "$dir/ref-mod.16k.wav" "$log") || { worker_fail "$name" "ViSQOL failed (ref-mod)"; return 0; }
    mr=$(visqol_mos "$dir/orig.16k.wav" "$dir/mod-ref.16k.wav" "$log") || { worker_fail "$name" "ViSQOL failed (mod-ref)"; return 0; }

    # ---- dMOS = mod-mod minus ref-ref ----
    delta=$(awk -v a="$mm" -v b="$rr" 'BEGIN { printf "%.3f", a - b }')

    # ---- split into decoder effect and encoder effect (both vs ref-ref) ----
    ddec=$(awk -v a="$rm" -v b="$rr" 'BEGIN { printf "%.3f", a - b }')
    denc=$(awk -v a="$mr" -v b="$rr" 'BEGIN { printf "%.3f", a - b }')
    dcolor=$(delta_color "$delta"); decolor=$(delta_color "$ddec"); encolor=$(delta_color "$denc")

    printf '"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$name" "$rr" "$mm" "$delta" "$bd" "$bt" "$rm" "$mr" \
        "$ddec" "$denc" > "$ROWS_DIR/$base.csv"

    (( bd == 0 )) && bd="-"
    printf "%*d | %-40.40s | %8.3f | %8.3f | %b%8.3f%b | %8s | %8.3f | %8.3f | %b%8.3f%b | %b%8.3f%b\n" \
        "$NUM_W" "$(next_number)" "$name" "$rr" "$mm" "$dcolor" "$delta" "$RESET" "$bd" "$rm" "$mr" \
        "$decolor" "$ddec" "$RESET" "$encolor" "$denc" "$RESET"
    return 0
}

export -f is_number delta_color bit_diff visqol_mos next_number worker_fail process_file
export REF_BIN MOD_BIN VISQOL_MODEL VISQOL_RATE TIE_EPS FILES_DIR ROWS_DIR COUNTER NUM_W
export BOLD RESET RED GREEN GRAY

# ---------------- SELECT FILES ----------------
find "$WAV_DIR" -type f -name "*.wav" | sort > "$WORK_DIR/all.txt"
total_available=$(wc -l < "$WORK_DIR/all.txt")

if [[ $NUM_FILES == all ]]; then
    NUM_FILES=$total_available
    cp "$WORK_DIR/all.txt" "$WORK_DIR/selected.txt"
else
    if (( NUM_FILES > total_available )); then
        echo "ERROR: requested $NUM_FILES files, only $total_available available" >&2
        exit 1
    fi
    # Seeded selection: order files by md5("seed:path"). Deterministic for a
    # given seed and file list, and independent of which awk is installed.
    while IFS= read -r f; do
        read -r h _ < <(printf '%s:%s' "$SEED" "$f" | md5sum)
        printf '%s\t%s\n' "$h" "$f"
    done < "$WORK_DIR/all.txt" | sort -k1,1 > "$WORK_DIR/ordered.txt"
    # Separate step on purpose: 'head' in a pipeline exits early, which kills
    # the writer with SIGPIPE and makes the pipeline fail under pipefail.
    head -n "$NUM_FILES" "$WORK_DIR/ordered.txt" | cut -f2- > "$WORK_DIR/selected.txt"
fi

# Per-file results are keyed by file name, so names must be unique.
dupes=$(sed 's#.*/##' "$WORK_DIR/selected.txt" | sort | uniq -d)
if [[ -n $dupes ]]; then
    echo "ERROR: duplicate WAV file names in $WAV_DIR (in different folders):" >&2
    echo "$dupes" >&2
    exit 1
fi

# Start fresh only once the arguments are known to be valid.
rm -rf "$FILES_DIR" "$ROWS_DIR"
mkdir -p "$FILES_DIR" "$ROWS_DIR"
: > "$LOG"

# Row numbering: shared counter file, column as wide as the largest number.
COUNTER="$WORK_DIR/counter"
echo 0 > "$COUNTER"
NUM_W=${#NUM_FILES}

# ---------------- RUN INFO ----------------
codec2_ver=$(pkg-config --modversion codec2 2>/dev/null || echo "unknown")
if mod_rev=$(git -C "$MOD_DIR" rev-parse --short HEAD 2>/dev/null); then
    [[ -n $(git -C "$MOD_DIR" status --porcelain --untracked-files=no 2>/dev/null) ]] \
        && mod_rev="$mod_rev (+ local changes)"
else
    mod_rev="unknown (no git checkout at $MOD_DIR)"
fi
echo "vanilla codec2 : $codec2_ver"
echo "Codec2-mod     : $MOD @ $mod_rev"
echo "files          : $NUM_FILES of $total_available (seed $SEED), $JOBS in parallel"
echo "ViSQOL input   : resampled to $VISQOL_RATE Hz"
echo "columns        : X-Y = encoded with X, decoded with Y; dMOS = mod-mod - ref-ref"
echo "                 dMOS-dec = ref-mod - ref-ref (decoder), dMOS-enc = mod-ref - ref-ref (encoder)"
echo

# ---------------- TABLE HEADER ----------------
printf "%b | %b | %b | %b | %b | %b | %b | %b | %b | %b\n" \
    "${BOLD}$(printf "%${NUM_W}s" '#')${RESET}" \
    "${BOLD}$(printf '%-40s' File)${RESET}" \
    "${BOLD}$(printf '%8s' ref-ref)${RESET}" \
    "${BOLD}$(printf '%8s' mod-mod)${RESET}" \
    "${BOLD}$(printf '%8s' dMOS)${RESET}" \
    "${BOLD}$(printf '%8s' Bit-diff)${RESET}" \
    "${BOLD}$(printf '%8s' ref-mod)${RESET}" \
    "${BOLD}$(printf '%8s' mod-ref)${RESET}" \
    "${BOLD}$(printf '%8s' dMOS-dec)${RESET}" \
    "${BOLD}$(printf '%8s' dMOS-enc)${RESET}"
hr

# ---------------- PARALLEL RUN ----------------
# Rows appear in completion order; results.csv is sorted by file name.
tr '\n' '\0' < "$WORK_DIR/selected.txt" \
    | xargs -0 -r -n 1 -P "$JOBS" bash -c 'process_file "$1"' _

# ---------------- COLLECT RESULTS ----------------
echo "file,ref_ref,mod_mod,dmos,bits_diff,bits_total,ref_mod,mod_ref,dmos_dec,dmos_enc" > "$CSV"
find "$ROWS_DIR" -name '*.csv' -exec cat {} + | sort >> "$CSV"
ok_count=$(( $(wc -l < "$CSV") - 1 ))
fail_count=$(find "$ROWS_DIR" -name '*.fail' | wc -l)

# errors.log: skip reasons plus each file's tool output, grouped per file.
while IFS= read -r f; do
    base=$(basename "$f" .log)
    [[ -s $f || -f $ROWS_DIR/$base.fail ]] || continue
    {
        echo "=== $base.wav"
        [[ -f $ROWS_DIR/$base.fail ]] && echo "SKIPPED: $(cat "$ROWS_DIR/$base.fail")"
        [[ -s $f ]] && cat "$f"
        echo
    } >> "$LOG"
done < <(find "$ROWS_DIR" -name '*.log' | sort)

# ---------------- SUMMARY ----------------
hr

if (( ok_count == 0 )); then
    echo "ERROR: no files processed successfully (see $LOG)" >&2
    exit 1
fi

# Means of every MOS column, win/tie/loss on dMOS, and bit totals.
read -r m_rr m_mm m_d m_rm m_mr m_dd m_de wins ties losses bits_diff bits_total < <(
    awk -F, -v e="$TIE_EPS" 'NR > 1 {
            rr += $2; mm += $3; d += $4; bd += $5; bt += $6; rm += $7; mr += $8
            dd += $9; de += $10; n++
            if ($4 > e) w++; else if ($4 < -e) l++; else t++
        }
        END { printf "%.3f %.3f %.3f %.3f %.3f %.3f %.3f %d %d %d %d %d\n",
                     rr/n, mm/n, d/n, rm/n, mr/n, dd/n, de/n, w, t, l, bd, bt }' "$CSV")

median_delta=$(awk -F, 'NR > 1 { print $4 }' "$CSV" | sort -g \
    | awk '{ v[NR] = $1 } END { if (NR % 2) printf "%.3f", v[(NR+1)/2];
                                 else        printf "%.3f", (v[NR/2] + v[NR/2+1]) / 2 }')

mcolor=$(delta_color "$m_d"); mdcolor=$(delta_color "$m_dd"); mecolor=$(delta_color "$m_de")

printf "%*s | %b | %b | %b | %b%b%b | %8s | %b | %b | %b%b%b | %b%b%b\n" \
    "$NUM_W" "" \
    "${BOLD}$(printf '%-40s' MEAN)${RESET}" \
    "${BOLD}$(printf '%8.3f' "$m_rr")${RESET}" \
    "${BOLD}$(printf '%8.3f' "$m_mm")${RESET}" \
    "$BOLD$mcolor" "$(printf '%8.3f' "$m_d")" "$RESET" \
    "" \
    "${BOLD}$(printf '%8.3f' "$m_rm")${RESET}" \
    "${BOLD}$(printf '%8.3f' "$m_mr")${RESET}" \
    "$BOLD$mdcolor" "$(printf '%8.3f' "$m_dd")" "$RESET" \
    "$BOLD$mecolor" "$(printf '%8.3f' "$m_de")" "$RESET"

bit_pct=$(awk -v a="$bits_diff" -v b="$bits_total" 'BEGIN { printf "%.4f", b ? 100 * a / b : 0 }')

echo
echo "Requested        : $NUM_FILES"
echo "Processed OK     : $ok_count"
echo "Skipped (fail)   : $fail_count"
echo "Median dMOS      : $median_delta"
echo "Win / tie / loss : $wins / $ties / $losses   (tie = |dMOS| <= $TIE_EPS)"
echo "Bit mismatches   : $bits_diff of $bits_total bits ($bit_pct %)"
echo "Per-file results : $CSV"
(( fail_count > 0 )) && echo "Error details    : $LOG"
exit 0