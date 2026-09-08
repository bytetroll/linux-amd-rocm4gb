#!/usr/bin/env bash

# shellcheck source-path=SCRIPTDIR

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/common.sh
source "$project_root/scripts/common.sh"
# shellcheck source=../scripts/model_paths.sh
source "$project_root/scripts/model_paths.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/rocm4gb-model-path-test.XXXXXXXX")
cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT INT TERM

make_file() {
    mkdir -p -- "$(dirname -- "$1")"
    printf '%s\n' "${2:-model-data}" > "$1"
}

expect_failure() {
    local expected=$1
    local model_path=$2
    local failure_log="$test_root/failure.log"

    if (rocm4gb_discover_model_paths "$model_path") >"$failure_log" 2>&1; then
        printf 'expected model discovery to fail: %s\n' "$model_path" >&2
        exit 1
    fi
    grep -Fq -- "$expected" "$failure_log" || {
        printf 'missing expected diagnostic %q in:\n' "$expected" >&2
        cat "$failure_log" >&2
        exit 1
    }
}

# Hugging Face snapshots expose useful split names as symlinks while storing
# opaque objects in blobs/.  Discovery and the llama invocation must retain the
# snapshot paths; validation must operate on their canonical targets.
hf_root="$test_root/huggingface"
snapshot_dir="$hf_root/snapshots/revision"
mkdir -p -- "$hf_root/blobs" "$snapshot_dir"
make_file "$hf_root/blobs/alpha" first
make_file "$hf_root/blobs/beta" second
ln -s ../../blobs/alpha "$snapshot_dir/model[Q8]-00001-of-00002.gguf"
ln -s ../../blobs/beta "$snapshot_dir/model[Q8]-00002-of-00002.gguf"

logical_first="$snapshot_dir/model[Q8]-00001-of-00002.gguf"
logical_second="$snapshot_dir/model[Q8]-00002-of-00002.gguf"
rocm4gb_discover_model_paths "$logical_first"
[[ "$rocm4gb_model_path" == "$logical_first" ]]
[[ "$rocm4gb_model_resolved_path" == "$hf_root/blobs/alpha" ]]
[[ "${#rocm4gb_model_shards[@]}" -eq 2 ]]
[[ "${rocm4gb_model_shards[0]}" == "$logical_first" ]]
[[ "${rocm4gb_model_shards[1]}" == "$logical_second" ]]
[[ "${rocm4gb_model_resolved_shards[0]}" == "$hf_root/blobs/alpha" ]]
[[ "${rocm4gb_model_resolved_shards[1]}" == "$hf_root/blobs/beta" ]]

# A caller may select a snapshot through a directory symlink (for example a
# local "current" alias).  Follow that command-line directory for discovery
# without replacing the logical alias in the paths passed onward.
ln -s snapshots/revision "$hf_root/current"
alias_first="$hf_root/current/model[Q8]-00001-of-00002.gguf"
alias_second="$hf_root/current/model[Q8]-00002-of-00002.gguf"
rocm4gb_discover_model_paths "$alias_first"
[[ "$rocm4gb_model_path" == "$alias_first" ]]
[[ "${rocm4gb_model_shards[0]}" == "$alias_first" ]]
[[ "${rocm4gb_model_shards[1]}" == "$alias_second" ]]
[[ "${rocm4gb_model_resolved_shards[0]}" == "$hf_root/blobs/alpha" ]]
[[ "${rocm4gb_model_resolved_shards[1]}" == "$hf_root/blobs/beta" ]]

# Relative input becomes absolute without resolving its symlink leaf.
make_file "$hf_root/blobs/single" single
ln -s ../../blobs/single "$snapshot_dir/single.gguf"
(
    cd -- "$test_root"
    rocm4gb_discover_model_paths huggingface/snapshots/revision/single.gguf
    [[ "$rocm4gb_model_path" == \
       "$test_root/huggingface/snapshots/revision/single.gguf" ]]
    [[ "$rocm4gb_model_resolved_path" == "$hf_root/blobs/single" ]]
)

missing_dir="$test_root/missing"
make_file "$missing_dir/gap-00001-of-00003.gguf" first
make_file "$missing_dir/gap-00003-of-00003.gguf" third
expect_failure 'missing GGUF shard: gap-00002-of-00003.gguf' \
    "$missing_dir/gap-00001-of-00003.gguf"

wrong_total_dir="$test_root/wrong-total"
make_file "$wrong_total_dir/total-00001-of-00002.gguf" first
make_file "$wrong_total_dir/total-00002-of-00003.gguf" second
expect_failure 'reports total 00003; expected 00002' \
    "$wrong_total_dir/total-00001-of-00002.gguf"

bad_index_dir="$test_root/bad-index"
make_file "$bad_index_dir/index-00000-of-00002.gguf" zero
make_file "$bad_index_dir/index-00001-of-00002.gguf" first
make_file "$bad_index_dir/index-00002-of-00002.gguf" second
expect_failure 'index 00000 is outside 00001-00002' \
    "$bad_index_dir/index-00001-of-00002.gguf"

duplicate_dir="$test_root/duplicate-target"
make_file "$duplicate_dir/blob" shared
ln -s blob "$duplicate_dir/duplicate-00001-of-00002.gguf"
ln -s blob "$duplicate_dir/duplicate-00002-of-00002.gguf"
expect_failure 'duplicate GGUF shard target' \
    "$duplicate_dir/duplicate-00001-of-00002.gguf"

not_first_dir="$test_root/not-first"
make_file "$not_first_dir/order-00001-of-00002.gguf" first
make_file "$not_first_dir/order-00002-of-00002.gguf" second
expect_failure 'pass the first GGUF shard' \
    "$not_first_dir/order-00002-of-00002.gguf"

dangling_dir="$test_root/dangling"
make_file "$dangling_dir/broken-00001-of-00002.gguf" first
ln -s absent "$dangling_dir/broken-00002-of-00002.gguf"
expect_failure 'model shard does not resolve to a regular file' \
    "$dangling_dir/broken-00001-of-00002.gguf"

printf 'model-path tests passed\n'
