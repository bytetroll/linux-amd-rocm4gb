#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/common.sh
source "$script_dir/scripts/common.sh"

readonly project_version='0.1.1'
readonly llama_repository='https://github.com/ggml-org/llama.cpp.git'
readonly llama_commit='666f8898a25a2d5e86cd53ea4dfa4e24e4426439'
readonly llama_tree='24dcdf0d96247e5e39a4ed18c6429eb5b35fd7b5'
readonly llama_build='b10469'
readonly patch_name='llama.cpp-b10469-staged-mmap.patch'
readonly patch_sha256='082ce61d9c2293960447016ce0f8d3ff6aeff9bbc318824089ec459640a25e77'
readonly llama_license_sha256='94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d'

mode='full'
prefix=$(rocm4gb_default_prefix)
source_dir=''
backend_dir=''
backend_action='link'
gpu_target='gfx1151'
jobs=1
with_server=false
create_links=true
offline=false
runtime_lib_dirs=()

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Build and install the pinned staged-mmap llama.cpp workaround in isolation.

Options:
  --mode full|reuse       full: compile the HIP backend; reuse: use an exact-build
                          libggml-hip.so from --backend-dir (default: full)
  --prefix DIR            install root (default: XDG data home)
  --source-dir DIR        clone from a local llama.cpp repository instead of GitHub
  --backend-dir DIR       existing exact b10469 binary directory for reuse mode
  --copy-backend          copy/reflink libggml-hip.so instead of linking it
  --runtime-lib-dir DIR   runtime library directory to add; may be repeated
  --gpu-target GFX        HIP target for full mode (default: gfx1151)
  --jobs N                parallel build jobs (default: 1; raise only with cooling headroom)
  --with-server           also build and install llama-server
  --no-link               do not create launchers under ~/.local/bin
  --offline               require local source and disable Git lazy fetching
  -h, --help              show this help

The reuse mode is ABI-sensitive. The backend must come from llama.cpp b10469,
commit 666f8898a25a2d5e86cd53ea4dfa4e24e4426439.
EOF
}

