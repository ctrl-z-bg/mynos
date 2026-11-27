# Decision: Ariadne, a new browser in OCaml

- **Issues:** none yet
- **Date:** 2026-11-27
- **Status:** proposed. The choices below are the owner's (2026-11-27);
  the plan is to be reviewed.

## Why

A browser is what makes MyNOS usable for real work. MyNOS has two today,
and neither is the answer:

- `packages/browser` (OCaml, about 2,700 lines) lays out text with a
  little CSS and no JavaScript. It stays, as it is.
- NetSurf (`ports/netsurf`, `netsurf.md`) is a browser in C. It is not
  what MyNOS is about: programs that run on the OCaml interpreter.

The evaluation of 2026-11-25 (64 bits, four processors) weighed NetSurf,
a rendering proxy, Ladybird, Servo and an OCaml browser.

## The choices (the owner's, 2026-11-27)

- **In OCaml, as bytecode on `ocamlrun`.** No engine in C or C++, and no
  native code from `ocamlopt` (`ocaml-native.md` stays deferred).
- **C only in services for specific jobs.** JavaScript is QuickJS, in a
  service of its own (`jsd`), as lwIP and mbedTLS are C inside `netd`.
  The pixels go through `Gfx`'s C primitives, as they do today, with a
  few more if needed. They stay generic, not the browser's own.
- **A new program, Ariadne** (`ariadne`): Minos's daughter, whose
  thread led Theseus through the labyrinth and out again, as links and
  history lead through the web. `packages/browser` stays as it is. The new one
  starts its HTML parser from the specification. It may reuse the old
  one's URL handling, window code and JPEG decoder.
- **MyNOS first.** The browser lives in this repository, on the
  `browser` branch (from `next`), next to the services it uses. The host
  is only a test bench: the parts with no input or output (parser, DOM,
  CSS, layout) run there as bytecode, to check them in seconds. Speed is
  measured only in MyNOS.

## The shape

| Piece | Where | Language |
|---|---|---|
| HTML parser (WHATWG tokenizer and tree builder), DOM | `ariadne/` | OCaml |
| CSS: syntax, selectors, cascade, computed values | `ariadne/` | OCaml |
| Layout: block, inline and line breaking, then floats, positioning, tables, flexbox | `ariadne/` | OCaml |
| Display list, painting, scrolling, the window, history, forms | `ariadne/` | OCaml, painting with `Gfx` |
| Fonts: TrueType outlines, rasterized once per glyph and size, cached as masks, drawn with `Gfx.draw_mask` (grey levels, so antialiased) | a library, usable by every GUI program | OCaml |
| Images: PNG (inflate), JPEG, GIF | an `imaged` service, which decodes in parallel with the layout, on another processor | OCaml |
| JavaScript: QuickJS, the DOM reached over typed IPC (handles, not objects) | a `jsd` service | C |
| The network: HTTP, TLS, redirects, gzip | `Http` and `netd`, as today. A shared fetch and cache service later, if it pays | OCaml / C |

## Rules for the code

1. **No OCaml loop over pixels.** Pixels move in fills, spans, masks and
   blits, through `Gfx`. The interpreter decides what to draw; it does
   not draw pixel by pixel.
2. **The DOM lives in OCaml.** JavaScript holds integer handles to the
   nodes, not values of either heap. Two garbage collectors never point
   at each other, so there are no cycles across them to leak.
3. **Trees are walked without deep recursion.** Use explicit stacks or
   an iterative walk. A page's tree can be thousands of levels deep, and
   a crash must not depend on how big the stack is.
4. **Only libraries that MyNOS has.** The standard library, `unix`,
   `threads`, `str`, `Mynos` and its libraries, and code copied into the
   repository that builds with plain `ocamlc`. No ppx, Lwt or Eio.
5. **The core does no input or output.** The parser, the DOM, the CSS
   and the layout take strings and give trees and display lists. That is
   what lets the host test them.
6. **Speed is measured from the start.** A fixed set of pages, timed in
   MyNOS under KVM at every milestone: parsing, cascade, layout and
   painting separately.

## Milestones

| | What | Done when |
|---|---|---|
| M0 | The skeleton: the program and its window, `ariadne --dump`, the test pages, the host test runner, a `run-tests.sh` lane, the timing harness | `ariadne` opens a page from the RAM disk and shows its text |
| M1 | The HTML parser and the DOM | html5lib-tests' tree construction tests mostly pass on the host; `--dump` reads the test pages well |
| M2 | Fonts: TrueType in OCaml, the glyph cache, measuring and drawing text | a paragraph in a proportional font, at several sizes, bold and italic, in a window |
| M3 | CSS and the first layout: cascade, block and inline boxes, line breaking, the display list, painting, scrolling, links, history | a Wikipedia article reads well, over https |
| M4 | Images, in `imaged`, and gzip in `Http` | the test pages with PNG, JPEG and GIF images |
| M5 | Floats, positioning, tables, flexbox; forms without JavaScript | the test pages match their reference renderings |
| M6 | `jsd` with QuickJS: `console`, timers, the core DOM, events, `fetch` | the test pages that need a little JavaScript work |
| later | Grid, more Web APIs, a fetch and cache service | — |

## Testing it inside the image

- `ariadne URL` opens a window; `ariadne --dump URL` writes the page as text
  (or its display list) on the standard output, for `run-tests.sh`;
  `ariadne --time URL` prints the time of each stage.
- The test pages are built into the program (`about:tests`,
  `about:test/NAME`), so they work with no network and do not crowd the
  RAM disk, which is flat. The same pages and their expected text are
  checked on the host (`tools/test-ariadne.sh`) and in MyNOS (a boot of
  `run-tests.sh`).
- For a quick loop, `tools/ariadne-dev.sh` builds only Ariadne and puts
  it on the disk as `/disk/bin/ariadne.byte`, which `PATH` finds before
  the RAM disk's: trying a change needs no new image. Pages can also be
  served by the host (QEMU's user network reaches it at `10.0.2.2`).

## Open questions

- **The fonts:** which scalable family goes on the RAM disk, and under
  which licence (DejaVu, Noto, the Liberation fonts...).
- **In the image or a package** (`packages.md`).
- **The test pages:** which real sites must read well for the browser to
  count as usable.
