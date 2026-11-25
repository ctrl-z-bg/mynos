# What is in doc/

- **`STATUS.md`**: the architecture and the current state of the
  project: what builds, what runs, what is missing. Read it first; it is
  updated with every change that alters the state, with a dated line in
  its work log.
- **`JOURNAL.md`**: the engineering diary. For each non-trivial finding
  (a bug, a surprising cause, a design decision): the symptom, the
  diagnosis, the cause, the fix and the lesson.
- **`decisions/`**: one file per design decision (the console, the
  graphical session, typed IPC, the pager, packages, the language
  models...): what was chosen, the alternatives, and why. A decision's
  issues in beads are named at its top.
- **`manual/`**: the MyNOS Reference Manual, one Markdown file per
  chapter and appendix, readable as it is (its `README.md` is the table
  of contents); `manual/examples/` holds the programs it shows.
- **`book/`**: the sources that typeset the manual as a printed book
  (pandoc, a Lua filter, LuaLaTeX): the preface and the back cover,
  which only the book has, the layout and the printer's format
  (160x235 mm). `build.sh` says what it needs; the PDF it makes stays
  out of git.
- **`screenshots/`**: the screens of the graphical session that the
  manual shows, made by `tools/screenshots.sh`.
- **`old-notes/`**: twelve notes from the original project (2002-2004),
  found again in 2026: newsgroup posts, notes on drivers, threads and
  memory. History, not instructions.
- **`website/`**: an offline copy of the original website,
  `mynos.sourceforge.net`, from the Internet Archive.

Issue IDs such as `mynos-awn` are those of beads, the project's issue
tracker (`bd show mynos-awn`), described in the manual's appendix H.
