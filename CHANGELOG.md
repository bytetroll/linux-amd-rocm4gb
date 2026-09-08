# Changelog

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
