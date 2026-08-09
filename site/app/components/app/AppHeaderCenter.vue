<script setup lang="ts">
// Docus's header centre is search-only; the app/pages/ routes are invisible to
// its content-driven nav, so they're listed in mainNav.
</script>

<template>
  <div class="flex items-center gap-2 w-full">
    <nav class="hidden lg:flex items-center gap-1">
      <UButton
        v-for="link in mainNav"
        :key="link.to"
        :to="link.to"
        :label="link.label"
        color="neutral"
        variant="ghost"
        size="sm"
        active-class="text-highlighted"
      />
    </nav>

    <UContentSearchButton
      :collapsed="false"
      class="ms-auto w-full max-w-64 hidden lg:flex"
      variant="soft"
      :ui="{ leadingIcon: 'size-4 mx-0.5' }"
    />
  </div>
</template>
