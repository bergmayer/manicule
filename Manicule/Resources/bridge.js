import './view.js'
import { SectionProgress } from './progress.js'
import { makeTextBook, captureSourceAnchor } from './text-book.js'

const post = msg => window.webkit.messageHandlers.bridge.postMessage(msg)

// Forward console errors to Swift for debugging
const origError = console.error
console.error = (...args) => {
    origError.apply(console, args)
    post({ type: 'diagnostic', message: 'console.error: ' + args.map(String).join(' ') })
}
window.addEventListener('error', e => {
    post({ type: 'error', message: 'uncaught: ' + (e.message || String(e)) })
})
window.addEventListener('unhandledrejection', e => {
    post({ type: 'error', message: 'unhandled rejection: ' + (e.reason?.message || String(e.reason)) })
})

const view = document.createElement('foliate-view')
document.body.append(view)

// Track current state
let currentFlow = 'paginated'
let lastMarginPx = 0
// columnPreference is the user's choice: 'auto' (orientation-driven), 1, or 2.
// currentColumnCount is the resolved value foliate is currently rendering.
let columnPreference = 'auto'
let currentColumnCount = 1
let coverOnRight = false
// Both margin pairs are stored locally so the bridge can pick the right one
// when the resolved column count flips on rotation, without a Swift round trip.
let marginsOneUp = { tb: 0, lr: 0 }
let marginsTwoUp = { tb: 0, lr: 0 }

// Read-aloud state
//
// Page navigation timing model:
//   readAloudAutoAdvanceUntil (1000ms) — set when TTS auto-advances a section.
//       Suppresses user-flip seeks AND auto-advance during settle.
//   readAloudUserFlipUntil (500ms) — set when user manually flips a page.
//       Suppresses auto-advance only, so highlights don't fight the gesture.
//   readAloudSeekTimer (300ms debounce) — fires after page-flip relayout settles,
//       posting the seek offset to Swift. Cleared on section load to prevent stale seeks.
//   readAloudLastPage — dedup guard; relocate handler ignores relayout noise.
let readAloudRequestID = null
let readAloudActive = false
let currentSectionDoc = null
let currentSectionIndex = -1
let readAloudTextNodeMap = null  // [{ node, start, length }]
let readAloudText = ''
let readAloudAutoAdvanceUntil = 0
let readAloudHighlight = null
let readAloudHighlightWin = null
let readAloudLastPage = -1
let readAloudSeekTimer = null
let readAloudUserFlipUntil = 0

// Incremented on every bridge.search() and bridge.clearSearch() so the async
// generator can detect that a newer query (or dismissal) has superseded it
// and stop posting partial results.
let searchGeneration = 0

// --- Center-based viewport anchor for resize stability ---
// Tracks the text at the vertical center of the visible page. On resize
// (chrome show/hide), sets this as the paginator's anchor so that after
// reflow the CENTER text stays on the visible page rather than the top.
let viewportCenterRange = null

function findCenterRange() {
    if (!currentSectionDoc || currentFlow !== 'paginated') return null
    const doc = currentSectionDoc
    if (!doc.body) return null
    const iframe = doc.defaultView?.frameElement
    if (!iframe) return null

    const iframeRect = iframe.getBoundingClientRect()
    const visibleLeft = -iframeRect.left
    const visibleRight = visibleLeft + window.innerWidth
    const centerY = window.innerHeight / 2

    // Walk visible text nodes, find the one closest to vertical center
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
            if (!node.textContent?.trim()) return NodeFilter.FILTER_REJECT
            const el = node.parentElement
            if (!el) return NodeFilter.FILTER_REJECT
            const tag = el.tagName?.toUpperCase()
            if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') return NodeFilter.FILTER_REJECT
            return NodeFilter.FILTER_ACCEPT
        }
    })

    let bestNode = null
    let bestDist = Infinity

    let node
    while (node = walker.nextNode()) {
        try {
            const range = doc.createRange()
            range.selectNodeContents(node)
            const rects = range.getClientRects()
            for (const rect of rects) {
                if (rect.right <= visibleLeft || rect.left >= visibleRight) continue
                if (rect.width <= 0 || rect.height <= 0) continue
                const dist = Math.abs((rect.top + rect.bottom) / 2 - centerY)
                if (dist < bestDist) {
                    bestDist = dist
                    bestNode = node
                }
            }
        } catch (e) { /* skip */ }
    }

    if (!bestNode) return null

    // Refine to the specific character closest to vertical center.
    // A full-node range spans many lines; a single-character range gives
    // a precise Y that stays consistent across reflows.
    const len = bestNode.textContent.length
    if (len === 0) {
        const range = doc.createRange()
        range.selectNodeContents(bestNode)
        return range
    }
    let bestCharIdx = 0, bestCharDist = Infinity
    const step = Math.max(1, Math.floor(len / 30))
    for (let i = 0; i < len; i += step) {
        try {
            const r = doc.createRange()
            r.setStart(bestNode, i)
            r.setEnd(bestNode, Math.min(i + 1, len))
            const rect = r.getBoundingClientRect()
            if (rect.width <= 0 || rect.height <= 0) continue
            if (rect.right <= visibleLeft || rect.left >= visibleRight) continue
            const dist = Math.abs((rect.top + rect.bottom) / 2 - centerY)
            if (dist < bestCharDist) {
                bestCharDist = dist
                bestCharIdx = i
            }
        } catch (e) {}
    }
    // Fine-tune around the best candidate
    for (let i = Math.max(0, bestCharIdx - step); i < Math.min(len, bestCharIdx + step + 1); i++) {
        try {
            const r = doc.createRange()
            r.setStart(bestNode, i)
            r.setEnd(bestNode, Math.min(i + 1, len))
            const rect = r.getBoundingClientRect()
            if (rect.width <= 0 || rect.height <= 0) continue
            if (rect.right <= visibleLeft || rect.left >= visibleRight) continue
            const dist = Math.abs((rect.top + rect.bottom) / 2 - centerY)
            if (dist < bestCharDist) {
                bestCharDist = dist
                bestCharIdx = i
            }
        } catch (e) {}
    }
    const range = doc.createRange()
    range.setStart(bestNode, bestCharIdx)
    range.setEnd(bestNode, Math.min(bestCharIdx + 1, len))
    return range
}

