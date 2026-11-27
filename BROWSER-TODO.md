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

- [ ] TrueType: `cmap`, `glyf`, `loca`, `hmtx`, `head`, `hhea`, `maxp`; kerning (`kern`, then simple `GPOS`)
- [ ] The rasterizer: outlines to coverage, antialiased, as a grey mask for `Gfx.draw_mask`
- [ ] The glyph cache: per font, size and glyph
- [ ] Measuring text: advance widths, ascent, descent, line gap
- [ ] Choosing a font: family, weight, style; a fallback glyph for missing characters
- [ ] The fonts chosen, on the RAM disk, with their licence
- [ ] A library usable by every GUI program, not only `ariadne`
- [ ] A paragraph in a window: several sizes, bold, italic

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
- [x] A Wikipedia article reads well; its timings recorded below
- [x] `ariadne --layout URL [WIDTH]`: the display list; the test pages' display lists checked (`tests/expected-layout/`), on the host and in MyNOS

Found in M3:

- The cascade took 5.7 s on Wikipedia (8,253 elements, 2,132 rules) in MyNOS. Two fixes, from `ocamlprof`: an element's classes are split once and kept (`Dom.classes`), and an ancestor filter (as browsers have) skips the rules whose descendant selectors need an ancestor tag, class or id that no ancestor has. Now 402 ms.
- Most of a page's time is now the network: about 1.8 s per request to Wikipedia (the page, then each style sheet, one after the other). Keeping connections open and fetching the sheets in parallel would help; `netd` and `Http` are where.
- Positioned elements are left out until M5, flex and grid are blocks: Wikipedia's header and tabs stack vertically; Hacker News's table rows break where a cell holds a block (`<center>`).

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
time apart. Until M3 the Layout column is the text's reading (`Text`); from M3 it is layout, and Paint is the window's drawing.

| Date | Milestone | Page | Size | Parse | Cascade | Layout | Paint | Network |
|---|---|---|---|---|---|---|---|---|
| 2026-11-27 | M0 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,256 nodes | 110 ms | — | 80 ms | — | 5.4 s |
| 2026-11-27 | M1 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,253 nodes | 281 ms, then about 235 ms (host) after the fast paths; decoding 50 ms, then 9 ms | — | 100 ms | — | 5.3 s |
| 2026-11-27 | M1 | www.repubblica.it | 478 KB, 10,241 nodes | 355 ms | — | 67 ms | — | 7.5 s |
| 2026-11-27 | M3 | en.wikipedia.org/wiki/Ariadne | 375 KB, 8,253 nodes, 2,132 rules | 251 ms | 5,672 ms, then 402 ms | 47 ms | — | 3.8 s, and 3.6 s for its style sheets |
| 2026-11-27 | M3 | news.ycombinator.com | 32 KB, 1,213 nodes, 125 rules | 29 ms | 63 ms | 9 ms | — | 3.5 s, and 2.0 s for its style sheet |

html5lib-tests pass rate:

| Date | Tokenizer | Tree construction |
|---|---|---|
| 2026-11-27 | 6,820 of 6,820 | 1,955 of 1,959 (4: `<selectedcontent>`); 14 skipped (scripting on) |
