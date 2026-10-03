# Native binding guide

The checked-in `archive.h` and `archive_entry.h` are from libarchive 3.8.9.
`python3 scripts/generate_bindings.py` produces the Rust dispatcher and Elixir function
registry from the audited API inventory. `--check` fails if any generated file is stale.
Every declaration is classified; platform-specific declarations remain visible.

## Conventions

* Function names match C, including deprecated aliases. Integer constants are in
  `Archive.Nif.constants/0`; atom conversions are available for formats, filters,
  and extraction flags.
* Archive, entry, matcher, and link-resolver handles are opaque BEAM resources.
  They own their native allocations. Free is idempotent; operations after free
  raise `ErlangError`. Never supply or retain native addresses.
* Status-returning operations return `:ok` or raise native errors. Predicates,
  counters, timestamps, and sizes return integers. Predicates retain C's nonzero
  success convention (some return bitmasks).
  `archive_entry_update_*_utf8` also retains C's integer success convention.
  `archive_write_fail` marks the writer failed and returns C's positive internal
  state value; it does not return an archive status code. Free the handle afterward.
* String getters return binaries or `nil`. String inputs reject embedded NULs;
  `nil` represents a C null string where the upstream function accepts it.
  Do not pass `nil` to upstream functions requiring a string.
* `_w` APIs convert UTF-8 binaries to/from native `wchar_t` (UTF-32 on Unix,
  UTF-16 on Windows). The Windows-only
  multi-volume wide opener reports `:UnsupportedPlatform` on Unix. The release workflow includes Windows binaries for both architectures.
* `safe_call/2` returns `:ok`, `{:ok, value}`, or `{:error, reason}`. It logs and
  accepts libarchive warnings. With an archive handle it returns and clears the
  diagnostic string. EOF is `{:error, :ArchiveEof}`. Exception constructors and
  `unwrap!/1` preserve structured errors.

## Read and write memory

```elixir
alias Archive.Nif, as: N
writer = N.archive_write_new()
N.archive_write_set_format_pax_restricted(writer)
N.archive_write_set_bytes_per_block(writer, 0)
N.archive_write_open_memory(writer, 1_048_576)
# Write entries with archive_write_header and archive_write_data.
N.archive_write_close(writer)
data = N.archive_write_memory(writer)
N.archive_write_free(writer)

reader = N.archive_read_new()
N.archive_read_support_filter_all(reader)
N.archive_read_support_format_all(reader)
N.archive_read_open_memory(reader, data)
# Read headers and bodies.
N.archive_read_free(reader)
```

The reader **copies and owns** input memory until freed. Memory output uses an
owned fixed-capacity buffer; retrieve its binary before freeing the writer. Close
first to flush trailers. A capacity overflow is an error, never an overrun.
Filename/fd I/O also works. File descriptors remain caller-owned.

## Adapted signatures and outputs

