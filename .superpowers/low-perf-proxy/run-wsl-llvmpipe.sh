#!/usr/bin/env bash
set -euo pipefail

profile="yernar"
repo=""
verify_only=0
probe_frames=0
stress=0
stress_seconds=180
connection_probe=0

while (($#)); do
    case "$1" in
        --profile)
            profile="${2:?missing value for --profile}"
            shift 2
            ;;
        --repo)
            repo="${2:?missing value for --repo}"
            shift 2
            ;;
        --verify-only)
            verify_only=1
            shift
            ;;
        --probe-frames)
            probe_frames="${2:?missing value for --probe-frames}"
            shift 2
            ;;
        --stress)
            stress=1
            shift
            ;;
        --stress-seconds)
            stress_seconds="${2:?missing value for --stress-seconds}"
            shift 2
            ;;
        --connection-probe)
            connection_probe=1
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

case "$profile" in
    yernar|stress) cpu_set="0-3" ;;
    torture) cpu_set="0-1" ;;
    *)
        echo "Unknown profile: $profile" >&2
        exit 2
        ;;
esac

if [[ -z "$repo" || ! -f "$repo/project.godot" ]]; then
    echo "Godot project not found: $repo" >&2
    exit 3
fi

proxy_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
godot="$proxy_dir/Godot_v4.7.1-stable_linux.x86_64"
icd="/usr/share/vulkan/icd.d/lvp_icd.x86_64.json"
runtime="$proxy_dir/runtime/$profile"
logs="$proxy_dir/logs"

[[ -x "$godot" ]] || { echo "Linux Godot is missing or not executable: $godot" >&2; exit 4; }
[[ -f "$icd" ]] || { echo "Mesa llvmpipe ICD is missing: $icd" >&2; exit 5; }
command -v vulkaninfo >/dev/null || { echo "vulkaninfo is missing" >&2; exit 6; }
command -v taskset >/dev/null || { echo "taskset is missing" >&2; exit 7; }

export VK_DRIVER_FILES="$icd"
export VK_ICD_FILENAMES="$icd"
export XDG_DATA_HOME="$runtime/data"
export XDG_CONFIG_HOME="$runtime/config"
export XDG_CACHE_HOME="$runtime/cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$logs"

godot_version="$($godot --version)"
[[ "$godot_version" == 4.7.1.* ]] || { echo "Expected Godot 4.7.1, got: $godot_version" >&2; exit 8; }

cpu_count="$(nproc)"
[[ "$cpu_count" == "4" ]] || { echo "Expected 4 WSL CPUs, got: $cpu_count" >&2; exit 9; }

mem_kib="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
swap_kib="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
if (( mem_kib < 3600000 || mem_kib > 4400000 )); then
    echo "Expected approximately 4 GB WSL memory, got ${mem_kib} KiB" >&2
    exit 10
fi
[[ "$swap_kib" == "0" ]] || { echo "Expected zero WSL swap, got ${swap_kib} KiB" >&2; exit 11; }

vulkan_summary="$(vulkaninfo --summary 2>&1)"
if ! grep -qi 'deviceName.*llvmpipe' <<<"$vulkan_summary"; then
    echo "Vulkan is not using llvmpipe:" >&2
    echo "$vulkan_summary" >&2
    exit 12
fi

effective_cpu_list="$(taskset -c "$cpu_set" awk '/^Cpus_allowed_list:/ { print $2 }' /proc/self/status)"
if [[ "$effective_cpu_list" != "$cpu_set" ]]; then
    echo "CPU affinity mismatch: requested $cpu_set, got $effective_cpu_list" >&2
    exit 15
fi

echo "Godot: 4.7.1 ($godot_version)"
echo "Vulkan device: llvmpipe"
echo "Renderer: Mobile"
echo "Resolution: 1280x720"
echo "WSL CPUs: 4"
echo "WSL memory: 4 GB"
echo "WSL swap: 0"
echo "CPU set: $cpu_set"
echo "Effective CPU list: $effective_cpu_list"
echo "Profile: $profile"

if (( verify_only )); then
    exit 0
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
log_file="$logs/${profile}-${timestamp}.log"
godot_args=(
    --path "$repo"
    --rendering-driver vulkan
    --rendering-method mobile
    --resolution 1280x720
    --verbose
    "$repo/.superpowers/low-perf-proxy/bench_project.tscn"
    --
    --perfbench
)
if (( probe_frames > 0 )); then
    godot_args+=(--quit-after "$probe_frames")
fi
if (( stress )); then
    godot_args+=(--stress "--stress-seconds=$stress_seconds")
fi
if (( connection_probe )); then
    godot_args+=(--connection-probe)
fi

echo "Log: $log_file"
set +e
taskset -c "$cpu_set" "$godot" "${godot_args[@]}" 2>&1 | tee "$log_file"
godot_exit=${PIPESTATUS[0]}
set -e

if ! grep -qi 'llvmpipe' "$log_file"; then
    echo "Godot did not report llvmpipe; refusing an unverified run." >&2
    exit 13
fi
if ! grep -Eqi 'Forward Mobile|renderer.*Mobile|Mobile.*renderer' "$log_file"; then
    echo "Godot did not report the Mobile renderer." >&2
    exit 14
fi
if (( godot_exit != 0 )); then
    echo "Godot exited with code $godot_exit" >&2
    exit "$godot_exit"
fi
