/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/*
 * The wire format of typed IPC, for C services and clients (the OCaml side
 * is module Wire, mynos-lib/ocaml/wire.mli, which describes the format;
 * doc/decisions/typed-ipc.md).
 *
 *   int     zigzag, then LEB128
 *   bool    one byte, 0 or 1
 *   string  its length (an int), then its bytes
 *   float   IEEE 754 double, 8 bytes little endian
 *   option  a bool, then the value if present
 *   list    the count (an int), then the elements
 *   variant the case number (an int), then the case's value
 *
 * A request is the protocol id (a string) then the request; a reply is
 * case 0 then the value, or case 1 then an error message (a string).
 *
 * Reading never fails loudly: a malformed message sets r->error, and the
 * getters then return 0 or empty values. Check r->error at the end.
 */

#ifndef __MYNOS_WIRE_H__
#define __MYNOS_WIRE_H__

typedef struct {
  char * buf;
  unsigned int len, cap;
  int error;                 /* out of memory */
} wire_writer;

typedef struct {
  const unsigned char * p;
  unsigned int len, pos;
  int error;                 /* malformed message */
} wire_reader;

/* writing (the buffer is malloc'd: wire_writer_free) */
void wire_writer_init(wire_writer * w);
void wire_writer_free(wire_writer * w);
void wire_put_int(wire_writer * w, long long v);
void wire_put_bool(wire_writer * w, int b);
void wire_put_string(wire_writer * w, const void * s, unsigned int len);
void wire_put_cstring(wire_writer * w, const char * s);
void wire_put_float(wire_writer * w, double f);

/* reading */
void wire_reader_init(wire_reader * r, const void * msg, unsigned int len);
long long wire_get_int(wire_reader * r);
int wire_get_bool(wire_reader * r);
/* a string: a pointer into the message (not 0-terminated) and its length */
const char * wire_get_string(wire_reader * r, unsigned int * len);
/* a string copied into buf with its final 0; an error if it does not fit
   or contains a 0 */
void wire_get_cstring(wire_reader * r, char * buf, unsigned int size);
double wire_get_float(wire_reader * r);
int wire_at_end(const wire_reader * r);

/* typed IPC */
/* read the protocol id of a request: 0 if it is id */
int wire_check_protocol(wire_reader * r, const char * id);
/* start a reply: Ok (then write the value), or a whole Error reply */
void wire_reply_ok(wire_writer * w);
void wire_reply_error(wire_writer * w, const char * message);

/* Descriptions (Ipc.describe, doc/decisions/llm.md): a request whose
   protocol id is "describe" asks a service for its protocol. */
#define WIRE_DESCRIBE "describe"

/* a shape (Wire.shape), written from a compact notation:
     U B I F S          unit, bool, int, float, string
     O<x> L<x>          an option, a list of x
     (x,y,...)          a tuple
     name:x             a named component (Wire.field)
   e.g. "(socket:I,max:I)". Returns -1 on a malformed notation. */
int wire_put_shape(wire_writer * w, const char * notation);

/* a request of a description, then the description's reply: Ok, the
   protocol, its summary and its requests */
typedef struct {
  int safe;
  const char * name, * args, * reply, * doc;  /* args, reply: shapes */
} wire_request_doc;
void wire_reply_description(wire_writer * w, const char * protocol,
                            const char * summary,
                            const wire_request_doc * requests, int n);

#endif
