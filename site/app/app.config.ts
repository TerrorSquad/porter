export default defineAppConfig({
  ui: {
    colors: {
      primary: 'green',
      neutral: 'zinc',
      success: 'teal',
      info: 'zinc',
    },
    pageHero: {
      slots: {
        headline: 'mb-4 font-mono text-xs uppercase tracking-[0.18em]',
      },
    },
    pageSection: {
      slots: {
        headline: 'mb-3 font-mono text-xs uppercase tracking-[0.18em]',
      },
    },
    contentToc: {
      slots: {
        linkText: 'whitespace-normal',
        link: 'group relative text-sm flex items-start rounded-sm outline-primary/25 focus-visible:outline-3 py-1',
      },
    },
  },
  header: {
    title: 'Porter',
  },
  // Not in socials too — the footer renders socials.* and github.url both.
  socials: {
    linkedin: 'https://www.linkedin.com/in/goran-ninkovic/',
  },
  github: {
    url: 'https://github.com/TerrorSquad/porter',
    branch: 'main',
  },
  author: {
    name: 'Goran Ninkovic',
    url: 'https://goranninkovic.com/',
  },
})
