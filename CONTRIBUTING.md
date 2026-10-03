# Contributing

The public Enumerable and Collectable protocols are the primary API. Preserve
lazy opening, bounded body copying, cleanup on halt/error, and independent
traversals. High-level operations build on them and document memory ownership.

## Setup and checks

Install Elixir 1.17+, OTP 27+, Rust 1.95.0, a C compiler, libclang, CMake, Ninja,
Perl, and Python 3.12+. Compression libraries are built from verified sources;
system development packages for those libraries are unnecessary.

```sh
rustup toolchain install 1.95.0 --profile minimal --component rustfmt,clippy
export ARCHIVE_BUILD=1
# macOS release compatibility:
export MACOSX_DEPLOYMENT_TARGET=11.0
rustup run 1.95.0 mix deps.get
python3 scripts/generate_bindings.py --check
rustup run 1.95.0 cargo fmt --manifest-path native/archive/Cargo.toml --check
rustup run 1.95.0 mix check
rustup run 1.95.0 cargo clippy --manifest-path native/archive/Cargo.toml --locked --release -- -D warnings
MIX_ENV=docs rustup run 1.95.0 mix docs --warnings-as-errors
mix hex.build
python3 scripts/verify_package.py archive-*.tar
```

Rustler 0.38 requires Rust 1.91 or later; this project pins 1.95.0 in
`rust-toolchain.toml`. `rustup run` also selects the correct Cargo for Rustler's
metadata step when another tool manager has installed an older Cargo.

Tests create their own archives and temporary files. No network is needed once
Hex/Cargo dependencies and pinned native sources are cached. Integration tests
exercise the production Rust backend, including formats, metadata, disk I/O,
stream suspension, early termination, corruption, retained input, garbage
collection, killed processes, and concurrent resource access.

## Native bridge maintenance

* `native/archive/src/lib.rs`: unique native owners, Rustler resources, per-resource
  mutexes, ownership dependencies, sorted locking, and BEAM value conversion.
* `native/archive/src/adapters.rs`: constructors, retained buffers, pointer outputs,
  generation checks, ACLs, xattrs, disk operations, and link resolution.
* `native/archive/src/stat.rs`: portable stat maps and checked C ABI conversion.
* `priv/tables.json`: format, filter, extraction flag, and constant metadata.
* `priv/operations.json`: stable dispatcher IDs and adapted signatures.

The generator reads pinned public headers and the audited API inventory, then
emits `native/archive/src/generated.rs` and `priv/bindings.exs`. Do not edit
those outputs directly. Every header declaration must retain an inventory record;
audit new signatures and exclusions when updating libarchive.

Raw pointers stay inside locked native calls. `OwnedHandle` frees exactly once,
including when BEAM GC drops the final reference. Clones own their allocations;
entries created with `archive_entry_new2` retain their parent archive. Explicit
free invalidates aliases. Clearing an entry detaches its original parent safely.
C outputs are copied before unlocking. Native memory-reader/writer buffers are
owned boxes with stable addresses. Generation comparison and body reads execute
under one reader lock. Independent readers do not share a global lock.

`build.rs` generates platform FFI types with bindgen and invokes
`scripts/build_native.py`. Native dependency versions and SHA-256 hashes live in
`native/dependencies.json`; OpenSSL is pinned by Cargo.lock. Keep bundled headers
aligned with the exact libarchive version. All dependencies compile as static,
position-independent libraries. Binary audits reject non-system shared dependencies.

The build checks that zstd and ZIP encryption remain enabled rather than accepting
failed CMake feature probes. Linux static-library probes link pthread and dl for
the glibc 2.28 baseline. A guarded patch to libarchive 3.8.9's filename writer
closes its owned descriptor during free after a fatal error; normal close resets
the descriptor to prevent a second close. Re-audit this patch on libarchive upgrades.
The Windows build also pins libarchive's internal default byte encoding to UTF-8,
matching Elixir strings across archive formats and filename I/O. This patch is
confined to the bundled library and leaves BEAM's process and thread locales alone.

## Coverage and CI

`mix test --cover` enforces 91% line coverage of handwritten Elixir runtime code,
including protocols. Generated native facade and compile-time schemas are
excluded; this is not a Rust/C coverage measurement. Rustler currently emits a
NIF upgrade warning when Cover attempts to instrument the native facade; the
original NIF remains loaded and its integration tests still run.

CI checks generated files, Elixir/Rust formatting, Clippy, tests, coverage, docs,
and package contents on Linux and macOS for both architectures. The separate
precompilation workflow builds all eight targets and smoke-tests downloading
artifacts into isolated Hex package installations with compilers blocked. See
[the release guide](guides/precompiled.md) before publishing.
