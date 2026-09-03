/**
 * Rhapsode ↔ foliate-js bridge.
 * Loaded as an ES module from rhapsode://reader/bridge.js
 */
import './foliate-js/view.js'

const post = (type, payload = {}) => {
  try {
    window.webkit?.messageHandlers?.rhapsode?.postMessage({ type, ...payload })
  } catch (e) {
    console.error('post failed', e)
  }
}

const log = (message) => {
  console.log('[rhapsode-reader]', message)
  post('log', { message: String(message) })
}

const statusEl = () => document.getElementById('status')
const setStatus = (text) => {
  const el = statusEl()
  if (!el) return
  if (text == null) {
    el.classList.add('hidden')
    el.textContent = ''
  } else {
    el.classList.remove('hidden')
    el.textContent = text
  }
}

/** @type {import('./foliate-js/view.js').View | null} */
let view = null
let relocateRaf = null
let pendingRelocate = null
let lastSettings = {
  theme: 'light',
  fontSize: 1,
  fontFamily: 'literata',
  fontFamilyId: 'literata',
  faces: [],
}
let turnBusy = false
let injectedFacesCSS = ''
let injectedFacesKey = ''

const flattenTOC = (items, depth = 0, out = []) => {
  if (!items) return out
  for (const item of items) {
    const label = item.label || item.title || item.href || 'Section'
    if (item.href) out.push({ label: String(label), href: String(item.href), depth })
    if (item.subitems?.length) flattenTOC(item.subitems, depth + 1, out)
    else if (item.children?.length) flattenTOC(item.children, depth + 1, out)
  }
  return out
}

/**
 * Build @font-face rules from the data-driven catalog payload (Path 1e.2).
 * Native sends `faces: [{ family, file, weight, style }, …]` — no hard-coded families here.
 */
const fontFormatForFile = (file) => {
  const ext = (file.split('.').pop() || '').toLowerCase()
  if (ext === 'woff2') return 'woff2'
  if (ext === 'woff') return 'woff'
  if (ext === 'otf') return 'opentype'
  return 'truetype'
}

const fontFaceCSSFromFaces = (faces) => {
  if (!Array.isArray(faces) || faces.length === 0) return ''
  return faces
    .map((f) => {
      const family = f.family || 'Book'
      const file = f.file
      if (!file) return ''
      const weight = f.weight || '400'
      const style = f.style || 'normal'
      const format = fontFormatForFile(file)
      return `@font-face {
  font-family: "${family}";
  src: url("rhapsode://reader/fonts/${file}") format("${format}");
  font-weight: ${weight};
  font-style: ${style};
  font-display: swap;
}`
    })
    .filter(Boolean)
    .join('\n')
}

/** Resolve CSS stack: prefer catalog `cssStack`, fall back to legacy id map. */
const resolveCssStack = (settings) => {
  if (settings.cssStack === null) return null // explicit publisher
  if (typeof settings.cssStack === 'string' && settings.cssStack.length > 0) {
    return settings.cssStack
  }
  // Legacy open payloads that only sent fontFamily id.
  const legacy = {
    literata: '"Literata", "Iowan Old Style", "Palatino Linotype", Palatino, serif',
    bitter: '"Bitter", "Literata", "Palatino Linotype", Palatino, serif',
    vollkorn: '"Vollkorn", "Literata", Georgia, serif',
    ptSerif: '"PT Serif", "Times New Roman", Times, serif',
    robotoSlab: '"Roboto Slab", "Bitter", Georgia, serif',
    atkinsonHyperlegible:
      '"Atkinson Hyperlegible", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
    openDyslexic: '"OpenDyslexic", "Comic Sans MS", "Arial", sans-serif',
  }
  const id = settings.fontFamilyId || settings.fontFamily
  if (!id || id === 'publisher') return null
  return legacy[id] || null
}

const THEME_COLORS = {
  light: { bg: '#faf8f5', fg: '#222222', link: '#0b57d0' },
  dark: { bg: '#000000', fg: '#e8e8e8', link: '#8ab4f8' },
  sepia: { bg: '#f4ecd8', fg: '#5b4636', link: '#8b4513' },
}

const themeColors = (theme) => THEME_COLORS[theme] || THEME_COLORS.light

/** Paint the host shell (outside the EPUB iframe) so margins match page color. */
const paintHost = (theme) => {
  const t = themeColors(theme)
  document.documentElement.className = `theme-${theme}`
  document.documentElement.style.background = t.bg
  document.documentElement.style.color = t.fg
  document.body.style.background = t.bg
  document.body.style.color = t.fg
  const root = document.getElementById('root')
  if (root) root.style.background = t.bg
}

