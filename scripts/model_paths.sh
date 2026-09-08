#!/usr/bin/env bash

# Model-path discovery for verify.sh.  Callers must source scripts/common.sh
# first so malformed or unsafe model sets fail through rocm4gb_die.

# Public outputs populated by rocm4gb_discover_model_paths.
rocm4gb_model_path=''
rocm4gb_model_resolved_path=''
rocm4gb_model_shards=()
rocm4gb_model_resolved_shards=()

rocm4gb_resolve_model_file() {
    local logical_path=$1
    local resolved_path

    resolved_path=$(readlink -f -- "$logical_path") || {
        rocm4gb_die "cannot resolve model file: $logical_path"
    }
    [[ -f "$resolved_path" ]] || {
        rocm4gb_die "model shard does not resolve to a regular file: $logical_path"
    }
    printf '%s\n' "$resolved_path"
}

rocm4gb_discover_model_paths() {
    local supplied_path=$1
    local model_dir model_name
    local split_prefix split_count_text split_count
    local candidate candidate_name candidate_prefix
    local candidate_index_text candidate_total_text candidate_index
    local expected_name shard resolved identity prior
    local index

    [[ -n "$supplied_path" ]] || rocm4gb_die 'model path is empty'
    if [[ "$supplied_path" == /* ]]; then
        rocm4gb_model_path=$supplied_path
    else
        # Make the invocation independent of later working-directory changes,
        # but deliberately do not resolve the leaf: Hugging Face snapshots use
        # meaningful GGUF symlink names whose sibling shards live beside them.
        rocm4gb_model_path="$PWD/$supplied_path"
    fi

    rocm4gb_model_resolved_path=$(
        rocm4gb_resolve_model_file "$rocm4gb_model_path"
    )
    rocm4gb_model_shards=("$rocm4gb_model_path")
    rocm4gb_model_resolved_shards=("$rocm4gb_model_resolved_path")

    model_dir=$(dirname -- "$rocm4gb_model_path")
    model_name=$(basename -- "$rocm4gb_model_path")
    if [[ ! "$model_name" =~ ^(.*)-([0-9]{5})-of-([0-9]{5})\.gguf$ ]]; then
        return
    fi

    [[ "${BASH_REMATCH[2]}" == '00001' ]] || {
        rocm4gb_die 'pass the first GGUF shard (00001-of-NNNNN)'
    }
    split_prefix=${BASH_REMATCH[1]}
    split_count_text=${BASH_REMATCH[3]}
    split_count=$((10#$split_count_text))
    ((split_count >= 1)) || rocm4gb_die 'GGUF split total must be at least 00001'

    local -A shard_for_index=()
    local -A target_for_identity=()

    # Scan every directory entry so regular files, valid symlinks, and broken
    # symlinks all receive deterministic validation.  Matching the generic
    # split grammar before comparing the literal prefix avoids treating model
    # names containing glob metacharacters as patterns.
    while IFS= read -r -d '' candidate; do
        candidate_name=$(basename -- "$candidate")
        if [[ ! "$candidate_name" =~ ^(.*)-([0-9]{5})-of-([0-9]{5})\.gguf$ ]]; then
            continue
        fi
        candidate_prefix=${BASH_REMATCH[1]}
        [[ "$candidate_prefix" == "$split_prefix" ]] || continue
        candidate_index_text=${BASH_REMATCH[2]}
        candidate_total_text=${BASH_REMATCH[3]}

        [[ "$candidate_total_text" == "$split_count_text" ]] || {
            rocm4gb_die \
                "GGUF shard $candidate_name reports total $candidate_total_text; expected $split_count_text"
        }
        candidate_index=$((10#$candidate_index_text))
        ((candidate_index >= 1 && candidate_index <= split_count)) || {
            rocm4gb_die \
                "GGUF shard index $candidate_index_text is outside 00001-$split_count_text"
        }
        [[ -z "${shard_for_index[$candidate_index]+present}" ]] || {
            rocm4gb_die "duplicate GGUF shard index: $candidate_index_text"
        }
        shard_for_index[$candidate_index]=$candidate
    done < <(find -H "$model_dir" -mindepth 1 -maxdepth 1 -print0 | sort -z)

    rocm4gb_model_shards=()
    rocm4gb_model_resolved_shards=()
    for ((index = 1; index <= split_count; index++)); do
        printf -v expected_name '%s-%05d-of-%s.gguf' \
            "$split_prefix" "$index" "$split_count_text"
        [[ -n "${shard_for_index[$index]+present}" ]] || {
            rocm4gb_die "missing GGUF shard: $expected_name"
        }
        shard=${shard_for_index[$index]}
        [[ "$(basename -- "$shard")" == "$expected_name" ]] || {
            rocm4gb_die "non-canonical GGUF shard name: $(basename -- "$shard")"
        }
        resolved=$(rocm4gb_resolve_model_file "$shard")
        identity=$(stat -Lc '%d:%i' -- "$resolved") || {
            rocm4gb_die "cannot stat resolved model shard: $resolved"
        }
        if [[ -n "${target_for_identity[$identity]+present}" ]]; then
            prior=${target_for_identity[$identity]}
            rocm4gb_die \
                "duplicate GGUF shard target: $(basename -- "$prior") and $(basename -- "$shard")"
        fi
        target_for_identity[$identity]=$shard
        rocm4gb_model_shards+=("$shard")
        rocm4gb_model_resolved_shards+=("$resolved")
    done

    rocm4gb_model_resolved_path=${rocm4gb_model_resolved_shards[0]}
}
