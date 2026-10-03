# Archive

<p align="center">
  <img src="assets/logo/archive.png" width="160" alt="Archive logo: purple ribbons forming the letter A">
</p>

[![Precompiled](https://github.com/acalejos/archive/actions/workflows/precompile.yml/badge.svg)](https://github.com/acalejos/archive/actions/workflows/precompile.yml)
[![CI](https://github.com/acalejos/archive/actions/workflows/ci.yml/badge.svg)](https://github.com/acalejos/archive/actions/workflows/ci.yml)
[![Hex v0.5.0](https://img.shields.io/badge/hex-v0.5.0-orange.svg)](https://hex.pm/packages/archive/0.5.0)
[![Docs v0.5.0](https://img.shields.io/badge/docs-v0.5.0-blue.svg)](https://hexdocs.pm/archive/0.5.0/)

Elixir bindings to [libarchive](https://www.libarchive.org/), built around
`Enumerable` and `Collectable`. Read, transform, and write archives with ordinary
Elixir streams. Entry bodies are copied in bounded chunks; files are opened only
when their streams are consumed.

```elixir
source = Archive.reader!("backup.tar.gz")

source
|> Stream.reject(&String.ends_with?(&1.path, ".tmp"))
|> Stream.map(&%{&1 | path: "backup/" <> &1.path})
|> Enum.into(Archive.writer!("clean.zip", format: :zip))
```

Each enumeration opens its own native reader. Descriptors are reusable, including
concurrent traversals. Completion, early halt, and exceptions release the handles.

## Install

```elixir
def deps do
  [{:archive, "~> 0.5.0"}]
end
```

Requires Elixir 1.17+ and Erlang/OTP 27+. Release packages download a
SHA-256-verified native binary using RustlerPrecompiled; users do not need Rust,
Zig, a C compiler, or a system libarchive installation.

Precompiled targets cover **x86-64 and ARM64** on Linux (glibc 2.28+ and musl),
macOS 11+, and Windows (MSVC). Binaries statically bundle libarchive **3.8.9**,
zlib, bzip2, XZ/liblzma, LZ4, Zstandard, libxml2, and vendored OpenSSL. System
libraries and the platform's normal runtime remain dependencies. Optional
external compression programs are not bundled; platform filesystem features
still depend on the OS.

**Working with this unreleased checkout:** the 0.5.0 release binaries do not exist
until the precompilation workflow runs. Build locally with `ARCHIVE_BUILD=1`:

```sh
rustup toolchain install 1.95.0 --profile minimal --component rustfmt,clippy
# Debian / Ubuntu: C compiler, libclang, CMake, Ninja, Perl, Python 3.12+
sudo apt-get install build-essential clang libclang-dev cmake ninja-build perl python3
# macOS: Xcode command-line tools, Python 3.12+, CMake and Ninja
brew install cmake ninja
ARCHIVE_BUILD=1 rustup run 1.95.0 mix deps.get
ARCHIVE_BUILD=1 rustup run 1.95.0 mix compile
```

See [the native build and release guide](guides/precompiled.md) for source builds,
release assets, supported platforms, and checksum generation.

## Complete operations

```elixir
metadata = Archive.list!("input.tar.gz")
archive = Archive.read!("input.tar.gz")
entry = Archive.fetch!("input.tar.gz", "config.json")
Archive.write!(archive, "output.zip", format: :zip)
```

`list` retains metadata; `read` retains all bodies; `fetch` retains the first exact
matching member. Sources may be paths, `{:file, path}`, `{:data, binary}`, or reader
descriptors. Bare binaries here are paths. Reads return `{:ok, value}`, and writes
/extraction return `:ok`; failures return `{:error, exception}`. Bang variants
raise. See the [operation guide](guides/high_level.md) for contracts and migration.

## Read metadata or bodies

```elixir
reader = Archive.reader!("input.tar.gz")
Enum.map(reader, &{&1.path, &1.stat.size})

Enum.each(reader, fn entry ->
  entry
  |> Archive.Entry.data_stream(64 * 1024)
  |> Enum.each(&IO.binwrite/1)
end)

# Retain all bodies in memory intentionally:
archive = Archive.read!("input.tar.gz")
```

The default reader detects whether a binary names an existing file. Use `as: :file`
or `as: :data` when that distinction must be explicit. **Read unloaded bodies
inside the enumeration callback, before advancing to the next entry.** A stale
entry raises an error. Metadata remains available after traversal.

## Create archives

```elixir
entries = [
  Archive.Entry.from_binary("hello.txt", "hello"),
  Archive.Entry.from_file("large.bin", path: "data/large.bin")
]

Enum.into(entries, Archive.writer!("output.tar.gz", filters: :gzip))
# Equivalent higher-level convenience:
Archive.write!(entries, "output.zip", format: :zip)
```

The collector preserves native entry metadata, writes bodies, validates the
written size, and finalizes the output. File bodies are lazy; binary bodies are
already loaded. A writer may leave a partial output on failure.

## Extract

```elixir
Archive.extract!("input.tar", to: "unpacked")
```

Extraction creates the destination without changing the working directory.
Secure symlink, parent-traversal, and absolute-path flags are enabled by default.
Passing `flags:` overrides those defaults. `extract` returns `:ok` or an error
tuple; `extract!` raises on failure. Extraction can leave files written before an
error.

## Native API and scope

`Archive.Nif` exposes 428 of the 455 declarations in the pinned libarchive public
headers, with managed resources and adapters for pointer outputs, memory I/O,
ACLs, xattrs, sparse descriptors, digests, matching, disk traversal, and hardlink
resolution. Wide-character APIs accept and return UTF-8 binaries.

The remaining declarations require foreign `FILE*`/Windows handles, arbitrary C
callbacks/client pointers, or an internal ACL pointer. Those are deliberately
listed as unavailable instead of exposing unsafe addresses. The complete
machine-readable inventory is [priv/api_inventory.json](priv/api_inventory.json).
See [the binding guide](guides/bindings.md) for the supported alternatives and
return conventions, and [the streaming guide](guides/streaming.md) for recipes.

## Validation

```sh
mix deps.get
python3 scripts/generate_bindings.py --check
ARCHIVE_BUILD=1 rustup run 1.95.0 mix check
ARCHIVE_BUILD=1 MIX_ENV=docs rustup run 1.95.0 mix docs --warnings-as-errors
```

CI enforces **at least 91% line coverage of handwritten Elixir code**. The generated
native facade and compile-time schemas are excluded from BEAM coverage; native
behavior is exercised by integration tests. This percentage does not measure Rust
or upstream libarchive C coverage.
