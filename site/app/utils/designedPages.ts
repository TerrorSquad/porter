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
  {
    path: '/wire-format',
    title: 'Wire format',
    description:
      'The three frame shapes, the content-derived transfer id, and the xorshift32 PRNG and degree table that must stay bit-identical across implementations.',
    eyebrow: 'Wire format',
    heading: 'Three frame shapes, one contract.',
    intro:
      'Two independent implementations have to agree on this exactly — a Rust sender and a Dart receiver, written against the same spec and checked against shared fixtures. Where this page and the code disagree, the code is wrong, but fix both.',
    sections: [
      {
        index: '01',
        eyebrow: 'The frames',
        title: 'Everything is a pipe-separated string',
        description:
          'A sequential data frame, a fountain data frame, and a checksum frame. No binary framing, because a QR payload is already a string.',
      },
      {
        index: '02',
        eyebrow: 'The id',
        title: 'Two characters that identify content, not a session',
        description:
          'Derived from the file digest, so the same file always gets the same id — which is exactly why a receiver must not key on the id alone.',
      },
      {
        index: '03',
        eyebrow: 'Symbol derivation',
        title: 'The part that must be bit-identical',
        description:
          'Sender and receiver independently derive each fountain symbol from its sequence number. Any drift here breaks decoding silently.',
      },
      {
        index: '04',
        eyebrow: 'Redundancy',
        title: 'Why K frames are never enough',
        description:
          'Peeling needs materially more than K distinct symbols. A progress bar scaled against K reads 99% with a third of the scanning left.',
      },
    ],
  },
  {
    path: '/design',
    title: 'Design',
    description:
      'The decisions behind Porter: a worker isolate in the receiver, fountain coding, disk hydration, and a sender that compiles to a single static binary.',
    eyebrow: 'Design',
    heading: 'Six decisions, written down.',
    intro:
      'Each of these was reversible and significant enough to be worth a record — including the one that is still an open gap rather than a resolved win.',
    sections: [
      {
        index: '01',
        eyebrow: 'Receiver',
        title: 'Decoding does not run on the UI thread',
        description:
          'A 109 MB transfer froze the app. One long-lived worker isolate owns the decode state; only small progress snapshots cross back.',
      },
      {
        index: '02',
        eyebrow: 'Encoding',
        title: 'Fountain codes, for the lossy case',
        description:
          'A single consistently-missed frame stalls a sequential transfer until the sender loops. Fountain removes the positional dependency.',
      },
      {
        index: '03',
        eyebrow: 'Persistence',
        title: 'Filenames are the ground truth',
        description:
          'Metadata writes are debounced, so they can lag what is actually on disk. The chunk files themselves cannot.',
      },
      {
        index: '04',
        eyebrow: 'Sender',
        title: 'A static binary, not a runtime',
        description:
          '"Install Node to send a file" is friction an air-gapped tool should not impose. The sender is Rust, and the repo now has no JavaScript at all.',
      },
      {
        index: '05',
        eyebrow: 'Known gaps',
        title: 'What is deliberately unresolved',
        description:
          'A pinned scanner fork carrying a local patch. Recorded as a gap rather than quietly carried.',
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
