#!/usr/bin/env bash

set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source_dir=''
if (($#)); then
    [[ "$1" == '--source-dir' && $# -eq 2 ]] || {
        printf 'usage: tests/smoke.sh [--source-dir LLAMA_CPP]\n' >&2
        exit 2
    }
    source_dir=$2
fi

for script in \
    "$project_root/rocm4gb" \
    "$project_root/install.sh" \
    "$project_root/verify.sh" \
    "$project_root/doctor.sh" \
    "$project_root/rollback.sh" \
    "$project_root/scripts/common.sh" \
    "$project_root/scripts/launcher.sh" \
    "$project_root/scripts/model_paths.sh" \
    "$project_root/scripts/verify_helpers.sh" \
    "$project_root/tests/verify-helpers.sh" \
    "$project_root/tests/verify-model-paths.sh"; do
    bash -n "$script"
done
python3 -m py_compile "$project_root/scripts/thermal_guard.py"
python3 -m json.tool "$project_root/profiles/llama-b10469-gfx1151-rocm7.json" >/dev/null

PROJECT_ROOT="$project_root" python3 - <<'PY'
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

module_path = Path(os.environ["PROJECT_ROOT"]) / "scripts" / "thermal_guard.py"
spec = importlib.util.spec_from_file_location("thermal_guard", module_path)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="rocm4gb-pgid-test.") as directory:
    pid_file = Path(directory) / "child.pid"
    child_code = """
import os
import signal
import sys
import time
from pathlib import Path

signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
os.setpgid(0, 0)
Path(sys.argv[1]).write_text(f"{os.getpid()} {os.getpgrp()}", encoding="utf-8")
time.sleep(30)
"""
    leader_code = """
import subprocess
import sys

subprocess.Popen([sys.executable, "-c", sys.argv[1], sys.argv[2]])
"""
    leader = subprocess.Popen(
        [sys.executable, "-c", leader_code, child_code, str(pid_file)],
        start_new_session=True,
    )
    for _ in range(100):
        if pid_file.exists() and leader.poll() is not None:
            break
        time.sleep(0.01)
    child_pid_text, child_group_text = pid_file.read_text(encoding="utf-8").split()
    child_pid = int(child_pid_text)
    child_group = int(child_group_text)
    assert child_group != leader.pid, "fixture descendant did not change process groups"
    module.stop_group(leader, 0.1)
    # A killed orphan can remain as a zombie until PID 1 reaps it, so require
    # the separate-group descendant to be gone or non-runnable.
    for _ in range(100):
        status = Path(f"/proc/{child_pid}/status")
        if not status.exists():
            break
        try:
            state = status.read_text(encoding="utf-8")
        except FileNotFoundError:
            break
        if "State:\tZ" in state:
            break
        time.sleep(0.01)
    else:
        raise AssertionError("TERM-ignoring descendant remained runnable")
PY

(
    cd -- "$project_root"
    sha256sum --check SHA256SUMS
)

"$project_root/rocm4gb" help >/dev/null
"$project_root/install.sh" --help >/dev/null
"$project_root/verify.sh" --help >/dev/null
"$project_root/scripts/thermal_guard.py" --help >/dev/null
"$project_root/tests/verify-helpers.sh" >/dev/null
"$project_root/tests/verify-model-paths.sh" >/dev/null

rollback_root=$(mktemp -d "${TMPDIR:-/tmp}/rocm4gb-rollback-test.XXXXXXXX")
patch_root=''
cleanup() {
    rm -rf -- "$rollback_root"
    [[ -z "$patch_root" ]] || rm -rf -- "$patch_root"
}
trap cleanup EXIT INT TERM
mkdir -p "$rollback_root/versions/one" "$rollback_root/versions/two"
for version in one two; do
    mkdir -p "$rollback_root/versions/$version/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$rollback_root/versions/$version/bin/llama-rocm4gb"
    chmod 0755 "$rollback_root/versions/$version/bin/llama-rocm4gb"
    (
        cd "$rollback_root/versions/$version"
        sha256sum bin/llama-rocm4gb > manifest.sha256
    )
done
ln -s versions/two "$rollback_root/current"
ln -s versions/one "$rollback_root/previous"
"$project_root/rollback.sh" --prefix "$rollback_root" >/dev/null
[[ "$(readlink "$rollback_root/current")" == 'versions/one' ]]
[[ "$(readlink "$rollback_root/previous")" == 'versions/two' ]]

if [[ -n "$source_dir" ]]; then
    source_dir=$(readlink -f -- "$source_dir")
    patch_root=$(mktemp -d "${TMPDIR:-/tmp}/rocm4gb-patch-test.XXXXXXXX")
    git clone --quiet --no-hardlinks --no-checkout "$source_dir" "$patch_root/llama.cpp"
    git -C "$patch_root/llama.cpp" checkout --quiet --detach \
        666f8898a25a2d5e86cd53ea4dfa4e24e4426439
    [[ "$(git -C "$patch_root/llama.cpp" rev-parse 'HEAD^{tree}')" == \
       '24dcdf0d96247e5e39a4ed18c6429eb5b35fd7b5' ]]
    git -C "$patch_root/llama.cpp" apply --check \
        "$project_root/patches/llama.cpp-b10469-staged-mmap.patch"
    git -C "$patch_root/llama.cpp" apply \
        "$project_root/patches/llama.cpp-b10469-staged-mmap.patch"
    git -C "$patch_root/llama.cpp" diff --check
    actual_files=$(git -C "$patch_root/llama.cpp" diff --name-only | sort)
    expected_files=$(printf '%s\n' \
        src/llama-model-loader.cpp \
        src/llama-model-loader.h \
        src/llama-model.cpp \
        tools/server/server-models.cpp \
        tools/server/server-models.h \
        tools/server/tests/unit/test_router.py | sort)
    [[ "$actual_files" == "$expected_files" ]]
    (
        cd "$patch_root/llama.cpp"
        printf '%s  %s\n' \
            e389a8f63ff775f60524cc1a7758ba9d702c47cf6797cefd7b0eaa39049b8734 \
            src/llama-model-loader.cpp \
            d2c5d2a5b94569bebe0fd8685d8b8249562c8fd1c48a848cc569f094d335a787 \
            src/llama-model-loader.h \
            ed68fed8e92f66fff43a6a9837b4ef266b748b75ddeb32f18bcbdb720d16e4d1 \
            src/llama-model.cpp \
            4d6def543c07c462180de35289f78680ee236c39047c71321d61347a32b50319 \
            tools/server/server-models.cpp \
            27f47fc7d9f6364790629c983f85ed6e5dc1d6a302a1cfc11da428c46b3ce406 \
            tools/server/server-models.h \
            c2a61ab516bd341051a726b2b01b442f602389d900c88d66dc8d3ed64e537ca9 \
            tools/server/tests/unit/test_router.py | sha256sum --check --quiet
    )
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck \
        "$project_root/rocm4gb" \
        "$project_root/install.sh" \
        "$project_root/verify.sh" \
        "$project_root/doctor.sh" \
        "$project_root/rollback.sh" \
        "$project_root/scripts/common.sh" \
        "$project_root/scripts/launcher.sh" \
        "$project_root/scripts/model_paths.sh" \
        "$project_root/scripts/verify_helpers.sh" \
        "$project_root/tests/verify-helpers.sh" \
        "$project_root/tests/verify-model-paths.sh" \
        "$project_root/tests/smoke.sh"
fi

printf 'smoke tests passed\n'
