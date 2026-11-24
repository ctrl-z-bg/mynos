# The original MyNOS website (archive copy)

This directory is a static, offline copy of the original MyNOS project website,
`http://mynos.sourceforge.net/`, as preserved by the Internet Archive's Wayback
Machine. It is kept for the history of the project.

The content is the original project's site. MyNOS (2002-2008, GPL) was written
by Cesare Zavattari, Alessandro Tommasi and Tommaso Schiavinotto; the news
posts are signed with the SourceForge user names `zavatt`, `alley` and `nardo`.
The logo is by Luigi Ferrini. The site was hosted on SourceForge (project
`mynos`, `group_id=35113`).

Open `index.html` in a browser.

## Source

- Reference snapshot:
  <https://web.archive.org/web/20090311064912/http://mynos.sourceforge.net/>
  (home page captured 2009-03-11).
- Every other file is the capture closest in time to 2009-03-11 among the
  status-200 captures of the same URL. Their dates range from 2003-01-24 to
  2013-05-20 (see the table below). The site did not change after 2004-2005,
  so the mix of dates gives a consistent picture of its final state.

## How it was obtained

1. The captures were listed with the Wayback CDX API:
   `https://web.archive.org/cdx/search/cdx?url=mynos.sourceforge.net/*&output=json&fl=timestamp,original,mimetype,statuscode,length`
   (the `matchType=domain` query returned the same 662 rows).
2. For each URL, only status-200 captures were kept and the one closest to
   2009-03-11 06:49:12 was selected (`http`/`https` and `:80` variants
   counted as the same URL).
3. Each file was downloaded with the `id_` form, which returns the archived
   bytes without the Wayback toolbar:
   `https://web.archive.org/web/<timestamp>id_/<original-url>`.
   Requests were sequential and spaced out, with retries on 5xx (the archive
   was intermittently "Temporarily Offline" during the download).
