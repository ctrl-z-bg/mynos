# NetSurf for MyNOS

[NetSurf](https://www.netsurf-browser.org/) 3.11, a web browser in C
with its own HTML and CSS engine and JavaScript (Duktape), built for
MyNOS (mynos-1g0). Its framebuffer front end draws in a window of
MyNOS's display service through a surface written for MyNOS
(`mynos-surface.c`, protocol display/1).

The sources are not in this repository: `build.sh` downloads them, and
those of zlib, libpng, libjpeg (IJG 9f), expat, FreeType 2.13.3 and the
DejaVu fonts 2.37 (the version and the SHA-256 of each archive are fixed
in it), applies the patches here, and
builds in a container. Images: PNG, JPEG, GIF, BMP, ICO and SVG
(libsvgtiny); not WebP.

```
tools/build-all.sh               # libmynos first
ports/netsurf/build.sh           # build/netsurf/stage: nsfb, res, home
ports/netsurf/try.sh             # MyNOS in QEMU, a clean disk with it in /disk/ns
```

In MyNOS: `gui`, open a Terminal, then `/disk/ns/netsurf [URL]`. Pages
come over the network through `netd` (`mynos-http.c`): Wikipedia's
article on OCaml, over HTTPS, in about 10 s under KVM.

| File | What it is |
|---|---|
| `build.sh` | download, check, unpack, patch; the container build |
| `inside.sh` | the build in the `mynos-netsurf` container (`tools/containers/netsurf`): NetSurf and its libraries for Linux (its build runs tools it builds), then the program linked again for MyNOS (load address 0x40000000, libmynos before musl), staged |
| `mynos-surface.c` | the libnsfb surface `mynos`: a window of `displayd`, its pixels a shared message, `damage` on each update; keys (UTF-8, VT100 sequences) on NetSurf's US keymap, the mouse, the wheel, close, resize. The calls to libmynos are weak: the same libnsfb links on Linux |
| `mynos-http.c` | `http:` and `https:` through `netd` (net/1: TCP, TLS with the certificate checked): a thread per fetch sends an HTTP/1.1 request (cookies, POST) and reads the reply (chunked or not); NetSurf's poll passes on the status, headers, data, redirects, errors. Connections are kept open, at most 4 per server and 12 in all (an idle one is closed after 20 s, or to make room): a reply whose end is known leaves its connection for the next fetch (netd does one TLS handshake at a time, so each one saved shortens every fetch); a kept connection the server closed meanwhile is tried once more on a new one. `NSFB_DEBUG=1` logs each fetch's phases. No authentication or gzip |
| `patches/01-fetch-without-curl.patch` | `fetch.c` included curl's header without curl |
| `patches/02-realpath-access.patch` | `realpath` (musl's reads `/proc/self/fd`) and `access` replaced, for the resource paths |
| `patches/03-frontend-realpath.patch` | the same in the front end's resource lookup |
| `patches/04-load-time.patch` | `NSFB_TIME=1`: the time a page took, on stderr when it is loaded |
| `patches/05-ram-surface-dump.patch` | the `ram` surface (no window) writes a PPM after `NSFB_DUMP_AT` seconds and quits (`NSFB_DUMP`): measures without a display |
| `patches/06-mynos-surface-type.patch`, `07-mynos-surface-build.patch` | the `mynos` surface declared and built |
| `patches/08-mynos-http-build.patch`, `09-mynos-http-register.patch` | the fetcher built and registered |
| `patches/10-empty-url.patch` | an empty URL argument (the launcher's empty `$1`) opens the home page |
| `patches/11-framebuffer-paths.patch` | the framebuffer front end drew no paths ("path unimplemented"), and SVG is drawn with nothing else: curves made line segments, filled a scan line at a time (non-zero winding), stroked; fill and stroke by colour, as `svg.c` leaves the plot types unset. A clip outside the surface is empty, not an error (the error fell on the next plot, an SVG, drawn as broken) |
| `patches/13-address-bar-select-all.patch`, `14-...-state.patch` | the address bar had no selection: the click that gives it the caret selects all of it (so does Ctrl-A), typing replaces it, Backspace and Delete clear it; Delete deletes forward; after Enter the caret leaves it |
| `patches/15-address-bar-search.patch` | words in the address bar (a space, or neither a dot nor a colon) are a web search, through NetSurf's own providers: the framebuffer front end never used them. `res/SearchEngines` puts Google over HTTP first, DuckDuckGo's lite page next |
| `patches/16-welcome-google-http.patch` | the welcome page searches Google over HTTP |
| `patches/12-svgtiny-quadratic.patch` | libsvgtiny: a relative `q` kept its control point relative, a relative `t` added the current point to its reflected one twice |
| `try.sh` | a clean disk (never `system/disk.img`) with the stage in `/disk/ns` and a launcher, `/disk/ns/netsurf` |

Built without: curl and OpenSSL (`netd` does the network and TLS), WebP.
SVG gradients are not drawn (libsvgtiny).
The program loads 3.92 MB (3.7 MB stripped): under MyNOS's limit of
4 MB for a program (one page table), so it is built for size (`-Os`, no unwind
tables, `--gc-sections`).

**Text** is drawn by FreeType with the DejaVu fonts (sans, serif and
mono, with their bold and italic faces), from `/disk/ns/fonts`
(`NETSURF_FB_FONTPATH`); cursive and fantasy fall back to the sans. Not
NetSurf's own bitmap font, which is monospaced: text took the wrong
widths and large sizes were blocks. FreeType is built with only the
modules a TrueType font needs, without font variations or compressed
tables, to fit.

**Measured** (a saved Wikipedia page, 346 KB, under KVM, `NSFB_TIME=1`):
0.68 s in MyNOS, 0.23 s on Linux (`doc/JOURNAL.md`, 2026-11-23: the two
fixes that took it from 4.3 s).

**Licence.** NetSurf is GPL version 2 only (some of its libraries are
MIT). Each patch follows the licence of the file it changes;
`mynos-surface.c` is MyNOS's, GPL version 2 or later. A NetSurf program
built from them is therefore distributed under version 2.

**Google** search works over plain HTTP only: over HTTPS its results
come through a JavaScript loader that NetSurf cannot run (it lacks
`performance` and `Image`), and the page stays blank; over HTTP the
results are in the page, as NetSurf on Linux shows. The query then
travels unencrypted.

**How it reaches users**: as this port only (decided on 2026-11-24,
`doc/decisions/netsurf.md`): built here, not a package, not in the
system image.

**Not done**: WebP (BBC's images, for one; no room for it
under 4 MB). Fetches still stall now and then for about 1.5 s, a matter
of MyNOS's network card under QEMU, not of NetSurf (mynos-bix). Room left under the 4 MB limit: about 270 KB.