function updateCenterRange() {
    if (currentFlow !== 'paginated') return
    requestAnimationFrame(() => {
        viewportCenterRange = findCenterRange()
    })
}


// Recalculate margin gap when the renderer width changes (rotation, resize)
function applyMarginGap() {
    if (!view.renderer || lastMarginPx <= 0) return
    const w = view.renderer.getBoundingClientRect().width || window.innerWidth
    if (w > 0) {
        const pct = (200 * lastMarginPx) / w
        const newValue = pct + '%'
        if (view.renderer.getAttribute('gap') !== newValue) {
            view.renderer.setAttribute('gap', newValue)
        }
    }
}

// Pick the margin pair that matches the currently rendered layout. Two-up
// margins only apply in paginated mode with 2 columns; scrolling mode and
// single-page paginated both use the one-up pair.
function applyCurrentMargins() {
    if (!view.renderer) return
    const useTwoUp = currentFlow === 'paginated' && currentColumnCount === 2
    const m = useTwoUp ? marginsTwoUp : marginsOneUp
    view.renderer.setAttribute('margin', m.tb + 'px')
    lastMarginPx = m.lr
    if (view.renderer.getBoundingClientRect().width > 0) {
        applyMarginGap()
    } else {
        requestAnimationFrame(() => applyMarginGap())
    }
}

function updateMaxInlineSize() {
    if (!view.renderer) return
    const w = view.renderer.getBoundingClientRect().width || window.innerWidth
    if (w > 0 && currentColumnCount > 0) {
        const newValue = Math.ceil(w / currentColumnCount) + 'px'
        if (view.renderer.getAttribute('max-inline-size') !== newValue) {
            view.renderer.setAttribute('max-inline-size', newValue)
        }
    }
}

function resolveColumnCount() {
    if (columnPreference !== 'auto') return columnPreference
    const rect = view.renderer?.getBoundingClientRect()
    const w = rect?.width || window.innerWidth
    const h = rect?.height || window.innerHeight
    return (w > 0 && h > 0 && w > h) ? 2 : 1
}

// Apply the resolved column count to the renderer and update inline size.
// In 'auto' mode, this is called on every resize so rotation flips columns
// without Swift having to orchestrate the change. Always re-applies margins
// so the right pair is in effect even on initial layout.
function applyResolvedColumnCount() {
    const n = resolveColumnCount()
    currentColumnCount = n
    if (view.renderer) {
        view.renderer.setAttribute('max-column-count', String(n))
        if (!view.isFixedLayout)
            view.renderer.setAttribute('spread-offset', coverOnRight ? '1' : '0')
    }
    updateMaxInlineSize()
    applyCurrentMargins()
}

window.addEventListener('resize', () => {
    // Set the center text as the paginator anchor so after reflow it shows
    // the page containing this text rather than defaulting to top-of-viewport.
    if (currentFlow === 'paginated' && viewportCenterRange && view.renderer) {
        try { view.renderer.scrollToAnchor(viewportCenterRange) } catch (e) {}
    }
    if (lastMarginPx > 0) {
        requestAnimationFrame(() => applyMarginGap())
    }
    requestAnimationFrame(() => applyResolvedColumnCount())
})

// --- Event forwarding ---

let initializing = true
let lastRelocation = null
// Match Foliate's content-based locations, independent of typography or viewport.
// Cache by publication so page entry does not rescan the spine on each keystroke.
const bookProgress = new WeakMap()
function estimatedProgress() {
    const book = view.book
    if (!bookProgress.has(book)) bookProgress.set(book, new SectionProgress(book.sections, 1500, 1600))
    return bookProgress.get(book)
}

function reportRelocation(detail) {
    const { fraction, tocItem, pageItem, cfi, location, section, range } = detail
    const renderer = view.renderer
    const atStart = renderer?.atStart ?? false
    const atEnd = renderer?.atEnd ?? false
    const page = renderer?.page ?? 0
    const pages = renderer?.pages ?? 1

    post({
        type: 'relocate',
        fraction: fraction ?? 0,
        cfi: cfi ?? null,
        tocItem: tocItem ? { label: tocItem.label, href: tocItem.href } : null,
        pageItem: pageItem ? { label: pageItem.label } : null,
        location: location ?? null,
        bookPagesEstimated: !view.isFixedLayout,
        bookPage: view.isFixedLayout ? Math.max(0, renderer.index)
            : Math.max(0, Math.min((location?.total || 1) - 1, location?.current || 0)),
        bookPageEnd: view.isFixedLayout ? Math.max(0, renderer.index)
            : Math.max(0, Math.min((location?.total || 1) - 1, location?.next || 0)),
        bookPages: view.isFixedLayout ? view.book.sections.length : Math.max(1, location?.total || 1),
        section: section ?? null,
        page,
        pages,
        atStart,
        atEnd,
        textAnchor: view.book?.textAnchorTarget ? captureSourceAnchor(range) : null,
    })

    // Update the center viewport range for resize stability
    updateCenterRange()

    // Read-aloud navigation sync
    if (readAloudActive) {
        // Only act on actual page changes, not relayout noise
        if (page !== readAloudLastPage) {
            readAloudLastPage = page
            clearReadAloudHighlight()

            if (Date.now() < readAloudAutoAdvanceUntil) {
                // Auto-advance recently triggered — don't seek
            } else if (readAloudText.length > 0 && pages > 0) {
                // User-initiated page change — suppress auto-advance so highlights
                // don't flip the page back, then debounce seek to let relayout settle
                readAloudUserFlipUntil = Date.now() + 500
                clearTimeout(readAloudSeekTimer)
                readAloudSeekTimer = setTimeout(() => {
                    const offset = getFirstVisibleTextOffset()
                    if (offset >= 0) {
                        post({ type: 'readAloudSeek', requestID: readAloudRequestID, offset, sectionIndex: currentSectionIndex })
                    }
                }, 300)
            }
        }
    }
}

view.addEventListener('relocate', ({ detail }) => {
    lastRelocation = detail
    if (!initializing) reportRelocation(detail)
})


