# Validation of the unreleased 0.5.0 Rust migration

Local checks on 2026-10-03 used Apple Silicon macOS, Elixir 1.19.5, OTP 28.3.1,
Rust 1.95.0, Rustler 0.38.0, RustlerPrecompiled 0.10.0, and bundled libarchive 3.8.9.

| Check | Result |
| --- | --- |
| Production source-build tests | 111 tests, no failures |
| Handwritten Elixir coverage | 97.73%; Enumerable and Collectable both 100% |
| Rust formatting and Clippy | Pass, including `-D warnings` |
| Elixir formatting | Pass |
| Binding generation | 455 declarations audited, 428 supported, 27 excluded; no missing adapter labels |
| Docs | HTML and EPUB generated with `--warnings-as-errors` |
| Source package audit | 44 files; Rust sources, headers, build scripts and docs included; binaries and this validation document excluded |
| ARM64 macOS release artifact | Built, audited, and packaged in RustlerPrecompiled format with licenses and a real SHA-256 checksum |
| Shared dependencies | macOS system libraries/frameworks only; no Homebrew, libarchive, or compression-library dependency |
| Isolated precompiled install | HTTP download, checksum verification, relocated NIF load, and all 111 production tests pass with compiler commands blocked |
| GitHub Actions workflows | Actionlint v1.7.12 passes |

Coverage measures handwritten Elixir runtime code. It excludes the generated
native facade and compile-time schemas; it is not a Rust/C coverage measurement.
Rustler's native facade currently warns about unsupported NIF upgrades when Cover
tries to reload it. The original native module stays loaded; integration tests
execute successfully.

Additional ownership tests observe exactly-once cleanup under garbage collection,
killed processes, aliases, concurrent frees, cloned entries, and retained parents.
They also verify input ownership after a producing process exits, stable binary
chunks after advancement/close, and cursor invalidation on EOF.

## Hosted GitHub Actions

The [source CI run](https://github.com/acalejos/archive/actions/runs/37132075685)
and [precompilation run](https://github.com/acalejos/archive/actions/runs/37132075690)
passed on 2026-10-03 for commit `52501d0`.

| Hosted check | Result |
| --- | --- |
| Source CI | Five jobs pass: Linux x86-64 on Elixir 1.17/OTP 27 and 1.19/OTP 28; Linux ARM64 and macOS x86-64/ARM64 on Elixir 1.19/OTP 28 |
| Production tests and coverage | Each source job passes 111 tests and 97.73% Elixir coverage; both protocols reach 100% |
| Native release builds | All eight pass: Linux glibc/musl, macOS, and Windows MSVC, each on x86-64/ARM64 |
| Binary audits | All eight pass architecture and system dependency checks; glibc requirements stay within 2.28 |
| Prepared source package | All eight actual SHA-256 checksums included; 44 source files audited; validation document and compiled outputs excluded |
| Compiler-free installation | Five jobs pass: Linux glibc x86-64/ARM64, macOS x86-64/ARM64, and Windows x86-64; HTTP download, checksum verification, NIF load, and 111 production tests |
| Runtime scope | Linux musl x86-64/ARM64 and Windows ARM64 receive build and binary audits; no BEAM runtime test is claimed for these three targets |

Hosted tests caught and verified fixes for static zstd/OpenSSL feature probes on
the glibc baseline, Windows timestamp precision, UTF-8 names and filename I/O,
symlink mode bits, and immediate cleanup after collection errors. A guarded patch
also closes libarchive's filename descriptor during free after a failed writer;
Linux tests inspect `/proc/self/fd`, and Windows tests verify immediate deletion.

No release has been published and no Hex upload has occurred. The checked-in
checksum manifest remains empty for this unreleased source checkout. The
prepared CI package contains the real hashes matching its eight artifacts.
