# Archive

[![Archive version](https://img.shields.io/hexpm/v/archive.svg)](https://hex.pm/packages/archive)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/archive/)
[![Hex Downloads](https://img.shields.io/hexpm/dt/archive)](https://hex.pm/packages/archive)
[![Twitter Follow](https://img.shields.io/twitter/follow/ac_alejos?style=social)](https://twitter.com/ac_alejos)
---

`Archive` provides Elixir bindings to [`libarchive`](https://github.com/libarchive/libarchive) through the power of the wonderful [`Zigler`](https://hexdocs.pm/zigler/Zig.html) library.

`Archive` provides a high-level API for interacting with archive files.

Like `libarchive`, `Archive` treats all files as streams first and foremost, but provides many convenient high-level APIs to make it more natural to work with archive.

> [!WARNING]
> `Archive` is still **very** early in its development, and currently only supports reading archives with all formats, compressions, and filters enabled. In the future, these will be configurable parameters. Writing is currently
> **NOT** supported.

## Installation

```elixir
def deps do
  [
    {:archive, github: "acalejos/archive"}
  ]
end
```
