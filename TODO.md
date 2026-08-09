# TODO

Working notes from the 2026-08-09 session (large fountain transfer debugging +
prod-readiness pass). Nothing here is committed yet — see "Uncommitted work".

## Immediate: the in-flight transfer

Transfer `1e`: a ~115 MB file, fountain, **K = 70965, blockSize = 1617**,
output dir: a local folder outside the repo (set in Settings).

- The transfer's `1e/chunks/` directory holds **only uniformly 1617-byte blocks**
  now — the 995 contaminated 2172-byte ones are gone, so the directory is
  clean and safe to resume against.
- Disk and metadata are **in sync** (checked live: 3532 chunk files vs 3531
  `seenIndices`, the 1 difference being a write in flight). An earlier
  reading of "30 blocks" was a mid-write snapshot, not data loss.
- Still real, and fixed this session: **hydration only ran once, at app
  launch**, so choosing an output directory _afterwards_ meant the app
  scanned the old location and ignored a resumable transfer already on disk.
  Changing the directory in Settings now re-hydrates.

### Sender settings for the restart

Receiver decodes ~13-19/s; the sender was showing ~85-195 ms/frame, so most
scans were duplicates (72% at one point).

- Use **`--speed=0.05`** (or `0.06`). Measured effect: ~8 h → ~2 h.
- **Do not bother with `--multi`.** `effective_multi_qr` only uses N codes if
  they all fit at the _same_ QR version; a 2x2 grid of v34 codes needs a
  ~316x156 terminal, so it silently falls back to 1.
- **Keep the terminal size fixed for the whole run.** Resizing recomputes K and
  blockSize mid-stream (`main.rs:518` → `layout()`), which forks the stream.
  The receiver now detects and handles this, but you lose the run's progress.

## Uncommitted work

39 changed files, nothing committed. Roughly:

- `rust-sender/`: QR encoding fixes, long-transfer warning, `--yes` flag.
- `flutter/lib/`: decoder rewrite (index + spill + Uint8List), resumability,
  layout-conflict detection, UI progress/ETA, app rename.
- `flutter/macos/`, `android/`: rename to PorterRx + `com.goranninkovic.porterrx`.
- `.github/workflows/`: new `rust-ci.yml`, rewritten `flutter-ci.yml`.
- `mise.toml`: build/strip/install tasks.

Suggested split into conventional commits (release-please parses these):

1. `fix(rust-sender): compute QR header reserve and force byte-mode encoding`
2. `fix(rust-sender): avoid u32 overflow in the fountain degree table`
3. `feat(rust-sender): warn before very long transfers (--yes to skip)`
4. `perf(flutter): make fountain peeling linear and bound decoder memory`
5. `feat(flutter): resumable fountain transfers via a seen-seqs sidecar`
6. `fix(flutter): treat (id, K, blockSize) as fountain transfer identity`
7. `fix(flutter): correct progress/ETA and per-transfer elapsed time`
8. `chore(flutter): rename app to PorterRx, real bundle id, arm64-only, icon`
9. `ci: add rust workflow, build macOS in flutter workflow`

## Distribution / prod readiness

- [ ] **Signing + notarization.** Currently ad-hoc signed, `TeamIdentifier=not
  set`, so Gatekeeper blocks it on any other Mac. Needs a Developer ID
      cert, `codesign --options runtime`, then `xcrun notarytool submit` +
      `xcrun stapler staple`. Requires your Apple Developer account.
- [ ] **Wire `macos/strip_x86_64.sh` into Xcode** as a Run Script build phase.
      Today it runs from `mise run flutter-build` and CI only, so a build
      straight from Xcode still produces a 44.7 MB universal bundle. Left out
      because hand-editing `project.pbxproj` is easy to corrupt — do it via
      Xcode's UI (Target → Build Phases → New Run Script Phase, after
      "Embed Frameworks").
- [ ] **App version is still `1.0.0+1`.** release-please covers the sender but
      not `flutter/pubspec.yaml`; decide whether to add it to
      `release-please-config.json`.
- [ ] **In-app title still says "Porter Receiver"** (`lib/main.dart:22`,
      `lib/screens/scanning_screen.dart:379`) while the bundle is PorterRx.
      Deliberate for now — it's a descriptive header, not the bundle name.
- [ ] Consider a `mise run flutter-release` task that builds, strips, signs,
      notarizes and staples in one go, once signing exists.

## Known limitations / deferred

