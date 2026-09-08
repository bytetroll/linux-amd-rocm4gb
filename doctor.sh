#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/common.sh
source "$script_dir/scripts/common.sh"

printf 'linux-amd-rocm4gb doctor\n'
printf 'kernel=%s\n' "$(uname -sr)"
printf 'architecture=%s\n' "$(uname -m)"
printf 'mem_total_kib=%s\n' "$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"

knob=/sys/module/amdgpu/parameters/no_system_mem_limit
if [[ -r "$knob" ]]; then
    printf 'no_system_mem_limit=%s\n' "$(<"$knob")"
else
    printf 'no_system_mem_limit=unavailable\n'
fi

for card in /sys/class/drm/card*/device; do
    [[ -r "$card/vendor" && "$(<"$card/vendor")" == '0x1002' ]] || continue
    printf 'amd_device=%s\n' "$(readlink -f -- "$card")"
    for field in mem_info_vram_total mem_info_vram_used mem_info_gtt_total mem_info_gtt_used gpu_busy_percent; do
        [[ -r "$card/$field" ]] && printf '%s=%s\n' "$field" "$(<"$card/$field")"
    done
done

tctl_found=false
for sensor_root in /sys/class/hwmon/hwmon*; do
    if [[ -r "$sensor_root/name" && "$(<"$sensor_root/name")" == 'k10temp' ]]; then
        printf 'tctl_millic=%s\n' "$(<"$sensor_root/temp1_input")"
        tctl_found=true
    fi
done
[[ "$tctl_found" == true ]] || printf 'tctl_millic=unavailable\n'

if command -v fuser >/dev/null 2>&1; then
    kfd_users=$(fuser /dev/kfd 2>/dev/null | tr -cd '0-9 ' | xargs 2>/dev/null || true)
    printf 'kfd_users=%s\n' "${kfd_users:-none}"
fi

if command -v hipconfig >/dev/null 2>&1; then
    printf 'hip_version=%s\n' "$(hipconfig --version 2>/dev/null | head -1)"
    printf 'hip_path=%s\n' "$(hipconfig --path 2>/dev/null | head -1)"
else
    printf 'hipconfig=unavailable\n'
fi

prefix=$(rocm4gb_default_prefix)
if [[ -L "$prefix/current" ]]; then
    printf 'installed_current=%s\n' "$(readlink "$prefix/current")"
else
    printf 'installed_current=none\n'
fi
