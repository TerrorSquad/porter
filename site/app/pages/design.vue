<script setup lang="ts">
definePageMeta({ layout: 'default' })

const page = useDesignedPageSeo('/design')

const isolate = `// Wrong shape: state must persist across
// thousands of calls, so a fresh isolate per
// scan would mean shipping the whole decode
// state across the boundary every frame.
compute(decodeChunk, payload)

// Right shape: spawned once, owns Assembler +
// FountainDecoder + all disk I/O for the app's
// lifetime. Only ProgressSnapshots come back.
AssemblerWorker.spawn()`

const hydration = `<outputDirectory>/<transfer.id>/chunks/
  chunk_000001.bin
  chunk_000002.bin
  ...

// Filenames are ground truth. metadata.json is
// debounced to once per 5s, so it can lag what
// is actually on disk after a crash.`

const decisions = [
  { id: '0001', title: 'Flutter receiver worker isolate', status: 'Accepted' },
  { id: '0002', title: 'Fountain (LT-code) vs. sequential encoding', status: 'Accepted' },
  { id: '0003', title: 'Disk hydration design', status: 'Accepted' },
  { id: '0004', title: 'Sender language — TypeScript → Rust', status: 'Accepted' },
  { id: '0005', title: 'mobile_scanner pinned at the vendored fork', status: 'Known gap' },
  { id: '0006', title: 'porter join ported to Rust; all JS deleted', status: 'Accepted' },
]
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

      <div class="mt-10 flex flex-wrap gap-2">
        <UBadge
          v-for="d in decisions"
          :key="d.id"
          :color="d.status === 'Known gap' ? 'warning' : 'neutral'"
          variant="subtle"
          class="font-mono text-xs"
        >
          ADR-{{ d.id }}
        </UBadge>
      </div>
    </UContainer>

    <UContainer class="py-16 sm:py-24">
      <SectionHead v-bind="page.sections[0]!" />

      <div class="mt-10 grid gap-8 lg:grid-cols-2 lg:items-start">
        <div class="space-y-4 text-base text-muted">
          <p>
            Fountain peeling, GF(2) elimination, gzip, SHA-256 and per-chunk disk writes
            all ran synchronously on the UI isolate. A real 109 MB, ~26,000-chunk transfer
            made that impossible to ignore: the interface froze during decode bursts.
          </p>
          <p class="text-toned">
            The obvious fix — <code class="font-mono text-sm">compute()</code> per call —
            is the wrong shape. The decoder's state has to survive across every scan, and
            re-creating it per frame means serialising all of it, every time.
          </p>
        </div>

        <CodeCard file="the choice" :code="isolate" lang="dart" :highlight="[9, 10, 11]" />
      </div>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[1]!" />

      <div class="mt-10 grid gap-6 sm:grid-cols-2">
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">Considered</p>
          <p class="mt-3 font-medium text-highlighted">Sequential only</p>
          <p class="mt-2 text-sm text-muted">
            Simplest, but one consistently-missed frame — bad angle, blur at the same
            point in every loop — stalls the transfer until the sender comes back around.
          </p>
        </div>
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">Considered</p>
          <p class="mt-3 font-medium text-highlighted">Fountain only</p>
          <p class="mt-2 text-sm text-muted">
            No positional dependency, but per-symbol decode overhead that small files do
            not need and do not benefit from.
          </p>
        </div>
      </div>

      <div class="mt-6 rounded-[var(--ui-radius)] border border-primary/40 bg-elevated p-6">
        <p class="font-mono text-xs uppercase tracking-[0.18em] text-primary">Decided</p>
        <p class="mt-3 font-medium text-highlighted">Both, sender-selectable</p>
        <p class="mt-2 text-sm text-muted">
          Sequential for small transfers, <code class="font-mono text-sm">--fountain</code>
          for long or lossy ones. The wire format's leading token — <code class="font-mono text-sm">F</code>
          against a bare index — tells the receiver which it is looking at, so no
          negotiation is needed on a link that could not carry one anyway.
        </p>
      </div>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[2]!" />

      <div class="mt-10 grid gap-8 lg:grid-cols-2 lg:items-start">
        <CodeCard file="what a resumable transfer looks like on disk" :code="hydration" lang="text" />

        <div class="space-y-4 text-base text-muted">
          <p>
            Metadata writes are debounced to at most once every five seconds — for exactly
            the UI-blocking reason above — so a crash can leave
            <code class="font-mono text-sm">metadata.json</code> reporting less than what
            actually landed.
          </p>
          <p class="text-toned">
            Chunk files cannot be stale that way: writes are single-shot, so a file that
            exists was fully written. Hydration reads the filenames and consults metadata
            only for what it cannot derive from them.
          </p>
          <p>
            The first version read every hydrated chunk's bytes into memory while
            scanning, and crashed outright on a real multi-thousand-chunk transfer. It now
            records what exists without loading it.
          </p>
        </div>
      </div>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[3]!" />

      <div class="mt-10 grid gap-6 md:grid-cols-3">
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <p class="mt-1 font-medium text-highlighted">TypeScript</p>
          <p class="mt-2 text-sm text-muted">
            Bundles to a standalone <code class="font-mono text-xs">.mjs</code>, but that
            still needs a Node runtime on the machine doing the sending.
          </p>
        </div>
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <p class="mt-1 font-medium text-highlighted">Go</p>
          <p class="mt-2 text-sm text-muted">
            A single static binary, so the runtime problem goes away. The terminal UI story
            is more hand-rolled — no equivalent of ratatui at the same maturity.
          </p>
        </div>
        <div class="rounded-[var(--ui-radius)] border border-primary/40 bg-elevated p-6">
          <p class="font-mono text-xs uppercase tracking-[0.18em] text-primary">Chosen</p>
          <p class="mt-1 font-medium text-highlighted">Rust</p>
          <p class="mt-2 text-sm text-muted">
            Static binary, plus <code class="font-mono text-xs">ratatui</code>/<code class="font-mono text-xs">crossterm</code>
            for the scrubbing, jump-to-chunk and gap-fill controls the sender needed.
          </p>
        </div>
      </div>

      <p class="mt-8 max-w-2xl text-base text-muted text-pretty">
        ADR-0004 deferred <code class="font-mono text-sm">porter join</code>, which left
        the repo needing two runtimes for one tool. ADR-0006 closed it: joining is the
        last step of an air-gapped transfer, so it runs on exactly the machine that
        motivated the move. With it ported, <code class="font-mono text-sm">nodejs/</code>
        and the whole JavaScript toolchain were deleted.
      </p>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[4]!" />

      <div class="mt-10 max-w-3xl">
        <UAlert
          color="warning"
          variant="subtle"
          icon="i-lucide-triangle-alert"
          title="mobile_scanner is pinned at 7.2.0"
          description="The vendored fork carries a local patch adding macOS external-camera enumeration and selection, which upstream does not support. Upstream is at 7.4.0; re-diffing the patch is real effort with real risk to camera selection — the entire reason the fork exists — for a changelog that is mostly camera lifecycle and orientation fixes. Recorded as a gap rather than quietly carried."
        />
      </div>

      <div class="mt-10">
        <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">All records</p>
        <div class="mt-4 divide-y divide-default border-y border-default">
          <div
            v-for="d in decisions"
            :key="d.id"
            class="flex items-center gap-4 py-3"
          >
            <span class="font-mono text-xs text-dimmed">ADR-{{ d.id }}</span>
            <span class="text-sm text-toned flex-1">{{ d.title }}</span>
            <UBadge
              :color="d.status === 'Known gap' ? 'warning' : 'success'"
              variant="subtle"
              size="sm"
            >
              {{ d.status }}
            </UBadge>
          </div>
        </div>
      </div>

      <div class="mt-8">
        <UButton
          to="/docs/reference/decisions"
          variant="link"
          class="!p-0"
          trailing-icon="i-lucide-arrow-right"
          label="The decision records in full"
        />
      </div>
    </UContainer>
  </div>
</template>