- [ ] **Segmentation for large files.** The single biggest resumability win:
      split a big file into independent ~50 MB fountain streams so a crash
      loses one segment instead of everything. **Blocked on sender changes** —
      the user cannot update the sender machine right now, so the receiver
      must stay compatible with the current Node.js sender. `--split-aware`
      concatenates parts (the opposite); `porter join` is the receiver-side
      joiner and is Node-only.
- [ ] **1 GB is memory-feasible but not time-feasible.** With spilling, RAM
      stays flat (measured: ~0.57 GB → flat at 200k symbols for K=618429).
      Scanning is the wall: ~928k symbols ≈ **9.5 h** at 27 symbols/s. The
      channel is ~0.3 MB/s; no code change moves this.
- [ ] **Pending pool is not persisted**, only the seen-seq set. Persisting it
      would cost more I/O than rescanning (one blockSize buffer per unpeeled
      symbol, larger than the file). Consequence: a resumed transfer only
      skips seqs whose blocks are _all_ already recovered.
- [ ] **Gaussian elimination is disabled above 500 missing blocks**
      (`kDefaultMaxEliminationMissingCount`). Fine for large K, where peeling
      must carry it, but it means a "stuck core" at large K can't be rescued.
- [ ] `ponytail:` markers worth revisiting: - `scanner_provider.dart:105` — sender-interval estimate is a plain
      median, not outlier-robust. - `scanner_provider.dart:128` — speed-hint thresholds tuned from one
      session (1080p Brio). - `chunker.rs:147` — zero chunk size at a too-small version.

## Testing gaps

- [ ] **Nothing has been run on a real device.** All verification was
      `flutter test` + benchmarks on this Mac. Android is entirely untested
      after the namespace/package rename.
- [ ] No golden-image tests; the UI changes (progress bar contrast, ETA text)
      are unverified visually beyond screenshots.
- [ ] The spill path has correctness tests but no test at realistic K — the
      1 GB-scale measurements were throwaway scripts, not committed tests.

## Reference: measurements from this session

Worth keeping, since several fixes were sized against these.

| Thing                      | Before                            | After                                |
| -------------------------- | --------------------------------- | ------------------------------------ |
| Fountain endgame (K=70965) | 99.4 s total, 78.7 s worst freeze | 1.2 s total, 0.55 s worst            |
| Decoder RAM (K=20000)      | 158 MB                            | 56 MB                                |
| Full decode at K=70965     | —                                 | 21 s, 0.23 GB peak, 1.89x K symbols  |
| macOS bundle               | 43 MB universal                   | 22 MB arm64                          |
| Peeling overhead           | assumed 1.05x K                   | measured 1.33-1.89x K (UI uses 2.0x) |

Sender QR encoding: `qrcode`'s optimal segmentation charged more bits than the
byte-mode capacity tables assume, so payloads under the table limit were
rejected. Fixed by forcing a single Byte segment (`renderer::encode`), which
makes the tables exact. Wire format unchanged.

## Ideas / possible features

Ranked by "would this have saved pain today". Nothing here is committed to;
several are deliberately argued against.

### High value — directly fixes something that hurt

- [ ] **Preflight screen before a transfer starts.** The receiver knows K,
      blockSize and fileSize from the first symbol. Show a one-time card:
      "115 MB · 70965 blocks · ~2 h at the current rate · output → <dir>"
      with Start / Change folder. Every wasted run today
      came from a wrong assumption that was knowable up front (wrong output
      dir, unrealistic duration, contaminated directory).
- [ ] **Surface the layout-conflict and archive events in the UI.** The
      receiver now detects a sender relayout and archives old chunks, but only
      emits `PersistErrorEvent`, which reads as an error. It deserves a real
      banner: "Sender layout changed (K 70965 → 60000). Earlier blocks kept in
      chunks*superseded*\*."
- [ ] **Show the resolved output directory on the scanning screen.** One line
      of text would have prevented a wrong-output-directory mistake that cost
      a full restart (the configured path did not exist, so the app silently
      resolved elsewhere and began from block 1).
- [ ] **"Sender too slow" as an actionable hint, with the number.** The HUD
      says "could go faster ⚡" but not what to do. It has
      `estimatedSenderIntervalMs`; it could say "sender at 195 ms/frame — try
      --speed=0.05" and cut a run from 8 h to 2 h.
- [ ] **Health check / doctor for a transfer directory.** Scan for mixed block
      sizes, metadata that disagrees with the `.bin` files, orphaned
      `chunks_superseded_*`. Would have flagged the `1e` contamination in
      seconds instead of an hour of forensics.

