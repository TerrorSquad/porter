<script setup lang="ts">
definePageMeta({ layout: 'default' })

const page = useDesignedPageSeo('/how-it-works')

const senderStages = [
  { title: 'Read', detail: 'The file is read whole, or piped in on stdin.', icon: 'i-lucide-file-input' },
  { title: 'Chunk', detail: 'Split to fit one QR code, sized from the terminal height.', icon: 'i-lucide-scissors' },
  { title: 'Encode', detail: 'Plain text, base64 for binary, gzip, or fountain symbols.', icon: 'i-lucide-binary' },
  { title: 'Frame', detail: 'Each chunk gets a pipe-separated header and becomes a QR code.', icon: 'i-lucide-qr-code' },
  { title: 'Render', detail: 'A ratatui slideshow you can scrub, pause and gap-fill.', icon: 'i-lucide-monitor-play' },
]

const receiverStages = [
  { title: 'Scan', detail: 'Continuous detection — no shutter, no trigger.', icon: 'i-lucide-scan-line' },
  { title: 'Parse', detail: 'The header identifies the transfer and the frame type.', icon: 'i-lucide-braces' },
  { title: 'Assemble', detail: 'A worker isolate peels fountain symbols and writes chunks to disk.', icon: 'i-lucide-blocks' },
  { title: 'Verify', detail: 'SHA-256 against the CHECKSUM frame, then save.', icon: 'i-lucide-shield-check' },
]

const flow = `Sending machine                      Receiving device
  (Rust binary)                        (Flutter app)

  read file
  chunk it
  encode
  build QR frames
  render slideshow ──── light ────►   camera
                                       decode QR
                                       parse frame
                                       assemble
                                       verify → save`

const fountainFrame = `F|seq|K|fileSize|id|payload

// seq       which blocks this symbol XORs together
// K         how many source blocks the file has
// fileSize  so the receiver can trim the zero padding
// id        two chars, derived from the file's digest`
</script>

