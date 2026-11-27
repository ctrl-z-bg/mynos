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
 * imaged: the picture service (registered as "image", protocol image/1,
 * module Images on the OCaml side; doc/decisions/browser.md, M4). A
 * program sends a picture's bytes and the size it wants; imaged decodes it
 * (picture.c: stb_image, NanoSVG) and answers its own size and the pixels,
 * which travel in the reply's pages. In C, a process of its own: a
 * picture from the web is untrusted data, and decoding it here keeps a
 * bad one away from the browser, on another processor.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mynos.h>
#include <mynos_wire.h>
#include "picture.h"

#define SERVICE  "image"
#define PROTOCOL "image/1"

static void send_reply(int ch, wire_writer * w)
{
  if (w->error) {
    wire_writer_free(w);
    wire_writer_init(w);
    wire_reply_error(w, "imaged: out of memory");
  }
  mynos_send(ch, w->buf, w->len, 0);
  mynos_freeChannel(ch);
  wire_writer_free(w);
}

static void reply_error(int ch, const char * m)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_error(&w, m);
  send_reply(ch, &w);
}

static const wire_request_doc requests[] = {
  { 1, "decode", "(data:S,width:I,height:I)",
    "((natural_width:I,natural_height:I),(width:I,height:I,pixels:S))",
    "A picture (JPEG, PNG, GIF, BMP, SVG) decoded at width x height (0 x 0: its own size; an SVG "
    "drawn at it): its own size, and the pixels, 4 bytes each (blue, green, red, alpha)." },
  { 1, "size", "data:S", "(width:I,height:I)",
    "A picture's own size, without decoding it." },
};

static void describe(int ch)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_description(&w, PROTOCOL,
    "Pictures (imaged, in C, with stb_image and NanoSVG): JPEG, PNG, GIF, BMP and SVG decoded "
    "and scaled, for Ariadne and any program.",
    requests, sizeof requests / sizeof requests[0]);
  send_reply(ch, &w);
}

static void handle(int ch, const char * msg, unsigned int len)
{
  wire_reader r;
  unsigned int n, dlen;
  const char * id, * data, * err = "";
  int kind, w, h;
  struct picture p;
  wire_writer o;

  wire_reader_init(&r, msg, len);
  id = wire_get_string(&r, &n);
  if (!r.error && n == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, n) && wire_at_end(&r)) {
    describe(ch);
    return;
  }
  if (r.error || n != strlen(PROTOCOL) || memcmp(id, PROTOCOL, n)) {
    reply_error(ch, "protocol: imaged speaks " PROTOCOL);
    return;
  }
  kind = wire_get_int(&r);
  if (kind == 1) {
    data = wire_get_string(&r, &dlen);
    if (!wire_at_end(&r) || r.error) { reply_error(ch, "malformed request"); return; }
    if (picture_size((const unsigned char *)data, (int)dlen, &w, &h, &err) < 0) { reply_error(ch, err); return; }
    wire_writer_init(&o);
    wire_reply_ok(&o);
    wire_put_int(&o, w);
    wire_put_int(&o, h);
    send_reply(ch, &o);
    return;
  }
  if (kind != 0) { reply_error(ch, "imaged: unknown request"); return; }
  data = wire_get_string(&r, &dlen);
  w = wire_get_int(&r);
  h = wire_get_int(&r);
  if (!wire_at_end(&r) || r.error) { reply_error(ch, "malformed request"); return; }
  if (picture_decode((const unsigned char *)data, (int)dlen, w, h, &p, &err) < 0) {
    reply_error(ch, err);
    return;
  }
  wire_writer_init(&o);
  wire_reply_ok(&o);
  wire_put_int(&o, p.natural_width);
  wire_put_int(&o, p.natural_height);
  wire_put_int(&o, p.width);
  wire_put_int(&o, p.height);
  wire_put_string(&o, p.pixels, (unsigned int)p.width * p.height * 4);
  free(p.pixels);
  send_reply(ch, &o);
}

int main(void)
{
  int port = mynos_registryRegister(SERVICE);
  if (port < 0) {
    mynos_log("imaged: cannot register (%d)\n", port);
    return 1;
  }
  mynos_log("imaged: JPEG, PNG, GIF, BMP, SVG; service %s\n", SERVICE);
  for (;;) {
    mynos_msg_t * m;
    int ch = mynos_listenPort(port);
    if (ch < 0) continue;
    if (mynos_recv(ch, &m, 0, 5000) < 0) { mynos_freeChannel(ch); continue; }
    handle(ch, m->start, m->size);
    mynos_freeMsg(&m);
  }
  return 0;
}
