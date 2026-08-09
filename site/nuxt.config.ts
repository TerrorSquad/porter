import { designedPagePaths } from './app/utils/designedPages'

const SITE_URL = 'https://porter.goranninkovic.com'

export default defineNuxtConfig({
  extends: ['docus'],

  devtools: { enabled: true },

  app: {
    head: {
      link: [{ rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    },
  },

  site: {
    url: SITE_URL,
    name: 'Porter',
    description:
      'Air-gapped file transfer over QR codes. A terminal displays your file as a QR slideshow; a phone scans it back. No network, no cloud.',
  },

  robots: {
    robotsTxt: false,
  },

  icon: {
    // Not 'server': a static build has no /api/_nuxt_icon route, so every page
    // 404s twice at runtime. 'none' inlines at prerender instead.
    provider: 'none',
    serverBundle: {
      collections: ['lucide', 'simple-icons'],
    },
    clientBundle: {
      scan: true,
      includeCustomCollections: true,
      sizeLimitKb: 512,
      // `scan` can't see icon names that arrive from app.config.
      icons: ['simple-icons:github', 'simple-icons:linkedin'],
    },
  },

  nitro: {
    // Pinned: unset, Nitro emits .output/public locally but dist/ on Pages.
    // Cloudflare's "Build output directory" must be `dist`.
    preset: 'cloudflare-pages-static',

    hooks: {
      // Docus builds the sitemap from content collections only, and emits
      // relative <loc> values. Add the app/pages/ routes, absolutise the rest.
      'prerender:generate'(route) {
        if (route.route !== '/sitemap.xml' || !route.contents) return

        if (!route.contents.includes('</urlset>')) {
          throw new Error('sitemap.xml: no </urlset> to append to — docus changed its format')
        }

        const extra = designedPagePaths
          .map(path => `  <url>\n    <loc>${path}</loc>\n  </url>\n`)
          .join('')

        route.contents = route.contents
          .replace('</urlset>', `${extra}</urlset>`)
          .replace(/<loc>(\/[^<]*)<\/loc>/g, `<loc>${SITE_URL}$1</loc>`)

        if (route.contents.includes('<loc>/')) {
          throw new Error('sitemap.xml: relative <loc> survived the rewrite')
        }
      },
    },
  },

  compatibilityDate: '2025-08-04',
})
