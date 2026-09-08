#!/usr/bin/env bash

set -euo pipefail

launcher_path=$(readlink -f -- "$0")
version_root=$(cd -- "$(dirname -- "$launcher_path")/.." && pwd -P)
libexec_dir="$version_root/libexec"

case "$(basename -- "$0")" in
    *server*) executable="$libexec_dir/llama-server" ;;
    *)        executable="$libexec_dir/llama-cli" ;;
esac

[[ -x "$executable" ]] || {
    printf 'linux-amd-rocm4gb: installed executable is missing: %s\n' "$executable" >&2
    exit 1
}

runtime_path=$libexec_dir
if [[ -f "$version_root/runtime-lib-dirs" ]]; then
    while IFS= read -r directory; do
        [[ -n "$directory" ]] || continue
        runtime_path="$runtime_path:$directory"
    done < "$version_root/runtime-lib-dirs"
fi
if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    runtime_path="$runtime_path:$LD_LIBRARY_PATH"
fi
export LD_LIBRARY_PATH=$runtime_path

exec "$executable" "$@"
