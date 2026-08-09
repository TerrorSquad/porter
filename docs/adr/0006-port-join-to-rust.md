# ADR-0006: Port `porter join` to Rust and remove JavaScript from the repo

Date: 2026-08-10

Status: Accepted. Resolves the open question left by
[ADR-0004](0004-sender-language-rust.md) ("Whether/when `porter join` gets
ported, and to what shape — deliberately deferred, not decided here").

## Context

ADR-0004 moved the sender and `porter serve` to Rust and deferred
`porter join` (`joiner.ts`, 178 lines), leaving `nodejs/` in the repo
indefinitely to host it. That left the project with two runtimes for one
tool: a static Rust binary for everything except a single subcommand that
still needed Node.js installed on the machine doing the joining.

Joining is the _last_ step of an air-gapped transfer, so it runs on the
same class of machine as the sender — exactly where "no Node.js runtime"
was the point of ADR-0004. The deferral was about scope, not merit, and
`join` is pure local file concatenation plus a SHA-256 check: no
networking, no terminal rendering, no wire-format compatibility surface.

## Decision

Port `porter join` to Rust as `rust-sender/src/join.rs`, then delete
`nodejs/` entirely — the package, its tests, and the prettier / eslint /
markdownlint toolchain it hosted. Porter becomes a two-language repo
(Rust sender, Dart receiver) with no JavaScript.

`join` keeps its own argument parser rather than reusing `cli.rs`'s flag
map. `joiner.ts` takes a space-separated `--output <path>` (plus `-o`/`-f`
short forms), while every sender flag is `--flag=value`; forcing them
together would have changed the join CLI's shape for no gain.

`alpha_part_suffix` is promoted from private-in-`serve.rs` to shared. The
receiver writes part files with it and the joiner reads them back, so the
two must agree by construction — a test round-trips the decoder against it
for indices 0..60.

## Deliberate divergence from the TypeScript

The port is behaviour-identical except in one case, where the TypeScript
is wrong.

`joiner.ts` decodes a part suffix with `idx * 26 + (ch.charCodeAt(0) - 97)`
and no validation, so any file sharing the `<base>.part` prefix is treated
as a part. A stray `dd.partaa.bak` decodes to a garbage index, sorts ahead
of the real parts, and is concatenated into the output. Verified against
the built TypeScript:

```console
$ node porter.standalone.mjs join dd     # parts: REAL-A, REAL-B, + dd.partaa.bak
Joining 3 parts (16 bytes total) → dd/dd.joined
Joined: dd/dd.joined (16 bytes)
$ cat dd/dd.joined
JUNKREAL-AREAL-B
```

It exits 0 and reports success. With a `.sha256` present this surfaces as
a checksum mismatch; without one the corruption is silent. The Rust
version rejects any suffix that is not all-lowercase-ASCII, joins the two
real parts, and is byte-correct. This is the only intentional behavioural
difference, and it is a bugfix, not a port artifact.

## Consequences

- `porter join` no longer requires Node.js. The Rust binary now covers
  every feature the TypeScript package had.
- **`nodejs/` was deleted outright**, along with the entire JavaScript
  toolchain it hosted — prettier, eslint, markdownlint, `pnpm-lock.yaml`,
  `pnpm-workspace.yaml`. The reason ADR-0004 gave for keeping the
  directory ("stays in the repo for `join` indefinitely") no longer held
  once `join` was ported, and nothing else depended on it: the
  cross-language fixture is committed under `flutter/test/` and read
  directly by the Rust and Dart suites, no CI workflow referenced Node,
  and eslint had no `.ts` files left to lint outside the package being
  deleted. The repo now has no JavaScript at all.
- Formatting is per-language and self-contained: `cargo fmt`,
  `dart format`, and `.editorconfig` for markup. **Nothing formats or
  lints Markdown anymore** — that capability was lost deliberately, as
  the cost of keeping a Node install alive for it was judged higher than
  the benefit. Reintroducing it means reintroducing a JS runtime, so
  prefer a Rust/Go-native Markdown linter if it is ever wanted back.
- The `forge` pre-commit hook drops its three Node tools and runs
  `cargo fmt` + `dart format` instead, so committing no longer depends on
  `node_modules` existing.
- Parity was verified by running both implementations against identical
  transfer directories and diffing stdout, exit codes, and output bytes:
  happy path, missing-part gap warnings, checksum mismatch, `--no-verify`,
  `--force`, existing-output refusal, explicit `--output`, multi-target,
  unknown flag, empty directory, and unresolvable target. All identical
  except the stray-file case above.
- The joiner's tests moved from trapping `process.exit` and monkey-patching
  `console` (what `joiner.test.ts` had to do) to asserting on a returned
  `JoinOutcome`. Same coverage, no global state.
- The TypeScript remains readable in git history — `git show
  backup-before-scrub:nodejs/src/lib/joiner.ts` — and the Rust modules
  still name their origin file in their `//!` headers. Those paths are
  historical pointers, not live ones.
