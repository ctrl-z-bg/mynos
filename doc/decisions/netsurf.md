# Decision: NetSurf as MyNOS's web browser

- **Issue:** mynos-1g0 (the experiment: mynos-6e0)
- **Date:** 2026-11-23
- **Status:** accepted for the port; how it reaches users is still open.

## The question

MyNOS's own browser (`packages/browser`, OCaml) lays out text with a
small subset of CSS and runs no JavaScript. Writing a real engine is
years of work. Could an existing browser in C run on MyNOS instead?

## Choices

### 1. NetSurf

NetSurf (GPL version 2 only) is a complete engine in C: HTML, CSS with
floats, tables and flexbox, JavaScript (Duktape), with a framebuffer
front end that needs nothing from the system but a surface of pixels
and events. It built with musl, statically, for i386, and fits MyNOS's
4 MB limit for a program when built for size (3.2 MB).

### 2. Measured before going on

The first build in MyNOS was 25 times slower than on Linux. The causes
were MyNOS's, and were fixed for every program: libmynos's malloc took a
kernel semaphore at each call (mynos-a0w), and the timer at 100 Hz made
every short wait last 10 to 20 ms (mynos-zeu, now 1000 Hz). A saved
Wikipedia page: 4.3 s, then 0.68 s (Linux 0.23 s).

### 3. MyNOS's pieces in NetSurf, not NetSurf's in MyNOS

A libnsfb surface (`ports/netsurf/mynos-surface.c`) draws in a window of
`displayd` (display/1, pixels shared); a fetcher
(`ports/netsurf/mynos-http.c`) does HTTP over `netd`'s sockets, which do
TLS. No C sockets in libmynos were needed (mynos-t9l stays open).

### 4. ports/netsurf: patches, not sources

The repository keeps the build script, the patches and MyNOS's two
files; the sources are downloaded at build time, their version and
SHA-256 fixed. The build runs in its own container image
(`tools/containers/netsurf`), not in `tools/build-all.sh`.

## Open

- How NetSurf reaches users: it would be the first package with a C
  program. To be discussed with the user before it is done.
- gzip, WebP. Images (PNG, JPEG, SVG) and real fonts (FreeType, DejaVu)
  are there, at 3.92 MB of the 4 MB a program may take: WebP does not
  fit; the limit, or JavaScript (Duktape, about 800 KB), would have to
  give way. NetSurf 3.11's own limits (no CSS var(), gradients, grid)
  stay.