view.addEventListener('load', ({ detail }) => {
    currentSectionDoc = detail.doc || null
    currentSectionIndex = detail.index ?? -1
    post({ type: 'load', index: detail.index })

    // If read-aloud is active, extract text from the newly loaded section
    if (readAloudActive && currentSectionDoc) {
        clearTimeout(readAloudSeekTimer)  // cancel stale page-flip seek from previous section
        buildTextNodeMap(currentSectionDoc)
        injectReadAloudStyle(currentSectionDoc)
        // Auto-advance: start from beginning; user navigation: start from visible text
        const isAutoAdvance = Date.now() < readAloudAutoAdvanceUntil
        const startOffset = isAutoAdvance ? 0 : Math.max(0, getFirstVisibleTextOffset())
        post({ type: 'readAloudSectionText', requestID: readAloudRequestID, text: readAloudText, sectionIndex: currentSectionIndex, startOffset })
    }
})

view.addEventListener('external-link', ({ detail }) => {
    post({ type: 'externalLink', href: detail.href })
})

// --- Tap zone handling ---
// Left 1/3 = prev, right 1/3 = next, center 1/3 = toggle chrome
// Mouse/pen clicks handled by pointerup; touch taps by touchend on iframe doc

// Convert iframe-document clientX to parent viewport X.
// The iframe element is expanded to span ALL pages (paginator.js expand()),
// so clientX inside the iframe is offset by the container's scroll position.
// We subtract the iframe element's left edge (which is negative when scrolled)
// to recover the position relative to the visible viewport.
function toViewportX(doc, clientX) {
    const iframe = doc.defaultView?.frameElement
    if (iframe) return clientX + iframe.getBoundingClientRect().left
    return clientX
}
function toViewportY(doc, clientY) {
    const iframe = doc.defaultView?.frameElement
    if (iframe) return clientY + iframe.getBoundingClientRect().top
    return clientY
}

// Debounce chrome toggle to avoid rapid-fire during toolbar relayout
let chromeToggleLock = false
function postToggleChrome() {
    if (chromeToggleLock) return
    chromeToggleLock = true
    // Capture center text as anchor before the chrome toggle causes a resize.
    if (currentFlow === 'paginated') {
        viewportCenterRange = findCenterRange()
    }
    post({ type: 'toggleChrome' })
    setTimeout(() => { chromeToggleLock = false }, 300)
}

// --- Section turn animation (scroll mode chapter navigation) ---
// All navigation is serialized. Input is intentionally queued rather than
// discarded: a reader who presses next three times should advance three pages,
// even when the first page is still loading or animating.
let navigationQueue = Promise.resolve()
let queuedNavigationCount = 0
let navigationInProgress = false
let sectionTurnInProgress = false
let pageTurnAnimationInProgress = false

function enqueueNavigation(operation, label = 'navigation') {
    queuedNavigationCount++
    const run = async () => {
        queuedNavigationCount--
        navigationInProgress = true
        try {
            return await operation()
        } catch (e) {
            console.error(`${label} failed:`, e)
        } finally {
            navigationInProgress = false
        }
    }
    navigationQueue = navigationQueue.then(run, run)
    return navigationQueue
}

function turnPage(direction, userInitiated = true) {
    if (userInitiated && readAloudActive)
        readAloudUserFlipUntil = Date.now() + 500
    return enqueueNavigation(
        () => direction > 0 ? view.next() : view.prev(),
        direction > 0 ? 'next page' : 'previous page')
}

function turnVisualDirection(direction) {
    if (readAloudActive) readAloudUserFlipUntil = Date.now() + 500
    return enqueueNavigation(
        () => direction > 0 ? view.goRight() : view.goLeft(),
        direction > 0 ? 'right page' : 'left page')
}

async function performSectionTurn(direction) {
    sectionTurnInProgress = true
    const w = window.innerWidth
    try {
        // 1. Slide current content off-screen
        view.style.transition = 'transform 200ms ease-out'
        view.style.transform = `translateX(${direction > 0 ? -w : w}px)`
        await new Promise(r => setTimeout(r, 210))
        view.style.transition = ''

        // 2. Load new section while off-screen (user sees blank/background)
        if (direction > 0) await view.renderer?.nextSection()
        else await view.renderer?.prevSection()

        // 3. Position at opposite edge so new content slides in
        view.style.transform = `translateX(${direction > 0 ? w : -w}px)`
        void view.offsetWidth  // force reflow before transition
        view.style.transition = 'transform 200ms ease-out'
        view.style.transform = ''
        await new Promise(r => setTimeout(r, 210))
    } finally {
        view.style.transition = ''
        view.style.transform = ''
        sectionTurnInProgress = false
    }
}

function commitSectionTurn(direction) {
    return enqueueNavigation(
        () => performSectionTurn(direction),
        direction > 0 ? 'next section' : 'previous section')
}

function cancelSectionTurn() {
    view.style.transition = 'transform 200ms ease-out'
    view.style.transform = ''
    setTimeout(() => { view.style.transition = '' }, 210)
}

view.addEventListener('load', ({ detail: { doc } }) => {
    // Mouse/pen click zone detection (touch taps handled by touchend below)
    doc.addEventListener('pointerup', e => {
        if (e.pointerType === 'touch') return
        const w = window.innerWidth
        const x = toViewportX(doc, e.clientX)
        const y = toViewportY(doc, e.clientY)
        if (y < 60) {
            postToggleChrome()
        } else if (x >= w / 3 && x <= w * 2 / 3) {
            postToggleChrome()
        } else if (currentFlow === 'paginated') {
            turnPage(x < w / 3 ? -1 : 1)
        } else {
            // Scroll mode: left/right taps navigate chapters with slide animation
            commitSectionTurn(x < w / 3 ? -1 : 1)
        }
    })

    // Touch handling: taps (zone detection) and horizontal swipe detection.
    // Note: finger-tracking for swipes is handled by a native UIKit gesture
    // recognizer (Swift side) which is more reliable than JS touch tracking
    // on iOS — the browser steals touchmove events for its own scrolling.
    // This JS handler detects taps and swipes via touchstart/touchend only.
    let tapStartX = null, tapStartY = null

    doc.addEventListener('touchstart', e => {
        if (e.touches.length === 1) {
            tapStartX = e.touches[0].clientX
            tapStartY = e.touches[0].clientY
        }
    }, { passive: true })

    doc.addEventListener('touchend', e => {
        if (e.changedTouches.length !== 1 || tapStartX == null) return
        const touch = e.changedTouches[0]
        const dx = touch.clientX - tapStartX
        const dy = touch.clientY - tapStartY
        const dist2 = dx * dx + dy * dy
        tapStartX = null

        // Scroll mode: detect horizontal swipe (> 30px, primarily horizontal)
        if (currentFlow !== 'paginated' && Math.abs(dx) > Math.abs(dy) && dist2 > 900) {
            commitSectionTurn(dx < 0 ? 1 : -1)
            return
        }

        // Tap: only if finger didn't move much (< 10px)
        if (dist2 > 100) return

        // Zone detection for taps
        const w = window.innerWidth
        const x = toViewportX(doc, touch.clientX)
        const y = toViewportY(doc, touch.clientY)
        if (y < 60) {
            postToggleChrome()
        } else if (x >= w / 3 && x <= w * 2 / 3) {
            postToggleChrome()
        } else if (currentFlow === 'paginated') {
            turnPage(x < w / 3 ? -1 : 1)
        } else {
            commitSectionTurn(x < w / 3 ? -1 : 1)
        }
    })

    // Wheel event handler for macOS trackpad page turning (iframe)
    addWheelHandler(doc)

    // Keyboard navigation within iframe documents
    doc.addEventListener('keydown', handleKeydown)

    shrinkSuperscripts(doc)
})

