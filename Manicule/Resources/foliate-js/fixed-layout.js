const parseViewport = str => str
    ?.split(/[,;\s]/) // NOTE: technically, only the comma is valid
    ?.filter(x => x)
    ?.map(x => x.split('=').map(x => x.trim()))

const getViewport = (doc, viewport) => {
    // use `viewBox` for SVG
    if (doc.documentElement.localName === 'svg') {
        const [, , width, height] = doc.documentElement
            .getAttribute('viewBox')?.split(/\s/) ?? []
        return { width, height }
    }

    // get `viewport` `meta` element
    const meta = parseViewport(doc.querySelector('meta[name="viewport"]')
        ?.getAttribute('content'))
    if (meta) return Object.fromEntries(meta)

    // fallback to book's viewport
    if (typeof viewport === 'string') return parseViewport(viewport)
    if (viewport?.width && viewport.height) return viewport

    // if no viewport (possibly with image directly in spine), get image size
    const img = doc.querySelector('img')
    if (img) return { width: img.naturalWidth, height: img.naturalHeight }

    // just show *something*, i guess...
    console.warn(new Error('Missing viewport properties'))
    return { width: 1000, height: 2000 }
}

export class FixedLayout extends HTMLElement {
    static observedAttributes = ['zoom', 'max-column-count']
    #root = this.attachShadow({ mode: 'closed' })
    #observer = new ResizeObserver(() => this.#render())
    #spreads
    #index = -1
    defaultViewport
    spread
    #portrait = false
    #left
    #right
    #center
    #side
    #zoom
    #navigationQueue = Promise.resolve()
    #pairing
    #pairingSection
    constructor() {
        super()

        const sheet = new CSSStyleSheet()
        this.#root.adoptedStyleSheets = [sheet]
        sheet.replaceSync(`:host {
            width: 100%;
            height: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
            overflow: auto;
        }`)

        this.#observer.observe(this)
    }
    attributeChangedCallback(name, _, value) {
        switch (name) {
            case 'max-column-count':
                this.#render()
                break
            case 'zoom':
                this.#zoom = value !== 'fit-width' && value !== 'fit-page'
                    ? parseFloat(value) : value
                this.#render()
                break
        }
    }
    async #createFrame({ index, src: srcOption }) {
        const srcOptionIsString = typeof srcOption === 'string'
        const src = srcOptionIsString ? srcOption : srcOption?.src
        const onZoom = srcOptionIsString ? null : srcOption?.onZoom
        const element = document.createElement('div')
        element.setAttribute('dir', 'ltr')
        const iframe = document.createElement('iframe')
        element.append(iframe)
        Object.assign(iframe.style, {
            border: '0',
            display: 'none',
            overflow: 'hidden',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts')
        iframe.setAttribute('scrolling', 'no')
        iframe.setAttribute('part', 'filter')
        element.style.visibility = 'hidden'
        this.#root.append(element)
        if (!src) return { blank: true, element, iframe }
        return new Promise((resolve, reject) => {
            let settled = false
            const timeout = setTimeout(() => {
                if (settled) return
                settled = true
                element.remove()
                reject(new Error(`Timed out loading fixed-layout section ${index}`))
            }, 15_000)
            iframe.addEventListener('error', () => {
                if (settled) return
                settled = true
                clearTimeout(timeout)
                element.remove()
                reject(new Error(`Failed to load fixed-layout section ${index}`))
            }, { once: true })
            iframe.addEventListener('load', () => {
                if (settled) return
                try {
                    const doc = iframe.contentDocument
                    this.dispatchEvent(new CustomEvent('load', { detail: { doc, index } }))
                    const { width, height } = getViewport(doc, this.defaultViewport)
                    settled = true
                    clearTimeout(timeout)
                    resolve({
                        element, iframe,
                        width: parseFloat(width),
                        height: parseFloat(height),
                        onZoom,
                    })
                } catch (e) {
                    settled = true
                    clearTimeout(timeout)
                    element.remove()
                    reject(e)
                }
            }, { once: true })
            iframe.src = src
        })
    }
    #render(side = this.#side) {
        if (!side) return
        const left = this.#left ?? {}
        const right = this.#center ?? this.#right ?? {}
        const target = side === 'left' ? left : right
        const { width, height } = this.getBoundingClientRect()
        const columns = this.getAttribute('max-column-count')
        const portrait = columns === '1' || (columns !== '2'
            && this.spread !== 'both' && this.spread !== 'portrait' && height > width)
        this.#portrait = portrait
        const blankWidth = left.width ?? right.width ?? 0
        const blankHeight = left.height ?? right.height ?? 0

        const scale = typeof this.#zoom === 'number' && !isNaN(this.#zoom)
            ? this.#zoom
            : (this.#zoom === 'fit-width'
                ? (portrait || this.#center
                    ? width / (target.width ?? blankWidth)
                    : width / ((left.width ?? blankWidth) + (right.width ?? blankWidth)))
                : (portrait || this.#center
                    ? Math.min(
                        width / (target.width ?? blankWidth),
                        height / (target.height ?? blankHeight))
                    : Math.min(
                        width / ((left.width ?? blankWidth) + (right.width ?? blankWidth)),
                        height / Math.max(
                            left.height ?? blankHeight,
                            right.height ?? blankHeight)))
            ) || 1

        const transform = frame => {
            let { element, iframe, width, height, blank, onZoom } = frame
            if (!iframe) return
            if (onZoom) onZoom({ doc: frame.iframe.contentDocument, scale })
            const iframeScale = onZoom ? scale : 1
            Object.assign(iframe.style, {
                width: `${width * iframeScale}px`,
                height: `${height * iframeScale}px`,
                transform: onZoom ? 'none' : `scale(${scale})`,
                transformOrigin: 'top left',
                display: blank ? 'none' : 'block',
            })
            Object.assign(element.style, {
                width: `${(width ?? blankWidth) * scale}px`,
                height: `${(height ?? blankHeight) * scale}px`,
                overflow: 'hidden',
                display: 'block',
                flexShrink: '0',
                marginBlock: 'auto',
            })
            if (portrait && frame !== target) {
                element.style.display = 'none'
            }
        }
        if (this.#center) {
            transform(this.#center)
        } else {
            transform(left)
            transform(right)
        }
    }
    async #showSpread({ left, right, center, side }) {
        const created = []
        try {
            if (center) {
                const nextCenter = await this.#createFrame(center)
                created.push(nextCenter)
                // The loaded frame is already attached. Re-inserting it with
                // replaceChildren reloads its document in WebKit.
                for (const child of Array.from(this.#root.children))
                    if (child !== nextCenter.element) child.remove()
                nextCenter.element.style.visibility = ''
                this.#left = null
                this.#right = null
                this.#center = nextCenter
                this.#side = 'center'
            } else {
                const nextLeft = await this.#createFrame(left)
                created.push(nextLeft)
                const nextRight = await this.#createFrame(right)
                created.push(nextRight)
                for (const child of Array.from(this.#root.children))
                    if (child !== nextLeft.element && child !== nextRight.element) child.remove()
                nextLeft.element.style.visibility = ''
                nextRight.element.style.visibility = ''
                this.#left = nextLeft
                this.#right = nextRight
                this.#center = null
                this.#side = nextLeft.blank ? 'right'
                    : nextRight.blank ? 'left' : side
            }
            this.#render()
        } catch (e) {
            for (const frame of created) frame.element?.remove()
            throw e
        }
    }

    #enqueueNavigation(operation) {
        const result = this.#navigationQueue.then(operation, operation)
        // Keep the internal chain usable after a malformed or missing section,
        // while returning the original rejection to the caller.
        this.#navigationQueue = result.catch(() => {})
        return result
    }
    #goLeft() {
        if (this.#center || this.#left?.blank) return
        if (this.#portrait && this.#left?.element?.style?.display === 'none') {
            this.#side = 'left'
            this.#render()
            this.#reportLocation('page')
            return true
        }
    }
    #goRight() {
        if (this.#center || this.#right?.blank) return
        if (this.#portrait && this.#right?.element?.style?.display === 'none') {
            this.#side = 'right'
            this.#render()
            this.#reportLocation('page')
            return true
        }
    }
    open(book) {
        this.book = book
        const { rendition } = book
        this.spread = rendition?.spread
        this.defaultViewport = rendition?.viewport

        const rtl = book.dir === 'rtl'
        const ltr = !rtl
        this.rtl = rtl

        if (rendition?.spread === 'none')
            this.#spreads = book.sections.map(section => ({ center: section }))
        else this.#spreads = book.sections.reduce((arr, section, i) => {
            const last = arr[arr.length - 1]
            const { pageSpread } = section
            const newSpread = () => {
                const spread = {}
                arr.push(spread)
                return spread
            }
            if (pageSpread === 'center') {
                const spread = last.left || last.right ? newSpread() : last
                spread.center = section
            }
            else if (pageSpread === 'left') {
                const spread = last.center || last.left || ltr && i ? newSpread() : last
                spread.left = section
            }
            else if (pageSpread === 'right') {
                const spread = last.center || last.right || rtl && i ? newSpread() : last
                spread.right = section
            }
            else if (ltr) {
                if (last.center || last.right) newSpread().left = section
                else if (last.left || !i) last.right = section
                else last.left = section
            }
            else {
                if (last.center || last.left) newSpread().right = section
                else if (last.right || !i) last.left = section
                else last.right = section
            }
            return arr
        }, [{}])
    }
    // Explicit reader pairing overrides publisher left/right hints. Keep centered
    // plates intact, and retain the same source page across repeated toggles.
    async setPagePairing(coverOnRight) {
        return this.#enqueueNavigation(async () => {
            if (this.#pairing === coverOnRight) return
            const section = this.#pairingSection ?? this.book.sections[Math.max(0, this.index)]
            const leading = this.rtl ? 'right' : 'left'
            const trailing = this.rtl ? 'left' : 'right'
            const spreads = []
            let pair = null
            for (const [index, section] of this.book.sections.entries()) {
                if (section.pageSpread === 'center') {
                    spreads.push({ center: section })
                    pair = null
                } else if (index === 0 && coverOnRight) {
                    spreads.push({ [trailing]: section })
                } else if (!pair) {
                    pair = { [leading]: section }
                    spreads.push(pair)
                } else {
                    pair[trailing] = section
                    pair = null
                }
            }
            const previousSpreads = this.#spreads
            const previousIndex = this.#index
            this.#spreads = spreads
            this.#index = -1 // Even an unchanged ordinal now contains a different pair.
            try {
                const target = this.getSpreadOf(section)
                if (target) await this.#goToSpread(target.index, target.side, 'pairing')
                this.#pairingSection = section
                this.#pairing = coverOnRight
            } catch (error) {
                this.#spreads = previousSpreads
                this.#index = previousIndex
                throw error
            }
        })
    }
    get index() {
        const spread = this.#spreads[this.#index]
        const section = spread?.center ?? (this.#side === 'left'
            ? spread?.left ?? spread?.right : spread?.right ?? spread?.left)
        return this.book.sections.indexOf(section)
    }
    #reportLocation(reason) {
        this.dispatchEvent(new CustomEvent('relocate', { detail:
            { reason, range: null, index: this.index, fraction: 0, size: 1 } }))
    }
    getSpreadOf(section) {
        const spreads = this.#spreads
        for (let index = 0; index < spreads.length; index++) {
            const { left, right, center } = spreads[index]
            if (left === section) return { index, side: 'left' }
            if (right === section) return { index, side: 'right' }
            if (center === section) return { index, side: 'center' }
        }
    }
    async #goToSpread(index, side, reason) {
        if (index < 0 || index > this.#spreads.length - 1) return
        if (index === this.#index) {
            this.#render(side)
            return
        }
        const spread = this.#spreads[index]
        if (spread.center) {
            const index = this.book.sections.indexOf(spread.center)
            const src = await spread.center?.load?.()
            await this.#showSpread({ center: { index, src } })
        } else {
            const indexL = this.book.sections.indexOf(spread.left)
            const indexR = this.book.sections.indexOf(spread.right)
            const srcL = await spread.left?.load?.()
            const srcR = await spread.right?.load?.()
            const left = { index: indexL, src: srcL }
            const right = { index: indexR, src: srcR }
            await this.#showSpread({ left, right, side })
        }
        // Do not expose a new logical position until all of its frames have
        // loaded and replaced the old spread successfully.
        this.#index = index
        this.#reportLocation(reason)
    }
    goToSpread(index, side, reason) {
        return this.#enqueueNavigation(() => {
            this.#pairingSection = null
            return this.#goToSpread(index, side, reason)
        })
    }
    async select(target) {
        await this.goTo(target)
        // TODO
    }
    async goTo(target) {
        const { book } = this
        const resolved = await target
        const section = book.sections[resolved.index]
        if (!section) return
        const { index, side } = this.getSpreadOf(section)
        await this.goToSpread(index, side)
    }
    async next() {
        return this.#enqueueNavigation(async () => {
            this.#pairingSection = null
            const s = this.rtl ? this.#goLeft() : this.#goRight()
            if (!s) await this.#goToSpread(
                this.#index + 1, this.rtl ? 'right' : 'left', 'page')
        })
    }
    async prev() {
        return this.#enqueueNavigation(async () => {
            this.#pairingSection = null
            const s = this.rtl ? this.#goRight() : this.#goLeft()
            if (!s) await this.#goToSpread(
                this.#index - 1, this.rtl ? 'left' : 'right', 'page')
        })
    }
    getContents() {
        return Array.from(this.#root.querySelectorAll('iframe'), frame => ({
            doc: frame.contentDocument,
            // TODO: index, overlayer
        }))
    }
    destroy() {
        this.#observer.unobserve(this)
    }
}

customElements.define('foliate-fxl', FixedLayout)
