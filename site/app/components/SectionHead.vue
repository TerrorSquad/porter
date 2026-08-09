<script setup lang="ts">
defineProps<{
  index: string
  eyebrow: string
  title: string
  description?: string
}>()
</script>

<template>
  <div class="max-w-3xl">
    <p class="font-mono text-xs uppercase tracking-[0.18em] text-primary">
      {{ index }} — {{ eyebrow }}
    </p>
    <h2 class="mt-3 text-3xl sm:text-4xl font-bold tracking-tight text-highlighted">
      {{ title }}
    </h2>
    <p
      v-if="description"
      class="mt-4 text-base sm:text-lg text-muted text-pretty"
    >
      {{ description }}
    </p>
  </div>
</template>
