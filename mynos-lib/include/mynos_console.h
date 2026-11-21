/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* console/1, the protocol of the consoles: consoled (services/console,
   the text console) and each terminal window's console service
   (gui/terminal.ml, named by MYNOS_CONSOLE). Programs use them through
   libmynos (fds 0-2, termios, Ctrl-C); OCaml programs can speak it typed
   (module Console, mynos-lib/ocaml/console.mli, which defines it).

   Typed IPC (mynos_wire.h): a request is "console/1", its case and its
   arguments; the reply Ok and the value, or Error and a message. The
   client is the process at the other end of the channel (channelPeer): a
   raw mode belongs to it. */

#ifndef __MYNOS_CONSOLE_H__
#define __MYNOS_CONSOLE_H__

#define CONSOLE_SERVICE "console"
#define CONSOLE_PROTOCOL "console/1"

#define CONSOLE_READ       0 /* (max:I) -> S: up to max bytes of input ("":
                                end of file, or a VTIME timeout)           */
#define CONSOLE_MODE       1 /* (mode:I,vmin:I,vtime:I) -> U               */
#define CONSOLE_KEYMAP     2 /* (layout:I): a CONSOLE_LAYOUT_*, or -1 -> I:
                                the layout in use                          */
#define CONSOLE_WRITE      3 /* (data:S) -> U: output, to a terminal's
                                console service (MYNOS_CONSOLE)            */
#define CONSOLE_FOREGROUND 4 /* (pid:I): a program the caller started and
                                waits for (0: none) -> U. Ctrl-C ends it
                                (an interrupt), unless the mode has
                                CONSOLE_NOSIG                              */
#define CONSOLE_LAYOUT_US 0
#define CONSOLE_LAYOUT_IT 1

/* mode bits (as termios ICANON and ECHO, which libmynos translates) */
#define CONSOLE_CANON 1  /* line editing: input comes by whole lines */
#define CONSOLE_ECHO  2  /* typed characters are shown */
#define CONSOLE_NOSIG 4  /* Ctrl-C is a character, not an interrupt (termios
                            without ISIG: editors) */
#define CONSOLE_RELEASES 8 /* raw mode: key releases too, after the keys,
                            as kitty's keyboard protocol reports them:
                            ESC [ code ; 1:3 u for a character (code: the
                            Unicode code point its press sent: 13 Enter,
                            127 Backspace, 27 Escape), ESC [ 1 ; 1:3 A..D,
                            H, F for the arrows, Home, End, ESC [ n ; 1:3 ~
                            for the keys sent as ESC [ n ~ (displayd) */

/* the screen (the kernel's terminal, VT100-like) */
#define CONSOLE_ROWS 25
#define CONSOLE_COLS 80

#endif
