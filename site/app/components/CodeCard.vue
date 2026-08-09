<script setup lang="ts">
// Shiki runs at prerender only — the import is behind `import.meta.server`, so
// Vite drops it from the client bundle and useAsyncData serialises the HTML.
//
// Code arrives as a string, not slot content: Vue's `whitespace: 'condense'`
// collapses newlines around any element in a slot, flattening the block.
const props = withDefaults(
  defineProps<{
    file: string
    code: string
    lang?: string
    /** 1-based line numbers to tint. */
    highlight?: number[]
  }>(),
  { lang: 'rust', highlight: () => [] },
)

// Key must match between prerender and client so the payload is reused. Derived
// from content (djb2) because `file` alone isn't unique.
const key = computed(() => {
  let h = 5381
  const s = props.file + props.code
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0
  return `code-${(h >>> 0).toString(36)}`
})

const { data: html } = await useAsyncData(key.value, async () => {
  if (!import.meta.server) return null

  const { codeToHtml } = await import('shiki')
  return codeToHtml(props.code, {
    lang: props.lang,
    themes: { light: 'github-light', dark: 'github-dark-default' },
    transformers: [
      {
        line(node, line) {
          if (props.highlight.includes(line)) {
            this.addClassToHast(node, 'line-highlighted')
          }
        },
      },
    ],
  })
})
</script>

<template>
  <div class="code-card rounded-[var(--ui-radius)] border border-default bg-elevated overflow-hidden">
    <div class="flex items-center gap-2 border-b border-default px-4 py-2.5">
      <span class="size-1.5 rounded-full bg-primary" />
      <span class="font-mono text-xs text-dimmed">{{ file }}</span>
    </div>
    <!-- eslint-disable-next-line vue/no-v-html -- build-time Shiki output, no user input -->
    <div
      v-if="html"
      class="overflow-x-auto"
      v-html="html"
    />
    <pre
      v-else
      class="overflow-x-auto px-4 py-4 font-mono text-[13px] leading-relaxed text-toned"
    >{{ code }}</pre>
  </div>
</template>

<style scoped>
.code-card :deep(pre.shiki) {
  background-color: transparent !important;
  padding: 1rem;
  font-size: 13px;
  line-height: 1.65;
}

.code-card :deep(pre.shiki code) {
  display: block;
  width: max-content;
  min-width: 100%;
}

/* Docus paints every line with the Shiki theme background, hiding the card
   surface. Neutralise it here... */
.code-card :deep(.shiki span) {
  background-color: transparent !important;
}

/* ...then re-apply on the tinted line. A rule in the gutter as well as a wash,
   so it still reads without colour. */
.code-card :deep(.shiki .line.line-highlighted) {
  display: inline-block;
  width: 100%;
  margin: 0 -1rem;
  padding: 0 calc(1rem - 2px);
  border-left: 2px solid var(--ui-color-primary-500);
  background-color: color-mix(in oklch, var(--ui-color-primary-500) 14%, transparent) !important;
}
</style>
