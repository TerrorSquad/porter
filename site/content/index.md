---
seo:
  title: Air-gapped file transfer over QR codes
  description: Move a file between two machines with no network between them. A terminal renders it as a QR slideshow, a phone scans it back, and fountain coding means no frame has to be caught twice.
---

::u-page-hero
---
orientation: horizontal
class: grid-surface
---
#headline
Free · ISC · Rust sender · Flutter receiver

#title
The QR codes are the wire.

#description
Porter moves a file between two machines that share no network. A terminal
displays it as a slideshow of QR codes, a phone camera reads them back, and
fountain coding means the receiver never has to catch any particular frame.

#links
  :::u-button
  ---
  to: /docs/getting-started/installation
  size: xl
  trailing-icon: i-lucide-arrow-right
  ---
  Get started
  :::

  :::u-button
  ---
  to: https://github.com/TerrorSquad/porter
  target: _blank
  size: xl
  color: neutral
  variant: subtle
  icon: i-simple-icons-github
  ---
  View on GitHub
  :::

#default
```bash
cd rust-sender
cargo build --release

./target/release/porter-sender myfile.pdf --fountain
# Point the receiver app at the terminal. That's the whole protocol.
```
::

::u-page-section
---
headline: 01 — The constraint
---
#title
A link with no back-channel

#description
The receiver cannot ask for a frame again. A dropped frame — bad angle, motion
blur, a reflection at exactly the wrong moment — is simply gone, and every
interesting decision in Porter follows from that.

#default
Sequential mode numbers each chunk, so a missed frame means waiting for the
sender to loop all the way back to that index. Fountain mode makes each frame
the XOR of a pseudo-random subset of the file's blocks, derived from the frame's
sequence number by a PRNG both sides share:

```text
F|seq|K|fileSize|id|payload
```

Any sufficiently large pile of those frames rebuilds the file, in any order. No
individual frame matters, so a persistently missed one costs nothing.

:u-button{to="/how-it-works" variant="link" trailing-icon="i-lucide-arrow-right" label="How a transfer actually runs"}
::

::u-page-section
---
headline: 02 — The contract
---
#title
Two implementations, derived bit for bit

#description
A Rust sender and a Dart receiver independently compute which source blocks each
fountain symbol carries. They never exchange that mapping — they recompute it
from `seq`. Drift by one bit and transfers fail to decode, silently.

#default
```text
state = seq XOR 0x9e3779b9
next():
  state ^= state << 13
  state ^= state >> 17
  state ^= state << 5
  return state
```

So the degree table is specified in integers only, `i * (i - 1)` is computed in
64-bit because it overflows `u32` past K≈65536, and agreement is checked against
shared fixtures rather than by trusting two codebases to stay in step.

:u-button{to="/wire-format" variant="link" trailing-icon="i-lucide-arrow-right" label="Read the wire format"}
::

::u-page-section
---
headline: 03 — What it costs you
---
#title
One binary on the sending machine

#description
Porter is an air-gapped tool, so the sending machine is often not the one you
keep a runtime on. The sender compiles to a single static binary with no
Node.js, no Python, and nothing to install alongside it.

#default
| Piece | What it is | Where it runs |
| --- | --- | --- |
| `porter-sender <file>` | ratatui TUI — QR grid, sidebar, scrubbing, gap-fill | The offline machine |
| Receiver app | Flutter, Android + macOS, resumes from disk | The phone with the camera |
| `porter-sender serve` | HTTP receiver on axum, for when a network does exist | Either |
| `porter-sender join` | Reassembles `.partaa`, `.partab`, … with a SHA-256 check | Either |

The repo carries no JavaScript at all — the TypeScript sender and its whole
toolchain were deleted once `join` was ported.

:u-button{to="/docs/reference/commands" variant="link" trailing-icon="i-lucide-arrow-right" label="Every flag and subcommand"}
::

::u-page-section
---
headline: 04 — Offline, and provably so
title: What Porter does not do
description: The security story is short, which is the point. There is no account, no server, no telemetry, and by default no trace left on disk.
features:
  - title: No network path
    description: The sender opens no sockets on the QR path. The transport is a camera pointed at a screen, so there is nothing to intercept in transit.
    icon: i-lucide-wifi-off
  - title: No disk trace by default
    description: Slideshow position persists only under --resume, which writes .porter_history. Without the flag, nothing is written.
    icon: i-lucide-file-x
  - title: No telemetry
    description: No analytics, no crash reporting, no phone-home. Both binaries do exactly what the flags say and nothing else.
    icon: i-lucide-eye-off
  - title: Verified on arrival
    description: Fountain transfers always carry a CHECKSUM frame; sequential ones do with --verify. The receiver checks SHA-256 before saving.
    icon: i-lucide-shield-check
  - title: Resumable receiver
    description: Chunks land on disk as they decode, so a killed app rehydrates from the files themselves rather than re-scanning.
    icon: i-lucide-rotate-ccw
  - title: Decisions on the record
    description: The worker isolate, fountain coding, disk hydration and the Rust move are all written up as ADRs, including the gaps left open.
    icon: i-lucide-file-text
---
::

::u-page-section
---
headline: 05 — Where it stops
---
#title
Honest limits

#description
QR codes are a slow, lossy, line-of-sight link, and no amount of coding makes
them otherwise. Throughput depends on lighting, terminal size and how steady
the hand holding the camera is.

#default
A 109 MB file is roughly 26,000 chunks. That is a real transfer that has been
run end to end — it is also a long time spent holding a phone at a screen, and
`porter serve` exists precisely for when the two machines can see each other
over a network after all.

Porter is for the case where they genuinely cannot: a machine with no NIC, an
isolated network, a device you will not plug anything into.
::

::u-page-section
---
links:
  - label: Read the docs
    to: /docs/getting-started/introduction
    size: xl
    trailingIcon: i-lucide-arrow-right
  - label: Browse the decisions
    to: /design
    size: xl
    color: neutral
    variant: subtle
---
#title
Free and ISC licensed

#description
A hobby project in daily use. Clone it, build the sender, and move a file across
a gap that nothing else crosses.
::
