#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/common.sh
source "$script_dir/scripts/common.sh"
# shellcheck source=scripts/model_paths.sh
source "$script_dir/scripts/model_paths.sh"
# shellcheck source=scripts/verify_helpers.sh
source "$script_dir/scripts/verify_helpers.sh"

model=''
launcher=''
output_dir=''
timeout_seconds=480
critical_c='90'
start_max_c='65'
context_size=512
tokens=8
allow_small=false

usage() {
    cat <<'EOF'
Usage: ./verify.sh --model MODEL.gguf [options]

Run a guarded, forced-mmap, full-iGPU qualification and retain its evidence.

Options:
  --model FILE          GGUF file (for splits, pass 00001-of-NNNNN)
  --launcher FILE       installed llama-rocm4gb launcher
  --output DIR          new evidence directory (default: results/TIME.RANDOM)
  --timeout SECONDS     hard watchdog (default: 480)
  --critical-c C        kill process group at Tctl (default: 90)
  --start-max-c C       refuse a hot start (default: 65)
  --ctx-size N          small qualification context (default: 512)
  --tokens N            deterministic generated tokens (default: 8)
  --allow-small         run a below-4-GiB smoke test (never reports PASS)
  -h, --help            show this help

This verifier refuses a busy /dev/kfd and refuses no_system_mem_limit=Y.
Its llama-cli command is fixed and auditable; invoke the launcher directly for
experimental arguments.
EOF
}

