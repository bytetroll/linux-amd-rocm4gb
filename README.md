# linux-amd-rocm4gb

An isolated, reproducible userspace workaround for large mmap-backed GGUF
uploads that can stall `llama.cpp` on AMD integrated GPUs under Linux.

The first supported profile pins `llama.cpp` build **b10469** and backports the
staged upload implementation from AMD engineer `liminfei-amd`'s
[llama.cpp PR #26023](https://github.com/ggml-org/llama.cpp/pull/26023). Instead
of handing a huge file-backed mapping to HIP, qualifying full-iGPU loads stream
tensor data through a small ring of pinned host buffers. This avoids the KFD SVM
accounting path that can strand queues in `svm_range_restore_work`.

This project never changes the kernel, sysfs, ROCm, or an existing `llama.cpp`
installation. It builds a versioned copy and exposes it as `llama-rocm4gb`.

## What this is—and is not

This is currently a **pinned `llama.cpp` loader workaround** for integrated AMD
GPUs that provide asynchronous uploads, host buffers, and events. It is not:

- a Linux kernel or ROCm-wide fix;
- a universal threshold of exactly 4 GiB;
- NPU acceleration or an inference-kernel speedup;
- permission to oversubscribe physical GPU-visible memory;
- a fix for partial offload, `mlock`, `--check-tensors`, or incompatible
  backends.

The actual failure threshold depends on Linux-visible RAM, KFD accounting,
memory topology, and the loader path. The repository name follows the community
shorthand for this problem; the tested failure on the reference machine began
when a 34.36 GiB model exceeded a 29.13 GiB KFD user-memory limit.

## Quick start

Inspect the machine without changing it:

```bash
./rocm4gb doctor
```

Build the pinned source with an installed ROCm development toolchain:

```bash
./rocm4gb install --mode full --gpu-target gfx1151
```

The installer is unprivileged. It defaults to
`$XDG_DATA_HOME/linux-amd-rocm4gb` (or
`$HOME/.local/share/linux-amd-rocm4gb`) and creates a unique
`$HOME/.local/bin/llama-rocm4gb` link when that path is available. It will not
replace a regular file at that location.

Then qualify a model with forced mmap and full GPU offload:

```bash
./rocm4gb verify --model /path/to/model.gguf
```

For a split GGUF, pass only its `00001-of-NNNNN.gguf` shard. Hugging Face
snapshot symlinks are supported: the named snapshot path is passed to
`llama.cpp`, while every resolved shard target is validated separately.
Verification refuses missing, duplicated, inconsistently numbered, or broken
shards, a busy `/dev/kfd`, a hot start, or an enabled `no_system_mem_limit`
bypass. The v0.1 evidence collector also requires exactly one AMD DRM device
with readable VRAM/GTT counters so it cannot silently sample a different GPU
than `ROCm0`.

A clean run reports `PASS` only when the total GGUF payload exceeds the host's
estimated KFD user-memory limit. A smaller successful run reports `SMOKE`, even
with `--allow-small`; explicitly passing `--allow-small` always caps the result
at `SMOKE`. Such a run exercises the loader but cannot prove that the staged
path avoided the oversized-registration failure. On Linux 6.17 the estimate
uses the kernel's limit formula with `/proc/meminfo`'s `MemTotal` as an
unprivileged x86 approximation. The estimate, model's logical and resolved
paths, command, logs, thermal and VRAM/GTT samples, kernel and swap deltas, and
result are retained as evidence. Default evidence directories have a random
suffix and are created privately; an explicit `--output` path must not already
exist. Qualification uses one fixed command, so pass custom `llama.cpp`
arguments directly to `llama-rocm4gb` only for non-qualification experiments.
Both `PASS` and `SMOKE` exit successfully; `FAIL` exits nonzero.

## Reusing an exact existing HIP backend

Compiling a 1+ GiB HIP plugin is slow. If an existing backend was built from
the exact pinned commit, the front end can be rebuilt and the backend reused:

```bash
./rocm4gb install \
  --mode reuse \
  --backend-dir /path/to/exact-b10469/bin \
  --runtime-lib-dir /path/to/rocm/core/lib \
  --runtime-lib-dir /path/to/rocm/core/lib/llvm/lib \
  --runtime-lib-dir /path/to/rocm/libraries/lib
```

Reuse mode performs an ELF dependency/symbol audit but cannot prove semantic
ABI compatibility. Use only an exact b10469 backend. By default it links the
plugin, leaving the original untouched; `--copy-backend` makes the installed
version independent at the cost of roughly 1.2 GiB.

## Safety choices

- No `sudo` and no package installation.
- No writes to `/sys/module/amdgpu/parameters/no_system_mem_limit`.
- No kernel modules, DKMS packages, boot changes, or ROCm replacement.
- No mutation of the supplied source/backend directory.
- Exact source commit, tree, license, patch, and changed-file hashes are pinned.
- Builds happen in a private temporary checkout and install atomically under a
  project-owned prefix.
- Builds default to one parallel job and refuse to start above 70 °C; a Tctl
  watchdog terminates the entire build or qualification process group at
  90 °C by default.
- Existing GPU clients are not killed; hardware verification refuses to start.
- `llama-server` is opt-in via `--with-server` and is never started by the
  installer.

## Reference result

The initial hardware qualification used a Ryzen AI MAX+ / Radeon 8060S
(`gfx1151`), Linux 6.17, ROCm 7.14, 96 GiB GPU-visible carveout, and 32 GiB
Linux-visible RAM. The stock KFD limit remained enabled.

| Model | GGUF payload | GPU layers | Peak RSS | Peak VRAM | End-to-end | Generation | Kernel faults |
|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen3.6-35B-A3B Q8_0 | 34.36 GiB | 41/41 | 679.5 MiB | 35.56 GiB | 11.79 s | 35.9 t/s | 0 |
| Qwen3-Coder-Next 80B Q8 | 78.99 GiB | 49/49 | 675.4 MiB | 80.95 GiB | 22.83 s | 23.6 t/s | 0 |
| GPT-OSS-120B Fable-5 Q5 | 75.15 GiB | 37/37 | 598.96 MiB | 76.96 GiB | 34:45.75¹ | 31.15 t/s | 0 |

All three forced-mmap logs contained the ROCm asynchronous-upload marker, kept
process RSS below 700 MiB, completed generation, and produced no SVM restore,
allocation, GPU-fault, timeout, or reset messages. See
[the validation record](docs/results/2026-09-08-gfx1151.md).

¹ The Fable-5 GGUF was read from an external rotating disk; its wall time is
storage-bound and is not comparable to the two NVMe results.

## Building requirements

Both modes require:

- Bash 4.4+, Python 3.9+, Git, CMake, Ninja, a C++ compiler, GNU coreutils,
  `binutils`, `psmisc`, and GNU `time`;
- a Linux AMD iGPU supported by the selected ROCm runtime;
- enough GPU-visible physical memory for weights, KV cache, and compute buffers.

Full mode additionally requires ROCm development headers, libraries, and HIP
compiler configuration. The installer reports missing dependencies; it never
installs system packages itself.

## Rollback

Installs are versioned. When a second version becomes active, the prior target
is retained as `previous`:

```bash
./rocm4gb rollback
```

Rollback only swaps project-owned symbolic links. Your original runtime was
never replaced, so the simplest rollback is always to stop using
`llama-rocm4gb`.

## Documentation

- [Design and failure mechanism](docs/design.md)
- [Supported matrix and constraints](docs/supported-matrix.md)
- [Validation protocol](docs/validation.md)
- [Security policy](SECURITY.md)
- [Third-party attribution](NOTICE)

## License

Nathan Young's original installer, validation tooling, and documentation are
available under the [MIT License](LICENSE). The backported loader change derives
from MIT-licensed `llama.cpp`; its original author and source are preserved in
[NOTICE](NOTICE), and the upstream license is included under [licenses/](licenses/).
