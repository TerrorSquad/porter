# Roadmap

Planned work, open questions and deliberate non-goals. Things already done
live in the git history and `CHANGELOG.md`, not here.

## Blocking distribution

- [ ] **Sign and notarize the macOS app.** It is currently ad-hoc signed with
      no Team ID, so Gatekeeper blocks it on any machine but the one that
      built it. Needs a Developer ID certificate, `codesign --options
    runtime`, then `xcrun notarytool submit` and `xcrun stapler staple`.
      Nothing else on this list matters for other people until this is done.
- [ ] **A `flutter-release` task** that builds, strips, signs, notarizes and
      staples in one step, once signing exists.
- [ ] **Version the Flutter app.** Still `1.0.0+1`; release-please covers the
      sender but not `flutter/pubspec.yaml`. Decide whether to add it to
      `release-please-config.json` or version it separately.
- [ ] **Wire `macos/strip_x86_64.sh` into Xcode** as a Run Script phase (after
      "Embed Frameworks"). It runs from `mise` and CI today, so a build
      started from Xcode still produces a universal bundle at twice the size.
      Left out of the project file deliberately — hand-editing
      `project.pbxproj` is easy to corrupt; do it through Xcode's UI.

## Receiver UX

Ranked by how much confusion each would remove.

- [ ] **Preflight card before a transfer starts.** The first symbol already
      carries K, block size and file size, so the receiver can show
      "115 MB · 70965 blocks · ~2 h at this rate · output → <dir>" with
      Start / Change folder. Most wasted runs come from an assumption that
      was knowable up front.
- [ ] **Show the resolved output directory while scanning.** A path that does
      not exist resolves silently to the default, and the transfer starts over
      from block 1 with no visible cause.
- [ ] **Make the "sender too slow" hint actionable.** The HUD knows
      `estimatedSenderIntervalMs`; it could name the fix ("sender at 195
      ms/frame — try `--speed=0.05`") rather than only flagging that headroom
      exists. This is worth hours on a large transfer.
- [ ] **Surface layout-conflict and archive events properly.** The receiver
      detects a sender relayout and archives the superseded chunks, but
      reports it as a `PersistErrorEvent`, which reads as a failure. It should
      be a plain banner explaining what happened and where the old blocks went.
- [ ] **Transfer directory health check.** Scan for mixed block sizes,
      metadata that disagrees with the `.bin` files on disk, and orphaned
      `chunks_superseded_*` directories.

## Reliability

- [ ] **Stop treating `metadata.json` as the record of received chunks.**
      `seenIndices` is rewritten wholesale, so a stale write can clobber it,
      and hydration already derives the truth from `.bin` filenames anyway.
      Make the filenames the only source and demote the metadata field to
      display-only.
- [ ] **Test the spill path at realistic K.** It has correctness tests, but
      the gigabyte-scale measurements were throwaway scripts. A committed
      benchmark-style test would catch a regression in the memory ceiling.
- [ ] **Verify on real devices.** All verification so far is `flutter test`
      plus benchmarks on a development Mac. Android in particular is untested
      since the namespace and package rename.

## Larger changes

- [ ] **Segment large transfers.** Split a big file into independent ~50 MB
      fountain streams, each decoding and verifying on its own. Caps memory at
      one segment regardless of total size, makes progress durable, and means
      an interrupted transfer loses one segment rather than everything.
      **Blocked on sender changes** — `porter join` already exists on the
      Node.js side for reassembly, but `--split-aware` currently does the
      opposite (it concatenates parts into one transfer).
- [ ] **Persist the pending symbol pool.** Deliberately not done: one
      block-sized buffer per unpeeled symbol is collectively larger than the
      file, so writing it costs more than rescanning. Only worth revisiting if
      the spill file can double as the resume artifact, since those bytes are
      already on disk.
- [ ] **Revisit the Gaussian-elimination cutoff.** Disabled above 500 missing
      blocks, which is right for large K where peeling must carry the
      transfer, but it means a stuck core at large K cannot be rescued.

## Documentation

- [ ] **Point `CLAUDE.md`, ADR 0002 and ADR 0004 at `docs/wire-format.md`**
      rather than restating the format, so there is one place to keep correct.
- [ ] **A demo GIF** of a live transfer (sender slideshow plus receiver
      decoding), for the README and the portfolio entry. This project is much
      easier to show than to describe.
- [ ] **A docs site — not yet.** There is already more prose here (~2300 lines
      across ADRs, package READMEs and architecture notes) than some shipped
      sites carry, with no external users and no distributable build. A site
      would add a pipeline and a second place for docs to drift, and drift is
      the actual failure mode: an ADR recently asserted the opposite of the
      code. Revisit once the app is notarized and installable by someone else,
      or once the wire format is published as a spec third parties implement
      against.

## Non-goals

Recorded so they don't get re-proposed.

- **Multi-threaded decoding.** Peeling is a dependency chain — each recovered
  block determines what becomes solvable next — it already runs off the UI
  isolate, and Dart isolates do not share memory, so splitting the pool means
  copying it. The large win here came from fixing the algorithm's complexity,
  not from parallelism.
- **`--multi` for throughput.** It only engages when N codes fit at the _same_
  QR version; at the versions large transfers use, a 2x2 grid needs a terminal
  far larger than any real one, so it silently falls back to a single code.
  Useful only with per-code version selection, which is a real sender change
  for a modest gain.
- **Chasing 1 GB transfers.** Memory is handled — the pending pool spills to
  disk and stays flat. Time is not: QR is roughly a 0.3 MB/s channel, so a
  gigabyte is ~9.5 hours of uninterrupted scanning. The sender now estimates
  and warns instead of pretending otherwise. Porter targets the
  tens-of-megabytes case.

## Known constraints

Context for anyone picking this up, not tasks.

- **A fountain transfer's identity is `(id, K, blockSize)`, not `id`.** The
  chunk id is a hash of file _content_, so the same file sent at a different
  QR version reuses it with an incompatible layout.
- **Resizing the sender's terminal mid-transfer forks the stream.** It
  recomputes K and block size on resize. The receiver detects and adapts, but
  the run's progress is lost.
- **Peeling needs materially more than K symbols** — measured 1.33x–1.89x.
  Progress UI scales against 2x K so it under-promises.
- **Only fully-recovered seqs are safely resumable.** The seen-seq set is
  persisted; the pending pool is not, so a seq whose contribution lived only
  in a dropped buffer must be rescanned.