// Many ePubs mark footnote references with publisher-specific classes/roles
// (e.g. <a class="noteref">449</a>, <a epub:type="noteref">...</a>) and rely
// on CSS `vertical-align: super` to raise them. Our user stylesheet forces
// `font-size` on common text elements, which leaves these references at full
// body size — visually elevated but jarringly large. Rather than guess every
// publisher's class names, walk inline elements and shrink anything the
// document has computed as super/sub.
function shrinkSuperscripts(doc) {
    const view = doc.defaultView
    if (!view) return
    const candidates = doc.querySelectorAll('a, span, sup, sub, small, b, i, em, strong')
    for (const el of candidates) {
        const va = view.getComputedStyle(el).verticalAlign
        if (va === 'super' || va === 'sub') {
            el.style.setProperty('font-size', '0.75em', 'important')
            el.style.setProperty('line-height', '0', 'important')
        }
    }
}

// Shared keyboard handler for both iframe and host document navigation
function handleKeydown(e) {
    if (currentFlow === 'paginated') {
        if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
            e.preventDefault()
            turnVisualDirection(1)
        } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
            e.preventDefault()
            turnVisualDirection(-1)
        } else if (e.key === ' ' && !e.shiftKey) {
            e.preventDefault()
            turnPage(1)
        } else if (e.key === ' ' && e.shiftKey) {
            e.preventDefault()
            turnPage(-1)
        } else if (e.key === 'Home') {
            e.preventDefault()
            enqueueNavigation(() => view.renderer.firstSection(), 'first section')
        } else if (e.key === 'End') {
            e.preventDefault()
            enqueueNavigation(() => view.renderer.lastSection(), 'last section')
        }
    } else {
        // Scroll mode: left/right arrows navigate chapters with animation
        if (e.key === 'ArrowRight') {
            e.preventDefault()
            commitSectionTurn(1)
        } else if (e.key === 'ArrowLeft') {
            e.preventDefault()
            commitSectionTurn(-1)
        } else if (e.key === 'Home') {
            e.preventDefault()
            if (view.renderer) enqueueNavigation(
                () => view.renderer.firstSection(), 'first section')
        } else if (e.key === 'End') {
            e.preventDefault()
            if (view.renderer) enqueueNavigation(
                () => view.renderer.lastSection(), 'last section')
        }
    }
}

// Host document keyboard navigation
document.addEventListener('keydown', handleKeydown)

// --- Host-level touch/pointer handlers for scroll mode ---
// On short ePub sections (title pages, part dividers), the iframe content
// area is tiny and most of the screen is the paginator's background (shadow DOM).
// Touch events from the shadow DOM don't fire on the iframe doc — they bubble
// to the host document instead. These handlers catch those events.
{
    let hostStartX = null, hostStartY = null
    document.addEventListener('touchstart', e => {
        if (currentFlow === 'paginated' || e.touches.length !== 1) return
        hostStartX = e.touches[0].clientX
        hostStartY = e.touches[0].clientY
    }, { passive: true })

    document.addEventListener('touchend', e => {
        if (currentFlow === 'paginated' || hostStartX == null) return
        if (e.changedTouches.length !== 1) return
        const touch = e.changedTouches[0]
        const dx = touch.clientX - hostStartX
        const dy = touch.clientY - hostStartY
        const dist2 = dx * dx + dy * dy
        hostStartX = null

        // Horizontal swipe
        if (Math.abs(dx) > Math.abs(dy) && dist2 > 900) {
            commitSectionTurn(dx < 0 ? 1 : -1)
            return
        }

        // Tap
        if (dist2 > 100) return
        const w = window.innerWidth
        const x = touch.clientX
        const y = touch.clientY
        if (y < 60) {
            postToggleChrome()
        } else if (x >= w / 3 && x <= w * 2 / 3) {
            postToggleChrome()
        } else {
            commitSectionTurn(x < w / 3 ? -1 : 1)
        }
    })

    document.addEventListener('pointerup', e => {
        if (currentFlow === 'paginated' || e.pointerType === 'touch') return
        const w = window.innerWidth
        const x = e.clientX
        const y = e.clientY
        if (y < 60) {
            postToggleChrome()
        } else if (x >= w / 3 && x <= w * 2 / 3) {
            postToggleChrome()
        } else {
            commitSectionTurn(x < w / 3 ? -1 : 1)
        }
    })
}

// --- Wheel event handler for macOS trackpad ---
let wheelAccum = 0
let wheelTriggered = false
let wheelResetTimer = null

function addWheelHandler(target) {
    target.addEventListener('wheel', e => {
        if (currentFlow !== 'paginated') return
        e.preventDefault()
        // Reset accumulator after 300ms of inactivity
        clearTimeout(wheelResetTimer)
        wheelResetTimer = setTimeout(() => {
            wheelAccum = 0
            wheelTriggered = false
        }, 300)

        if (wheelTriggered) return

        const delta = Math.abs(e.deltaX) >= Math.abs(e.deltaY) ? e.deltaX : e.deltaY
        wheelAccum += delta
        if (Math.abs(wheelAccum) > 15) {
            wheelTriggered = true
            turnPage(wheelAccum > 0 ? 1 : -1)
        }
    }, { passive: false })
}

