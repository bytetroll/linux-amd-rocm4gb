# Supported matrix

## Qualified profile

| Component | Qualified value |
|---|---|
| llama.cpp | b10469, commit `666f8898a25a2d5e86cd53ea4dfa4e24e4426439` |
| GPU | AMD Radeon 8060S / `gfx1151` integrated GPU |
| Runtime | TheRock ROCm 7.14 libraries |
| Kernel | Ubuntu OEM Linux 6.17 |
| XNACK | Disabled |
| Topology | 96 GiB GPU-visible carveout, about 32 GiB Linux-visible RAM |
| Load | All layers on one iGPU; mmap; no repack; fit disabled |

Other AMD integrated GPUs and ROCm 7.x builds may work but are unqualified until
their results reproduce the validation protocol. Discrete GPUs are intentionally
excluded from the staged mmap selection in this patch. The v0.1 verifier is
deliberately limited to a host with one counter-bearing AMD DRM device; it
refuses ambiguous multi-GPU telemetry instead of guessing which card is
`ROCm0`.

## Capacity

The patch avoids an oversized SVM registration; it does not create memory.
Before loading, require:

```text
GGUF tensor payload + idle VRAM + KV + measured compute + safety margin
    <= GPU-visible physical pool
```

Use at least an 8 GiB safety margin until the model architecture's compute
buffers have been measured. A 72B BF16 model is roughly 134 GiB before runtime
overhead and cannot fit in a 96 GiB pool; a suitable Q8/Q6/Q5 quant may fit.

## Paths that do not qualify

- partial CPU/GPU layer splits;
- `--mlock`;
- `--check-tensors` during the qualification load;
- CPU MoE offload;
- weight repacking that needs a second large allocation;
- multiple concurrent KFD clients;
- backends without async copies, pinned host buffers, or events.

Validate GGUF structure and checksums separately before the GPU test. For split
models, every shard must be present and the first shard must be passed to the
loader. Snapshot symlinks are valid, but their resolved targets must be regular,
unique files and the logical sibling names must form the exact sequence
`00001-of-N` through `N-of-N` with one consistent total.
