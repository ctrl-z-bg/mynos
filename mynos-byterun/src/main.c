/***********************************************************************/
/*                                                                     */
/*                           Objective Caml                            */
/*                                                                     */
/*         Xavier Leroy and Damien Doligez, INRIA Rocquencourt         */
/*                                                                     */
/*  Copyright 1996 Institut National de Recherche en Informatique et   */
/*  en Automatique.  All rights reserved.  This file is distributed    */
/*  under the terms of the GNU Library General Public License, with    */
/*  the special exception on linking described in file ../LICENSE.     */
/*                                                                     */
/***********************************************************************/

/* $Id$ */

/* Main entry point (can be overridden by a user-provided main()
   function that calls caml_main() later). */

#ifndef MYNOS
#define MYNOS
#endif

#ifdef MYNOS
#include <mynos.h>

char *getenv(const char *name) {
  return (char*)0;
}
#endif

#include "misc.h"
#include "mlvalues.h"
#include "sys.h"

CAMLextern void caml_main (char **);

#ifdef _WIN32
CAMLextern void expand_command_line (int *, char ***);
#endif

#if macintosh
#include "rotatecursor.h"
#include "signals.h"
#endif

int main(int argc, char **argv)
{
#ifdef MYNOS
  char *_argv[3];
  _argv[0] = "test";
  _argv[1] = "mynos_bytecode";
  _argv[2] = (char*)NULL;
  argc = 2;
  argv = _argv;
#endif //MYNOS
#ifdef _WIN32
  /* Expand wildcards and diversions in command line */
  expand_command_line(&argc, &argv);
#endif
#if macintosh
  rotatecursor_options (&something_to_do, 0, NULL);
#endif /* macintosh */
  caml_main(argv);
  sys_exit(Val_int(0));
  return 0; /* not reached */
}