// Attach wheel handler to host document
addWheelHandler(document)

// --- Read-aloud helpers ---

function buildTextNodeMap(doc) {
    const body = doc.body
    if (!body) {
        post({ type: 'diagnostic', message: 'readAloud: doc.body is null' })
        readAloudText = ''
        readAloudTextNodeMap = []
        return
    }

    const blockTags = new Set(['P', 'DIV', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
        'LI', 'BLOCKQUOTE', 'SECTION', 'ARTICLE', 'HEADER', 'FOOTER',
        'FIGCAPTION', 'TD', 'TH', 'DT', 'DD', 'PRE', 'TR', 'TABLE'])

    function getBlockAncestor(node) {
        let el = node.parentElement
        while (el && el !== body) {
            if (blockTags.has(el.tagName?.toUpperCase())) return el
            el = el.parentElement
        }
        return body
    }

    const walker = doc.createTreeWalker(body, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
            let el = node.parentElement
            while (el && el !== body) {
                const tag = el.tagName?.toUpperCase()
                if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') return NodeFilter.FILTER_REJECT
                if (el.hidden || (el.style && el.style.display === 'none')) return NodeFilter.FILTER_REJECT
                // Skip superscript footnote reference numbers
                if (tag === 'SUP' && /^\d[\d,\s\-\u2013\u2014]*$/.test(el.textContent?.trim() || ''))
                    return NodeFilter.FILTER_REJECT
                // Skip elements with epub footnote reference roles
                if (tag === 'A') {
                    const epubType = el.getAttributeNS?.('http://www.idpf.org/2007/ops', 'type')
                        || el.getAttribute?.('epub:type') || ''
                    if (/noteref|biblioref|glossref/.test(epubType)) return NodeFilter.FILTER_REJECT
                    const role = el.getAttribute?.('role') || ''
                    if (/doc-noteref|doc-biblioref|doc-glossref/.test(role)) return NodeFilter.FILTER_REJECT
                }
                el = el.parentElement
            }
            return NodeFilter.FILTER_ACCEPT
        }
    })

    const map = []
    let text = ''
    let node
    let lastBlock = null
    while (node = walker.nextNode()) {
        // Skip whitespace-only text nodes (indentation, blank lines between tags)
        const raw = node.textContent
        if (!raw || raw.replace(/[\s\u00a0\u200b\u200c\u200d\ufeff]/g, '').length === 0) continue

        const block = getBlockAncestor(node)
        // Insert paragraph separator between different block-level elements
        // so sentence boundary detection can isolate headings from body text
        if (lastBlock && block !== lastBlock && !text.endsWith('\n\n')) {
            if (!text.endsWith('\n')) text += '\n'
            text += '\n'
        }
        lastBlock = block

        // Normalize internal whitespace: collapse runs of whitespace (including
        // newlines from HTML formatting) to single space. Newlines within text
        // nodes are just source formatting, not paragraph breaks.
        const content = raw.replace(/\s+/g, ' ')
        const start = text.length
        text += content
        map.push({ node, start, length: content.length })
    }

    // Fallback: if TreeWalker found no text but body has content, use innerText
    if (text.length === 0) {
        const fallback = (body.innerText || body.textContent || '').trim()
        if (fallback.length > 0) {
            post({ type: 'diagnostic', message: 'readAloud: TreeWalker empty, falling back to innerText (' + fallback.length + ' chars)' })
            readAloudText = fallback
            readAloudTextNodeMap = null  // no node map = no highlighting
            return
        }
    }

    readAloudText = text
    readAloudTextNodeMap = map
    console.debug('readAloud: extracted', text.length, 'chars from', map.length, 'nodes')
}

function injectReadAloudStyle(doc) {
    if (doc.getElementById('manicule-readaloud-style')) return
    const style = doc.createElement('style')
    style.id = 'manicule-readaloud-style'
    style.textContent = '::highlight(read-aloud) { background-color: rgba(255, 200, 0, 0.4); }'
    if (doc.head) doc.head.appendChild(style)
    else doc.documentElement?.appendChild(style)
}

// Find the text offset of the first visible text on the current page.
// Uses the text node map and checks character-level visibility against the viewport.
function getFirstVisibleTextOffset() {
    if (!readAloudTextNodeMap || !currentSectionDoc) return -1
    const doc = currentSectionDoc
    const iframe = doc.defaultView?.frameElement
    if (!iframe) return -1

    const iframeRect = iframe.getBoundingClientRect()
    const visibleLeft = -iframeRect.left
    const visibleRight = visibleLeft + window.innerWidth

    function isRectVisible(rect) {
        if (currentFlow === 'paginated') {
            return rect.right > visibleLeft && rect.left < visibleRight && rect.width > 0
        }
        return rect.bottom > 0 && rect.top < window.innerHeight && rect.height > 0
    }

    for (const entry of readAloudTextNodeMap) {
        if (entry.length === 0) continue
        const trimmed = entry.node.textContent.trim()
        if (trimmed.length === 0) continue

        try {
            // Quick check: is any part of this node visible?
            const nodeRange = doc.createRange()
            nodeRange.selectNodeContents(entry.node)
            const nodeRects = nodeRange.getClientRects()
            let nodeVisible = false
            for (const rect of nodeRects) {
                if (isRectVisible(rect)) { nodeVisible = true; break }
            }
            if (!nodeVisible) continue

            // Find the first visible character within this node using binary search
            let lo = 0, hi = entry.length - 1, bestOffset = 0
            while (lo <= hi) {
                const mid = (lo + hi) >> 1
                const charRange = doc.createRange()
                charRange.setStart(entry.node, mid)
                charRange.setEnd(entry.node, Math.min(mid + 1, entry.length))
                const charRect = charRange.getBoundingClientRect()
                if (isRectVisible(charRect)) {
                    bestOffset = mid
                    hi = mid - 1  // look for earlier visible char
                } else if (currentFlow === 'paginated' ? charRect.right <= visibleLeft : charRect.bottom <= 0) {
                    lo = mid + 1  // char is before visible area
                } else {
                    hi = mid - 1  // char is after visible area (shouldn't happen for first visible)
                }
            }
            return entry.start + bestOffset
        } catch (e) { /* skip */ }
    }

    // Fallback to linear approximation
    const page = view.renderer?.page ?? 0
    const pages = view.renderer?.pages ?? 1
    return Math.floor((page / Math.max(pages, 1)) * readAloudText.length)
}

