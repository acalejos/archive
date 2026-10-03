# Initial reader comparison

Measured locally on 2026-10-02, Apple Silicon macOS
(`aarch64-apple-darwin25.2.0`), Elixir 1.19.5, OTP 28, Zig 0.16.0 / Zigler 0.16.0,
Rust 1.95.0 / Rustler 0.38.0, and the same bundled libarchive 3.8.9.
The measured Zig NIF used ReleaseSafe; the Rust crate uses release.

These compare the reader implementations before the full Rust migration. They do not isolate the
language, Rust ownership, compiler optimizations, or individual locking changes.

## Results

Median elapsed milliseconds, seven samples after two warmups per backend, 64 KiB
body chunks, warm filesystem cache. Backend order rotates between samples.
Every timed traversal verifies its total byte count; body bytes are consumed and
discarded without assembling a complete output binary.

| Workload | Zig default | Zig TAR-only configuration | Rust prototype | Default Zig / Rust |
| --- | ---: | ---: | ---: | ---: |
| 1,500 entry headers | 25.59 ms | 25.17 ms | 14.48 ms | 1.77× |
| 64 MiB TAR file body | 12.36 ms | 11.81 ms | 7.28 ms | 1.70× |
| 64 MiB TAR memory body | 9.53 ms | 8.89 ms | 5.14 ms | 1.85× |
| 64 MiB gzip TAR body | 11.47 ms | 11.15 ms | 6.18 ms | 1.85× |
| Four concurrent TAR readers, 256 MiB total | 58.04 ms | 57.52 ms | 17.84 ms | 3.25× |

The narrower Zig configuration enables only TAR and the appropriate filter. It
reduces setup work without changing the rest of the reader implementation.

## Interpretation

The prototype is faster in these measured workloads. Plausible contributors,
visible in the implementations but not isolated by these measurements, include:

- Rust combines generation validation and body reading into one NIF call; Zig
  performs a generation query followed by a separate data-read call.
- Rust lets C write into a BEAM-owned binary; Zig reads into a temporary C
  allocation and copies the returned bytes into a BEAM binary.
- Rust uses a mutex per reader rather than the Zig bridge's global archive mutex,
  allowing independent readers to perform C reads concurrently.
- Rust configures support and returns basic metadata using fewer NIF crossings.

This is an early, warm-cache comparison. It does not measure cold storage, ZIP or
7z performance, incompressible data, writer throughput, full metadata forwarding,
peak memory, or scheduler latency. The deterministic large input repeats all 256
byte values and compresses well; the gzip result should not be generalized to
arbitrary compressed archives. Compiler profiles and metadata capabilities differ.
The Rust body path also initializes its output allocation, and memory input is
copied into owned storage by both implementations.

Allocation counters and the 23 integration tests establish ownership and cleanup
behavior separately. A passing correctness test is not a performance result, and
these prototype tests do not establish that the Zig backend fails equivalent
cases. The new direct observations include exactly-once native cleanup on normal
and killed process exit, entry ownership after the opening process exits, and
concurrent reads/close on the same resource.

## Reproduction status

The prototype was retired when the full backend migrated to Rustler. The table
above is a historical result, not a performance guarantee for the new backend.
The root integration suite exercises the current streaming implementation.