4. The HTML pages were then adapted for offline use (see "Changes from the
   original bytes"). No Wayback scripts or toolbar were present in the `id_`
   downloads, so none had to be removed. Images and tarballs are byte-for-byte
   the archived ones.

Date of the download: 2026-11-16.

## Changes from the original bytes

Only these edits were made to the HTML pages:

- **File names.** The pages were PHP pages; they are saved as `.html` so they
  open from disk: `why.php` becomes `why.html`, `screenshots.php?shot=N`
  becomes `screenshots-shot-N.html`, and `/` (and `index.php`, the same page)
  becomes `index.html`.
- **The news archive link.** "Site news archive »" on the home page points
  to `news.html` (see below) instead of SourceForge's list.
- **Links.** Links (`href`/`src`) to archived files of `mynos.sourceforge.net`
  were rewritten as relative paths. Links to files of `mynos.sourceforge.net`
  that were never archived were rewritten as absolute original URLs
  (`http://mynos.sourceforge.net/...`). Links to other sites were left
  unchanged.
- **Scripts.** The pages contained two visitor-counter scripts: a local
  `statitm` counter and `thunderstats.com`. They were disabled by adding
  `type="text/plain"` to their `<script>` tags. The code is still there and
  unchanged, but browsers no longer run it. The `<noscript>` and 1x1 tracker
  `<img>` tags were left as they were (absolute URLs, now dead).

The `img/^Z_bg_logo.gif` file keeps its original name, which includes a `^`.

## Files

| Local file | Original URL (`http://mynos.sourceforge.net/...`) | Capture | Size (bytes) |
|---|---|---|---|
| `index.html` | `/` | 2009-03-11 | 6268 |
| `why.html` | `why.php` | 2009-03-19 | 7423 |
| `status.html` | `status.php` | 2009-03-19 | 4995 |
| `sfcorner.html` | `sfcorner.php` | 2009-03-21 | 5792 |
| `screenshots.html` | `screenshots.php` | 2009-03-19 | 5335 |
| `screenshots-shot-1.html` | `screenshots.php?shot=1` | 2005-08-31 | 3136 |
| `screenshots-shot-2.html` | `screenshots.php?shot=2` | 2005-09-05 | 3303 |
| `screenshots-shot-3.html` | `screenshots.php?shot=3` | 2005-09-07 | 3369 |
| `screenshots-shot-4.html` | `screenshots.php?shot=4` | 2005-09-22 | 3193 |
| `screenshots-shot-5.html` | `screenshots.php?shot=5` | 2005-04-04 | 3135 |
| `screenshots-shot-6.html` | `screenshots.php?shot=6` | 2005-08-28 | 3254 |
| `screenshots-shot-7.html` | `screenshots.php?shot=7` | 2005-04-04 | 3211 |
| `screenshots-shot-8.html` | `screenshots.php?shot=8` | 2005-08-31 | 3140 |
| `screenshots-shot-9.html` | `screenshots.php?shot=9` | 2005-04-04 | 3156 |
| `tryit.html` | `tryit.php` | 2009-03-19 | 4067 |
| `links.html` | `links.php` | 2009-03-19 | 5126 |
| `files/mynos-test.tgz` | `files/mynos-test.tgz` | 2004-06-05 | 162106 |
| `files/mynos-test-2002-10-17.tgz` | `files/mynos-test.tgz` (earlier version) | 2002-10-17 | 80711 |
| `img/mynos-logo.jpg` | `img/mynos-logo.jpg` | 2004-09-21 | 3407 |
| `img/^Z_bg_logo.gif` | `img/^Z_bg_logo.gif` | 2004-09-21 | 1284 |
| `img/php-logo.png` | `img/php-logo.png` | 2004-10-26 | 3035 |
| `img/counter/0.gif` ... `9.gif` | visitor counter digits | 2003-01-24 ... 2013-05-20 | 106-122 each, 1198 in total |
| `img/snap_5processes_small.jpg` | same | 2003-01-24 | 1431 |
| `img/snap_fork_small.jpg` | same | 2003-01-24 | 1433 |
| `img/snap_initsys_small.jpg` | same | 2003-01-24 | 1535 |
| `img/snap_ocaml_small.jpg` | same | 2003-01-24 | 1871 |
| `img/snap_pagefault_small.jpg` | same | 2003-01-24 | 1817 |
| `img/snap_ramdisk_small.jpg` | same | 2003-01-24 | 1736 |
| `img/snap_vga_small.jpg` | same | 2003-01-24 | 1528 |
| `img/snap_sem_small.jpg` | same | 2003-01-24 | 1893 |
| `img/snap_sem.png` | same | 2004-07-05 | 17650 |
| `img/snap_serial_small.jpg` | same | 2013-05-20 | 1949 |
| `img/snap_serial.jpg` | same | 2013-05-20 | 49827 |
| `news.html` | see below | 2009-03 | 7308 |
| `README.md` | this file | | |

The counter digits were captured on these dates: 0 on 2003-01-24, 1 on
2003-12-04, 2 on 2004-09-21, 3 on 2013-05-20, 4 and 5 on 2003-12-31, 6, 7 and
8 on 2004-09-21, and 9 on 2013-05-20.

### The test package

`files/mynos-test.tgz` was the "test package" offered on the "Try it!" page.
It holds a GRUB boot floppy image, a `bochsrc`, a test program (`test.c`,
`vga.c`), a Makefile that builds a boot floppy with the kernel and modules,
and `bytecode`. The README says `bytecode` is the third-party OCaml program
*oclisp* (a small Lisp interpreter), which the MyNOS OCaml VM runs. The files
in it are dated 2002-07 to 2002-11-26. The captures from 2002-12 to 2004-06
have the same size, so they are probably the same file.

The 2002-10-17 capture is an earlier, different version of the package. It
has its own printf implementation instead of dietlibc and a `bochsout.txt`
log. It is kept as `files/mynos-test-2002-10-17.tgz`.

### `news.html` (added, not a page of the site)

The home page lists the project news. The news items themselves were posted on
SourceForge (`http://sourceforge.net/forum/forum.php?forum_id=N`), not on
`mynos.sourceforge.net`. All ten were archived (captures from 2009-03-12 to
2009-03-15). The full SourceForge pages are mostly generic SourceForge layout
and ads, so they were not stored. Instead, the text of each post (author,
date, title and body) was extracted verbatim into `news.html`. The home
page's news links still point to the original SourceForge URLs.

The home page's "Site news archive »" linked SourceForge's list of all the
project's news (`http://sourceforge.net/news/?group_id=35113`): fourteen
items, the ten above and four older ones (2002-01-08 to 2002-10-22). That
list held only titles (captures 2002 to 2009). The four older posts were
never captured, but SourceForge still publishes all fourteen news items
(`https://sourceforge.net/p/mynos/news/`, moved there in 2013). Their
author, title and text were taken on 2026-11-24 from its REST interface
(`https://sourceforge.net/rest/p/mynos/news/YYYY/MM/NAME/`) and their dates
from its feed (`https://sourceforge.net/p/mynos/news/feed.rss?limit=100`,
UTC, as the dates of the other ten), and added to `news.html`. The text
is the feed's rendering: the REST interface gives Markdown, with `\(` for
`(`; one line break, `<br />` in the feed, is written `&nbsp;<br />` as
in the other posts. The home page's link now points to `news.html`.

## Missing or skipped

Not archived (the links stay as absolute original URLs, which no longer work):

- The full-size screenshots `img/snap_initsys.jpg`, `snap_pagefault.jpg`,
  `snap_5processes.jpg`, `snap_fork.jpg`, `snap_vga.jpg`, `snap_ocaml.jpg` and
  `snap_ramdisk.jpg`. Only the thumbnails survive. Screenshot pages 1 to 7
  show a broken image; pages 8 (`snap_sem.png`) and 9 (`snap_serial.jpg`) are
  complete. The live site no longer has them either (HTTP 404 on 2026-11-16).
- `/project/stats/?group_id=35113` (the Wayback Machine has only 404
  captures; it was a broken link on the original site too).

Skipped on purpose:

- `index.php`: the same page as `/`. Its latest capture (2005-04-04) differs
  only in the news formatting and the visitor count. `index.html` uses the
  2009 capture of `/`.
- `statitm_v30a/stat.php?...`, `stat_page.php?...` and `statistik.php`: the
  visitor-counter script (tracking pixels, a few hundred bytes each). Also
  skipped are several `stat.php?...&refer=...gav.sourceforge.net...` URLs,
  which were hits from another project's site.
- `robots.txt`, `favicon.ico`, `document.referrer?escape`,
  `screen.colorDepth==0?...` and `status.ph`: 404 captures, or URLs crawled by
  mistake from the JavaScript.
- `http://www.mynos.sourceforge.net/robots.txt`: 302 redirects only.
- `https://mynos.sourceforge.net/` captures from 2022-2023: the site was still
  online, unchanged. The 2023-06-01 home page is identical to the 2009 one
  except for the visitor counter, which reads 30098 instead of 22664. These
  captures are newer than the reference snapshot, so they were not used. The
  2025-09-03 capture is a 302 redirect.
- External images (SourceForge logo and icons, the OSDev ring image) and the
  SourceForge project pages (tracker, forums, CVS, files, donate). These are
  generic SourceForge content, not the project's.
- No file was larger than 10 MB, so the size limit skipped nothing.