| Function | Elixir parameters / result |
| --- | --- |
| `archive_read_next_header`, `archive_read_next_header2` | `(reader, owned_entry)` fills the entry, returns status |
| `archive_read_data` | `(reader, max_bytes)` returns up to that many bytes; `<<>>` at body EOF |
| `archive_read_data_block` | `(reader)` returns `%{data: binary, offset: integer}`; archive EOF raises |
| `archive_write_data` | `(writer, binary)` returns bytes written |
| `archive_write_data_block` | `(disk_writer, binary, offset)` returns status |
| `archive_read_open_memory` / `memory2` | `(reader, binary)` / `(reader, binary, read_size)` |
| `archive_write_open_memory` / `archive_write_memory` | `(writer, capacity)` / `(writer)` retrieves binary |
| `archive_read_open_filenames` | `(reader, [binary], block_size)`; names are copied by libarchive |
| `archive_entry_copy_fflags_text_len` | `(entry, text)` derives the byte length safely |
| `archive_entry_stat` / `copy_stat` | `(entry)` returns a portable stat map / `(entry, stat_map)` |
| `archive_entry_fflags` | `(entry)` returns `%{set: integer, clear: integer}` |
| `archive_entry_mac_metadata` / `copy_mac_metadata` | `(entry)` returns binary or nil / `(entry, binary)` |
| `archive_entry_digest` / `set_digest` | `(entry, kind)` returns fixed-size binary / `(entry, kind, binary)` validates size |
| `archive_entry_acl_next` | `(entry, wanted_types)` returns `%{type:, permset:, tag:, qual:, name:}` |
| `archive_entry_acl_to_text`, `_w` | `(entry, flags)` returns text; native allocation is freed |
| `archive_entry_xattr_add_entry` / `xattr_next` | `(entry, name, binary)` / `(entry)` returns `%{name:, value:}` |
| `archive_entry_sparse_next` | `(entry)` returns `%{offset:, length:}` |
| `archive_match_path_unmatched_inclusions_next`, `_w` | `(matcher)` returns a pattern or EOF |
| `archive_read_disk_entry_from_file` | `(disk_reader, entry, fd)` asks libarchive to obtain stat metadata |
| `archive_read_disk_set_matching` | `(disk_reader, matcher)` installs matching without a callback |
| `archive_entry_linkify` | `(resolver, entry_or_nil)` returns `%{entry: handle_or_nil, spare: handle_or_nil}` |
| `archive_entry_partial_links` | `(resolver)` returns `%{entry: handle_or_nil, links: integer}` |
| `archive_set_error` | `(archive, errno, message)` treats message literally, including `%` |
| `archive_utility_string_sort` | `([binary])` returns sorted binaries |
| `archive_read_*_program_signature` | `(reader, command, binary_signature)` |

Stat maps contain `dev`, `rdev`, `ino`, `mode`, `nlink`, `uid`, `gid`, `size`,
`blocks`, `blksize`, `flags`, and `atim`/`mtim`/`ctim`/`birthtim` timestamps with
`%{sec: integer, nsec: integer}` values. Missing input fields default to zero.
The bridge converts this map to the target platform's C `struct stat`, checking
integer ranges. Unsupported birthtime/flags fields remain zero. No platform ABI
padding crosses the BEAM boundary. `Archive.Stat` converts `File.Stat` values.
This replaces the former platform-dependent raw stat map.

Link resolution works on clones: inputs retain ownership and returned entries are
independently owned. Feed `nil` to drain deferred entries, then free the resolver.
Xattr and sparse iterators translate their end-of-list warning into `ArchiveEof`.
Disk readers retain installed matcher resources and reject further operations if
a matcher is explicitly freed. For ACLs use the upstream reset/count/type
semantics before iteration.

## Unavailable C interfaces

The inventory explicitly lists these categories instead of creating stubs that
pretend to provide them:

* Arbitrary C callback pointers and opaque client data (`archive_read_open*`,
  callback registration, custom identity lookups, progress, and passphrase
  callbacks). Use managed protocols, filename/fd/memory I/O, native standard
  identity lookup, explicit passphrases, and Elixir stream functions.
* Foreign `FILE*` openers. Use filename/fd variants.
* Windows `BY_HANDLE_FILE_INFORMATION`. Use portable entry stat setters.
* `archive_entry_acl`, which exposes an internal `struct archive_acl *` with no
  independent public operation API. Use the complete `archive_entry_acl_*` family.

This is broad coverage of the callable API, not a claim that arbitrary C plugins
can be passed into Elixir. See `priv/api_inventory.json` for exact names and
`priv/bindings.exs` for every exported arity and native parameter signature.

## Coverage scope

BEAM coverage measures handwritten runtime Elixir code and protocol
implementations. `Archive.Nif`'s generated facade and
the compile-time option schemas are excluded because they are not meaningful BEAM coverage
units. Native integration tests verify getters/setters, memory ownership, short
reads, iterators, errors, disk operations, and format/compression round trips.
No Rust/C source coverage percentage is claimed.
