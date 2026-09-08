# Validation protocol

`./rocm4gb verify` automates the minimum acceptance test. It labels a successful
run `PASS` only when the aggregate GGUF file size exceeds its estimated KFD
user-memory ceiling. A successful model at or below that ceiling is `SMOKE`,
including every model admitted by `--allow-small`; it does not reproduce the
allocation pressure that this workaround is meant to avoid. Runtime or safety
failures always produce `FAIL`. Supplying `--allow-small` explicitly caps the
result at `SMOKE`, regardless of file size.

For Linux 6.17, the verifier reproduces the kernel formula—63/64 of
`totalram - totalhigh`, less 1.5 GiB when that intermediate value is at least
3 GiB, otherwise halved—and approximates its input with `/proc/meminfo`'s
`MemTotal`. That is an unprivileged estimate, not a stable kernel ABI; record it
and recheck the formula when qualifying another kernel family.

A promotable hardware result must satisfy all of these conditions:

1. `no_system_mem_limit` is readable and remains disabled (`N` or `0`).
2. `/dev/kfd` has no user before launch, exactly one AMD DRM device exposes the
   required counters, and Tctl is at or below 65 °C.
3. The command explicitly uses mmap, disables fit and repacking, and requests
   every model layer on the iGPU.
4. Every layer reports as offloaded.
5. The verbose log contains `using async uploads for device ROCm0`.
6. Peak process RSS remains below 4 GiB and no swap I/O occurs.
7. The verbose timing record proves that one or more tokens were generated,
   the loaded-model marker names the requested logical model, and the process
   exits normally.
8. A readable kernel-journal cursor and post-run delta are available, and that
   delta has no SVM restore/mapping error, GPU fault, ring timeout, or reset.
9. VRAM returns to within 256 MiB of baseline within 60 seconds.
10. Tctl never reaches the 90 °C process-group cutoff.

For split GGUFs, pass the logical `00001-of-NNNNN.gguf` path. The verifier
accepts Hugging Face snapshot symlinks, requires exactly the indices 1 through
N with one consistent total, rejects duplicate resolved targets, and sizes the
canonical regular-file targets. The original logical first-shard path remains
the one supplied to `llama.cpp`.

The qualification command is fixed: arbitrary trailing `llama.cpp` arguments
are rejected so they cannot replace the model, reduce generation to zero, or
override mmap/offload safety flags. GNU `time` runs under `LC_ALL=C`, and a
missing or non-numeric peak-RSS field is a failure rather than being treated as
zero. Evidence is written only to a newly and exclusively created private
directory; explicit output paths must not exist.

For release-quality evidence, repeat a candidate three times and compare its
deterministic token sequence with the same patched binary using direct I/O.
Token IDs should match exactly. When comparing top-log-probabilities, define and
record a numerical tolerance appropriate to the backend (typically `1e-5` to
`1e-4`).

Do not compare load time across different storage devices. A staged upload from
an external rotating disk can be storage-bound even when the ROCm path is
healthy.
