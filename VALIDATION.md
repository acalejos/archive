# Validation of the unreleased 0.5.0 Rust migration

Local checks on 2026-10-03 used Apple Silicon macOS, Elixir 1.19.5, OTP 28.3.1,
Rust 1.95.0, Rustler 0.38.0, RustlerPrecompiled 0.10.0, and bundled libarchive 3.8.9.

| Check | Result |
| --- | --- |
| Production source-build tests | 108 tests, no failures |
| Handwritten Elixir coverage | 97.69%; Enumerable and Collectable both 100% |
| Rust formatting and Clippy | Pass, including `-D warnings` |
| Elixir formatting | Pass |
| Binding generation | 455 declarations audited, 428 supported, 27 excluded; no missing adapter labels |
| Docs | HTML and EPUB generated with `--warnings-as-errors` |
| Source package audit | 44 files; Rust sources, headers, build scripts and docs included; binaries and this validation document excluded |
| ARM64 macOS release artifact | Built, audited, and packaged in RustlerPrecompiled format with licenses and a real SHA-256 checksum |
| Shared dependencies | macOS system libraries/frameworks only; no Homebrew, libarchive, or compression-library dependency |
| Isolated precompiled install | HTTP download, checksum verification, relocated NIF load, and all 108 production tests pass with compiler commands blocked |
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

The eight-target release matrix is configured for Linux glibc/musl, macOS, and
Windows, each on x86-64/ARM64. Only ARM64 macOS was built and executed locally;
the other seven builds await hosted Actions. No release has been published and
no Hex upload has occurred. The checked-in checksum manifest remains empty for
this unreleased source checkout. Release automation requires all eight real
hashes before preparing the publishable Hex package.
