# BROWSER-TODO

What is left to do for Ariadne (`ariadne`), the new browser, milestone by milestone. The plan,
its choices and rules are in [`doc/decisions/browser.md`](doc/decisions/browser.md);
this file only keeps track.

Tick a line when it is done and committed; add lines as work finds
them. Timings go in "Measurements", decisions in "Decisions".

## Decisions

Taken (the owner, 2026-11-27):

- [x] OCaml, as bytecode on `ocamlrun`; no C/C++ engine, no `ocamlopt`
- [x] C only in services for specific jobs: QuickJS in `jsd`; generic `Gfx` primitives
- [x] A new program; `packages/browser` stays as it is
- [x] Its name: Ariadne, `ariadne`
- [x] The fonts: Liberation 2.1.5 (Sans, Serif, Mono; SIL OFL 1.1), on the RAM disk (2026-11-27)
- [x] Pages compared with a reference browser's rendering (headless Chrome) at each step, side by side, rather than judged from memory (2026-11-27, after two overstatements)
- [x] MyNOS first, in this repository, on the `browser` branch (from `next`); the host is a test bench

Open:

- [ ] Ariadne as a package (`doc/decisions/packages.md`): the owner's choice (2026-11-27), to do later; on the RAM disk until then
- [ ] The target sites: which real pages must read well for it to count as usable
- [ ] Review and accept `doc/decisions/browser.md`

## M0: the skeleton

- [x] `ariadne/`: Makefile, built by `tools/build-all.sh`, on the system RAM disk (tried on x86-64)
- [ ] The same, tried on i386 and AArch64
- [x] The window (`Gui`), an address bar, a page area that scrolls (wheel, Page Up/Down, Home, End)
- [x] `ariadne --dump URL`: the page as text on the standard output, then its links
- [x] `ariadne --time URL`: the time of each stage
- [x] Test pages with no network needed: built into the program (`about:tests`, `about:test/NAME`) rather than on the flat RAM disk
- [x] The host test runner: `tools/test-ariadne.sh` (`make -C ariadne test`; `make -C ariadne expected` writes the expected texts, to be read before committing)
- [x] The same checks in MyNOS: `tests/ariadne`, a boot in lane b of `run-tests.sh` (tried alone; passes in 3 s)
- [ ] The whole of lane b with the new boot, in the `mynos-test` container
- [x] The quick loop: `tools/ariadne-dev.sh` builds only Ariadne and puts it in `/disk/bin`, which `PATH` finds first
- [ ] The quick loop, part two: the host serves test pages at `10.0.2.2`
- [x] Manual: ARIADNE in the command reference (chapter 13)

Found in M0, for later:

- The M0 parser walked the stack of open elements at every tag: a page nested 5,000 deep took minutes in MyNOS. It now counts the open elements by name. M1's parser needs the same, since the specification's "in scope" checks also walk the stack.
- `en.m.wikipedia.org` redirects to the desktop site, whose menus come before the article. Without CSS (M3) they show.

## M1: the HTML parser and the DOM

- [x] The DOM's types: document (with its quirks mode), fragment, doctype, element (namespace, namespaced attributes), text, comment, processing instruction; template contents; parents and children without deep recursion (`dom.ml`)
- [x] The decoding: UTF-8 (invalid bytes as U+FFFD), windows-1252 and its labels (ISO-8859-1, ASCII...), UTF-16; the BOM, the HTTP header, the `<meta>` prescan, else UTF-8 if valid, windows-1252 if not (`encoding.ml`)
- [ ] Other encodings (ISO-8859-15, Shift_JIS, GBK...): read as windows-1252 for now
- [x] The tokenizer: every state of the HTML Standard, with its processing instructions (`tokenizer.ml`)
- [x] Named character references: the full table (2,231), generated from the Standard's `entities.json` at build time
- [x] The tree builder: every insertion mode, the adoption agency, foster parenting, templates, SVG and MathML, fragments; scripting off (`treebuilder.ml`)
- [x] html5lib-tests' tokenizer tests (MIT) and WPT's tree construction tests (BSD) in `third_party/`, run on the host by `make -C ariadne test`, which fails under 99.9%
- [x] The pass rate recorded below: 8,775 of 8,779
- [ ] `<selectedcontent>` filled from the selected `<option>`: DOM behaviour, not the parser's; the 4 tests that fail (M6, with the DOM's API)
- [x] `--dump` reads the test pages from the DOM; `--time` adds the decoding

