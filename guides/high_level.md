# Archive operations

Use the high-level operations for complete tasks. Use `Archive.reader!/2` and
`Archive.writer!/2` when you want to compose a lazy pipeline with Elixir's
`Enumerable` and `Collectable` protocols.

| Operation | Successful result | Retained memory |
| --- | --- | --- |
| `Archive.list(source, opts)` | `{:ok, %Archive{}}` with entry metadata | Metadata for every entry |
| `Archive.read(source, opts)` | `{:ok, %Archive{}}` with entry bodies | Metadata and all bodies |
| `Archive.fetch(source, path, opts)` | `{:ok, %Archive.Entry{}}` with its body | One matching entry and body |
| `Archive.write(entries, path, opts)` | `:ok` after finalization | Bounded body copying |
| `Archive.extract(source, opts)` | `:ok` after extraction | Bounded body copying |

Each operation has a bang variant: `list!`, `read!`, and `fetch!` return the value;
`write!` and `extract!` return `:ok`. Non-bang operations return
`{:error, exception}` on operational failures; bang variants raise that exception.
Errors from user-supplied enumerable code can still propagate.

## Sources and options

A source is a file path, `{:file, path}`, `{:data, binary}`, or a configured
reader descriptor. A bare binary at this level means a **file path**. Tag archive
bytes explicitly to avoid guessing whether they name a file:

```elixir
snapshot = Archive.list!("backup.tar.gz")
snapshot = Archive.list!({:data, File.read!("backup.tar.gz")})

reader = Archive.reader!("encrypted.zip", passphrases: ["secret"])
entry = Archive.fetch!(reader, "settings.json")
```

Pass reader options directly to `list`, `read`, and `fetch`. For `extract`, use
`reader: [...]`, keeping reader options separate from extraction options:

```elixir
Archive.extract!("encrypted.zip", to: "restored", reader: [passphrases: ["secret"]])
```

Configured descriptors already contain their reader options; supplying additional
reader options with one returns an error. Tagged sources reject a conflicting
`as:` option. The low-level `Archive.reader/2` keeps its existing `as: :auto`
behavior, and explicit `as: :data` remains supported by high-level operations.
See the [streaming guide](streaming.md) for supported reader/writer options.

## Metadata snapshots

```elixir
archive = Archive.list!("backup.tar.gz")
Enum.map(archive.entries, &{&1.path, &1.stat.size})
{archive.count, archive.total_size, archive.format, archive.compression}
```

Snapshots preserve entry order and duplicate paths. `count` is the number of
entries, including duplicates; `total_size` sums their declared sizes. Empty
archives have zero entries and size. Format descriptions come from libarchive;
the `compression` field reports libarchive's filter at index 0.

Returned entries have no live reader cursor. Each retains an opaque native
metadata resource, so ACLs, extended attributes, links, and precise timestamps
can survive a rewrite. The resource is managed by the VM and is not a C address.
A metadata snapshot has no retained body. Attempting to write a nonempty regular
file from one returns an `Archive.Error` with reason `:BodyNotLoaded`.

## Retain and edit bodies

```elixir
archive = Archive.read!("input.zip")
entries = Enum.map(archive.entries, fn entry ->
  %{entry | path: "backup/" <> entry.path}
end)
Archive.write!(entries, "output.tar.gz", filters: :gzip)
```

`read` retains all bodies by default, so the result can be used after traversal
ends or written later. This intentionally uses memory proportional to the archive
contents. When replacing a body, update `entry.stat.size` to its exact byte count.
`write` accepts a snapshot or any enumerable of entries.

For a single member, use `fetch`:

```elixir
case Archive.fetch("backup.tar", "config.json") do
  {:ok, entry} -> entry.data
  {:error, %Archive.Error{reason: :EntryNotFound}} -> :missing
  {:error, error} -> raise error
end
```

`fetch` compares exact archive pathnames, selects the first duplicate, reads its
body, and halts the traversal. It does not normalize paths or inspect later
members. Skipping earlier compressed bodies may still require decompression.

## Keep large transformations streaming

```elixir
Archive.reader!("input.tar.gz")
|> Stream.reject(&String.ends_with?(&1.path, ".tmp"))
|> Stream.map(&%{&1 | path: "backup/" <> &1.path})
|> Archive.write!("output.zip", format: :zip)
```

`write` uses the existing collector. It consumes each body while the reader is
positioned at that member, copies bounded chunks, checks the written size, and
finalizes the output. Format-specific metadata can grow with entry count.
See the [streaming guide](streaming.md) for body lifetimes and suspension.

## Extraction and partial outputs

Extraction streams directly from the source. Secure symlink, parent-traversal,
and absolute-path flags are enabled by default; supplying `flags:` replaces
those defaults. The destination is created without changing the working directory.

A failed write can leave a partial archive. A failed extraction can leave files
already extracted; neither operation rolls back. For atomic archive publication,
write to a temporary path and rename it after success.

## Migrating earlier convenience calls

* Use `list(source)` for metadata. `read(source)` now retains bodies by default;
  `read(source, load: false)` remains available for compatibility.
* Use `{:data, binary}` for in-memory sources. Bare binaries default to file paths
  at this level; reader descriptors retain their existing source inference.
* `write` and `write!` return `:ok` on success instead of a writer descriptor.
* `extract` returns errors; use `extract!` when you want failures to raise.
* `index/2` remains a compatibility helper. New code can create snapshots with
  `list/2` in one traversal.

The protocol API remains the basis for lazy transformations, including repeated
and concurrent traversals of a reader descriptor.
