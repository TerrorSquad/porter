# ADR-0003: Disk hydration design

**Status:** Accepted · **Date:** 2026-08-09

## Context

A killed or backgrounded-then-evicted app shouldn't force a re-scan of
every already-received chunk. Chunks are written to disk incrementally as
they arrive (`ChunkStorage.writeChunk`, one `chunk_NNNNNN.bin` file per
recovered block, under `<outputDirectory>/<transfer.id>/chunks/`), so a
cold start has enough on disk to resume — the question is how to rebuild
in-memory `Transfer`/`FountainDecoder` state from that without either
re-scanning physical QR codes or crashing on real transfer sizes.

## Options (verified 2026-08-09)

- **Trust `metadata.json`'s `seenIndices`** — cheap to read (one small JSON
  file per transfer) but can lag behind the actual `.bin` files on disk,
  since metadata writes are debounced to at most once per 5s
  (`ChunkMetadataWriter`) for exactly the reason described in
  [ADR-0001](0001-worker-isolate.md). A crash between a chunk write and its
  next metadata flush would under-report what's actually on disk.
- **Trust `chunk_NNNNNN.bin` filenames as ground truth, `metadata.json` only
  for non-derivable fields** — filenames can't be stale in the same way;
  if the file exists, the chunk was fully written (writes are
  single-shot `writeAsBytes`, not incremental). This is what's implemented
  (`ChunkStorage.hydrateAll`/`_hydrateOne`).
- **Eagerly read every hydrated chunk's bytes into memory during the scan**
  — this was the first implementation and it crashed the receiver outright
  against a real multi-thousand-chunk transfer (two in-progress transfers,
  26k and 14k chunks): `HydrateAll`/`_hydrateOne` read every chunk file's
  `List<int>` for every resumable transfer at once, which was the wrong
  memory shape entirely for tens of thousands of chunks.

## Decision

`ChunkStorage.hydrateAll` scans `chunk_NNNNNN.bin` filenames only — never
their bytes — to rebuild each transfer's `seenIndices` set. A
`HydratedTransfer` carries that index set plus a lazy `readChunk(index)`
callback (`flutter/lib/models/hydrated_transfer.dart`). `Assembler.hydrate`
only calls `Transfer.markSeen(index)` for each — chunk bytes are read from
disk one at a time via `Transfer.chunkReader` only if a hydrated transfer
turns out to already be complete and needs assembling
(`Assembler._assemble`).

A transfer directory with a final `<id>.<ext>` output file already written
is skipped entirely during hydration — it's done, nothing to resume.

`metadata.json` is still read, but only for fields that can't be derived
from `.bin` filenames alone (`mode`, `encoding`, `total`,
`fountainFileSize`, `checksum`). A missing or corrupt `metadata.json`
(e.g. the app was killed mid-write) still yields a valid hydration with
those fields defaulted — `total`/`mode`/`checksum` are re-learned once the
sender re-sends its header/checksum chunks during the resumed scan.

The second bug that surfaced alongside the memory-shape issue: hydration
is triggered from `ScanningScreen` before any `ingestQR`/`setOutputDirectory`
call, so the worker isolate's `outputDirectory` was still unset when a
hydrated-and-already-complete transfer tried to assemble. Assembly's
completion path falls through to `FileHandler.resolveOutputDirectory`'s
`getDownloadsDirectory()` — a `path_provider` platform-channel call made
from inside the worker isolate mid-hydration-scan, which crashes the
isolate outright (see the platform-channel caveat in
[ADR-0001](0001-worker-isolate.md)). Fix: the `_HydrateFromDisk` message
now adopts its `outputDirectory` as the worker's working directory
up front, so assembly during hydration never needs the platform-channel
round trip.

## Known limitation

For fountain-encoded transfers, hydration only restores already-recovered
source blocks (credited immediately via `markSeen`). The underlying
`FountainDecoder`'s partial peeling state — pending symbols, seen `seq`
numbers — cannot be reconstructed from recovered bytes alone, so a resumed
fountain transfer's decoder starts peeling from scratch. Already-recovered
blocks aren't re-requested or re-decoded; new symbols scanned post-resume
feed a fresh decoder as normal. Worst case is redundantly re-processing
some already-effectively-seen symbol information, not a correctness loss
— final SHA-256 verification still gates completion regardless.

## Consequences

- Cold-start hydration against a real 26k+11k-chunk on-disk state
  completes in ~140ms with no crash (verified against the actual reported
  failure case).
- Disk (`.bin` filenames), not `metadata.json`, is the durable source of
  truth for "what's been received" — metadata.json is a display/debounce
  convenience, never load-bearing for correctness.
- Resumed fountain transfers pay a peeling-restart cost proportional to
  symbols-still-needed, not a correctness or memory cost.

## Open questions

- None currently open.