<template>
  <div>
    <UContainer class="grid-surface relative pt-16 pb-12 sm:pt-24 sm:pb-16">
      <p class="font-mono text-xs uppercase tracking-[0.18em] text-primary">
        {{ page.eyebrow }}
      </p>
      <h1 class="mt-4 max-w-3xl text-4xl sm:text-6xl font-bold tracking-tight text-highlighted text-pretty">
        {{ page.heading }}
      </h1>
      <p class="mt-6 max-w-2xl text-lg text-muted text-pretty">
        {{ page.intro }}
      </p>
    </UContainer>

    <UContainer class="py-16 sm:py-24">
      <SectionHead v-bind="page.sections[0]!" />

      <div class="mt-10 grid gap-8 lg:grid-cols-2">
        <div>
          <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">Sender</p>
          <div class="mt-4 space-y-3">
            <div
              v-for="(stage, i) in senderStages"
              :key="stage.title"
              class="flex gap-4 rounded-[var(--ui-radius)] border border-default bg-elevated p-4"
            >
              <span class="font-mono text-xs text-dimmed pt-1">{{ String(i + 1).padStart(2, '0') }}</span>
              <UIcon :name="stage.icon" class="size-5 shrink-0 text-primary mt-0.5" />
              <div>
                <p class="font-medium text-highlighted">{{ stage.title }}</p>
                <p class="mt-1 text-sm text-muted">{{ stage.detail }}</p>
              </div>
            </div>
          </div>
        </div>

        <div>
          <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">Receiver</p>
          <div class="mt-4 space-y-3">
            <div
              v-for="(stage, i) in receiverStages"
              :key="stage.title"
              class="flex gap-4 rounded-[var(--ui-radius)] border border-default bg-elevated p-4"
            >
              <span class="font-mono text-xs text-dimmed pt-1">{{ String(i + 1).padStart(2, '0') }}</span>
              <UIcon :name="stage.icon" class="size-5 shrink-0 text-primary mt-0.5" />
              <div>
                <p class="font-medium text-highlighted">{{ stage.title }}</p>
                <p class="mt-1 text-sm text-muted">{{ stage.detail }}</p>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="mt-8">
        <CodeCard file="the whole protocol" :code="flow" lang="text" />
      </div>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[1]!" />

      <div class="mt-10 grid gap-6 sm:grid-cols-2">
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <UIcon name="i-lucide-arrow-right" class="size-5 text-primary" />
          <p class="mt-3 font-medium text-highlighted">What the sender knows</p>
          <p class="mt-2 text-sm text-muted">
            Nothing. It does not know whether anyone is scanning, how much has been
            caught, or whether the receiver exists. It draws frames until you stop it.
          </p>
        </div>
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <UIcon name="i-lucide-eye" class="size-5 text-primary" />
          <p class="mt-3 font-medium text-highlighted">What the receiver can ask for</p>
          <p class="mt-2 text-sm text-muted">
            Nothing. A frame lost to glare, blur or a bad angle is simply gone. There is
            no retransmit request, because there is no channel to send one on.
          </p>
        </div>
      </div>

      <p class="mt-8 max-w-2xl text-base text-muted text-pretty">
        Every other design decision follows from this. It is why fountain coding is in
        the box, why the checksum travels in-band, and why the receiver writes chunks to
        disk as it goes instead of holding them until the end.
      </p>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[2]!" />

      <div class="mt-10 grid gap-8 lg:grid-cols-2 lg:items-start">
        <div class="space-y-4">
          <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
            <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">Sequential</p>
            <p class="mt-3 text-sm text-muted">
              Frame <em>n</em> is byte range <em>n</em> of the file. Simple, and enough for a
              few hundred chunks. Miss one and you wait for the sender to loop back to
              exactly that index — or drive it there yourself with gap-fill mode.
            </p>
          </div>
          <div class="rounded-[var(--ui-radius)] border border-primary/40 bg-elevated p-6">
            <p class="font-mono text-xs uppercase tracking-[0.18em] text-primary">Fountain</p>
            <p class="mt-3 text-sm text-muted">
              Each frame is the XOR of a pseudo-random subset of the file's blocks, chosen
              from the frame's sequence number by a PRNG both sides run independently.
              Collect enough and peeling recovers everything. No specific frame matters.
            </p>
          </div>
        </div>

        <CodeCard file="fountain frame" :code="fountainFrame" lang="text" :highlight="[1]" />
      </div>

      <p class="mt-8 max-w-2xl text-base text-muted text-pretty">
        The catch is that "enough" is more than <code class="font-mono text-sm">K</code>.
        Peeling needs between 1.33× and 1.89× the number of source blocks, so a progress
        bar scaled to <code class="font-mono text-sm">K</code> sits at 99% with a third of
        the scanning still to do.
      </p>

      <div class="mt-6">
        <UButton
          to="/docs/reference/wire-format"
          variant="link"
          class="!p-0"
          trailing-icon="i-lucide-arrow-right"
          label="The full wire format"
        />
      </div>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[3]!" />

      <div class="mt-10 grid gap-6 md:grid-cols-3">
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <UIcon name="i-lucide-camera" class="size-5 text-primary" />
          <p class="mt-3 font-medium text-highlighted">Scan</p>
          <p class="mt-2 text-sm text-muted">
            The normal path. Point the app at the terminal; it assembles, verifies and
            saves, resuming from disk if it is killed partway.
          </p>
        </div>
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <UIcon name="i-lucide-server" class="size-5 text-primary" />
          <p class="mt-3 font-medium text-highlighted"><code class="font-mono text-sm">serve</code></p>
          <p class="mt-2 text-sm text-muted">
            An HTTP receiver, for when a network turns out to exist after all. Takes raw
            uploads, multipart, and QR-scan JSON alike.
          </p>
        </div>
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <UIcon name="i-lucide-combine" class="size-5 text-primary" />
          <p class="mt-3 font-medium text-highlighted"><code class="font-mono text-sm">join</code></p>
          <p class="mt-2 text-sm text-muted">
            Reassembles the <code class="font-mono text-xs">.partaa</code> files a receiver
            wrote, checking them against the recorded digest.
          </p>
        </div>
      </div>
    </UContainer>
  </div>
</template>