// Expand a character offset to the enclosing sentence boundaries in readAloudText.
// Returns { start, end } of the sentence.
// Block separators (\n\n) always act as boundaries. Single \n acts as a boundary
// to isolate headings and list items from surrounding text.
function findSentenceBounds(offset) {
    const text = readAloudText
    if (!text) return { start: offset, end: offset }

    // Search backward for sentence start
    let sStart = 0
    for (let i = offset - 1; i >= 0; i--) {
        const ch = text[i]
        if ((ch === '.' || ch === '!' || ch === '?') && i + 1 < text.length && /\s/.test(text[i + 1])) {
            sStart = i + 1
            while (sStart < text.length && /\s/.test(text[sStart])) sStart++
            break
        }
        // Any newline acts as a sentence boundary (isolates headings, list items)
        if (ch === '\n') {
            sStart = i + 1
            while (sStart < text.length && /\s/.test(text[sStart])) sStart++
            break
        }
    }

    // Search forward for sentence end
    let sEnd = text.length
    for (let i = offset; i < text.length; i++) {
        const ch = text[i]
        if ((ch === '.' || ch === '!' || ch === '?') && (i + 1 >= text.length || /\s/.test(text[i + 1]))) {
            sEnd = i + 1
            break
        }
        if (ch === '\n') {
            sEnd = i
            break
        }
    }

    return { start: sStart, end: sEnd }
}

function highlightReadAloudRange(start, length) {
    const doc = currentSectionDoc
    if (!doc || !doc.defaultView) return
    if (!readAloudTextNodeMap) return  // fallback mode — no highlighting available

    // Expand word range to enclosing sentence
    const sentence = findSentenceBounds(start)
    const hlStart = sentence.start
    const hlEnd = sentence.end
    if (hlStart >= hlEnd) return  // empty range

    // Determine visible viewport for filtering highlights to current page
    const iframe = doc.defaultView?.frameElement
    let visibleLeft = 0, visibleRight = Infinity, visibleTop = 0, visibleBottom = Infinity
    if (iframe) {
        const iframeRect = iframe.getBoundingClientRect()
        if (currentFlow === 'paginated') {
            visibleLeft = -iframeRect.left
            visibleRight = visibleLeft + window.innerWidth
        } else {
            visibleTop = -iframeRect.top
            visibleBottom = visibleTop + window.innerHeight
        }
    }

    const ranges = []

    for (const entry of readAloudTextNodeMap) {
        const entryEnd = entry.start + entry.length
        if (entryEnd <= hlStart) continue
        if (entry.start >= hlEnd) break

        const nodeStart = Math.max(0, hlStart - entry.start)
        const nodeEnd = Math.min(entry.length, hlEnd - entry.start)

        try {
            const range = doc.createRange()
            range.setStart(entry.node, nodeStart)
            range.setEnd(entry.node, nodeEnd)

            // Only include ranges that are on the currently visible page
            if (iframe) {
                const rect = range.getBoundingClientRect()
                if (currentFlow === 'paginated') {
                    if (rect.right <= visibleLeft || rect.left >= visibleRight) continue
                } else {
                    if (rect.bottom <= visibleTop || rect.top >= visibleBottom) continue
                }
            }

            ranges.push(range)
        } catch (e) { /* offset out of bounds */ }
    }

    const win = doc.defaultView
    if (win?.CSS?.highlights) {
        // If window changed (section transition), discard old highlight
        if (win !== readAloudHighlightWin) {
            if (readAloudHighlightWin?.CSS?.highlights) {
                readAloudHighlightWin.CSS.highlights.delete('read-aloud')
            }
            readAloudHighlight = null
            readAloudHighlightWin = win
        }

        // Reuse the same Highlight object — WebKit doesn't reliably repaint
        // when replacing entries via highlights.set(), but clearing/adding
        // ranges on an existing Highlight works correctly.
        if (!readAloudHighlight) {
            readAloudHighlight = new win.Highlight()
            win.CSS.highlights.set('read-aloud', readAloudHighlight)
        }

        readAloudHighlight.clear()
        for (const r of ranges) readAloudHighlight.add(r)
    }

    // Auto-advance page if highlight is past the current visible page
    if (currentFlow === 'paginated') {
        checkReadAloudPageAdvance(start)
    }
}

function clearReadAloudHighlight() {
    if (readAloudHighlight) {
        readAloudHighlight.clear()
    }
}

function checkReadAloudPageAdvance(charOffset) {
    // Don't advance if a recent advance is still settling
    if (Date.now() < readAloudAutoAdvanceUntil) return
    // Don't fight a user-initiated page flip
    if (Date.now() < readAloudUserFlipUntil) return
    if (!readAloudTextNodeMap || !currentSectionDoc) return

    // Check if the text node being spoken is beyond the visible viewport
    const doc = currentSectionDoc
    const iframe = doc.defaultView?.frameElement
    if (!iframe) return

    // Find the text node entry for this character offset
    let targetEntry = null
    for (const entry of readAloudTextNodeMap) {
        if (charOffset >= entry.start && charOffset < entry.start + entry.length) {
            targetEntry = entry
            break
        }
    }
    if (!targetEntry) return

    try {
        const range = doc.createRange()
        const nodeOffset = charOffset - targetEntry.start
        range.setStart(targetEntry.node, Math.min(nodeOffset, targetEntry.length))
        range.setEnd(targetEntry.node, Math.min(nodeOffset + 1, targetEntry.length))
        const rect = range.getBoundingClientRect()

        if (currentFlow === 'paginated') {
            const iframeRect = iframe.getBoundingClientRect()
            const visibleRight = -iframeRect.left + window.innerWidth
            if (rect.left > visibleRight) {
                readAloudAutoAdvanceUntil = Date.now() + 1000
                turnPage(1, false)
            }
        }
    } catch (e) { /* ignore */ }
}

