# BROWSER-TODO

What is left to do for the new browser, milestone by milestone. The plan,
its choices and rules are in [`doc/decisions/browser.md`](doc/decisions/browser.md);
this file only keeps track. `web` is a working name.

Tick a line when it is done and committed; add lines as work finds
them. Timings go in "Measurements", decisions in "Decisions".

## Decisions

Taken (the owner, 2026-11-27):

- [x] OCaml, as bytecode on `ocamlrun`; no C/C++ engine, no `ocamlopt`
- [x] C only in services for specific jobs: QuickJS in `jsd`; generic `Gfx` primitives
- [x] A new program; `packages/browser` stays as it is
- [x] MyNOS first, in this repository, on the `browser` branch (from `next`); the host is a test bench

Open:

- [ ] The program's name
- [ ] The scalable fonts on the RAM disk, and their licence (DejaVu, Noto, Liberation...)
- [ ] In the image, or a package (`doc/decisions/packages.md`)
- [ ] The target sites: which real pages must read well for it to count as usable
- [ ] Review and accept `doc/decisions/browser.md`

## M0: the skeleton

- [ ] `web/`: Makefile, built by `tools/build-all.sh` (i386, x86-64, AArch64)
- [ ] The window (`Gui`), an address bar, a page area that scrolls
- [ ] `web --dump URL`: the page as text on the standard output
- [ ] `web --time URL`: the time of each stage
- [ ] Test pages on the RAM disk (no network needed)
- [ ] The host test runner, in the dev container: the core's tests as bytecode
- [ ] A `run-tests.sh` lane: `--dump` of the test pages, compared with the expected text
- [ ] The quick loop: the host serves the pages and the fresh `web.byte` at `10.0.2.2`, so a change needs no new image
- [ ] Manual: a first page (command reference)

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
- [ ] A library usable by every GUI program, not only `web`
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

Timings in MyNOS under KVM, x86-64, on the test pages (`web --time`).

| Date | Milestone | Page | Parse | Cascade | Layout | Paint | Total |
|---|---|---|---|---|---|---|---|

html5lib-tests pass rate:

| Date | Tokenizer | Tree construction |
|---|---|---|
