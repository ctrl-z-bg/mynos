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

#define CONSOLE_READ 1

/* request; the reply is up to len bytes of input, 0 bytes at end of file */
struct console_req {
  int op;
  int len;
};

#endif