### Medium value

- [ ] **Persist a resume manifest instead of trusting metadata.json.** Today
      `seenIndices` is rewritten wholesale, so a stale write can clobber it
      (observed: 2917 files on disk, 30 in metadata). Deriving from filenames
      already happens at hydrate; make that the only source and drop
      `seenIndices` from metadata.json to a display-only field.
- [ ] **Adaptive sender pacing via the relay.** `porter serve` already exists;
      a receiver that reports its decode rate could let the sender self-tune
      `--speed`. Removes the manual tuning loop entirely — but only works when
      a network path exists, which defeats the air-gap premise. Probably a
      "lab mode" only.
- [ ] **Show throughput in useful units.** "539 B/s" is technically right but
      meaningless; "~2 h remaining, 4.1 MB of 115 MB" is what the user needs.
- [ ] **Persist the pending pool across restarts** (currently deliberately
      not done — see Known limitations). Only worth it if the spill file can
      double as the resume artifact, since the bytes are already on disk.

### Low value / argued against

- [ ] ~~Multi-threaded decoding.~~ Peeling is a dependency chain, already off
      the UI isolate, and Dart isolates don't share memory. The 82x win came
      from fixing the algorithm; parallelism would have added complexity for
      approximately nothing.
- [ ] ~~`--multi` grid for throughput.~~ Only engages when N codes fit at the
      _same_ QR version; at v34 that needs a ~316x156 terminal, so it silently
      no-ops. Would need per-code version selection to be useful — a real
      sender change for a modest gain.
- [ ] ~~Docs site.~~ See below.

## Do we need a docs site?

**Not yet — and building one now would make things worse, not better.**

Measured: Porter already has ~2300 lines of Markdown across 19 files (5 ADRs,
4 package READMEs, architecture/setup/features specs). Forge's entire
VitePress site is ~1100 lines. Porter is not under-documented; it has _more_
prose than the project you're comparing it to.

What Porter lacks that Forge has is a _reason_ for a site: Forge is an
installable CLI with `install.sh`, releases, backends and hooks that other
people configure. Porter today has one user, an unsigned local build, and no
distribution story. A site would add a build pipeline, a deploy target, and a
second place for docs to drift.

And drift is the actual problem. This session found `docs/adr/0003` asserting
that seen-seq state "cannot be reconstructed" — the exact opposite of the code
after the resumability work — and `flutter/docs/setup.md` still naming
`porter_receiver.app`. Both are now fixed. A site would have rendered those
untruths more attractively.

**Correction after checking the other projects:** gstack and griffin both run
Nuxt Content sites, forge runs VitePress, agent-skills is plain Markdown — so
a docs site is an established pattern here, not an exotic ask. The judgement
above still holds for _developer_ docs (Porter has ~2300 lines already, more
than forge's whole site, and no external users yet). But it does not hold for
a **portfolio entry**, which is a different job: audience, not reference.

- [x] **Portfolio entry written**:
      `~/Projects/vue3/nuxt3-portfolio/content/projects/porter.md`, matching
      the existing schema (validated against `content.config.ts`), `order:
  1.2` to sit just after forge. No `docs:` link yet — add one if a site
      ever ships. Frontmatter omits `image:` because
      `public/projects/porter.webp` does not exist; **a screenshot or short
      GIF of a live transfer is the single highest-value addition** — this
      project is much easier to show than to describe.
- [ ] Consider a short demo GIF (sender slideshow + phone decoding) for both
      the portfolio entry and the repo README. `demo.tape` in forge is the
      VHS precedent.

**Revisit a real docs site when** any of these becomes true:

- Porter is signed/notarized and someone other than you installs it.
- The Rust sender gets a real release + `install.sh` (then a CLI reference
  page genuinely helps, as it does for Forge).
- The wire format is stable enough to publish as a spec others implement
  against — that's the one doc a third party would actually need.

**Done instead of a site:** `docs/wire-format.md` now holds one normative
description of all three frame shapes, the transfer-id derivation, the
xorshift32 PRNG, the degree table (including the two "looks like a bug but
isn't" details), redundancy, and the sizing math. That is the doc most likely
to prevent a real bug across three implementations, and it needs no site.

- [ ] Point `CLAUDE.md`, ADR 0002 and ADR 0004 at `docs/wire-format.md`
      instead of restating the format, so there's one place to keep correct.
