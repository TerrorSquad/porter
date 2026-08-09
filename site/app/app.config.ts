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
    // Docus defaults to py-16/24/32, which compounds into screens of dead
    // space between sections. Roughly halved, and the container capped so body
    // copy doesn't run the full desktop width.
    pageSection: {
      slots: {
        root: 'landing-section',
        container: 'py-12 sm:py-16 lg:py-20 gap-8 sm:gap-10',
        headline: 'mb-3 font-mono text-xs uppercase tracking-[0.18em]',
        features: 'mt-10 gap-6',
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
