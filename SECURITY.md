# Security policy

Please report a suspected command-injection, path-validation, symlink, unsafe
cleanup, or privilege-boundary issue through GitHub's private security advisory
feature rather than a public issue.

The installer is designed to run without privileges. A request for `sudo`, a
kernel module, a sysfs write, shell-startup modification, or automatic GPU
process termination is outside this project's threat model and should be
treated as a defect if introduced by project code.

Model files are untrusted inputs. The verifier passes a path to the pinned
`llama.cpp` build but does not establish that arbitrary GGUF parser input is
safe. Verify model provenance and hashes, and avoid serving an untrusted model
over a network-facing endpoint.

No ROCm runtime libraries are redistributed. Users remain responsible for the
security and licensing of their driver, runtime, models, and compiler toolchain.
