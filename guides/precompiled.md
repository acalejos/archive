# Native builds and releases

Archive uses Rustler 0.38 for managed NIF resources and RustlerPrecompiled 0.10
for verified binary delivery. The public Enumerable/Collectable streaming API is
the same for source and precompiled builds. No compiler runs when installing a
supported release binary.

## Supported targets

All binaries use NIF ABI **2.17**, compatible with OTP 26+, while Archive's tested
runtime requirement is OTP 27+. One binary per target serves all supported OTP
versions. Linux glibc binaries build in manylinux_2_28 containers; musl binaries
build on Alpine 3.22. macOS binaries target 11.0. Windows binaries use MSVC and
the normal Windows/Visual C++ runtime.

| Platform | x86-64 | ARM64 |
| --- | --- | --- |
| Linux, glibc 2.28+ | `x86_64-unknown-linux-gnu` | `aarch64-unknown-linux-gnu` |
| Linux, musl | `x86_64-unknown-linux-musl` | `aarch64-unknown-linux-musl` |
| macOS 11+ | `x86_64-apple-darwin` | `aarch64-apple-darwin` |
| Windows, MSVC | `x86_64-pc-windows-msvc` | `aarch64-pc-windows-msvc` |

These are configured build targets. A release is ready only after their Actions
jobs succeed. Linux/macOS and Windows x86-64 artifacts also run the production
tests from isolated Hex installations. Windows ARM64 binaries receive architecture
and dependency audits; an ARM64 BEAM runtime is required to load them.

Binaries bundle libarchive 3.8.9, zlib 1.3.2, bzip2 1.0.8, XZ 5.8.4, LZ4 1.10.0,
Zstandard 1.5.7, libxml2 2.15.4, and the OpenSSL version in Cargo.lock. C sources
are checked against `native/dependencies.json`; Cargo dependencies are locked.
No system libarchive/compression installation is used. Release archives include
third-party license notices. External programs such as lrzip/lzop are optional
and are not included. OS filesystem permissions, symlinks, and timestamps retain
platform behavior. Disk restoration of OS ACLs is disabled in the portable build;
archive ACL metadata APIs remain available.

## Source builds

For this unreleased checkout, set `ARCHIVE_BUILD=1`: no release assets exist yet.
The checked-in checksum map starts empty; release automation replaces it with
actual SHA-256 hashes. Do not invent hashes or publish that empty manifest.

```sh
export ARCHIVE_BUILD=1
rustup toolchain install 1.95.0 --profile minimal --component rustfmt,clippy
rustup run 1.95.0 mix deps.get
rustup run 1.95.0 mix compile
```

Source builds require Python 3.12+, a C compiler, libclang, CMake, Ninja, and Perl.
Use Xcode command-line tools on macOS or Visual Studio's developer environment
with LLVM on Windows. On macOS, set `MACOSX_DEPLOYMENT_TARGET=11.0` when producing
portable binaries. Downloads cache in `_build/native-downloads`; set
`ARCHIVE_NATIVE_CACHE` to override this location. Rust output is in
`native/archive/target`. Unsupported systems require a source build and are not
covered by release testing.

Downstream applications can force compilation explicitly:

```elixir
config :rustler_precompiled, :force_build, archive: true
```

Include `{:rustler, "~> 0.38.0", runtime: false}` in downstream dependencies when
forcing a source build: Archive's optional Rustler dependency is omitted from
normal consumer dependency resolution.

## Build and publish a release

1. Update matching versions in `mix.exs`, Cargo.toml/Cargo.lock, README, badges,
   and the changelog. Commit the source changes.
2. Run the **Precompile** workflow manually first. It builds all eight targets,
   audits architecture and shared dependencies, verifies the glibc baseline,
   gathers all assets, and generates the checksum manifest from actual bytes.
3. Download `release-package`. It contains eight NIF archives,
   `checksum-Elixir.Archive.Nif.exs`, and an `archive-VERSION.tar` Hex source package
   with that complete manifest embedded. The smoke jobs extract this package,
   download binaries over HTTP, verify checksums, and run production tests with
   compiler commands blocked.
4. Tag the tested source commit with `vVERSION` and push the tag. The tag workflow rebuilds and
   verifies the assets, then publishes a GitHub release after the smoke jobs pass.
   Download the **new tag run's** `release-package`: rebuilding can change binary
   bytes, so use its checksum file and prepared Hex package together.
5. Check out that exact tag and copy the tag run's generated checksum manifest
   into its root. Run `mix hex.build`, then
   `python3 scripts/verify_package.py --require-checksums archive-VERSION.tar`.
   Publish from that checkout with `mix hex.publish package`, and publish docs
   with `mix hex.publish docs`. Hex rebuilds the source package when publishing;
   it does not accept a tarball filename argument. Save the verified manifest
   in the repository for future installations from Git. Hex credentials are not stored in this repository and
   the workflow does not automatically publish to Hex.

GitHub release URLs match the default loader URL:
`https://github.com/acalejos/archive/releases/download/vVERSION/…`.
Manual and pull-request runs produce artifacts without creating releases.
`ARCHIVE_PRECOMPILED_BASE_URL` overrides the URL for local smoke tests or mirrors.

To package one target locally (after installing its Rust target and C toolchain):

```sh
python3 scripts/build_release.py --target aarch64-apple-darwin
python3 scripts/package_nif.py checksums
python3 scripts/verify_package.py --require-checksums archive-*.tar
```

The checksum command requires all eight archives. Its `--allow-partial` option is
for isolated local smoke testing only. Release package verification rejects
missing checksums. The ordinary source-package audit permits an empty map so
unreleased source development can proceed.

Implementation follows the official
[RustlerPrecompiled precompilation guide](https://rustler-precompiled.hexdocs.pm/precompilation_guide.html).