while (($#)); do
    case "$1" in
        --model) (($# >= 2)) || rocm4gb_die '--model requires a value'; model=$2; shift 2 ;;
        --launcher) (($# >= 2)) || rocm4gb_die '--launcher requires a value'; launcher=$2; shift 2 ;;
        --output) (($# >= 2)) || rocm4gb_die '--output requires a value'; output_dir=$2; shift 2 ;;
        --timeout) (($# >= 2)) || rocm4gb_die '--timeout requires a value'; timeout_seconds=$2; shift 2 ;;
        --critical-c) (($# >= 2)) || rocm4gb_die '--critical-c requires a value'; critical_c=$2; shift 2 ;;
        --start-max-c) (($# >= 2)) || rocm4gb_die '--start-max-c requires a value'; start_max_c=$2; shift 2 ;;
        --ctx-size) (($# >= 2)) || rocm4gb_die '--ctx-size requires a value'; context_size=$2; shift 2 ;;
        --tokens) (($# >= 2)) || rocm4gb_die '--tokens requires a value'; tokens=$2; shift 2 ;;
        --allow-small) allow_small=true; shift ;;
        --) rocm4gb_die 'extra llama-cli arguments are not accepted by qualification' ;;
        -h|--help) usage; exit 0 ;;
        *) rocm4gb_die "unknown option: $1" ;;
    esac
done

[[ -n "$model" ]] || rocm4gb_die '--model is required'
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || rocm4gb_die '--timeout must be a positive integer'
[[ "$context_size" =~ ^[1-9][0-9]*$ ]] || rocm4gb_die '--ctx-size must be a positive integer'
[[ "$tokens" =~ ^[1-9][0-9]*$ ]] || rocm4gb_die '--tokens must be a positive integer'

for required in \
    awk basename date dirname find fuser grep journalctl mkdir mktemp python3 \
    readlink sed sleep sort stat tail tee timeout tr uname xargs; do
    rocm4gb_require_command "$required"
done
[[ -x /usr/bin/time ]] || rocm4gb_die '/usr/bin/time is required'

rocm4gb_discover_model_paths "$model"
model=$rocm4gb_model_path
model_resolved=$rocm4gb_model_resolved_path
shards=("${rocm4gb_model_shards[@]}")
resolved_shards=("${rocm4gb_model_resolved_shards[@]}")

if [[ -z "$launcher" ]]; then
    if command -v llama-rocm4gb >/dev/null 2>&1; then
        launcher=$(command -v llama-rocm4gb)
    else
        default_launcher="$(rocm4gb_default_prefix)/current/bin/llama-rocm4gb"
        [[ -x "$default_launcher" ]] || rocm4gb_die 'no launcher found; pass --launcher'
        launcher=$default_launcher
    fi
fi
launcher_input=$launcher
launcher=$(readlink -f -- "$launcher_input") || {
    rocm4gb_die "cannot resolve launcher: $launcher_input"
}
[[ -x "$launcher" ]] || rocm4gb_die "launcher is not executable: $launcher"

limit_knob=/sys/module/amdgpu/parameters/no_system_mem_limit
[[ -r "$limit_knob" ]] || {
    rocm4gb_die "$limit_knob is absent or unreadable; cannot prove the stock KFD limit is active"
}
knob_value=$(<"$limit_knob")
[[ "$knob_value" == 'N' || "$knob_value" == '0' ]] || {
    rocm4gb_die "$limit_knob is enabled; qualification requires the stock limit"
}

[[ -c /dev/kfd && -r /dev/kfd && -w /dev/kfd ]] || {
    rocm4gb_die '/dev/kfd is absent or inaccessible'
}
set +e
kfd_probe=$(fuser /dev/kfd 2>&1)
kfd_probe_exit=$?
set -e
if ((kfd_probe_exit == 0)); then
    kfd_users=$(tr -cd '0-9 ' <<< "$kfd_probe" | xargs)
elif ((kfd_probe_exit == 1)) && [[ -z "$kfd_probe" ]]; then
    kfd_users=''
else
    rocm4gb_die "could not determine /dev/kfd users: $kfd_probe"
fi
[[ -z "$kfd_users" ]] || rocm4gb_die "/dev/kfd is already in use by PID(s): $kfd_users"

tctl_sensor=''
for sensor_root in /sys/class/hwmon/hwmon*; do
    if [[ -r "$sensor_root/name" && "$(<"$sensor_root/name")" == 'k10temp' ]]; then
        tctl_sensor="$sensor_root/temp1_input"
        break
    fi
done
[[ -r "$tctl_sensor" ]] || rocm4gb_die 'no readable k10temp Tctl sensor found'
start_millic=$(<"$tctl_sensor")
if ! awk -v actual="$start_millic" -v limit="$start_max_c" \
    'BEGIN { exit ! (actual / 1000 <= limit) }'; then
    rocm4gb_die "Tctl is $((start_millic / 1000))C; cool below ${start_max_c}C first"
fi

model_bytes=0
for shard in "${resolved_shards[@]}"; do
    shard_bytes=$(stat -c '%s' -- "$shard")
    model_bytes=$((model_bytes + shard_bytes))
done
if [[ "$allow_small" == false && "$model_bytes" -lt 4294967296 ]]; then
    rocm4gb_die "model payload is below 4 GiB ($model_bytes bytes); use --allow-small for a smoke test"
fi

# Linux v6.17 computes KFD's per-process user-memory ceiling from
# (totalram - totalhigh), keeps 63/64, then reserves 1.5 GiB when the
# intermediate value is at least 3 GiB (otherwise it halves it).  On x86,
# MemTotal is the closest unprivileged userspace observation of that input.
# This remains an estimate and is recorded as such in the evidence.
mem_total_kib=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)
[[ "$mem_total_kib" =~ ^[1-9][0-9]*$ ]] || {
    rocm4gb_die 'could not read MemTotal from /proc/meminfo'
}
estimated_kfd_limit_bytes=$(rocm4gb_estimate_kfd_limit_bytes "$mem_total_kib")
kernel_release=$(uname -r)
crosses_estimated_kfd_limit=false
if ((model_bytes > estimated_kfd_limit_bytes)); then
    crosses_estimated_kfd_limit=true
else
    rocm4gb_note \
        "model payload does not exceed the estimated KFD limit ($model_bytes <= $estimated_kfd_limit_bytes bytes); a successful run is SMOKE, not PASS"
fi
qualification_eligible=$crosses_estimated_kfd_limit
if [[ "$allow_small" == true ]]; then
    qualification_eligible=false
    rocm4gb_note '--allow-small requested; a successful run is SMOKE, not PASS'
fi

if ! kernel_probe=$(journalctl -k -n 0 --show-cursor --no-pager 2>&1); then
    rocm4gb_die "kernel journal is unreadable; cannot collect qualification evidence: $kernel_probe"
fi
kernel_cursor=$(sed -n 's/^-- cursor: //p' <<< "$kernel_probe" | tail -1)
[[ -n "$kernel_cursor" ]] || {
    rocm4gb_die 'kernel journal did not provide a cursor; refusing an unbounded or incomplete delta'
}

rocm4gb_create_evidence_dir \
    "$output_dir" "$script_dir/results" "$(date -u +%Y%m%dT%H%M%SZ)"
output_dir=$rocm4gb_evidence_dir
umask 077

model_log="$output_dir/model.log"
thermal_log="$output_dir/thermal.jsonl"
metrics_log="$output_dir/metrics.tsv"
kernel_log="$output_dir/kernel.log"
summary_file="$output_dir/summary.txt"
: > "$model_log"
: > "$thermal_log"
: > "$metrics_log"

card_devices=()
for busy_file in /sys/class/drm/card*/device/gpu_busy_percent; do
    candidate_device=${busy_file%/gpu_busy_percent}
    candidate_driver=$(readlink -f -- "$candidate_device/driver" 2>/dev/null || true)
    if [[ -r "$busy_file" && -r "$candidate_device/mem_info_vram_used" &&
          -r "$candidate_device/mem_info_gtt_used" &&
          "$candidate_driver" == */amdgpu ]]; then
        card_devices+=("$candidate_device")
    fi
done
[[ "${#card_devices[@]}" -eq 1 ]] || {
    rocm4gb_die \
        "qualification requires exactly one AMD DRM device with memory counters; found ${#card_devices[@]}"
}
card_device=${card_devices[0]}

baseline_vram=$(<"$card_device/mem_info_vram_used")
baseline_gtt=$(<"$card_device/mem_info_gtt_used")
read -r swap_in_before swap_out_before < <(
    awk '/^pswpin /{a=$2} /^pswpout /{b=$2} END{print a+0,b+0}' /proc/vmstat
)

command=(
    "$launcher"
    --offline
    -m "$model"
    --device ROCm0
    --load-mode mmap
    --fit off
    -ngl 999
    --split-mode none
    --no-repack
    -c "$context_size"
    -b 256
    -ub 256
    --cache-ram 0
    -n "$tokens"
    --temp 0
    --seed 424242
    --top-k 1
    --top-p 1
    --min-p 0
    --repeat-penalty 1
    --presence-penalty 0
    --frequency-penalty 0
    --dry-multiplier 0
    --ignore-eos
    -p 'Reply with exactly: ROCm staged upload verified'
    --no-conversation
    --single-turn
    --no-display-prompt
    --no-warmup
    --simple-io
    --verbose
)
printf '%q ' "${command[@]}" > "$output_dir/command.txt"
printf '\n' >> "$output_dir/command.txt"

(
    while true; do
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$(date +%s.%N)" "$(<"$tctl_sensor")" \
            "$(<"$card_device/gpu_busy_percent")" \
            "$(<"$card_device/mem_info_vram_used")" \
            "$(<"$card_device/mem_info_gtt_used")" >> "$metrics_log"
        sleep 0.25
    done
) &
monitor_pid=$!
cleanup_monitor() {
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
}
trap cleanup_monitor EXIT INT TERM

set +e
LC_ALL=C python3 "$script_dir/scripts/thermal_guard.py" \
    --warn-c 75 --critical-c "$critical_c" --poll-seconds 0.25 \
    --log "$thermal_log" -- \
    timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" \
    /usr/bin/time -v "${command[@]}" > "$model_log" 2>&1
run_exit=$?
set -e
metrics_monitor_ok=true
jobs -pr | grep -qx -- "$monitor_pid" || metrics_monitor_ok=false
cleanup_monitor
trap - EXIT INT TERM

kernel_journal_ok=true
if ! journalctl -k --after-cursor="$kernel_cursor" --no-pager \
    > "$kernel_log" 2>&1; then
    kernel_journal_ok=false
fi

read -r swap_in_after swap_out_after < <(
    awk '/^pswpin /{a=$2} /^pswpout /{b=$2} END{print a+0,b+0}' /proc/vmstat
)
swap_in_delta=$((swap_in_after - swap_in_before))
swap_out_delta=$((swap_out_after - swap_out_before))

vram_recovered=false
for _ in {1..60}; do
    current_vram=$(<"$card_device/mem_info_vram_used")
    if (( current_vram <= baseline_vram + 268435456 )); then
        vram_recovered=true
        break
    fi
    sleep 1
done
final_vram=$(<"$card_device/mem_info_vram_used")
final_gtt=$(<"$card_device/mem_info_gtt_used")

read -r sample_count max_tctl max_busy max_vram max_gtt < <(
    awk 'BEGIN{t=0;b=0;v=0;g=0} {if($2>t)t=$2;if($3>b)b=$3;if($4>v)v=$4;if($5>g)g=$5}
         END{printf "%d %.3f %d %.3f %.3f\n",NR,t/1000,b,v/1073741824,g/1073741824}' "$metrics_log"
)
rss_parse_ok=true
if ! max_rss_kib=$(rocm4gb_extract_max_rss_kib "$model_log"); then
    rss_parse_ok=false
    max_rss_kib='unavailable'
fi
generation_tokens=$(rocm4gb_extract_generation_tokens "$model_log")
[[ "$generation_tokens" =~ ^[0-9]+$ ]] || {
    rocm4gb_die 'internal error while parsing generated-token evidence'
}
offload_pair=$(sed -nE 's/.*offloaded ([0-9]+)\/([0-9]+) layers to GPU.*/\1 \2/p' "$model_log" | tail -1)
offload_ok=false
if [[ -n "$offload_pair" ]]; then
    read -r offloaded total_layers <<< "$offload_pair"
    [[ "$offloaded" == "$total_layers" ]] && offload_ok=true
fi
async_ok=false
grep -q 'using async uploads for device ROCm0' "$model_log" && async_ok=true
mmap_ok=false
grep -q 'load_mode = mmap' "$model_log" && mmap_ok=true
model_identity_ok=false
if grep -Fq -- "load_model: loading model '$model'" "$model_log" ||
   grep -Fq -- "load_model: local path '$model'" "$model_log"; then
    model_identity_ok=true
fi
kernel_bad=$(grep -Eic \
    'svm_range_restore_work|amdgpu_amdkfd_restore_userptr_worker|SVM mapping failed|already allocated by SVM|GPU fault|ring[^:]*timeout|GPU reset' \
    "$kernel_log" || true)

failures=()
((run_exit == 0)) || failures+=("command exit $run_exit")
((sample_count > 0)) || failures+=("hardware metrics were not sampled")
[[ "$metrics_monitor_ok" == true ]] || failures+=("hardware metrics monitor ended early")
[[ "$offload_ok" == true ]] || failures+=("incomplete or unproven GPU offload")
[[ "$async_ok" == true ]] || failures+=("ROCm staged async marker absent")
[[ "$mmap_ok" == true ]] || failures+=("forced mmap marker absent")
[[ "$model_identity_ok" == true ]] || failures+=("loaded model identity not proven")
((generation_tokens == tokens)) || {
    failures+=("generated-token evidence does not match requested count ($generation_tokens != $tokens)")
}
if [[ "$rss_parse_ok" == false ]]; then
    failures+=("GNU time peak RSS missing or non-numeric")
elif ((max_rss_kib >= 4194304)); then
    failures+=("peak RSS >= 4 GiB")
fi
((swap_in_delta == 0 && swap_out_delta == 0)) || failures+=("swap I/O occurred")
[[ "$kernel_journal_ok" == true ]] || failures+=("kernel journal delta unavailable")
((kernel_bad == 0)) || failures+=("kernel GPU/SVM faults recorded")
[[ "$vram_recovered" == true ]] || failures+=("VRAM did not return near baseline")
if ((${#failures[@]})); then
    qualification='FAIL'
elif [[ "$qualification_eligible" == true ]]; then
    qualification='PASS'
else
    qualification='SMOKE'
fi

{
    printf 'qualification=%s\n' "$qualification"
    printf 'exit_code=%s\n' "$run_exit"
    printf 'model=%s\n' "$model"
    printf 'model_resolved=%s\n' "$model_resolved"
    printf 'model_bytes=%s\n' "$model_bytes"
    printf 'shards=%s\n' "${#shards[@]}"
    printf 'kernel_release=%s\n' "$kernel_release"
    printf 'mem_total_kib=%s\n' "$mem_total_kib"
    printf 'estimated_kfd_limit_bytes=%s\n' "$estimated_kfd_limit_bytes"
    printf 'crosses_estimated_kfd_limit=%s\n' "$crosses_estimated_kfd_limit"
    printf 'allow_small=%s\n' "$allow_small"
    printf 'no_system_mem_limit=%s\n' "$knob_value"
    printf 'drm_device=%s\n' "$card_device"
    printf 'samples=%s\n' "$sample_count"
    printf 'metrics_monitor_ok=%s\n' "$metrics_monitor_ok"
    printf 'max_tctl_c=%s\n' "$max_tctl"
    printf 'max_gpu_busy_percent=%s\n' "$max_busy"
    printf 'max_vram_gib=%s\n' "$max_vram"
    printf 'max_gtt_gib=%s\n' "$max_gtt"
    printf 'max_rss_kib=%s\n' "$max_rss_kib"
    printf 'rss_parse_ok=%s\n' "$rss_parse_ok"
    printf 'generation_tokens=%s\n' "$generation_tokens"
    printf 'swap_in_delta=%s\n' "$swap_in_delta"
    printf 'swap_out_delta=%s\n' "$swap_out_delta"
    printf 'baseline_vram_bytes=%s\n' "$baseline_vram"
    printf 'final_vram_bytes=%s\n' "$final_vram"
    printf 'baseline_gtt_bytes=%s\n' "$baseline_gtt"
    printf 'final_gtt_bytes=%s\n' "$final_gtt"
    printf 'kernel_journal_ok=%s\n' "$kernel_journal_ok"
    printf 'kernel_bad_lines=%s\n' "$kernel_bad"
    printf 'offload_ok=%s\n' "$offload_ok"
    printf 'async_upload_ok=%s\n' "$async_ok"
    printf 'mmap_ok=%s\n' "$mmap_ok"
    printf 'model_identity_ok=%s\n' "$model_identity_ok"
    if ((${#failures[@]})); then
        printf 'failures=%s\n' "$(IFS='; '; printf '%s' "${failures[*]}")"
    fi
} | tee "$summary_file"

rocm4gb_note "evidence retained in $output_dir"
[[ "$qualification" != 'FAIL' ]]
