/*
  MyNOS
  Copyright (C) 2026
  MyNOS team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.
*/

/* The wire format of typed IPC in C: see mynos_wire.h. */

#include <stdlib.h>
#include <string.h>
#include <mynos_wire.h>

void wire_writer_init(wire_writer * w) {
  w->cap = 64;
  w->len = 0;
  w->error = 0;
  w->buf = malloc(w->cap);
  if (w->buf == NULL) { w->cap = 0; w->error = 1; }
}

void wire_writer_free(wire_writer * w) {
  free(w->buf);
  w->buf = NULL;
  w->len = w->cap = 0;
}

static void put(wire_writer * w, const void * p, unsigned int n) {
  if (w->error) return;
  if (w->len + n > w->cap) {
    unsigned int cap = w->cap ? w->cap : 64;
    char * b;
    while (cap < w->len + n) cap *= 2;
    b = realloc(w->buf, cap);
    if (b == NULL) { w->error = 1; return; }
    w->buf = b;
    w->cap = cap;
  }
  memcpy(w->buf + w->len, p, n);
  w->len += n;
}

void wire_put_int(wire_writer * w, long long v) {
  unsigned long long z = ((unsigned long long)v << 1) ^ (unsigned long long)(v >> 63);
  unsigned char c;
  while (z >= 0x80) {
    c = (unsigned char)((z & 0x7F) | 0x80);
    put(w, &c, 1);
    z >>= 7;
  }
  c = (unsigned char)z;
  put(w, &c, 1);
}

void wire_put_bool(wire_writer * w, int b) {
  unsigned char c = b ? 1 : 0;
  put(w, &c, 1);
}

void wire_put_string(wire_writer * w, const void * s, unsigned int len) {
  wire_put_int(w, len);
  put(w, s, len);
}

void wire_put_cstring(wire_writer * w, const char * s) {
  wire_put_string(w, s, strlen(s));
}

void wire_put_float(wire_writer * w, double f) {
  unsigned char b[8];
  unsigned long long u;
  int i;
  memcpy(&u, &f, 8);
  for (i = 0; i < 8; i++) { b[i] = (unsigned char)u; u >>= 8; }
  put(w, b, 8);
}

void wire_reader_init(wire_reader * r, const void * msg, unsigned int len) {
  r->p = msg;
  r->len = len;
  r->pos = 0;
  r->error = 0;
}

static int byte(wire_reader * r) {
  if (r->error || r->pos >= r->len) { r->error = 1; return 0; }
  return r->p[r->pos++];
}

long long wire_get_int(wire_reader * r) {
  unsigned long long z = 0;
  int shift = 0, b;
  do {
    b = byte(r);
    if (r->error) return 0;
    if (shift >= 64 || (shift == 63 && (b & 0x7E))) { r->error = 1; return 0; }
    z |= (unsigned long long)(b & 0x7F) << shift;
    shift += 7;
  } while (b & 0x80);
  return (long long)(z >> 1) ^ -(long long)(z & 1);
}

int wire_get_bool(wire_reader * r) {
  int b = byte(r);
  if (b > 1) { r->error = 1; return 0; }
  return b;
}

const char * wire_get_string(wire_reader * r, unsigned int * len) {
  long long n = wire_get_int(r);
  const char * s;
  if (r->error || n < 0 || n > (long long)(r->len - r->pos)) {
    r->error = 1;
    *len = 0;
    return "";
  }
  s = (const char *)r->p + r->pos;
  r->pos += (unsigned int)n;
  *len = (unsigned int)n;
  return s;
}

void wire_get_cstring(wire_reader * r, char * buf, unsigned int size) {
  unsigned int n;
  const char * s = wire_get_string(r, &n);
  if (r->error || n >= size || memchr(s, 0, n)) {
    r->error = 1;
    if (size) buf[0] = 0;
    return;
  }
  memcpy(buf, s, n);
  buf[n] = 0;
}

double wire_get_float(wire_reader * r) {
  unsigned long long u = 0;
  double f;
  int i;
  if (r->error || r->len - r->pos < 8) { r->error = 1; return 0; }
  for (i = 7; i >= 0; i--) u = (u << 8) | r->p[r->pos + i];
  r->pos += 8;
  memcpy(&f, &u, 8);
  return f;
}

int wire_at_end(const wire_reader * r) {
  return !r->error && r->pos == r->len;
}

int wire_check_protocol(wire_reader * r, const char * id) {
  unsigned int n;
  const char * s = wire_get_string(r, &n);
  if (r->error || n != strlen(id) || memcmp(s, id, n)) return -1;
  return 0;
}

void wire_reply_ok(wire_writer * w) {
  wire_put_int(w, 0);
}

void wire_reply_error(wire_writer * w, const char * message) {
  wire_put_int(w, 1);
  wire_put_cstring(w, message);
}
