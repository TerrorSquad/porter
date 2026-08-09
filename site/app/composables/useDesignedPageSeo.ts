import { getDesignedPage } from '../utils/designedPages'

/** What docus's [...slug].vue does for content pages: canonical + OG + JSON-LD. */
export function useDesignedPageSeo(path: string) {
  const page = getDesignedPage(path)

  useSeo({
    title: page.title,
    description: page.description,
    type: 'website',
  })

  defineOgImage('Landing', {
    title: page.heading.slice(0, 60),
    description: page.description,
  })

  return page
}
