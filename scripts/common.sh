#!/usr/bin/env bash

set -euo pipefail

rocm4gb_die() {
    printf 'linux-amd-rocm4gb: error: %s\n' "$*" >&2
    exit 1
}

rocm4gb_note() {
    printf 'linux-amd-rocm4gb: %s\n' "$*"
}

rocm4gb_require_command() {
    command -v "$1" >/dev/null 2>&1 || rocm4gb_die "required command not found: $1"
}

rocm4gb_project_root() {
    local script_dir
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    cd -- "$script_dir/.." && pwd -P
}

rocm4gb_default_prefix() {
    local data_root
    data_root=${XDG_DATA_HOME:-"${HOME}/.local/share"}
    printf '%s/linux-amd-rocm4gb\n' "$data_root"
}

rocm4gb_assert_safe_prefix() {
    local candidate=$1
    case "$candidate" in
        ''|'/'|'/home'|'/home/'|'/usr'|'/usr/'|'/opt'|'/opt/'|'/var'|'/var/'|"${HOME}"|"${HOME}/")
            rocm4gb_die "refusing unsafe install prefix: $candidate"
            ;;
    esac
}

rocm4gb_join_colon() {
    local joined=''
    local item
    for item in "$@"; do
        [[ -n "$item" ]] || continue
        if [[ -z "$joined" ]]; then
            joined=$item
        else
            joined="$joined:$item"
        fi
    done
    printf '%s\n' "$joined"
}

rocm4gb_resolve_managed_version() {
    local prefix=$1
    local target=$2
    local versions_root candidate relative

    [[ "$target" =~ ^versions/[^/]+$ ]] || {
        rocm4gb_die "refusing unmanaged version target: $target"
    }
    [[ -d "$prefix/$target" && ! -L "$prefix/$target" ]] || {
        rocm4gb_die "managed version is not a real directory: $target"
    }
    [[ -d "$prefix/versions" && ! -L "$prefix/versions" ]] || {
        rocm4gb_die "versions path is not a real directory: $prefix/versions"
    }
    versions_root=$(realpath -e -- "$prefix/versions" 2>/dev/null) || {
        rocm4gb_die "versions directory is missing: $prefix/versions"
    }
    [[ "$versions_root" == "$prefix/versions" ]] || {
        rocm4gb_die "versions directory escapes the canonical install prefix"
    }
    candidate=$(realpath -e -- "$prefix/$target" 2>/dev/null) || {
        rocm4gb_die "version target is missing: $target"
    }
    [[ -d "$candidate" && "$candidate" == "$versions_root/"* ]] || {
        rocm4gb_die "version target escapes the managed versions directory: $target"
    }
    relative=${candidate#"$versions_root/"}
    [[ -n "$relative" && "$relative" != */* ]] || {
        rocm4gb_die "version target is not a direct managed child: $target"
    }
    printf '%s\n' "$candidate"
}