const themeBodyCSS = (settings) => {
  const theme = settings.theme || 'light'
  const fontSize = settings.fontSize ?? 1
  const t = themeColors(theme)
  const sizePct = Math.round(fontSize * 100)
  const family = resolveCssStack(settings)
  const familyRule = family ? `font-family: ${family} !important;` : ''

  // Force both html and body so getBackground() and publisher CSS can't leave
  // a white page on a dark shell (the "half dark / half light" bug).
  return `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
      color-scheme: ${theme === 'dark' ? 'dark' : 'light'};
      background: ${t.bg} !important;
      background-color: ${t.bg} !important;
      color: ${t.fg} !important;
      font-size: ${sizePct}% !important;
      ${familyRule}
    }
    body {
      background: ${t.bg} !important;
      background-color: ${t.bg} !important;
      color: ${t.fg} !important;
      ${familyRule}
      padding-inline: 0.45em !important;
      padding-block: 0 !important;
      box-sizing: border-box !important;
    }
    p, li, blockquote, dd, h1, h2, h3, h4, h5, h6, div, span, section, article {
      color: inherit;
      ${familyRule}
    }
    a:link, a:visited { color: ${t.link} !important; }
    p, li, blockquote, dd {
      line-height: 1.55;
      widows: 2;
      orphans: 2;
    }
    img, svg, video { max-width: 100%; height: auto; }
    pre { white-space: pre-wrap !important; }
  `
}

const commitRelocate = () => {
  relocateRaf = null
  const detail = pendingRelocate
  pendingRelocate = null
  if (!detail) return

  const fraction =
    typeof detail.fraction === 'number'
      ? detail.fraction
      : detail.location?.total
        ? (detail.location.current + 1) / detail.location.total
        : 0

  post('relocate', {
    cfi: detail.cfi || null,
    fraction,
    sectionLabel: detail.tocItem?.label || detail.tocItem?.title || null,
  })
}

const onRelocate = (event) => {
  pendingRelocate = event.detail
  if (relocateRaf != null) return
  relocateRaf = requestAnimationFrame(commitRelocate)
}

const onSectionLoad = (event) => {
  applyStyles(lastSettings)
  const doc = event?.detail?.doc
  if (doc) wireTapZones(doc)
}

const ensureView = () => {
  if (view) return view
  const root = document.getElementById('root')
  view = document.createElement('foliate-view')
  view.id = 'foliate-view'
  root.append(view)
  view.addEventListener('relocate', onRelocate)
  return view
}

const wireTapZones = (doc) => {
  if (!doc?.documentElement || doc.documentElement.dataset.rhapsodeTaps) return
  doc.documentElement.dataset.rhapsodeTaps = '1'

  doc.addEventListener(
    'click',
    (e) => {
      if (e.defaultPrevented) return
      if (e.target.closest('a[href]')) return

      const x = e.clientX
      const w = doc.documentElement.clientWidth || window.innerWidth
      const edge = Math.max(64, w * 0.22)
      const gutter = 18

      if (x < gutter) return
      if (x < gutter + edge) {
        e.preventDefault()
        safeTurn(() => view.prev())
        return
      }
      if (x > w - edge) {
        e.preventDefault()
        safeTurn(() => view.next())
        return
      }
      post('chromeToggle')
    },
    false,
  )
}

const wireRenderer = (v) => {
  const r = v.renderer
  if (!r || r.__rhapsodeWired) return
  r.__rhapsodeWired = true
  r.addEventListener?.('load', onSectionLoad)
}

const applyStyles = (settings = {}) => {
  lastSettings = {
    ...lastSettings,
    ...settings,
    theme: settings.theme || lastSettings.theme || 'light',
    fontSize: settings.fontSize ?? lastSettings.fontSize ?? 1,
  }
  const theme = lastSettings.theme
  paintHost(theme)
  const faces = lastSettings.faces || []
  const facesKey = JSON.stringify(faces)
  if (facesKey !== injectedFacesKey) {
    injectedFacesCSS = fontFaceCSSFromFaces(faces)
    injectedFacesKey = facesKey
  }

  const v = view
  if (!v?.renderer?.setStyles) return
  // beforeStyle = @font-face (stable); style = theme (per section).
  v.renderer.setStyles([injectedFacesCSS, themeBodyCSS(lastSettings)])
  // Re-sync paginator backdrop after styles land (also done inside setStyles rAF).
  requestAnimationFrame(() => {
    try {
      const bg = themeColors(theme).bg
      const host = v.renderer
      if (host?.style) host.style.background = bg
    } catch (_) {
      /* ignore */
    }
  })
  if (v.renderer.setAttribute) {
    v.renderer.removeAttribute('flow')
  }
}

