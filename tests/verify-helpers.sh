#!/usr/bin/env bash

# shellcheck source-path=SCRIPTDIR

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/common.sh
source "$project_root/scripts/common.sh"
# shellcheck source=../scripts/verify_helpers.sh
source "$project_root/scripts/verify_helpers.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/rocm4gb-verify-helper-test.XXXXXXXX")
cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT INT TERM

[[ "$(rocm4gb_estimate_kfd_limit_bytes 32622992)" == '31273363200' ]]
[[ "$(rocm4gb_estimate_kfd_limit_bytes 1048576)" == '528482304' ]]

default_root="$test_root/default-results"
rocm4gb_create_evidence_dir '' "$default_root" 20260908T000000Z
default_one=$rocm4gb_evidence_dir
rocm4gb_create_evidence_dir '' "$default_root" 20260908T000000Z
default_two=$rocm4gb_evidence_dir
[[ "$default_one" != "$default_two" ]]
[[ -d "$default_one" && -d "$default_two" ]]
[[ "$(stat -c '%a' -- "$default_one")" == '700' ]]
[[ "$(stat -c '%a' -- "$default_two")" == '700' ]]

explicit="$test_root/explicit-evidence"
rocm4gb_create_evidence_dir "$explicit" "$default_root" unused
[[ "$rocm4gb_evidence_dir" == "$explicit" ]]
[[ "$(stat -c '%a' -- "$explicit")" == '700' ]]
printf 'retain me\n' > "$explicit/sentinel"
if (rocm4gb_create_evidence_dir "$explicit" "$default_root" unused) \
    >"$test_root/existing.log" 2>&1; then
    printf 'existing explicit evidence path was accepted\n' >&2
    exit 1
fi
grep -Fq 'explicit evidence path already exists' "$test_root/existing.log"
grep -Fq 'retain me' "$explicit/sentinel"

ln -s missing-target "$test_root/dangling-output"
if (rocm4gb_create_evidence_dir \
        "$test_root/dangling-output" "$default_root" unused) \
    >"$test_root/symlink.log" 2>&1; then
    printf 'dangling explicit evidence symlink was accepted\n' >&2
    exit 1
fi
grep -Fq 'explicit evidence path already exists' "$test_root/symlink.log"

timing_log="$test_root/model.log"
printf '%s\n' \
    '0.1 I slot print_timing: id 0 | prompt eval time = 1 ms / 16 tokens' \
    '0.2 I slot print_timing: id 0 |        eval time = 2 ms / 8 tokens' \
    'Maximum resident set size (kbytes): 695856' \
    > "$timing_log"
[[ "$(rocm4gb_extract_generation_tokens "$timing_log")" == '8' ]]
[[ "$(rocm4gb_extract_max_rss_kib "$timing_log")" == '695856' ]]

printf '%s\n' \
    '0.1 I slot print_timing: id 0 | prompt eval time = 1 ms / 16 tokens' \
    > "$test_root/no-generation.log"
[[ "$(rocm4gb_extract_generation_tokens \
    "$test_root/no-generation.log")" == '0' ]]
if rocm4gb_extract_max_rss_kib "$test_root/no-generation.log" >/dev/null; then
    printf 'missing GNU time RSS was accepted\n' >&2
    exit 1
fi

if "$project_root/verify.sh" --model /does/not/exist -- -m /other.gguf \
    >"$test_root/extra-args.log" 2>&1; then
    printf 'qualification accepted overriding llama-cli arguments\n' >&2
    exit 1
fi
grep -Fq 'extra llama-cli arguments are not accepted' "$test_root/extra-args.log"

printf 'verify-helper tests passed\n'
