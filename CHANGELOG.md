# Changelog

## 0.5.0 (unreleased)

* Expand libarchive bindings across metadata, disk I/O, ACLs, xattrs, sparse
  descriptors, digests, matching, memory I/O, and link resolution; inventory every
  public declaration from pinned libarchive 3.8.9 headers.
* Preserve Enumerable and Collectable with fresh handles per traversal, body
  forwarding in bounded chunks, correct collector state, and cleanup on halt/error.
* Define task-level operations: metadata `list`, retained-body `read`, first-member
  `fetch`, streaming `write`, and `extract`, with consistent result/bang variants.
  Accept file/data tags and configured readers; detach snapshot bodies from cursors.
* Add entry constructors and body streams; preserve native metadata in retained
  snapshots as well as streaming transformations.
* Replace Zigler with Rustler 0.38 and Rust 1.95.0. Use unique native owners,
  resource mutexes, RAII cleanup, retained input buffers, and atomic cursor checks.
* Add RustlerPrecompiled 0.10 downloads and eight Linux/macOS/Windows targets,
  covering x86-64 and ARM64, glibc and musl. Bundle verified static compression,
  XML, and crypto dependencies; generate checksums and Hex packages in Actions.
* Fix multiple extraction flags, reader exclusions, fatal read handling, aggregate
  resets, File.Stat type mapping, stat link counts, and retained native buffers.
* Preserve symlinks in disk entry construction, native timestamp precision in
  transformations, and complete File.Stat device identifiers.
* Load native binaries from the runtime priv directory so releases remain
  relocatable; exclude compiled artifacts from source packages.
* Enable secure extraction flags by default; avoid changing the working directory.
* Add integration tests, a 91% handwritten Elixir coverage gate, CI, reproducible
  binding generation, pinned native source verification, and contributor guides.

Compatibility: native pointers remain managed resources; explicit free invalidates
handles. Unloaded entry bodies are traversal-local. Streams open lazily and no
longer expose allocated handles before consumption. Disabled sides are `nil`;
use `reader: false` / `writer: false` to configure them. `writer: true` is rejected
because a file destination is required. `Archive.stream/0` is an empty descriptor.

High-level migration: `read` retains bodies by default (`load: false` remains
supported); use `list` for metadata. Bare binaries are file paths at this level;
use `{:data, binary}` for archive bytes. `write`/`write!` return `:ok` after
finalization. `extract` returns errors and `extract!` raises. See
[the operation guide](guides/high_level.md). Native stat maps now use uniform
fields and `%{sec: ..., nsec: ...}` timestamps; see the binding guide.
