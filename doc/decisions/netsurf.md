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
TLS. No C sockets in libmynos were needed (they came later, mynos-t9l,
without TLS: the fetcher stays on net/1).

### 4. ports/netsurf: patches, not sources

The repository keeps the build script, the patches and MyNOS's two
files; the sources are downloaded at build time, their version and
SHA-256 fixed. The build runs in its own container image
(`tools/containers/netsurf`), not in `tools/build-all.sh`.

### 5. It reaches users as a port only (2026-11-24)

The owner's decision, for the version the book describes: NetSurf stays
in `ports/netsurf` (its scripts, patches and MyNOS pieces), built by
whoever wants it with `build.sh` and tried with `try.sh`. No package,
nothing in the system image or the release: `pkg` does not change. A
package (the first with a C program, its fonts apart, with a note on
where its GPL sources are) remains possible later.

## Open

- gzip, WebP. Images (PNG, JPEG, SVG) and real fonts (FreeType, DejaVu)
  are there, at 3.92 MB of the 4 MB a program may take: WebP does not
  fit; the limit, or JavaScript (Duktape, about 800 KB), would have to
  give way. NetSurf 3.11's own limits (no CSS var(), gradients, grid)
  stay.