const applyLayout = (v) => {
  if (!v.renderer?.setAttribute) return
  // Phone-first single column. IMPORTANT: margin values need CSS units (default is `48px`).
  // Foliate `margin` = top/bottom band; `gap` = side gutters (% of container).
  v.renderer.setAttribute('max-column-count', '1')
  v.renderer.setAttribute('max-inline-size', '720px')
  v.renderer.setAttribute('max-block-size', '100%')
  // Vertical: modest air (top safe area is handled by SwiftUI, not full-bleed under island).
  v.renderer.setAttribute('margin', '11px')
  // Sides: another ~10% tighter (7% → 6.3%).
  v.renderer.setAttribute('gap', '6.3%')
  v.renderer.setAttribute('data-rhapsode-fast-turn', '')
}

const safeTurn = (fn) => {
  if (turnBusy || !view) return false
  turnBusy = true
  try {
    fn()
    return true
  } catch (e) {
    post('error', { message: String(e) })
    return false
  } finally {
    // Coalesce rapid taps so chapter jumps don't stack.
    requestAnimationFrame(() => {
      turnBusy = false
    })
  }
}

/**
 * Public API for native evaluateJavaScript / callAsyncJavaScript.
 */
window.__rhapsode = {
  async open(options = {}) {
    try {
      setStatus('Opening book…')
      if (view) {
        try {
          view.close?.()
        } catch (_) {
          /* ignore */
        }
        view.remove?.()
        view = null
        const root = document.getElementById('root')
        if (root) root.replaceChildren()
      }

      const v = ensureView()
      const bookURL = options.bookURL || 'rhapsode://book/book.epub'
      const name = options.name || 'book.epub'
      log(`open ${bookURL} name=${name}`)
      setStatus('Parsing book…')

      await v.open(bookURL)
      wireRenderer(v)
      applyLayout(v)
      applyStyles(options.settings || lastSettings)

      setStatus('Restoring position…')
      if (options.cfi) {
        try {
          await v.goTo(options.cfi)
        } catch (e) {
          log(`goTo cfi failed, trying fraction: ${e}`)
          if (typeof options.fraction === 'number' && options.fraction > 0) {
            await v.goToFraction(Math.min(1, Math.max(0, options.fraction)))
          } else {
            await v.goToFraction(0)
          }
        }
      } else if (typeof options.fraction === 'number' && options.fraction > 0) {
        await v.goToFraction(Math.min(1, Math.max(0, options.fraction)))
      } else {
        await v.goToFraction(0)
      }

      applyStyles(options.settings || lastSettings)

      const contents = v.renderer.getContents?.()
      if (contents?.[0]?.doc) wireTapZones(contents[0].doc)

      const toc = flattenTOC(v.book?.toc || v.book?.nav?.toc || [])
      setStatus(null)
      post('opened', {
        title: v.book?.metadata?.title || name,
        toc,
      })
      log(`opened toc=${toc.length}`)
      return { ok: true, tocCount: toc.length }
    } catch (e) {
      const message = e?.message || String(e)
      const friendly =
        /not found|404|NotFound/i.test(message)
          ? 'Couldn’t load the book file. Delete it and download again.'
          : /zip|corrupt|invalid|Unsupported/i.test(message)
            ? 'This file doesn’t look like a valid EPUB. Delete and download again.'
            : message
      setStatus('Couldn’t open book')
      post('error', { message: friendly })
      log(`open failed: ${message}`)
      return { ok: false, error: friendly }
    }
  },

  next() {
    return safeTurn(() => view.next())
  },

  prev() {
    return safeTurn(() => view.prev())
  },

  async goTo(target) {
    if (!view) return false
    try {
      if (typeof target === 'string') await view.goTo(target)
      else if (target?.cfi) await view.goTo(target.cfi)
      else if (target?.href) await view.goTo(target.href)
      else if (typeof target?.fraction === 'number') await view.goToFraction(target.fraction)
      return true
    } catch (e) {
      post('error', { message: String(e) })
      return false
    }
  },

  setStyles(settings) {
    applyStyles(settings || {})
    return true
  },

  destroy() {
    try {
      view?.close?.()
      view?.remove?.()
    } catch (_) {
      /* ignore */
    }
    view = null
    injectedFacesCSS = ''
    injectedFacesKey = ''
    const root = document.getElementById('root')
    if (root) root.replaceChildren()
    setStatus('Loading…')
  },
}

// Hide the in-page label — native shows its own opening chrome.
// Do not leave "Ready" visible or it stacks with SwiftUI's "Opening…".
setStatus(null)
post('ready', {})
log('bridge ready')