// Navigate forward or backward so that the given character offset is visible.
// Called from Swift when the user skips sentences forward/back.
function scrollToReadAloudOffset(offset) {
    if (!readAloudTextNodeMap || !currentSectionDoc) return
    const doc = currentSectionDoc
    const iframe = doc.defaultView?.frameElement
    if (!iframe) return

    // Find the text node entry for this offset
    let targetEntry = null
    for (const entry of readAloudTextNodeMap) {
        if (offset >= entry.start && offset < entry.start + entry.length) {
            targetEntry = entry
            break
        }
    }
    if (!targetEntry) return

    try {
        const range = doc.createRange()
        const nodeOffset = offset - targetEntry.start
        range.setStart(targetEntry.node, Math.min(nodeOffset, targetEntry.length))
        range.setEnd(targetEntry.node, Math.min(nodeOffset + 1, targetEntry.length))
        const rect = range.getBoundingClientRect()

        if (currentFlow === 'paginated') {
            const iframeRect = iframe.getBoundingClientRect()
            const visibleLeft = -iframeRect.left
            const visibleRight = visibleLeft + window.innerWidth

            if (rect.left >= visibleRight) {
                // Target is ahead — advance pages until visible
                readAloudAutoAdvanceUntil = Date.now() + 1000
                turnPage(1, false)
            } else if (rect.right <= visibleLeft) {
                // Target is behind — go back pages until visible
                readAloudAutoAdvanceUntil = Date.now() + 1000
                turnPage(-1, false)
            }
        } else {
            // Scroll mode: scroll the iframe content so the target is visible
            const iframeRect = iframe.getBoundingClientRect()
            const visibleTop = -iframeRect.top
            const visibleBottom = visibleTop + window.innerHeight

            if (rect.top < visibleTop || rect.bottom > visibleBottom) {
                targetEntry.node.parentElement?.scrollIntoView({ block: 'center' })
            }
        }
    } catch (e) { /* ignore */ }
}

// --- Bridge API ---

