# ADR-0001: Flutter receiver worker isolate

**Status:** Accepted · **Date:** 2026-08-09

## Context

Decoding QR-scanned chunks (fountain peeling, GF(2) elimination, gzip
decompression, SHA-256, and all per-chunk disk I/O) is CPU/IO work that
used to run synchronously on the UI isolate, inside `Assembler.ingest`.
Transferring a real 109 MB / ~26k-chunk file exposed this as a hard
bottleneck: the UI froze during decode bursts, and per-chunk
`metadata.json` rewrites added blocking disk I/O on every scan.

## Options (verified 2026-08-09)

- **`compute()` / `Isolate.run()` per call** — spins up a fresh isolate per
  invocation. Wrong shape here: the `Assembler`/`FountainDecoder` state
  (recovered blocks, pending fountain symbols, per-transfer maps) must
  persist across thousands of calls; re-creating it per QR scan would mean
  serializing and re-sending that whole state every time, which is worse
  than the problem being solved.
- **Long-lived worker isolate** — spawned once (`AssemblerWorker.spawn`),
  owns the real `Assembler` for the app's lifetime. State lives entirely in
  the worker; only small events cross the isolate boundary.

## Decision

A single long-lived worker isolate (`flutter/lib/services/assembler_worker.dart`)
owns `Assembler`, `FountainDecoder`, and all chunk/metadata disk I/O. The
main (UI) isolate holds a thin `AssemblerWorker` handle that sends
requests (`ingestQR`, `reset`, `setOutputDirectory`, `flushAll`,
`hydrateFromDisk`) and receives `WorkerEvent`s.

**What crosses the isolate boundary:**

- `ScanCountedEvent` — one per ingested QR string (new or duplicate).
- `ProgressSnapshotEvent` — a `ProgressSnapshot`: id, total, mode,
  encoding, `seenIndices` (just the index set, not bytes), byte counts,
  checksum/verified/error, completion timestamps.
- `ChunkBytesEvent` — a byte count, for UI-level throughput display.
- `TransferCompletedEvent` — a `ProgressSnapshot` plus the final assembled
  bytes (sent exactly once, on completion, not per chunk).
- `PersistErrorEvent` — disk I/O failures surfaced to the UI.

**What never crosses:** the `Transfer.chunks` byte map, the
`FountainDecoder`'s recovered-block map or pending-symbol pool. The
main-isolate `Transfer` is a lightweight mirror populated only from
`ProgressSnapshot`s (see `Transfer.applySnapshot`) — it never holds real
chunk bytes.

Spawning requires `BackgroundIsolateBinaryMessenger.ensureInitialized`
with the root isolate's token before any Flutter platform channel
(`path_provider`, etc.) can be used from the worker — a spawned isolate
has no messenger of its own until it registers with the root's.

## Consequences

- UI stays responsive through decode bursts and GF(2) elimination — the
  most CPU-intensive work never touches the UI isolate.
- Metadata writes are debounced per-transfer (`ChunkMetadataWriter`, ≤1
  write per 5s, immediate flush on completion/error/backgrounding) rather
  than per-chunk, cutting disk I/O during a scan burst.
- A platform-channel call made _from inside_ the worker isolate mid-scan
  (e.g. `path_provider`'s `getDownloadsDirectory()`) crashes the isolate
  outright ("Callbacks into the Dart VM are currently prohibited") — this
  bit twice during hydration (see [ADR-0003](0003-disk-hydration.md)) and
  is the sharp edge to remember before adding new platform-channel calls
  inside `_workerMain`.
- Only one worker isolate exists per app run; `AssemblerWorker.dispose()`
  kills it. No pooling, no multiple workers — not needed at current scale.

## Open questions

- None currently open; revisit if a future feature needs concurrent
  transfers processed genuinely in parallel (today all transfers share the
  one worker isolate, processed serially per QR scan).