while (($#)); do
    case "$1" in
        --mode)
            (($# >= 2)) || rocm4gb_die '--mode requires a value'
            mode=$2
            shift 2
            ;;
        --prefix)
            (($# >= 2)) || rocm4gb_die '--prefix requires a value'
            prefix=$2
            shift 2
            ;;
        --source-dir)
            (($# >= 2)) || rocm4gb_die '--source-dir requires a value'
            source_dir=$2
            shift 2
            ;;
        --backend-dir)
            (($# >= 2)) || rocm4gb_die '--backend-dir requires a value'
            backend_dir=$2
            mode='reuse'
            shift 2
            ;;
        --copy-backend)
            backend_action='copy'
            shift
            ;;
        --runtime-lib-dir)
            (($# >= 2)) || rocm4gb_die '--runtime-lib-dir requires a value'
            runtime_lib_dirs+=("$2")
            shift 2
            ;;
        --gpu-target)
            (($# >= 2)) || rocm4gb_die '--gpu-target requires a value'
            gpu_target=$2
            shift 2
            ;;
        --jobs)
            (($# >= 2)) || rocm4gb_die '--jobs requires a value'
            jobs=$2
            shift 2
            ;;
        --with-server)
            with_server=true
            shift
            ;;
        --no-link)
            create_links=false
            shift
            ;;
        --offline)
            offline=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            rocm4gb_die "unknown option: $1"
            ;;
    esac
done

[[ "$mode" == 'full' || "$mode" == 'reuse' ]] || rocm4gb_die "invalid mode: $mode"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || rocm4gb_die '--jobs must be a positive integer'
[[ "$gpu_target" =~ ^gfx[0-9a-f]+$ ]] || rocm4gb_die "invalid AMD GPU target: $gpu_target"
[[ "$offline" == false || -n "$source_dir" ]] || rocm4gb_die '--offline requires --source-dir'

for required in awk chmod cmake c++ env find flock git grep install ldd ninja python3 readelf realpath sha256sum xargs; do
    rocm4gb_require_command "$required"
done

patch_file="$script_dir/patches/$patch_name"
[[ -f "$patch_file" ]] || rocm4gb_die "patch file not found: $patch_file"
actual_patch_sha=$(sha256sum "$patch_file" | awk '{print $1}')
[[ "$actual_patch_sha" == "$patch_sha256" ]] || {
    rocm4gb_die "patch checksum mismatch: expected $patch_sha256, got $actual_patch_sha"
}

if [[ -n "$source_dir" ]]; then
    source_dir=$(readlink -f -- "$source_dir")
    [[ "$(git -C "$source_dir" rev-parse --is-inside-work-tree 2>/dev/null || true)" == true ]] || {
        rocm4gb_die "not a Git work tree: $source_dir"
    }
fi

if [[ "$mode" == 'reuse' ]]; then
    [[ -n "$backend_dir" ]] || rocm4gb_die 'reuse mode requires --backend-dir'
    backend_dir=$(readlink -f -- "$backend_dir")
    [[ -f "$backend_dir/libggml-hip.so" ]] || {
        rocm4gb_die "libggml-hip.so not found under $backend_dir"
    }
fi

for index in "${!runtime_lib_dirs[@]}"; do
    runtime_lib_dirs[index]=$(readlink -f -- "${runtime_lib_dirs[index]}")
    [[ -d "${runtime_lib_dirs[index]}" ]] || {
        rocm4gb_die "runtime library directory not found: ${runtime_lib_dirs[index]}"
    }
done

mkdir -p -- "$(dirname -- "$prefix")"
prefix=$(realpath -m -- "$prefix")
rocm4gb_assert_safe_prefix "$prefix"
mkdir -p -- "$prefix"
# Lock the directory itself so a preplaced lock-file symlink cannot redirect a
# truncating open.  The descriptor remains open until this process exits.
exec {install_lock_fd}< "$prefix"
flock -n "$install_lock_fd" || rocm4gb_die "another install or rollback owns $prefix"
versions_dir="$prefix/versions"
[[ ! -L "$versions_dir" ]] || rocm4gb_die "refusing symlinked versions directory: $versions_dir"
mkdir -p -- "$versions_dir"
[[ "$(realpath -e -- "$versions_dir")" == "$versions_dir" ]] || {
    rocm4gb_die "versions directory escapes the canonical install prefix: $versions_dir"
}
for managed_link in current previous; do
    if [[ -e "$prefix/$managed_link" && ! -L "$prefix/$managed_link" ]]; then
        rocm4gb_die "$prefix/$managed_link exists and is not a symbolic link"
    fi
    if [[ -L "$prefix/$managed_link" ]]; then
        managed_target=$(readlink "$prefix/$managed_link")
        rocm4gb_resolve_managed_version "$prefix" "$managed_target" >/dev/null
    fi
done

work_root=$(mktemp -d "${TMPDIR:-/tmp}/linux-amd-rocm4gb.XXXXXXXX")
stage_dir=''
activation_link=''
previous_activation_link=''
cleanup() {
    rm -rf -- "$work_root"
    if [[ -n "$stage_dir" && -d "$stage_dir" && "$(basename -- "$stage_dir")" == .staging.* ]]; then
        rm -rf -- "$stage_dir"
    fi
    [[ -z "$activation_link" ]] || rm -f -- "$activation_link"
    [[ -z "$previous_activation_link" ]] || rm -f -- "$previous_activation_link"
}
trap cleanup EXIT INT TERM

source_checkout="$work_root/llama.cpp"
git_command=(git)
if [[ "$offline" == true ]]; then
    # Prevent a partial/promisor source checkout from fetching missing objects.
    git_command=(env GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 git)
fi
if [[ -n "$source_dir" ]]; then
    rocm4gb_note "cloning pinned source from $source_dir"
    "${git_command[@]}" clone --quiet --no-hardlinks --no-checkout "$source_dir" "$source_checkout"
else
    rocm4gb_note "cloning pinned source from $llama_repository"
    "${git_command[@]}" clone --quiet --filter=blob:none --no-checkout "$llama_repository" "$source_checkout"
fi

"${git_command[@]}" -C "$source_checkout" checkout --quiet --detach "$llama_commit"
actual_commit=$("${git_command[@]}" -C "$source_checkout" rev-parse HEAD)
[[ "$actual_commit" == "$llama_commit" ]] || rocm4gb_die "unexpected llama.cpp commit: $actual_commit"
actual_tree=$("${git_command[@]}" -C "$source_checkout" rev-parse 'HEAD^{tree}')
[[ "$actual_tree" == "$llama_tree" ]] || rocm4gb_die "unexpected llama.cpp tree: $actual_tree"
(
    cd -- "$source_checkout"
    printf '%s  %s\n' \
        "$llama_license_sha256" LICENSE \
        1ad62ec289374fa0282e27fae17464fd48c6198f54ab30e3e2f5c8d684af8049 src/llama-model-loader.cpp \
        9368fc4f1420ee41c56af4c229e72dc7b0dad2b7a2c9bd391d5144145e73de3b src/llama-model-loader.h \
        7b8f526f1c468b1541fb9427264c63d7a2a6ca2dd0b42a08f58530a90f03ddef src/llama-model.cpp \
        20c1373cacd1295993f90e2bef4a796efb353f96746d925f7f6f5798802b90ba tools/server/server-models.cpp \
        b325e1eaac8c1738a9063fdc61043d10b364522c93c78b450a7695bf3d74a72f tools/server/server-models.h \
        4c84ca508972f485a62bd9b8afc98227b816ea0966c8eb5cbb03dac75205dbfe tools/server/tests/unit/test_router.py \
        | sha256sum --check --quiet
)
git -C "$source_checkout" apply --check "$patch_file"
git -C "$source_checkout" apply "$patch_file"
git -C "$source_checkout" diff --check
actual_changed_files=$(git -C "$source_checkout" diff --name-only | sort)
expected_changed_files=$(printf '%s\n' \
    src/llama-model-loader.cpp \
    src/llama-model-loader.h \
    src/llama-model.cpp \
    tools/server/server-models.cpp \
    tools/server/server-models.h \
    tools/server/tests/unit/test_router.py | sort)
[[ "$actual_changed_files" == "$expected_changed_files" ]] || {
    rocm4gb_die 'the patch changed files outside the pinned allowlist'
}
(
    cd -- "$source_checkout"
    printf '%s  %s\n' \
        e389a8f63ff775f60524cc1a7758ba9d702c47cf6797cefd7b0eaa39049b8734 src/llama-model-loader.cpp \
        d2c5d2a5b94569bebe0fd8685d8b8249562c8fd1c48a848cc569f094d335a787 src/llama-model-loader.h \
        ed68fed8e92f66fff43a6a9837b4ef266b748b75ddeb32f18bcbdb720d16e4d1 src/llama-model.cpp \
        4d6def543c07c462180de35289f78680ee236c39047c71321d61347a32b50319 tools/server/server-models.cpp \
        27f47fc7d9f6364790629c983f85ed6e5dc1d6a302a1cfc11da428c46b3ce406 tools/server/server-models.h \
        c2a61ab516bd341051a726b2b01b442f602389d900c88d66dc8d3ed64e537ca9 tools/server/tests/unit/test_router.py \
        | sha256sum --check --quiet
)

build_dir="$work_root/build"
cmake_args=(
    -S "$source_checkout"
    -B "$build_dir"
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=ON
    -DGGML_BACKEND_DL=ON
    -DGGML_NATIVE=OFF
    -DGGML_CPU_ALL_VARIANTS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_BUILD_APP=OFF
    -DLLAMA_BUILD_UI=OFF
    # At pinned b10469, tools/cli is added under LLAMA_BUILD_SERVER even when
    # only the llama-cli target is requested.
    -DLLAMA_BUILD_SERVER=ON
)

if [[ "$mode" == 'full' ]]; then
    cmake_args+=( -DGGML_HIP=ON "-DAMDGPU_TARGETS=$gpu_target" )
else
    cmake_args+=( -DGGML_HIP=OFF )
fi

rocm4gb_note "configuring llama.cpp $llama_build ($mode mode)"
cmake "${cmake_args[@]}"
build_targets=(llama-cli)
if [[ "$with_server" == true ]]; then
    build_targets+=(llama-server)
fi
python3 "$script_dir/scripts/thermal_guard.py" \
    --start-max-c 70 --warn-c 75 --critical-c 90 --poll-seconds 0.25 -- \
    cmake --build "$build_dir" --target "${build_targets[@]}" -- -j"$jobs"

stage_dir=$(mktemp -d "$versions_dir/.staging.XXXXXXXX")
mkdir -p -- "$stage_dir/bin" "$stage_dir/libexec" "$stage_dir/licenses" "$stage_dir/patches" "$stage_dir/profiles"
cp -a -- "$build_dir/bin/." "$stage_dir/libexec/"
install -m 0755 "$script_dir/scripts/launcher.sh" "$stage_dir/bin/llama-rocm4gb"
install -m 0644 "$script_dir/LICENSE" "$stage_dir/LICENSE"
install -m 0644 "$script_dir/NOTICE" "$stage_dir/NOTICE"
install -m 0644 "$script_dir/licenses/llama.cpp-MIT.txt" "$stage_dir/licenses/llama.cpp-MIT.txt"
install -m 0644 "$patch_file" "$stage_dir/patches/$patch_name"
install -m 0644 "$script_dir/profiles/llama-b10469-gfx1151-rocm7.json" \
    "$stage_dir/profiles/llama-b10469-gfx1151-rocm7.json"
if [[ "$with_server" == true ]]; then
    ln -s llama-rocm4gb "$stage_dir/bin/llama-server-rocm4gb"
fi

if [[ "$mode" == 'reuse' ]]; then
    if [[ "$backend_action" == 'copy' ]]; then
        cp --reflink=auto --preserve=mode,timestamps \
            "$backend_dir/libggml-hip.so" "$stage_dir/libexec/libggml-hip.so"
    else
        ln -s "$backend_dir/libggml-hip.so" "$stage_dir/libexec/libggml-hip.so"
    fi
fi
[[ -f "$stage_dir/libexec/libggml-hip.so" ]] || {
    rocm4gb_die 'the completed build does not contain libggml-hip.so'
}

: > "$stage_dir/runtime-lib-dirs"
for directory in "${runtime_lib_dirs[@]}"; do
    printf '%s\n' "$directory" >> "$stage_dir/runtime-lib-dirs"
done

runtime_path=$(rocm4gb_join_colon "$stage_dir/libexec" "${runtime_lib_dirs[@]}")
if [[ -f "$stage_dir/libexec/libggml-hip.so" ]]; then
    if ! LD_LIBRARY_PATH=$runtime_path ldd -r "$stage_dir/libexec/libggml-hip.so" \
        > "$stage_dir/backend-link-audit.txt" 2>&1; then
        cat "$stage_dir/backend-link-audit.txt" >&2
        rocm4gb_die 'HIP backend dependency/ABI audit failed'
    fi
    if grep -Eq 'not found|undefined symbol' "$stage_dir/backend-link-audit.txt"; then
        cat "$stage_dir/backend-link-audit.txt" >&2
        rocm4gb_die 'HIP backend has an unresolved dependency or symbol'
    fi
fi

backend_sha256=$(sha256sum "$stage_dir/libexec/libggml-hip.so" | awk '{print $1}')

cat > "$stage_dir/build-info.txt" <<EOF
schema_version=1
project_version=$project_version
llama_repository=$llama_repository
llama_commit=$llama_commit
llama_tree=$llama_tree
llama_build=$llama_build
patch_sha256=$patch_sha256
llama_license_sha256=$llama_license_sha256
mode=$mode
with_server=$with_server
gpu_target=$gpu_target
backend_action=$backend_action
backend_dir=$backend_dir
backend_sha256=$backend_sha256
EOF

# Exercise the exact launcher and persisted runtime path from a clean shell
# before making this version current.  In particular, do not let the
# installer's ambient LD_LIBRARY_PATH hide an omitted --runtime-lib-dir.
if ! env -u LD_LIBRARY_PATH LC_ALL=C "$stage_dir/bin/llama-rocm4gb" --version \
    > "$stage_dir/launcher-smoke-test.txt" 2>&1; then
    cat "$stage_dir/launcher-smoke-test.txt" >&2
    rocm4gb_die 'staged launcher failed its clean-environment smoke test'
fi
if ! env -u LD_LIBRARY_PATH LC_ALL=C "$stage_dir/bin/llama-rocm4gb" --list-devices \
    > "$stage_dir/device-smoke-test.txt" 2>&1; then
    cat "$stage_dir/device-smoke-test.txt" >&2
    rocm4gb_die 'staged launcher could not enumerate devices'
fi
if ! grep -Eq '^[[:space:]]+ROCm[0-9]+:' "$stage_dir/device-smoke-test.txt"; then
    cat "$stage_dir/device-smoke-test.txt" >&2
    rocm4gb_die 'staged HIP backend did not expose a ROCm device'
fi

# Build tools honor the caller's umask, which is commonly 0002 on development
# hosts. Normalize the immutable payload before hashing it so an attesting
# service never has to trust group/world-writable code or libraries.
find "$stage_dir" -type d -exec chmod 0755 {} +
find "$stage_dir" -type f -perm /111 -exec chmod 0755 {} +
find "$stage_dir" -type f ! -perm /111 -exec chmod 0644 {} +

manifest_file="$work_root/manifest.sha256"
(
    cd -- "$stage_dir"
    find -L . -type f -print0 \
        | sort -z \
        | xargs -0 sha256sum > "$manifest_file"
)
install -m 0644 "$manifest_file" "$stage_dir/manifest.sha256"

artifact_manifest_sha256=$(sha256sum "$stage_dir/manifest.sha256" | awk '{print $1}')
artifact_fingerprint=${artifact_manifest_sha256:0:12}
version_name="llama-$llama_build-staged-mmap-v1-$mode-$artifact_fingerprint"
version_dir="$versions_dir/$version_name"
[[ ! -e "$version_dir" ]] || {
    rocm4gb_die "this artifact is already installed: $version_dir"
}
mv -T -- "$stage_dir" "$version_dir"
stage_dir=''
if [[ -L "$prefix/current" ]]; then
    old_target=$(readlink "$prefix/current")
    rocm4gb_resolve_managed_version "$prefix" "$old_target" >/dev/null
    previous_activation_link="$prefix/.previous.install.$$"
    ln -s -- "$old_target" "$previous_activation_link"
    mv -Tf -- "$previous_activation_link" "$prefix/previous"
    previous_activation_link=''
fi
activation_link="$prefix/.current.install.$$"
ln -s -- "versions/$version_name" "$activation_link"
mv -Tf -- "$activation_link" "$prefix/current"
activation_link=''

if [[ "$create_links" == true ]]; then
    user_bin="${HOME}/.local/bin"
    if ! mkdir -p -- "$user_bin"; then
        rocm4gb_note "could not create optional launcher directory: $user_bin"
    else
        link_launchers=(llama-rocm4gb)
        if [[ "$with_server" == true ]]; then
            link_launchers+=(llama-server-rocm4gb)
        fi
        for launcher in "${link_launchers[@]}"; do
            destination="$user_bin/$launcher"
            if [[ -e "$destination" && ! -L "$destination" ]]; then
                rocm4gb_note "not replacing non-symlink launcher: $destination"
                continue
            fi
            if ! ln -sfn -- "$prefix/current/bin/$launcher" "$destination"; then
                rocm4gb_note "could not create optional launcher: $destination"
            fi
        done
    fi
fi

rocm4gb_note "installed $version_name under $version_dir"
rocm4gb_note "manifest sha256: $artifact_manifest_sha256"
rocm4gb_note "version root: $version_dir"
rocm4gb_note "run: $prefix/current/bin/llama-rocm4gb --version"
rocm4gb_note 'the original ROCm installation and llama.cpp binaries were not modified'
