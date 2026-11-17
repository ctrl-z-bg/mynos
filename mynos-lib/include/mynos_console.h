/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* Protocol of the console service (services/console/consoled.c). */

#ifndef __MYNOS_CONSOLE_H__
#define __MYNOS_CONSOLE_H__

#define CONSOLE_SERVICE "console"

#define CONSOLE_READ 1   /* len: max bytes -> up to len bytes of input
                            (0 bytes: end of file, or a VTIME timeout) */
#define CONSOLE_MODE 2   /* mode, vmin, vtime -> 0 bytes */
#define CONSOLE_KEYMAP 3 /* mode: a layout (CONSOLE_LAYOUT_*), or -1 -> one
                            byte, the layout in use */
#define CONSOLE_WRITE 4  /* len bytes after the request -> 0 bytes: output, to
                            a terminal's console service (MYNOS_CONSOLE) */
#define CONSOLE_LAYOUT_US 0
#define CONSOLE_LAYOUT_IT 1

/* mode bits (as termios ICANON and ECHO, which libmynos translates) */
#define CONSOLE_CANON 1  /* line editing: input comes by whole lines */
#define CONSOLE_ECHO  2  /* typed characters are shown */

/* the screen (the kernel's terminal, VT100-like) */
#define CONSOLE_ROWS 25
#define CONSOLE_COLS 80

struct console_req {
  int op;
  int len;
  int pid;               /* the client: a raw mode belongs to its process */
  int mode;
  int vmin;              /* raw mode: as termios VMIN and VTIME (tenths of */
  int vtime;             /* a second); VMIN 0 with VTIME > 0 may return 0 */
};

#endif
