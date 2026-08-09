<script setup lang="ts">
definePageMeta({ layout: 'default' })

const page = useDesignedPageSeo('/wire-format')

const frames = `index|total|mode|id|payload      // sequential data
F|seq|K|fileSize|id|payload      // fountain symbol
CHECKSUM|T|id|sha256             // digest of the original file`

const transferId = `value = (digest[0] << 8) | digest[1]
id    = ALPHABET[(value >> 6) & 0x3f]
      + ALPHABET[value & 0x3f]

ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
         + "WXYZabcdefghijklmnopqrstuvwxyz-_"`

const prng = `state = seq XOR 0x9e3779b9   // if 0, use 0x9e3779b9

next():
  state ^= state << 13
  state ^= state >> 17
  state ^= state << 5
  return state                 // u32, wrapping`

const degreeTable = `weights[1] = 1
weights[i] = floor(K / (i * (i - 1)))   for i = 2..K

S = max(2, floor(sqrt(K)))
weights[i] += max(1, floor(S / i))      for i = 1..S-1
weights[S] += S`

const pitfalls = [
  {
    title: 'weights[i] is not floored to 1',
    detail:
      'It reaches 0 once i*(i-1) > K, around i > sqrt(K), and that is exactly what caps the maximum degree. Flooring it would give every high degree equal weight and make large-K transfers effectively undecodable.',
    icon: 'i-lucide-triangle-alert',
  },
  {
    title: 'i * (i - 1) must be 64-bit',
    detail:
      'It overflows u32 past i ≈ 65536, which a large file genuinely reaches. This was a real bug: the product wrapped to a bogus divisor and corrupted the entire degree distribution.',
    icon: 'i-lucide-circle-alert',
  },
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
    </UContainer>

    <UContainer class="py-16 sm:py-24">
      <SectionHead v-bind="page.sections[0]!" />

      <div class="mt-10 grid gap-8 lg:grid-cols-2 lg:items-start">
        <CodeCard file="the three frame shapes" :code="frames" lang="text" />

        <div class="space-y-4 text-base text-muted">
          <p>
            No binary framing, because a QR payload is already a string. Fields are
            separated by <code class="font-mono text-sm">|</code>, and the leading token
            says which shape you are looking at.
          </p>
          <p class="text-toned">
            The payload of a sequential frame <strong>may itself contain a pipe</strong>,
            so a parser must split on the first four separators only — not on every one it
            finds. This is the single most common way to get the format wrong.
          </p>
          <p>
            <code class="font-mono text-sm">blockSize</code> is never transmitted. The
            receiver infers it from the decoded payload length, since every fountain
            symbol is exactly one block.
          </p>
        </div>
      </div>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[1]!" />

      <div class="mt-10 grid gap-8 lg:grid-cols-2 lg:items-start">
        <CodeCard file="transfer id, from the file digest" :code="transferId" lang="text" />

        <div class="space-y-4">
          <p class="text-base text-muted">
            Two characters, taken from the first two bytes of the file's SHA-256. Cheap to
            put in every frame, and enough to tell two concurrent transfers apart.
          </p>
          <UAlert
            color="warning"
            variant="subtle"
            icon="i-lucide-triangle-alert"
            title="Do not key on the id alone"
            description="The id identifies content, not a session. The same file sent twice gets the same id — and if the terminal was resized in between, a different K and blockSize with it. Those two streams are mutually undecodable, so a receiver must key fountain state on (id, K, blockSize)."
          />
        </div>
      </div>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[2]!" />

      <div class="mt-10 grid gap-6 lg:grid-cols-2">
        <CodeCard file="xorshift32" :code="prng" lang="text" />
        <CodeCard file="degree table" :code="degreeTable" lang="text" />
      </div>

      <p class="mt-8 max-w-2xl text-base text-muted text-pretty">
        Integer weights only, so the same table and the same draw-by-modulo produce
        identical degrees in both languages. Dart masks to 32 bits explicitly; Rust's
        <code class="font-mono text-sm">u32</code> wraps natively.
      </p>

      <div class="mt-8 grid gap-6 sm:grid-cols-2">
        <div
          v-for="item in pitfalls"
          :key="item.title"
          class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6"
        >
          <UIcon :name="item.icon" class="size-5 text-warning" />
          <p class="mt-3 font-medium text-highlighted font-mono text-sm">{{ item.title }}</p>
          <p class="mt-2 text-sm text-muted">{{ item.detail }}</p>
        </div>
      </div>

      <p class="mt-8 max-w-2xl text-base text-muted text-pretty">
        Agreement between the two implementations is checked against shared fixtures —
        <code class="font-mono text-sm">flutter/test/fixtures/fountain_sample.json</code>
        holds known-good derivations, and the Rust suite asserts against the same file.
        Neither language runs the other's tests.
      </p>
    </UContainer>

    <UContainer class="py-16 sm:py-24 border-t border-default">
      <SectionHead v-bind="page.sections[3]!" />

      <div class="mt-10 grid gap-6 md:grid-cols-3">
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">Sender emits</p>
          <p class="mt-3 font-mono text-2xl text-highlighted">max(K+20, 3K)</p>
          <p class="mt-2 text-sm text-muted">
            Symbols before the checksum frame. The 3× factor is empirical — enough for
            full recovery from the complete pool, with margin for scan loss.
          </p>
        </div>
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">Receiver needs</p>
          <p class="mt-3 font-mono text-2xl text-highlighted">1.33–1.89 × K</p>
          <p class="mt-2 text-sm text-muted">
            Distinct symbols before peeling completes. Measured across real transfers from
            K=50 to K=70,965.
          </p>
        </div>
        <div class="rounded-[var(--ui-radius)] border border-default bg-elevated p-6">
          <p class="font-mono text-xs uppercase tracking-[0.18em] text-dimmed">So scale UI to</p>
          <p class="mt-3 font-mono text-2xl text-highlighted">~2K</p>
          <p class="mt-2 text-sm text-muted">
            A bar scaled to K reads 99% complete with a third of the scanning left, which
            is worse than no bar at all.
          </p>
        </div>
      </div>

      <div class="mt-8">
        <UButton
          to="/docs/reference/wire-format"
          variant="link"
          class="!p-0"
          trailing-icon="i-lucide-arrow-right"
          label="Read the normative reference"
        />
      </div>
    </UContainer>
  </div>
</template>
