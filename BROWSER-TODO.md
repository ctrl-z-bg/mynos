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
- [x] MyNOS first, in this repository, on the `browser` branch (from `next`); the host is a test bench

Open:

- [ ] The scalable fonts on the RAM disk, and their licence (DejaVu, Noto, Liberation...)
- [ ] In the image, or a package (`doc/decisions/packages.md`)
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

- [ ] The DOM's types: document, element, text, comment, doctype; attributes; parents and children without deep recursion
- [ ] The decoding: UTF-8, windows-1252, ISO-8859-1; the BOM, `<meta charset>`, the HTTP header
- [ ] The tokenizer: every state of the WHATWG specification
- [ ] Named character references (the full table, about 2,200)
- [ ] The tree builder: the insertion modes, the adoption agency, foster parenting, the implied ends
- [ ] html5lib-tests copied into the repository (MIT); tokenizer and tree construction tests run on the host
- [ ] The pass rate recorded below
- [ ] `--dump` reads the test pages from the DOM

## M2: fonts

- [ ] TrueType: `cmap`, `glyf`, `loca`, `hmtx`, `head`, `hhea`, `maxp`; kerning (`kern`, then simple `GPOS`)
- [ ] The rasterizer: outlines to coverage, antialiased, as a grey mask for `Gfx.draw_mask`
- [ ] The glyph cache: per font, size and glyph
- [ ] Measuring text: advance widths, ascent, descent, line gap
- [ ] Choosing a font: family, weight, style; a fallback glyph for missing characters
- [ ] The fonts chosen, on the RAM disk, with their licence
- [ ] A library usable by every GUI program, not only `ariadne`
- [ ] A paragraph in a window: several sizes, bold, italic

## M3: CSS and the first layout

- [ ] CSS syntax (Syntax Level 3): tokenizer and parser; `<style>`, `<link rel=stylesheet>`, the `style` attribute
- [ ] Selectors: type, class, id, attributes, combinators, `:not`, `:is`, `:where`, structural pseudo-classes; specificity
- [ ] The cascade: the browser's own style sheet, the author's, `!important`, order; inheritance
- [ ] Computed values: `px`, `em`, `rem`, `%`, `vw`/`vh`; colours; `@media` by width
- [ ] The box tree: `display` block, inline, none, inline-block; anonymous boxes
- [ ] Block layout: widths, margins (with collapsing), padding, borders
- [ ] Inline layout: line breaking, `white-space`, `text-align`, `line-height`, `vertical-align` (baseline)
- [ ] The display list; painting: backgrounds, borders, text, underlines
- [ ] Scrolling, hit testing, links, history (back, forward)
- [ ] URLs (the WHATWG parser), https through `Http`
- [ ] A Wikipedia article reads well; its timings recorded below

## M4: images

- [ ] `imaged`: its typed IPC protocol; the pixels come back in shared pages
- [ ] Inflate (deflate) in OCaml, shared with gzip
- [ ] PNG: filters, palettes, alpha, interlacing
- [ ] JPEG: from `packages/browser`; progressive JPEG
- [ ] GIF: the first frame
- [ ] Scaling to the box's size; `width`/`height` before the image arrives
- [ ] `background-image`
- [ ] gzip in `Http` (`Accept-Encoding`)

## M5: the rest of the layout, and forms

- [ ] Floats and `clear`
- [ ] `position`: relative, absolute, fixed; `z-index` and stacking contexts
- [ ] `overflow`; list markers
- [ ] Tables (automatic layout)
- [ ] Flexbox
- [ ] Forms without JavaScript: text fields, buttons, checkboxes, `select`; GET and POST
- [ ] New generic `Gfx` primitives if painting needs them (alpha blit, scaled blit)
- [ ] The test pages match their reference renderings

## M6: JavaScript

- [ ] QuickJS (quickjs-ng) copied into the repository, built with musl for i386, x86-64, AArch64
- [ ] `jsd`: the service, its typed IPC protocol, DOM nodes as handles
- [ ] `console`, timers (`setTimeout`, `setInterval`, `requestAnimationFrame`)
- [ ] The core DOM: `document`, `querySelector`, attributes, `textContent`, creating and moving nodes
- [ ] Events: `click`, `input`, `submit`, `DOMContentLoaded`, `load`
- [ ] `fetch` and `XMLHttpRequest`
- [ ] Scripts in order: inline, `defer`, `async`
- [ ] Layout again after the DOM changes (only what changed)

## Later

- [ ] CSS grid
- [ ] More Web APIs (`localStorage`, `canvas`...)
- [ ] A fetch and cache service shared by every program
- [ ] Tabs

## Measurements

Timings in MyNOS under KVM, x86-64 (`ariadne --time`); the network's
time apart. Until M3 the Layout column is the text's reading (`Text`).

| Date | Milestone | Page | Size | Parse | Cascade | Layout | Paint | Network |
|---|---|---|---|---|---|---|---|---|
| 2026-11-27 | M0 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,256 nodes | 110 ms | — | 80 ms | — | 5.4 s |

html5lib-tests pass rate:

| Date | Tokenizer | Tree construction |
|---|---|---|
