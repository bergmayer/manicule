// A Foliate publication adapter for generated text/Markdown sections. Layout,
// search, and narration use the same engine and bridge as EPUB.
const read = async url => {
    const response = await fetch(url)
    if (!response.ok) throw new Error(`Could not load text section: ${response.status}`)
    return response
}

export const captureSourceAnchor = range => {
    if (!range) return null
    const node = range.startContainer
    const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
    const block = element?.closest('[data-source-line]')
        ?? element?.querySelector('[data-source-line]')
    if (!block) return null
    const prefix = block.ownerDocument.createRange()
    prefix.selectNodeContents(block)
    if (block.contains(node)) prefix.setEnd(node, range.startOffset)
    else prefix.collapse(true)
    const offset = prefix.toString().length
    return { line: Number(block.dataset.sourceLine), offset: offset + Number(block.dataset.sourceOffset ?? 0),
        quote: Array.from(block.textContent.slice(offset)).slice(0, 80).join('') }
}

const sourceRange = (doc, anchor) => {
    const blocks = Array.from(doc.querySelectorAll('[data-source-line]'))
    let best, bestScore = Infinity
    for (const [i, block] of blocks.entries()) {
        const line = Number(block.dataset.sourceLine)
        const end = Number(blocks[i + 1]?.dataset.sourceLine ?? Infinity)
        const distance = anchor.line >= line && anchor.line < end ? 0 : Math.abs(anchor.line - line)
        const matches = anchor.quote && block.textContent.includes(anchor.quote)
        const sourceOffset = Number(block.dataset.sourceOffset ?? 0)
        const nextOffset = Number(blocks[i + 1]?.dataset.sourceOffset ?? Infinity)
        const offsetDistance = line === anchor.line && anchor.offset >= sourceOffset && anchor.offset < nextOffset ? 0 : 0.25
        const score = matches ? -1 / (1 + distance) : distance + offsetDistance + 0.5
        if (score < bestScore) { best = block; bestScore = score }
    }
    if (!best) return 0
    const text = best.textContent
    const blockOffset = Math.max(0, (anchor.offset ?? 0) - Number(best.dataset.sourceOffset ?? 0))
    // Choose the nearest occurrence, so repeated prose does not move backwards
    // a little on every raw/rendered round trip.
    let quoteOffset = -1, quoteDistance = Infinity
    if (anchor.quote) {
        let found = text.indexOf(anchor.quote)
        while (found >= 0) {
            const distance = Math.abs(found - blockOffset)
            if (distance < quoteDistance) { quoteOffset = found; quoteDistance = distance }
            if (found >= blockOffset) break
            found = text.indexOf(anchor.quote, found + 1)
        }
    }
    let offset = quoteOffset >= 0 ? quoteOffset
        : Math.min(text.length, blockOffset)
    const walker = doc.createTreeWalker(best, NodeFilter.SHOW_TEXT)
    let node
    while ((node = walker.nextNode())) {
        if (offset <= node.length) {
            const range = doc.createRange()
            range.setStart(node, offset)
            range.collapse(true)
            return range
        }
        offset -= node.length
    }
    return best
}

export const makeTextBook = async manifestURL => {
    const manifest = await (await read(manifestURL)).json()
    const entries = manifest.sections
    const resourceURL = new URL('./text/', manifestURL)
    const splitHref = href => {
        const url = new URL(href, resourceURL)
        const fragment = decodeURIComponent(url.hash.slice(1))
        url.hash = ''
        return [url.href, fragment]
    }
    const getTOCFragment = (doc, id) => id ? doc.getElementById(id) : doc.body
    const sections = entries.map(entry => {
        const url = new URL(entry.href, resourceURL).href
        return {
            id: url, size: entry.size, linear: 'yes',
            load: async () => url,
            unload() {}, // URLs refer to leased files, not allocated blob URLs.
            createDocument: async () => new DOMParser().parseFromString(
                await (await read(url)).text(), 'text/html'),
            resolveHref: href => href.startsWith('#') ? new URL(href, url).href : href,
        }
    })
    return {
        metadata: { title: manifest.title },
        sections, toc: manifest.toc, splitTOCHref: splitHref, getTOCFragment,
        isExternal: href => /^(https?:|mailto:|tel:)/i.test(href),
        resolveHref(href) {
            const [id, fragment] = splitHref(href)
            const index = sections.findIndex(section => section.id === id)
            if (index < 0) throw new Error('Link is outside this text publication')
            return { index, anchor: doc => getTOCFragment(doc, fragment) }
        },
        async textAnchorTarget(anchor) {
            // Line markers describe source positions, independent of section
            // sizes, pagination, Markdown rendering, and line-break reflow.
            let index = 0
            for (let i = 1; i < entries.length; i++) {
                if (entries[i].firstLine > anchor.line || (entries[i].firstLine === anchor.line && entries[i].firstOffset > anchor.offset)) break
                index = i
            }
            if (anchor.quote) {
                // Reflow can move a passage across section boundaries. Search
                // the expected section first, then one document at a time;
                // retain no whole-book DOM cache. Repeated passages prefer the
                // section nearest the source-line estimate.
                const order = sections.map((_, i) => i).sort((a, b) => Math.abs(a - index) - Math.abs(b - index))
                for (const candidate of order) {
                    const doc = await sections[candidate].createDocument()
                    if (doc.body.textContent.includes(anchor.quote)) { index = candidate; break }
                }
            }
            return { index, anchor: doc => sourceRange(doc, anchor) }
        },
        destroy() {},
    }
}
