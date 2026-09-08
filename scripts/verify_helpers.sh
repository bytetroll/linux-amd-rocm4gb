#!/usr/bin/env bash

# Small, side-effect-contained helpers used by verify.sh.  Callers must source
# scripts/common.sh first.

# Public output populated by rocm4gb_create_evidence_dir.
rocm4gb_evidence_dir=''

rocm4gb_estimate_kfd_limit_bytes() {
    local mem_total_kib=$1
    local mem_bytes limit_bytes

    [[ "$mem_total_kib" =~ ^[1-9][0-9]*$ ]] || {
        rocm4gb_die "invalid MemTotal value: $mem_total_kib"
    }
    mem_bytes=$((mem_total_kib * 1024))
    limit_bytes=$((mem_bytes - (mem_bytes >> 6)))
    if ((limit_bytes < 3221225472)); then
        limit_bytes=$((limit_bytes / 2))
    else
        limit_bytes=$((limit_bytes - 1610612736))
    fi
    printf '%s\n' "$limit_bytes"
}

rocm4gb_create_evidence_dir() {
    local requested=$1
    local default_root=$2
    local timestamp=$3
    local parent leaf physical_parent

    if [[ -z "$requested" ]]; then
        [[ ! -L "$default_root" ]] || {
            rocm4gb_die "default evidence root must not be a symlink: $default_root"
        }
        if [[ ! -e "$default_root" ]]; then
            (umask 077; mkdir -m 0700 -- "$default_root") || {
                rocm4gb_die "cannot create default evidence root: $default_root"
            }
        fi
        [[ -d "$default_root" && ! -L "$default_root" ]] || {
            rocm4gb_die "default evidence root is not a directory: $default_root"
        }
        physical_parent=$(cd -- "$default_root" && pwd -P) || {
            rocm4gb_die "cannot resolve default evidence root: $default_root"
        }
        rocm4gb_evidence_dir=$(umask 077; mktemp -d \
            "$physical_parent/$timestamp.XXXXXXXX") || {
            rocm4gb_die 'cannot create a unique evidence directory'
        }
    else
        [[ ! -e "$requested" && ! -L "$requested" ]] || {
            rocm4gb_die "explicit evidence path already exists: $requested"
        }
        parent=$(dirname -- "$requested")
        leaf=$(basename -- "$requested")
        [[ "$leaf" != '.' && "$leaf" != '..' ]] || {
            rocm4gb_die "invalid evidence directory name: $requested"
        }
        [[ -d "$parent" ]] || {
            rocm4gb_die "evidence parent directory does not exist: $parent"
        }
        physical_parent=$(cd -- "$parent" && pwd -P) || {
            rocm4gb_die "cannot resolve evidence parent directory: $parent"
        }
        rocm4gb_evidence_dir="$physical_parent/$leaf"
        [[ ! -e "$rocm4gb_evidence_dir" && ! -L "$rocm4gb_evidence_dir" ]] || {
            rocm4gb_die "explicit evidence path already exists: $requested"
        }
        (umask 077; mkdir -m 0700 -- "$rocm4gb_evidence_dir") || {
            rocm4gb_die "cannot exclusively create evidence directory: $requested"
        }
    fi

    [[ -d "$rocm4gb_evidence_dir" && ! -L "$rocm4gb_evidence_dir" ]] || {
        rocm4gb_die "unsafe evidence directory: $rocm4gb_evidence_dir"
    }
}

rocm4gb_extract_generation_tokens() {
    local log_file=$1

    LC_ALL=C sed -nE \
        '/slot[[:space:]]+print_timing:/ {
            /prompt eval time/! s/^.*[|][[:space:]]+eval time[[:space:]]*=.*\/[[:space:]]*([0-9]+)[[:space:]]+tokens.*$/\1/p
        }' "$log_file" \
        | awk '$1 ~ /^[0-9]+$/ && $1 > maximum { maximum=$1 }
               END { print maximum + 0 }'
}

rocm4gb_extract_max_rss_kib() {
    local log_file=$1
    local rss

    rss=$(LC_ALL=C sed -nE \
        's/^[[:space:]]*Maximum resident set size \(kbytes\):[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' \
        "$log_file" | tail -1)
    [[ "$rss" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$rss"
}
