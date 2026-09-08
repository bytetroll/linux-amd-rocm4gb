# Design

## Failure chain

On the reference Strix Halo system, Linux exposes roughly 32 GiB as ordinary
system RAM and 96 GiB as GPU-visible VRAM. KFD calculates its user-memory limit
from Linux-visible system RAM, not from the large VRAM carveout. With XNACK
disabled, a large SVM/userptr registration is charged by virtual range size.

The unpatched mmap upload path can pass pages from the model's large file-backed
mapping into HIP. Once the charged range exceeds KFD's system-memory allowance,
allocation fails. If an MMU invalidation has already evicted KFD queues,
`svm_range_restore_work` retries failed restoration repeatedly and the loader
appears frozen.

The kernel exposes `no_system_mem_limit`, but bypassing the limit removes an
oversubscription guard that was deliberately added for XNACK-off devices. This
project leaves that limit enabled.

## Userspace mitigation

The backport selects staged mmap uploads only when every model layer and the
output layer target an integrated GPU whose backend supports:

- asynchronous tensor uploads;
- pinned host buffers;
- backend events.

For eligible GPU buffers, tensor bytes are read from the GGUF file into four
small pinned buffers and copied asynchronously to the device. Events prevent a
buffer from being reused until its preceding upload is complete. Whole-file
prefetch is disabled for this path.

Host-resident buffers retain the synchronous fallback. That is why a valid
verbose log can contain both:

```text
staged mmap uploads unavailable, using synchronous fallback
using async uploads for device ROCm0
```

The first line may describe a small CPU-mapped context; qualification requires
the second line for the ROCm model buffer.

## Isolation

`install.sh` clones the exact source into a private temporary directory, checks
out a detached pinned commit, verifies the patch hash, applies it after
`git apply --check`, and builds out of tree. Artifacts are staged under a
project-owned version directory and activated with a symbolic link.

Neither full nor reuse mode edits the source/backend supplied by the user.
Reuse mode links or copies only `libggml-hip.so`, then runs `ldd -r` against the
new generic libraries and requested ROCm runtime paths.

## Upstream relationship

The implementation is backported from `liminfei-amd`'s llama.cpp PR #26023,
commit `f5f4f66675196809a4b816315cdc1173862b14a3`. The pull request was closed
without merge while maintainers pursued a different automatic load-mode
direction. Its staged implementation was experimentally successful; this
project pins it so that result is reproducible while the kernel issue remains.
