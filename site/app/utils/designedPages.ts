/**
 * Pages that live in `app/pages/` rather than `content/`, because docus scopes
 * its collection to `docs/**` once `content/docs/` exists, so top-level markdown
 * doesn't route at all.
 *
 * Read by the pages themselves, by `useDesignedPageSeo()`, and by the sitemap
 * hook in `nuxt.config.ts` — which imports this at config time, so it must stay
 * plain data.
 */

export interface PageSection {
  index: string
  eyebrow: string
  title: string
  description?: string
}

export interface DesignedPage {
  path: string
  /** Browser/SEO title. The visible <h1> is `heading`. */
  title: string
  description: string
  heading: string
  intro: string
  eyebrow: string
  sections: PageSection[]
}

export const designedPages: DesignedPage[] = [
  {
    path: '/how-it-works',
    title: 'How it works',
    description:
      'A file becomes chunks, chunks become QR frames, a camera reads them back. What each stage does, and why the link is one-way.',
    eyebrow: 'How it works',
    heading: 'The QR codes are the wire.',
    intro:
      'There is no network in this picture. A terminal draws frames, a camera reads them, and nothing travels between the two machines except light.',
    sections: [
      {
        index: '01',
        eyebrow: 'The path',
        title: 'File in, file out',
        description:
          'Five stages on the sending side, four on the receiving side, and an air gap in the middle that no packet crosses.',
      },
      {
        index: '02',
        eyebrow: 'The constraint',
        title: 'A link with no back-channel',
        description:
          'The receiver cannot ask for a frame again. Everything interesting about the design follows from that one fact.',
      },
      {
        index: '03',
        eyebrow: 'Two encodings',
        title: 'Sequential, or fountain',
        description:
          'Sequential frames are file slices in order. Fountain frames are XORs of a random subset, so any sufficient pile of them rebuilds the file.',
      },
      {
        index: '04',
        eyebrow: 'Getting it back',
        title: 'Scan, or serve, or join',
        description:
          'The camera is the normal path. When you already have the bytes on disk, two subcommands finish the job without one.',
      },
    ],
  },
]

export const designedPagePaths = designedPages.map(page => page.path)

export function getDesignedPage(path: string): DesignedPage {
  const page = designedPages.find(p => p.path === path)
  if (!page) throw new Error(`designedPages: no entry for "${path}"`)
  return page
}
