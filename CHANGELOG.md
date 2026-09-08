# Changelog

## 0.1.1 — 2026-09-08

- Make single-resident llama.cpp router eviction and request admission atomic.
- Queue and replay late requests for a model already reserved as an LRU victim.
- Route `/models/load` through the capacity-aware scheduler and prevent stale
  direct-load waiters from hanging across a same-name model reload.
- Add a deterministic two-model handoff regression using llama.cpp's tiny test
  models.
- Record server inclusion and copied-backend identity in `build-info.txt`, and
  print the immutable version root plus its full manifest digest.

## 0.1.0 — 2026-09-08

- Pin llama.cpp b10469 (`666f8898a`).
- Backport staged mmap uploads from PR #26023.
- Add isolated full-HIP and exact-backend-reuse installers.
- Add atomic activation and project-owned rollback.
- Add host diagnostics and guarded large-model verification.
- Preserve logical Hugging Face model paths while strictly validating split
  shard names and resolved targets.
- Distinguish below-limit `SMOKE` runs from above-limit qualification `PASS`
  results using the Linux 6.17 KFD memory-limit estimate.
- Make qualification arguments fixed, require generation/model/RSS and kernel
  evidence, fail closed on an unproven KFD limit, and create evidence paths
  exclusively.
- Record successful 34.36 GiB and 78.99 GiB gfx1151/ROCm 7.14 qualifications.