window.bridge = {
    async open(epubURL) {
        try {
            initializing = true
            lastRelocation = null
            const book = epubURL.endsWith('/publication.json') ? await makeTextBook(epubURL) : epubURL
            await view.open(book)
            const metadata = view.book?.metadata ?? {}
            const toc = view.book?.toc ?? []
            post({
                type: 'bookOpened',
                metadata: {
                    title: metadata.title ?? '',
                    author: metadata.author ?? '',
                    language: metadata.language ?? '',
                },
                tocLength: toc.length,
            })
        } catch (e) {
            console.error('bridge.open failed:', e)
            post({ type: 'error', message: 'open: ' + (e.message ?? String(e)) })
            throw e
        }
    },

    async init(options) {
        try {
            if (view.renderer) {
                view.renderer.setAttribute('animated', '')
                view.renderer.setAttribute('max-block-size', '10000px')
                applyResolvedColumnCount()
            }
            if (options?.textAnchor && view.book?.textAnchorTarget) {
                await view.renderer.goTo(await view.book.textAnchorTarget(options.textAnchor))
            } else if (Number.isFinite(options?.fraction)) {
                await view.goToFraction(Math.max(0, Math.min(1, options.fraction)))
            } else {
                await view.init(options ?? {})
            }
            initializing = false
            if (lastRelocation) reportRelocation(lastRelocation)
        } catch (e) {
            console.error('bridge.init failed:', e)
            post({ type: 'error', message: 'init: ' + (e.message ?? String(e)) })
            throw e
        }
    },

    next() {
        return turnPage(1)
    },

    prev() {
        return turnPage(-1)
    },

    nextSection() {
        if (view.renderer) return enqueueNavigation(
            () => view.renderer.nextSection(), 'next section')
    },

    prevSection() {
        if (view.renderer) return enqueueNavigation(
            () => view.renderer.prevSection(), 'previous section')
    },

    async goTo(target) {
        try {
            await enqueueNavigation(() => view.goTo(target), 'go to location')
        } catch (e) {
            console.error('goTo failed:', e)
        }
    },

    async goToPage(page) {
        if (!Number.isSafeInteger(page) || page < 0) return
        await enqueueNavigation(async () => {
            if (view.isFixedLayout) {
                if (page < view.book.sections.length) await view.goTo(page)
            } else {
                const progress = estimatedProgress()
                if (progress.sizeTotal > 0 && page < Math.ceil(progress.sizeTotal / progress.sizePerLoc)) {
                    await view.goToFraction(page * progress.sizePerLoc / progress.sizeTotal)
                }
            }
        }, 'go to page')
    },
    async goToFraction(f) {
        try {
            await enqueueNavigation(() => view.goToFraction(f), 'go to fraction')
        } catch (e) {
            console.error('goToFraction failed:', e)
        }
    },

    async goToTextAnchor(anchor) {
        if (!view.book?.textAnchorTarget) return
        await enqueueNavigation(async () => view.renderer.goTo(await view.book.textAnchorTarget(anchor)), 'restore source passage')
    },

    setFlow(mode) {
        currentFlow = mode
        post({ type: 'flowChanged', flow: mode })
        if (view.renderer) {
            view.renderer.setAttribute('flow', mode === 'paginated' ? 'paginated' : 'scrolled')
            view.renderer.setAttribute('animated', '')
            // Margins differ between scrolling (always one-up) and paginated
            // (one-up or two-up). Re-pick when the flow changes.
            applyCurrentMargins()
        }
    },

    setStyles(css) {
        if (view.renderer?.setStyles) {
            view.renderer.setStyles(css)
        }
    },

    setColumnCount(n) {
        // 'auto' resolves to 1 or 2 from viewport orientation and re-resolves
        // on every resize. 1 / 2 force a fixed value. The renderer's
        // attributeChangedCallback in paginator.js sets --_max-column-count,
        // --_max-column-count-portrait, and --_max-column-count-spread on
        // #top (closed shadow root, so we can't write those CSS vars from
        // here directly — the override has to flow through the attribute).
        if (n === 'auto') {
            columnPreference = 'auto'
        } else {
            const num = Number(n)
            if (num !== 1 && num !== 2) return
            columnPreference = num
        }
        applyResolvedColumnCount()
    },

    async setPagePairing(shifted) {
        coverOnRight = Boolean(shifted)
        if (view.isFixedLayout) await view.renderer.setPagePairing(coverOnRight)
        else applyResolvedColumnCount()
    },

    setGap(value) {
        if (view.renderer) {
            view.renderer.setAttribute('gap', value)
        }
    },

    // Backward-compat single-pair setter — applies the same margins to both
    // one-up and two-up. New callers should use setMarginsBoth so the bridge
    // can pick the right pair when the resolved column count flips.
    setMargins(topBottom, leftRight) {
        marginsOneUp = { tb: topBottom, lr: leftRight }
        marginsTwoUp = { tb: topBottom, lr: leftRight }
        applyCurrentMargins()
    },

    // Sets both margin pairs at once. The bridge picks one-up vs two-up based
    // on currentColumnCount, and re-picks automatically when the column count
    // flips on rotation (see applyResolvedColumnCount).
    setMarginsBoth(oneTB, oneLR, twoTB, twoLR) {
        marginsOneUp = { tb: oneTB, lr: oneLR }
        marginsTwoUp = { tb: twoTB, lr: twoLR }
        applyCurrentMargins()
    },

    setMaxInlineSize(value) {
        if (view.renderer) {
            view.renderer.setAttribute('max-inline-size', value)
        }
    },

    getMetadata() {
        return view.book?.metadata ?? null
    },

    getTOC() {
        return JSON.stringify(view.book?.toc ?? [])
    },

    getPosition() {
        const loc = view.lastLocation
        if (!loc) return null
        return JSON.stringify({
            cfi: loc.cfi ?? null,
            fraction: loc.fraction ?? 0,
            tocItem: loc.tocItem ? { label: loc.tocItem.label, href: loc.tocItem.href } : null,
        })
    },

    async search(query, requestID) {
        // Generation counter — every new search or clear bumps it. The
        // async iterator below checks `myGen === searchGeneration` before
        // posting, so results from a superseded search never reach Swift
        // (avoids partial counts from "e" landing after the real query).
        const myGen = ++searchGeneration
        try {
            view.clearSearch()
            const results = []
            for await (const item of view.search({ query })) {
                if (myGen !== searchGeneration) return
                if (item === 'done') break
                for (const sub of (item.subitems || [])) {
                    results.push({ cfi: sub.cfi, excerpt: sub.excerpt, label: item.label })
                }
                post({ type: 'searchResult', requestID, results: results.slice(), done: false })
            }
            if (myGen === searchGeneration) {
                post({ type: 'searchResult', requestID, results, done: true })
            }
        } catch (e) {
            console.error('search failed:', e)
            if (myGen === searchGeneration) {
                post({ type: 'searchError', requestID, message: 'Search could not finish: ' + e.message })
            }
        }
    },

    clearSearch() {
        searchGeneration++  // invalidate any in-flight search
        try { view.clearSearch() } catch (e) {}
    },

    async goToSearchResult(cfi) {
        try {
            await enqueueNavigation(() => view.goTo(cfi), 'go to search result')
        } catch (e) {
            console.error('goToSearchResult failed:', e)
        }
    },

    // Trackpad finger-tracking: apply a visual offset during pan gesture
    setPageOffset(px) {
        if (navigationInProgress || sectionTurnInProgress
            || pageTurnAnimationInProgress || queuedNavigationCount > 0) return
        view.style.transform = `translateX(${px}px)`
    },

    // Commit the page/section turn after a successful trackpad swipe.
    // In scroll mode, delegates to animated section turn.
    commitPageTurn(direction) {
        if (currentFlow !== 'paginated') {
            return commitSectionTurn(direction)
        }
        if (readAloudActive) readAloudUserFlipUntil = Date.now() + 500
        return enqueueNavigation(async () => {
            pageTurnAnimationInProgress = true
            const w = window.innerWidth
            try {
                view.style.transition = 'transform 200ms ease-out'
                view.style.transform = `translateX(${direction > 0 ? -w : w}px)`
                await new Promise(r => setTimeout(r, 210))
                view.style.transition = ''
                view.style.transform = ''
                if (direction > 0) await view.next()
                else await view.prev()
            } finally {
                view.style.transition = ''
                view.style.transform = ''
                pageTurnAnimationInProgress = false
            }
        }, direction > 0 ? 'animated next page' : 'animated previous page')
    },

    // Cancel the page/section turn — snap back to original position
    cancelPageTurn() {
        if (pageTurnAnimationInProgress) return
        if (currentFlow !== 'paginated') {
            if (sectionTurnInProgress) return
            cancelSectionTurn()
            return
        }
        view.style.transition = 'transform 200ms ease-out'
        view.style.transform = ''
        setTimeout(() => { view.style.transition = '' }, 210)
    },

    setAnimated(enabled) {
        if (view.renderer) {
            if (enabled) {
                view.renderer.setAttribute('animated', '')
            } else {
                view.renderer.removeAttribute('animated')
            }
        }
    },

    captureViewportAnchor() {
        // Force immediate center range update (for Swift to call before resize)
        viewportCenterRange = findCenterRange()
    },

    startReadAloud(requestID) {
        readAloudRequestID = requestID
        readAloudActive = true
        readAloudUserFlipUntil = 0
        readAloudAutoAdvanceUntil = 0
        readAloudLastPage = -1
        clearTimeout(readAloudSeekTimer)
        if (currentSectionDoc) {
            buildTextNodeMap(currentSectionDoc)
            injectReadAloudStyle(currentSectionDoc)
            const startOffset = Math.max(0, getFirstVisibleTextOffset())
            post({ type: 'readAloudSectionText', requestID: readAloudRequestID, text: readAloudText, sectionIndex: currentSectionIndex, startOffset })
        }
    },

    highlightReadAloud(start, length) {
        highlightReadAloudRange(start, length)
    },

    clearReadAloud() {
        clearReadAloudHighlight()
    },

    stopReadAloud() {
        readAloudActive = false
        clearTimeout(readAloudSeekTimer)
        readAloudUserFlipUntil = 0
        clearReadAloudHighlight()
        // Remove highlight from registry entirely when stopping
        if (readAloudHighlightWin?.CSS?.highlights) {
            readAloudHighlightWin.CSS.highlights.delete('read-aloud')
        }
        readAloudHighlight = null
        readAloudHighlightWin = null
        readAloudTextNodeMap = null
        readAloudText = ''
    },

    advanceReadAloudSection() {
        if (!readAloudActive) return
        readAloudAutoAdvanceUntil = Date.now() + 1000
        if (view.renderer) return enqueueNavigation(
            () => view.renderer.nextSection(), 'read-aloud section advance')
    },

    scrollToReadAloudOffset(offset) {
        scrollToReadAloudOffset(offset)
    },

    destroy() {
        view.close()
    },
}

post({ type: 'bridgeReady' })
