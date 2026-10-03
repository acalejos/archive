# Retired reader prototype

The Rustler prototype has been replaced by the production implementation in
`native/archive`. Its ownership tests are now part of the root test suite and
its precompiled release path is implemented by the root GitHub Actions workflows.

[BENCHMARKS.md](BENCHMARKS.md) retains historical measurements from the original
Zig/Rust reader comparison. Those measurements describe the earlier prototype;
they are not benchmarks of the completed Rust migration.
