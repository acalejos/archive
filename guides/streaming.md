# Streaming archives

An `Archive.Stream` is a descriptor. Creating a reader or writer validates its
options; protocol consumption allocates, opens, and owns the native handles.

## Read only what you need

```elixir
reader = Archive.reader!("input.tar.gz", formats: [only: [:tar]])
Enum.take(reader, 2) # Only two headers are requested; the reader is then closed.
Enum.count(reader) # Opens a fresh reader and counts every entry.
```

Listing metadata does not retain bodies. Libarchive skips unread entry data as
it advances. Skipping compressed data may still require decompression.

## Transform a body

```elixir
reader = Archive.reader!("input.tar")

reader
|> Stream.map(fn entry ->
  loaded = Archive.Entry.read_data!(entry, reader)
  body = String.upcase(loaded.data)
  %{loaded | data: body, stat: %{loaded.stat | size: byte_size(body)}}
end)
|> Enum.into(Archive.writer!("upper.tar.gz", filters: :gzip))
```

`read_data/2` retains one complete body, so memory use grows with that entry's
size. Prefer `data_stream/2` for large bodies. Its chunk size defaults to 65,536
bytes and must be positive. Bodies represented by a custom enumerable are
consumed as provided; the producer controls their chunk size.

## Copy without loading

```elixir
Archive.reader!("input.tar")
|> Stream.filter(&(&1.stat.type == :regular))
|> Enum.into(Archive.writer!("files.zip", format: :zip))
```

The collector consumes unread bodies before the source advances. This retains
bounded body memory, though format-specific metadata (for example a ZIP central
directory) can grow with the number of entries. Metadata clones preserve ACLs,
xattrs, file flags, sparse descriptors, and other native fields. Explicit changes
to path, stat, symlink, and hardlink override the cloned metadata.

Do not collect unloaded entries into a list and then try to copy their bodies:

```elixir
# Retain bodies while each entry is current:
entries = Enum.map(reader, &Archive.Entry.read_data!(&1, reader))
Enum.into(entries, Archive.writer!("output.tar"))
```

This intentionally retains all bodies. Use a direct streaming pipeline for
bounded memory. Archive bodies are single-pass within one traversal: consuming
part of an entry and then forwarding the unread remainder will fail the size
check. Start a new traversal if you need to reread a body.

## Construct entries

`Archive.Entry.from_binary/3` takes a pathname, binary, and optional `mode:` and
`mtime:`. Timestamps are Unix seconds. `from_file/2` reads file metadata eagerly
and its regular-file body lazily; `path:` controls the archive name and
`chunk_size:` controls the file stream. If the file changes size before writing,
the collector reports a size mismatch.

You can also construct an `Archive.Entry` with a `File.Stat`, pathname, and a body
implementing `Enumerable`. Set `stat.size` to the exact byte count. Directory and
link entries do not write bodies. `from_file/2` uses `File.lstat!/2` and preserves
filesystem symlinks, including broken links.

## Options

Readers support `formats:`, `filters:`, `as:`, `block_size:`, `options:` (a native
libarchive option string), and `passphrases:`. Format/filter selection accepts a
single atom, a list, `only:`, or `except:`; formats additionally accept `:all`.
Raw format requires explicit `formats: :raw`, so arbitrary input is not silently
accepted as an archive.

Writers support `format:`, `filters:`, `options:`, and `passphrase:`. Defaults are
TAR with no outer compression. Selecting encryption or a compression format that
was not built into libarchive returns an error. Using all filters at once is
rarely useful: choose the pipeline explicitly.

`Archive.list/2` retains metadata; `Archive.read/2` retains bodies by default.
`Archive.fetch/3` retains the first exact matching member. Their result functions
return `{:ok, value}` or `{:error, exception}`. `Archive.write/3` and
`Archive.extract/2` return `:ok` or an error tuple. Bang variants and protocol
operations raise on errors. See the [operation guide](high_level.md).

## Lifecycle and concurrency

A descriptor supports repeated, nested, and concurrent traversals. Each traversal
has its own handles. Suspension retains them until resumed or halted. Always halt
an abandoned `Enumerable.reduce/3` continuation. Unloaded entry bodies expire
when the next header is read or the traversal closes. Native operations serialize
access to libarchive state and run on dirty I/O schedulers.

Collection closes and finalizes the output on success. On failure it aborts the
writer and releases its handles. Partial output can remain; write to a temporary
file and rename it after success when atomic publication is required. Concurrent
writers must use different destination paths.
