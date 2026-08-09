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
title: A link with no back-channel
description: The receiver cannot ask for a frame again. A dropped frame — bad angle, motion blur, a reflection at exactly the wrong moment — is simply gone, and every interesting decision in Porter follows from that.
features:
  - title: Sequential
    description: Frame n is byte range n. Miss one and you wait for the sender to loop all the way back to that index.
    icon: i-lucide-list-ordered
  - title: Fountain
    description: Each frame XORs a random subset of blocks, picked from its sequence number by a PRNG both sides run. Any sufficient pile rebuilds the file.
    icon: i-lucide-waves
  - title: So nothing is special
    description: No individual frame matters, which means a persistently missed one costs nothing at all.
    icon: i-lucide-shuffle
links:
  - label: How a transfer actually runs
    to: /how-it-works
    variant: link
    trailingIcon: i-lucide-arrow-right
---
::

::u-page-section
---
title: One binary on the sending machine
description: Porter is an air-gapped tool, so the sending machine is often not the one you keep a runtime on. The sender compiles to a single static binary — no Node.js, no Python, nothing to install alongside it.
features:
  - title: porter-sender <file>
    description: A ratatui TUI — QR grid, sidebar, scrubbing and gap-fill. Runs on the offline machine.
    icon: i-lucide-monitor-play
  - title: Receiver app
    description: Flutter, on Android and macOS. Scans, decodes, verifies, and resumes from disk if it is killed.
    icon: i-lucide-smartphone
  - title: porter-sender serve
    description: An HTTP receiver on axum, for when a network turns out to exist after all.
    icon: i-lucide-server
  - title: porter-sender join
    description: Reassembles the .partaa and .partab files a receiver wrote, with a SHA-256 check.
    icon: i-lucide-combine
links:
  - label: Every flag and subcommand
    to: /docs/reference/commands
    variant: link
    trailingIcon: i-lucide-arrow-right
---
::

::u-page-section
---
title: What Porter does not do
description: The security story is short, which is the point. No account, no server, no telemetry, and by default no trace left on disk.
features:
  - title: No network path
    description: The sender opens no sockets on the QR path. The transport is a camera pointed at a screen, so there is nothing to intercept in transit.
    icon: i-lucide-wifi-off
  - title: No disk trace by default
    description: Slideshow position persists only under --resume. Without the flag, nothing is written.
    icon: i-lucide-file-x
  - title: No telemetry
    description: No analytics, no crash reporting, no phone-home. Both binaries do exactly what the flags say.
    icon: i-lucide-eye-off
  - title: Verified on arrival
    description: Fountain transfers always carry a CHECKSUM frame. The receiver checks SHA-256 before saving.
    icon: i-lucide-shield-check
  - title: Resumable receiver
    description: Chunks land on disk as they decode, so a killed app rehydrates from the files rather than re-scanning.
    icon: i-lucide-rotate-ccw
  - title: Decisions on the record
    description: The worker isolate, fountain coding, disk hydration and the Rust move are all written up as ADRs.
    icon: i-lucide-file-text
---
::

::u-page-section
---
title: Honest limits, and an ISC licence
description: QR is a slow, lossy, line-of-sight link, and no amount of coding changes that. A 109 MB file is roughly 26,000 chunks — a real transfer that has been run end to end, and also a long time holding a phone at a screen. Porter is for the case where two machines genuinely cannot talk: no NIC, an isolated network, a device you will not plug anything into.
links:
  - label: Read the docs
    to: /docs/getting-started/introduction
    size: xl
    trailingIcon: i-lucide-arrow-right
  - label: View on GitHub
    to: https://github.com/TerrorSquad/porter
    target: _blank
    size: xl
    color: neutral
    variant: subtle
    icon: i-simple-icons-github
---
::
