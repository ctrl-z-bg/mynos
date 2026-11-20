# Decision: packages (`pkg`)

- **Issues:** mynos-vcd
- **Date:** 2026-11-20
- **Status:** accepted (2026-11-20), implemented the same day.

## What was asked

A way to distribute new demos and programs as they are written, without
putting each on the RAM disk: "niente di ambizioso", an index with
versions and packages as archives, on GitHub.

## Choices

1. **A separate repository**, `ctrl-z-bg/mynos-packages`, public, holding
   only what `pkg` downloads: `index.json` and `packages/NAME-VERSION.tar`.
   Binary archives in the main repository would weigh on every clone
   forever. The packages are *described* in the main repository
   (`packages/NAME/spec`), next to the code they are built from, and
   built by `tools/pkg-build.sh`.
2. **Served as plain files** from `raw.githubusercontent.com`: `Http`
   does not follow redirects, and GitHub's release assets are redirects.
   HTTPS gives the origin; the index's BLAKE2b-256 hash and size check
   each archive. No signatures for now.
3. **Hybrid packages**: the program as bytecode *and* its sources.
   A bytecode program depends on the runtime's format (OCaml's magic
   number), on the primitives it calls (resolved by name: adding some
   breaks nothing, removing one does) and on the copy of `mynos.cma`
   linked into it (whose protocols are versioned by name, `display/1`).
   `pkg` installs the bytecode when its magic number is `/ocamlc.byte`'s
   and every primitive of its `PRIM` section is in `/primitives`;
   otherwise, or with `-s`, it compiles the sources with the `ocamlc`
   of the RAM disk. A package thus outlives a change of the runtime, and
   its installation shows what the system can do.
4. **Archives in ustar, not compressed.** A tar reader is a few dozen lines
   of OCaml; gzip would need an inflater. The archives are made the same
   way each time (sorted names, owner and date 0), so an unchanged
   package keeps its hash. Compression can come later, as a new
   `"format"` of the index.
5. **Installed on `/disk`**: the files in `/disk/pkg/NAME`, the program
   in `/disk/bin`, which is first on `sh`'s `PATH`. The index is cached
   in `/disk/pkg/index.json`; `pkg update` reads it again.
6. **The libraries are named** in the spec (`graphics`, `unix`, `threads`,
   `str`, `num`), not guessed from the sources as `compile` does: the
   build on the host and the one inside MyNOS must be the same.
7. **Compiled in the sources' directory**: 2048-ml has a module `Gui`,
   as `mynos.cma` does; `ocamlc` finds an interface in the current
   directory before the `-I` directories.

8. **A window for the graphical session** (`packages.byte`, in the
   MyNOS menu): it reads the index and the installed packages itself
   (module `Pkgdb`, shared with `pkg`) and runs `pkg` as a process for
   every change, its output in a file of `/tmp` that it shows as it
   grows. One implementation of installing, and a window that keeps
   answering while a package downloads or compiles. The repository can
   also be named in `/disk/pkg/url`, since a program started from the
   menu has no shell to set `MYNOS_PKG_URL` in.

## Rejected

- *Packages in the main repository*: the history would keep every
  binary.
- *Bytecode only*: every change of the runtime or of OCaml would break
  the packages already published.
- *Sources only*: a large program would take long to install in QEMU,
  and a package would need the compiler to be installed at all.
- *A version range of MyNOS in the index*: the version changes at every
  commit; what decides is the bytecode's format and primitives, checked
  on the program itself.

## The first packages

`2048` (2048-ml, `third_party/2048-ml`, BSD; it left the RAM disk) and
`windtree` (the agent's tree in the wind, the manual's example of 20.6,
GPL; first called `tree`, renamed the same day: `tree` is Unix's
command for directory trees).
