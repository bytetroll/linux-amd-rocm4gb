#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/common.sh
source "$script_dir/scripts/common.sh"

prefix=$(rocm4gb_default_prefix)
if (($#)); then
    [[ "$1" == '--prefix' && $# -eq 2 ]] || rocm4gb_die 'usage: ./rollback.sh [--prefix DIR]'
    prefix=$2
fi
prefix=$(realpath -m -- "$prefix")
rocm4gb_assert_safe_prefix "$prefix"

for required in env flock realpath sha256sum; do
    rocm4gb_require_command "$required"
done
[[ -d "$prefix" ]] || rocm4gb_die "install prefix not found: $prefix"
exec {rollback_lock_fd}< "$prefix"
flock -n "$rollback_lock_fd" || rocm4gb_die "another install or rollback owns $prefix"

[[ -L "$prefix/current" ]] || rocm4gb_die 'no active installation to roll back'
[[ -L "$prefix/previous" ]] || rocm4gb_die 'no previous installation recorded'
current_target=$(readlink "$prefix/current")
previous_target=$(readlink "$prefix/previous")
rocm4gb_resolve_managed_version "$prefix" "$current_target" >/dev/null
candidate=$(rocm4gb_resolve_managed_version "$prefix" "$previous_target")
[[ -x "$candidate/bin/llama-rocm4gb" && -f "$candidate/manifest.sha256" ]] || {
    rocm4gb_die 'previous installation is missing its launcher or manifest'
}
if ! (cd -- "$candidate" && sha256sum --check --quiet manifest.sha256); then
    rocm4gb_die 'previous installation failed its artifact integrity check'
fi
if ! env -u LD_LIBRARY_PATH "$candidate/bin/llama-rocm4gb" --version >/dev/null 2>&1; then
    rocm4gb_die 'previous installation failed its clean-environment launcher check'
fi

temporary_current="$prefix/.current.rollback.$$"
temporary_previous="$prefix/.previous.rollback.$$"
trap 'rm -f -- "$temporary_current" "$temporary_previous"' EXIT INT TERM
ln -s -- "$previous_target" "$temporary_current"
ln -s -- "$current_target" "$temporary_previous"
mv -Tf -- "$temporary_current" "$prefix/current"
mv -Tf -- "$temporary_previous" "$prefix/previous"
trap - EXIT INT TERM
rocm4gb_note "activated $previous_target; previous is now $current_target"