Found in M1:

- The Standard changed in 2025–26 since the parser was first written from memory: processing instructions (`<?target data>`) are nodes, no longer bogus comments; the customizable `<select>` removed the "in select" modes (`select` is now a scope boundary, and `option`, `optgroup`, `hr`, `input` have new rules in "in body"); "parsing template contents" replaced "a template on the stack" for forms; an implied `<body>` leaves frameset-ok "ok". The tests caught each one; the rules were read from the Standard's text (13.2), not guessed.
- Speed (bytecode): the parser is about twice M0's tag soup. The time is spread over the tokenizer's ~130,000 steps per large page and the tree builder's per-token work, with no hotspot (`ocamlprof`). Valid UTF-8 is now checked, not copied; runs of text and attribute values are copied at once. `tests/bench.ml` times the stages on saved pages.

## M2: fonts

- [x] TrueType: `cmap` (formats 4, 12), `glyf` (simple and composite glyphs), `loca`, `hmtx`, `head`, `hhea`, `maxp`; kerning from `kern` (`ttf.ml`, checked against fontTools)
- [ ] Kerning from `GPOS`; ligatures (`GSUB`); hinting
- [x] The rasterizer: outlines to coverage by signed-area accumulation (as font-rs), antialiased, a grey mask for `Gfx.draw_mask`
- [x] The glyph cache: per font, size and glyph; measured widths and glyph runs cached too (`fonts.ml`)
- [x] Measuring text: advances, kerning, ascent, descent, line gap; lines on a baseline with CSS's half-leading
- [x] Choosing a font: `font-family` mapped to Sans, Serif or Mono (Arial, Helvetica, Georgia, Times, Courier, generic names...), weight, style
- [ ] A fallback for characters Liberation lacks (CJK, many symbols): today the font's empty box
- [x] The fonts on the RAM disk (and the test boot's), with their licence (`third_party/liberation-fonts`)
- [ ] A library usable by every GUI program, not only `ariadne` (`ttf.ml` is self-contained; `fonts.ml` would move to `mynos-lib`)
- [x] Text in a window: sizes, bold, italic, serif and sans (Wikipedia's article, in MyNOS)
- [ ] Selecting and copying text in Ariadne's window (lost: the window no longer draws with `Gui.text`)
- [x] `tests/render.ml`: a page rendered to an image on the host, as the window paints it, to compare with a reference browser's screenshot

Found in M2, by comparing with Chrome at the same width:

- Images keep the ratio of their `width` and `height` attributes when CSS says `height: auto`; a percentage `max-width` does not apply while natural widths are measured.
- Wikipedia's headings are `display: flow-root`: a formatting context of their own, beside floats.
- A cell spanning columns gives them its extra width in proportion to their own.
- `vertical-align: super` raises the text of the element's inline descendants too (the footnotes' `<a>` in `<sup>`).
- `::before` and `::after` with text content (`[ edit ]`), `caption-side: bottom` (figures).

## M3: CSS and the first layout

- [x] CSS syntax (Syntax Level 3): tokenizer and parser; `<style>`, `<link rel=stylesheet>` (fetched, with its `media`), `@import` (three levels), the `style` attribute (`css.ml`)
- [x] Selectors (Level 4): type, class, id, attributes (all operators, `i`), the four combinators, `:not`, `:is`, `:where`, `:has`, `:nth-child(An+B of S)` and the structural ones, `:root`, `:empty`, `:link`, `:checked`, `:disabled`; dynamic ones valid but never matching; specificity (`selector.ml`)
- [x] The cascade: the browser's own style sheet (the rendering section, with quirks mode's table rule), presentational hints (`bgcolor`, `align`, `width`, `<font>`...), the author's, the style attribute, `!important`, specificity, order; inheritance; `inherit`, `initial`, `unset` (`style.ml`)
- [x] Computed values: `px`, `em`, `rem`, `%`, `vw`/`vh` and the others; `calc()`, `min()`, `max()`, `clamp()`; custom properties and `var()` with fallbacks; colours (148 names, system colours, `#hex`, `rgb()`, `hsl()`, `light-dark()`); `@media` (types, ranges, the usual features), `@supports`, `@layer`; the shorthands (`margin`, `padding`, `border*`, `font`, `background`'s colour, `list-style`)
- [x] The box tree: `display` block, inline, none, contents, list-item; anonymous blocks; blocks inside inlines (`layout.ml`)
- [ ] `inline-block` as a box of its own (today: its content flows inline)
- [x] Block layout: widths (`auto`, lengths, `%`, `min-`/`max-width`, `box-sizing`), `auto` margins centring, padding, borders, heights; sibling margins collapsing
- [ ] Margins collapsing between a parent and its first or last child (`<body>`'s and an `<h1>`'s add up today)
- [x] Inline layout: lines broken at spaces, words too long cut, `white-space` (all five), `text-align`, `text-indent`, `line-height`, `text-transform`; inline backgrounds, margins and padding; underlines, line-through
- [ ] `vertical-align` (`sub`, `super`, `middle`); justified text (shown left-aligned)
- [x] The display list; painting: the canvas, backgrounds, borders, text (bold), underlines, list markers (bullets, numbers, letters, Roman); form controls and images as frames (M4: images)
- [x] Scrolling, hit testing, links (in-page `#anchors` too), history (back, forward), `<base href>`
- [ ] URLs (the WHATWG parser): still M0's resolver
- [x] https through `Http`
- [x] A Wikipedia article's text is legible, in order; its timings recorded below. (Written first as "reads well": an overstatement. The page took Wikipedia's shape only with M5's floats, flexbox, grid, tables and positioning; its fonts come with M2, its pictures with M4.)
- [x] `ariadne --layout URL [WIDTH]`: the display list; the test pages' display lists checked (`tests/expected-layout/`), on the host and in MyNOS

Found in M3:

- The cascade took 5.7 s on Wikipedia (8,253 elements, 2,132 rules) in MyNOS. Two fixes, from `ocamlprof`: an element's classes are split once and kept (`Dom.classes`), and an ancestor filter (as browsers have) skips the rules whose descendant selectors need an ancestor tag, class or id that no ancestor has. Now 402 ms.
- Most of a page's time is now the network: about 1.8 s per request to Wikipedia (the page, then each style sheet, one after the other). Keeping connections open and fetching the sheets in parallel would help; `netd` and `Http` are where.
- Positioned elements are left out until M5, flex and grid are blocks: Wikipedia's header and tabs stack vertically; Hacker News's table rows break where a cell holds a block (`<center>`).

## M4: images

Decoding is in C, at the owner's choice (2026-11-27): `imaged` (services/image) uses stb_image (JPEG baseline and progressive, PNG, GIF, BMP) and NanoSVG (SVG), in third_party/. A picture from the web is untrusted data, decoded in a process of its own. A first version of the decoders in OCaml (inflate, PNG, GIF, JPEG) was written and dropped untested.

- [x] `imaged`: protocol `image/1` (`size`, `decode` at a width and height, an SVG drawn at it), module `Images`; started by `init.rc`
- [x] JPEG (baseline, progressive), PNG, GIF (the first frame), BMP: stb_image
- [x] SVG: NanoSVG (Wikipedia's wordmark and tagline)
- [x] `Gfx.draw_image`: a picture blended by its alpha, clipped (C)
- [x] Pictures fetched in the background (three workers) once the page shows; their size from `imaged`; laid out again (at most every second) only when a picture without `width` and `height` was waiting for its size
- [x] Sized by `width`/`height` attributes and CSS (ratio kept, `max-width`) before arriving; by their own size after; pixels asked of `imaged` at the size drawn, the last two sizes kept
- [x] Pictures as blocks (flex and grid items, `display: block`): replaced boxes
- [x] The host's renderer (tests/render.ml) draws pictures, with `services/image/picture` (imaged's code as a host command)
- [x] `srcset` and `<picture>` (`Layout.img_source`): a `<source>` imaged decodes (not WebP, AVIF) and without a media query, else `src`, else `srcset`'s candidate (density nearest above 1x, or the narrowest from the page's width up); `data:` URLs (base64 or not) in the Loader
- [x] `background-image`, `-repeat`, `-position`, `-size` (and the shorthand): the first layer, in the padding box of block-level boxes; `url()` resolved against its style sheet's URL
- [x] `mask-image` (and `-webkit-`, `mask-size`, `-position`, `-repeat`, the shorthand) over a background colour: the picture's alpha in that colour (`Gfx.draw_image ~tint`): Wikipedia's icons
- [x] A custom property that refers to itself (`--x: var(--x, 1rem)`, everywhere in Wikipedia's skin) has no value and the fallback holds (it made every declaration using it invalid: the icons' size among them)
- [ ] Backgrounds of inline boxes; several layers; gradients; `background-clip`, `-origin`, `-attachment`
- [ ] Wikipedia's header: the icons' places (the menu 9 px left of Chrome's, search lower), the appearance and bookmark icons, the contents icon by the title
- [ ] gzip in `Http` (`Accept-Encoding`)
- [x] Pictures on screen fetched before the others (then the rest in the page's order); pixels for the screen before any fetch
- [x] A cache of pictures across pages (by URL, 24 MB of their data, the oldest dropped): Back draws a page's pictures without fetching them
- [x] `Http` keeps connections open and reuses them (per server: at most 2, one TLS handshake at a time; at most 8 idle): a picture on an open connection takes 0.1–0.3 s instead of about 1.1 s
- [x] The first page laid out once, at the window's width (it was laid out twice: 1.1 s)
- [x] `ARIADNE_DEBUG`: the page's stages, the pictures' fetches and decodings, slow frames, in the kernel log (ms since the start)
- [ ] Shared pages for the pixels instead of a copy in the reply (if large pictures make it slow)
- [x] A check of `imaged` in MyNOS: `ariadne --check-images` (tools/run-tests.sh): its description, a PNG with transparency, a JPEG (and scaled), an SVG drawn at twice its size, an error
- [ ] `<source>` media queries (today such sources are skipped)
- [ ] Measurements: time from page shown to pictures drawn

## Network speed (netd)

Measured 2026-11-27 under KVM (`netbench`, a throwaway program, and `ARIADNE_DEBUG`): an HTTPS GET of a 22 KB picture from upload.wikimedia.org takes about 1.1 s in MyNOS against 0.2 s on the host, and the TLS handshake is 860–1010 ms of it (about 50 ms on the host); request to first byte 80–150 ms, DNS 1 ms once cached. Three handshakes at once take as long as three in a row (3.1 s against 3.3 s).

- [x] Why a TLS handshake costs about 0.9 s: not netd. Each handshake step and frame timed in netd (2026-11-27): the handshake's computation is about 35 ms in all, netd sends each packet within a few ms; the time is between a packet out and the answer in, with QEMU's NE2000 (SYN to SYN-ACK 270 ms, ClientHello to the server's answer 502 ms). With a virtio card (`VIRTIO=1`) the same handshake takes 94–125 ms, and Wikipedia's Ariadne page shows in 1.4 s (7.9 s with the NE2000), all its 30 pictures in 5.0 s (about 16 s).
- [ ] The NE2000's delay: QEMU's NE2000 holding received packets (it refuses them while it thinks its ring is busy, and QEMU retries later?), or how netd's driver (ne2k.c) empties the ring. Meanwhile: virtio by default for x86-64 (`tools/run-demo.sh`), the NE2000 for i386 and PCs without virtio
- [ ] Handshakes in parallel: netd runs lwIP (NO_SYS) and every connection's TLS in its one main loop, so their cryptography takes turns on one processor. TLS (mbedTLS) in threads of its own, the loop passing them the bytes, would let them use the other processors.
- [ ] Style sheets fetched in parallel (today one after the other: 13 sheets, 2.9 s on a reused connection)

## M5: the rest of the layout, and forms

Done before M2, at the owner's choice (2026-11-27): what gives pages their shape.

- [x] Floats (left, right) in their block formatting context: lines and new formatting contexts shortened beside them, the context's height holding them; `clear`
- [x] `position`: relative (offsets), absolute (in the nearest positioned ancestor, insets, static position), fixed (as absolute in the page; it does not stay on screen yet), sticky (as static)
- [ ] `z-index` and stacking contexts (today: positioned boxes are painted after the flow)
- [x] `transform`'s translations (`translate`, `translateX`, `translateY`, `translate3d`, and the `translate` property): the box moved as drawn, a percentage of its own size (Repubblica's off-canvas menu was shown over half the page); scale and rotate are not drawn
- [x] `overflow: hidden` and `clip` clip to the padding box; other values make a new formatting context; `clip: rect()` and `clip-path: inset(50%)` (screen-reader text) hide
- [x] `opacity: 0` hides; an element with `mask-image` paints no background (icons, until masks)
- [x] Tables: automatic layout (columns from their cells' minimum and maximum widths), `colspan`, `rowspan`, `thead` before and `tfoot` after, captions, `border-spacing`, `border-collapse` (as no spacing), cells' `vertical-align`, row backgrounds, the `width` of tables and cells
- [x] Flexbox: rows and columns (and reversed), wrapping, `flex-grow`, `flex-shrink`, `flex-basis`, `min-width: auto`, `order`, `gap`, `justify-content`, `align-items`, `align-self`, auto margins
- [x] Grid: `grid-template-columns` (px, `fr`, `minmax`, `auto`, `min-content`, `max-content`, `fit-content`, `repeat` with `auto-fill`), `grid-template-areas` and `grid-area`, `grid-column` and `grid-row` (lines, spans), auto-placement, `gap`, rows sized to their items
- [ ] Grid: `grid-template-rows` in px or `fr`, named lines, `grid-auto-flow: column`, `justify-items`
- [x] `inline-block`, `inline-flex`, `inline-grid` as boxes in the line, shrink-to-fit
- [x] Margins collapsing through a parent's top and bottom (and out of the root)
- [x] Boxes measured "dry" (nothing drawn), cached by element and width; min- and max-content widths cached by element
- [x] Forms without JavaScript (`forms.ml`, its state in the DOM): text fields (typing, a caret, Left, Right, Home, End, Delete, a password's dots, a placeholder), textareas, check boxes, radio buttons (their groups), `select` (a list of its options), submit buttons (`button`, `input`), hidden fields, `form=`; Enter sends; GET and POST (urlencoded; `formaction`, `formmethod`; a redirect after POST is followed with GET); Chrome's look for the controls (the UA sheet: 13.33 px sans-serif, fields and buttons' colours); a control's text on the line's baseline. Wikipedia's search works
- [ ] Forms: `reset`, `multipart/form-data` (files), `input type=number` and dates' own editing, a textarea's caret by a click, Tab between controls, selecting text in a field, the select list by the keyboard, validation (`required`, `pattern`)
- [x] The `font` shorthand sets the family too, and resets style, weight and line height
- [x] New generic `Gfx` primitives if painting needs them: `Gfx.draw_image` (M4; scaling is `imaged`'s)
- [ ] The test pages match their reference renderings (a browser's screenshots: not yet; the display lists are checked)
- [x] A test page for floats, flexbox, grid, positioning, clipping, inline-blocks and spans (`pages/m5.html`)

Found in M5:

- Wikipedia's skin builds its page with grid and flexbox: until both existed, everything stacked. Its icons are backgrounds shown through masks, its menu toggles checkboxes made invisible with `opacity: 0`, its buttons have transparent borders: each showed as black until handled.
- Laying out by measuring first costs: Wikipedia's layout went from 47 ms to 141 ms in MyNOS. Caching the measurements by element and width keeps nested flex containers from multiplying it.

## M6: JavaScript

- [x] QuickJS-ng v0.18.0 copied into the repository (third_party/quickjs-ng, the library only), built with musl (x86-64 so far)
- [ ] Built and checked on i386 and AArch64
- [x] `jsd` (services/js): protocol `js/1` (create a context, eval, destroy), module `Js`; a runtime per context (64 MB, a stack limit, a run stopped after 5 s); the contexts of a program that ended freed; `ariadne --check-js` in tools/run-tests.sh
- [x] DOM nodes as handles: jsd's `__dom(op, ...args)` calls Ariadne's service `dom/1` (one request: an operation, strings) during a run; `Dom_api` (in the core) does the operations, nodes answered as handle, type, name; an IPC round trip costs 130-210 µs under KVM, so the API does bulk work in one call (querySelectorAll, innerHTML)
- [x] `console` (log, info, debug, warn, error): its text returned with each run
- [x] Timers (`setTimeout`, `setInterval`, `requestAnimationFrame`): none before the page is shown (as browsers: the page's own scripts only, then showing it); then in a thread of their own (`Scripts.start`), every 100 ms, those due
- [x] The core DOM (`js_prelude.ml`, JavaScript over `__dom`): `document`, `window`, `Node`, `Element`, `Text`; queries, attributes, `id`, `className`, `classList`, `dataset`, `style` (the attribute), `textContent`, `innerHTML`, `outerHTML`, `insertAdjacentHTML`, creating, inserting, moving and removing nodes, form values; `location`, `navigator`, `localStorage` (in memory), `URL`; `<noscript>` not shown when scripts ran; `ARIADNE_NOJS` turns scripts off
- [x] Events: `addEventListener`, `dispatchEvent` (bubbling), the document's readiness (`readyState`; `readystatechange` at interactive and complete, `DOMContentLoaded`, `load`)
- [x] Events from the user: the context kept while the page is shown (closed when another replaces it), the shown page's tree held by one lock (`Scripts.dom_lock`): the timers' thread takes it for a batch, each frame tries it, and while scripts have it paints the page as last laid out, scrolls, and says "scripts running..." (no clicks or typing that frame); `click` at what is under the pointer (a control, a link, else the innermost block: `Layout.hits`), `onclick=` attributes, `preventDefault` stops following a link, toggling, sending; `input`, `change`, `submit`; style and layout again when a script changed the page, at most once a second (pages whose ads keep changing them). Repubblica's Menu button opens its menu
- [ ] `fetch` and `XMLHttpRequest`
- [x] Scripts in order, once the page is parsed (inline, `src`); Wikipedia's 4 run without an error (126 ms) and the page takes its `client-js` look
- [x] Cookies (`cookies.ml`, RFC 6265's essentials: Expires, Max-Age, Domain and host-only, Path, Secure, HttpOnly; no public suffix list, a Domain must have a dot and contain the host): Ariadne's jar in the Loader, sent with each request, set by each answer (redirects too), those that outlive the session in /disk/ariadne-cookies.txt (ARIADNE_COOKIES); `document.cookie` (not HttpOnly). Google's consent page now goes through
- [x] `fetch` (`Response`, `Headers`), `XMLHttpRequest`, `URLSearchParams`, `FormData` (basic), `DOMParser` (a detached element): requests made by Ariadne (`Loader.fetch`: any method, headers, body; redirects; cookies), synchronous inside, their callbacks later; another origin's: no cookies, readable only if it allows it (Access-Control-Allow-Origin), only GET, HEAD, POST (no preflight); `data:` URLs anyone's. jsd runs pending jobs (promises, async functions) after each run, and the time waited for the browser does not count against a run's 5 s
- [x] Layout geometry for scripts: a layout of the page as it is now (forced, cached by the DOM's version; the window's once the page is shown), every element's box (`Layout.element_box`: block boxes, and inline fragments by element); `getBoundingClientRect`, `getClientRects`, `offset*` (`offsetParent` by CSS's rule), `client*`, `scroll*`, `scrollIntoView`, `window.scrollTo`/`scrollBy`, `innerWidth`/`scrollY`..., `getComputedStyle` (the cascade's computed values); `IntersectionObserver` from the boxes and the viewport, at observing and as the page scrolls; scroll events. Clicks go to the innermost element under the pointer (`Layout.element_at`)
- [ ] `ResizeObserver`, `MutationObserver` (they report nothing yet); IntersectionObserver's thresholds other than 0; elements' own scrolling
- [x] Scripts added by scripts (`appendChild`, `insertBefore`... of a `<script>`, or of what holds one): run soon after, their `src` fetched (no CORS for scripts, cookies sent), then their `load` or `error`; `document.currentScript`; never twice; not those `innerHTML` made
- [x] Inline `<svg>` drawn (`svg.ml`: serialized into a document of its own, `<use>` replaced by what it names, a lone symbol's viewBox the picture's, `currentColor` and the outer fill the element's colour; a data: URL, which goes the pictures' way to imaged); sized by CSS, its attributes, the viewBox's ratio, else 300 x 150. Repubblica's icons
- [x] SVG's painting from the cascade: `fill`, `stroke`, `stroke-width` (inherited; black, none, 1 at first), presentation attributes as hints below author rules; the root's computed values, each element's where it sets them; `<use>`'s content inherits from the `<use>` (currentColor too)
- [ ] SVG's `<text>` (NanoSVG draws none)
- [x] Gradients: `linear-gradient` (direction, stops with positions, hard stops), `conic-` and `radial-` as one colour; as backgrounds, and as `border-image` (with `fill`: the box and its outset, Repubblica's full-width band; without: the border's strips, instead of the border); drawn in bands of one colour (`Layout.bands`)
- [ ] Gradients: diagonals (drawn along the nearer axis), radial and conic ones, several layers
- [ ] Repubblica: a white box over the top strip's video picture
- [ ] Web fonts (`@font-face`: WOFF needs zlib, WOFF2 Brotli): Repubblica's Eugenio
- [x] Google's home page as Chrome draws it (with Ariadne's User-Agent): `<center>` and `align=` centre block children (the HTML Standard's alignment, `text-align: -webkit-center`); auto margins centre tables too (CSS 2.1 10.3.3); an inline svg with only a viewBox fills its containing block (CSS 2.1 10.3.2; 0 in a shrink-to-fit box); test pages align, svgsize, checked against Chrome
- [x] Style sheets as the document holds them now: `<style>`s parsed once per text, `<link rel=stylesheet>` a script adds fetched in the background and applied when they arrive
- [x] The element interfaces (`HTMLLinkElement`, `HTMLScriptElement`, `HTMLImageElement`... about 60): each element's object of its tag's interface, reflecting its content attributes (strings, URLs, booleans, numbers, enumerations, CORS settings: `link.rel`, `script.async`, `img.loading`, `input.type`, `form.method`...), `relList`, a link's URL parts, `form`/`elements`/`options`/`selectedIndex`; SVG elements `SVGElement`; `Image`, `Option`, `Audio`; `document.baseURI`
- [x] `Location`: `location.href = ...`, `assign`, `replace`, `reload`, its parts, `window.location = ...`: Ariadne goes there after the run; a fragment alone scrolls (`hashchange`)
- [x] `AbortController`/`AbortSignal` (the DOM Standard: `abort`, `timeout`, `any`, the event, fetch refusing an aborted signal); `DOMException`; `TextEncoder`/`TextDecoder` (UTF-8, UTF-16, windows-1252; the same as Node's on valid and invalid input); `Response.arrayBuffer`
- [x] Cookies with control characters refused (RFC 6265bis 5.6): a script's error text with newlines had broken the cookie file
- [ ] Google's results: its page checks the browser with a script, then goes on (Location, now): it now ends at Google's "unusual traffic" page (a reCAPTCHA, in an iframe); not to get around. Iframes are not drawn at all yet
- [x] Iframes: each a page of its own (`src`, `srcdoc`, about:blank; loaded in a thread, its scripts in a context of their own, its pictures), laid out at the frame's size and drawn clipped in its box (`Layout.Frame`; `paint_items` draws any page at an origin, frames within frames); loaded again when `src`/`srcdoc` change; those scripts make, too (found as they are drawn); the iframe's `load` event; a 2px inset border (UA), its own background under a document that sets none (a frame's canvas is transparent: no `html { background }` in the UA sheet any more). The wheel over a frame scrolls it; a click there is its scripts' event and follows its link (in the frame; the window for `_top`, `_parent`, `_blank`); its scripts' navigation moves the frame. Test page frames
- [x] `postMessage` between frames (each a context): `contentWindow`, `parent`, `top` as window proxies; Ariadne carries the data (JSON, the structured clone's plain values) as a `message` event with `origin` (http(s): scheme://host[:port]; srcdoc and about:blank their parent's; else "null") and `source`, the target origin checked; to itself; `MessageChannel`/`MessagePort` within a context
- [x] The window's `addEventListener`, `removeEventListener`, `dispatchEvent` called bare (at a script's top level): the window their this (they threw before, on any page that did it)
- [ ] Frames: form controls in a frame (typing, selects), the pointer shapes over a frame's links; `contentDocument` of a same-origin frame (each frame is a context of its own: it would need one context per origin), `window.frames`/`length`; message ports carried between frames; `sandbox`, `allow`, `loading=lazy`; a frame whose iframe left the document keeps running until its page is closed; `_parent` from a frame within a frame goes to the top
- [ ] Google's reCAPTCHA: its widget is drawn in its frame now; clicking it, and its challenge (another frame), untested
- [ ] WebP pictures (stb_image has none): Repubblica's small thumbnails (gelestatic.it) are WebP
- [ ] `form.submit()`, `requestSubmit()` from scripts; `select.selectedIndex` for several selected options
- [ ] Repubblica: one "TypeError: not a function" left, without a stack
- [ ] Google's home page: "Accedi" not rounded (`border-radius`), the logo 40 px higher than Chrome's, "Google offerto in: English" missing
- [ ] The host's renderer: protocol-relative picture URLs (`//host/...`) not downloaded
- [ ] `defer` and `async` as such, `type=module`, `document.write` while parsing
- [ ] Layout again after the DOM changes (only what changed): a layout of Repubblica costs 1-1.5 s, and the window waits for it
- [ ] The page's own scripts block showing it (4.5 to 17 s on Repubblica, its scripts fetched one after another): what is parsed shown before them, and their `src` fetched ahead, as browsers do
- [x] Repubblica's lazy sections (`lazy-html`, an IntersectionObserver with a 500 px bottom margin, then XHR): loaded when the reader scrolls near them, at 28 400 px (Chrome: 29 000)
- [x] A debugging hook: with ARIADNE_DEBUG, /disk/ariadne-probe.js runs before the page's scripts (pages may replace `console.log`: a probe keeps its own)

## Later

- [ ] CSS grid
- [ ] More Web APIs (`localStorage`, `canvas`...)
- [ ] A fetch and cache service shared by every program
- [ ] Tabs

## Measurements

Timings in MyNOS under KVM, x86-64 (`ariadne --time`); the network's
time apart. Until M3 the Layout column is the text's reading (`Text`); from M3 it is layout, and Paint is the window's drawing.

| Date | Milestone | Page | Size | Parse | Cascade | Layout | Paint | Network |
|---|---|---|---|---|---|---|---|---|
| 2026-11-27 | M0 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,256 nodes | 110 ms | — | 80 ms | — | 5.4 s |
| 2026-11-27 | M1 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,253 nodes | 281 ms, then about 235 ms (host) after the fast paths; decoding 50 ms, then 9 ms | — | 100 ms | — | 5.3 s |
| 2026-11-27 | M1 | www.repubblica.it | 478 KB, 10,241 nodes | 355 ms | — | 67 ms | — | 7.5 s |
| 2026-11-27 | M3 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,253 nodes, 2,132 rules | 251 ms | 5,672 ms, then 402 ms | 47 ms | — | 3.8 s, and 3.6 s for its style sheets |
| 2026-11-27 | M3 | news.ycombinator.com | 32 KB, 1,213 nodes, 125 rules | 29 ms | 63 ms | 9 ms | — | 3.5 s, and 2.0 s for its style sheet |
| 2026-11-27 | M5 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,253 nodes, 2,132 rules | 191 ms | 410 ms | 141 ms | — | 3.6 s, and 3.6 s for its style sheets |
| 2026-11-27 | M2 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,253 nodes, 2,288 rules (with `::before`/`::after`) | 215 ms | 574 ms | 399 ms (text measured in its fonts) | glyphs rasterized once, drawn as masks | 3.8 s, and 3.6 s for its style sheets |

html5lib-tests pass rate:

| Date | Tokenizer | Tree construction |
|---|---|---|
| 2026-11-27 | 6,820 of 6,820 | 1,955 of 1,959 (4: `<selectedcontent>`); 14 skipped (scripting on) |
