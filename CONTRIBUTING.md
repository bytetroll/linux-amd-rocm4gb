# Contributing

Contributions are welcome under the MIT License.

For a new llama.cpp revision or AMD iGPU profile, include:

- the exact source commit and tree IDs;
- hashes before and after every patched file;
- a canonical patch hash and upstream provenance;
- a clean CPU build in CI;
- hardware evidence following `docs/validation.md`;
- confirmation that the stock KFD memory limit remained enabled.

Do not weaken the thermal, exclusive-device, kernel-log, swap, or full-offload
gates merely to turn a failed qualification green. Document an unsupported path
instead.
