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

/* ---- descriptions ---- */

/* the case numbers of Wire.shape_codec */
enum { SH_UNIT, SH_BOOL, SH_INT, SH_FLOAT, SH_STRING, SH_OPTION, SH_LIST,
       SH_TUPLE, SH_NAMED, SH_VARIANT, SH_REC, SH_VAR };

static int is_name_char(char c) {
  return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
}

/* the shape at *p; *p moves past it */
static int put_shape(wire_writer * w, const char ** p) {
  const char * s = *p;
  const char * q = s;
  while (is_name_char(*q)) q++;
  if (q > s && *q == ':') {                  /* name:x */
    wire_put_int(w, SH_NAMED);
    wire_put_string(w, s, q - s);
    *p = q + 1;
    return put_shape(w, p);
  }
  switch (*s) {
  case 'U': *p = s + 1; wire_put_int(w, SH_UNIT); return 0;
  case 'B': *p = s + 1; wire_put_int(w, SH_BOOL); return 0;
  case 'I': *p = s + 1; wire_put_int(w, SH_INT); return 0;
  case 'F': *p = s + 1; wire_put_int(w, SH_FLOAT); return 0;
  case 'S': *p = s + 1; wire_put_int(w, SH_STRING); return 0;
  case 'O': case 'L':
    if (s[1] != '<') return -1;
    wire_put_int(w, *s == 'O' ? SH_OPTION : SH_LIST);
    *p = s + 2;
    if (put_shape(w, p) < 0 || **p != '>') return -1;
    (*p)++;
    return 0;
  case 'V': {                         /* V(0:name=x,1:other=y) */
    int n = 1, depth = 0;
    const char * c;
    if (s[1] != '(') return -1;
    for (c = s + 2; *c && !(depth == 0 && *c == ')'); c++) {
      if (*c == '(' || *c == '<') depth++;
      else if (*c == ')' || *c == '>') depth--;
      else if (*c == ',' && depth == 0) n++;
    }
    if (*c != ')') return -1;
    wire_put_int(w, SH_VARIANT);
    wire_put_int(w, n);
    *p = s + 2;
    while (n-- > 0) {
      int k = 0;
      const char * name;
      while (**p >= '0' && **p <= '9') k = k * 10 + (*(*p)++ - '0');
      if (**p != ':') return -1;
      name = ++*p;
      while (is_name_char(**p)) (*p)++;
      if (**p != '=') return -1;
      wire_put_int(w, k);
      wire_put_string(w, name, *p - name);
      (*p)++;
      if (put_shape(w, p) < 0) return -1;
      if (**p == ',') (*p)++;
    }
    if (**p != ')') return -1;
    (*p)++;
    return 0;
  }
  case '(': {
    /* the components at this depth, counted first */
    int n = 1, depth = 0;
    const char * c;
    for (c = s + 1; *c && !(depth == 0 && *c == ')'); c++) {
      if (*c == '(' || *c == '<') depth++;
      else if (*c == ')' || *c == '>') depth--;
      else if (*c == ',' && depth == 0) n++;
    }
    if (*c != ')') return -1;
    wire_put_int(w, SH_TUPLE);
    wire_put_int(w, n);
    *p = s + 1;
    while (n-- > 0) {
      if (put_shape(w, p) < 0) return -1;
      if (**p == ',') (*p)++;
    }
    if (**p != ')') return -1;
    (*p)++;
    return 0;
  }
  default: return -1;
  }
}

int wire_put_shape(wire_writer * w, const char * notation) {
  const char * p = notation;
  if (put_shape(w, &p) < 0 || *p) return -1;
  return 0;
}

void wire_reply_description(wire_writer * w, const char * protocol,
                            const char * summary,
                            const wire_request_doc * requests, int n) {
  int i;
  wire_reply_ok(w);
  wire_put_cstring(w, protocol);
  wire_put_cstring(w, summary);
  wire_put_int(w, n);
  for (i = 0; i < n; i++) {
    wire_put_int(w, i);                    /* the case: the index */
    wire_put_cstring(w, requests[i].name);
    wire_put_cstring(w, requests[i].doc);
    wire_put_shape(w, requests[i].args);
    wire_put_shape(w, requests[i].reply);
    wire_put_bool(w, requests[i].safe);
  }
}

