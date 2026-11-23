# NetSurf for MyNOS

[NetSurf](https://www.netsurf-browser.org/) 3.11, a web browser in C
with its own HTML and CSS engine and JavaScript (Duktape), built for
MyNOS (mynos-1g0). Its framebuffer front end draws in a window of
MyNOS's display service through a surface written for MyNOS
(`mynos-surface.c`, protocol display/1).

The sources are not in this repository: `build.sh` downloads them (the
version and the SHA-256 of each archive are fixed in it), applies the
patches here, and builds in a container.

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
| `mynos-http.c` | `http:` and `https:` through `netd` (net/1: TCP, TLS with the certificate checked): a thread per fetch makes the connection, sends an HTTP/1.1 request (cookies, POST) and reads the reply (chunked or not); NetSurf's poll passes on the status, headers, data, redirects, errors. No authentication, gzip or kept connections |
| `patches/01-fetch-without-curl.patch` | `fetch.c` included curl's header without curl |
| `patches/02-realpath-access.patch` | `realpath` (musl's reads `/proc/self/fd`) and `access` replaced, for the resource paths |
| `patches/03-frontend-realpath.patch` | the same in the front end's resource lookup |
| `patches/04-load-time.patch` | `NSFB_TIME=1`: the time a page took, on stderr when it is loaded |
| `patches/05-ram-surface-dump.patch` | the `ram` surface (no window) writes a PPM after `NSFB_DUMP_AT` seconds and quits (`NSFB_DUMP`): measures without a display |
| `patches/06-mynos-surface-type.patch`, `07-mynos-surface-build.patch` | the `mynos` surface declared and built |
| `patches/08-mynos-http-build.patch`, `09-mynos-http-register.patch` | the fetcher built and registered |
| `patches/10-empty-url.patch` | an empty URL argument (the launcher's empty `$1`) opens the home page |
| `try.sh` | a clean disk (never `system/disk.img`) with the stage in `/disk/ns` and a launcher, `/disk/ns/netsurf` |

Built without: curl and OpenSSL (`netd` does the network and TLS), PNG,
JPEG, WebP, SVG.
The program is about 3.2 MB stripped: under MyNOS's limit of 4 MB for a
program (one page table), so it is built for size (`-Os`, no unwind
tables, `--gc-sections`).

**Measured** (a saved Wikipedia page, 346 KB, under KVM, `NSFB_TIME=1`):
0.68 s in MyNOS, 0.23 s on Linux (`doc/JOURNAL.md`, 2026-11-23: the two
fixes that took it from 4.3 s).

**Licence.** NetSurf is GPL version 2 only (some of its libraries are
MIT). Each patch follows the licence of the file it changes;
`mynos-surface.c` is MyNOS's, GPL version 2 or later. A NetSurf program
built from them is therefore distributed under version 2.

**Not done** (mynos-1g0): images (PNG, JPEG, SVG); faster pages (a TLS
handshake for every resource: connections are not kept); how NetSurf
reaches users (to be decided).
