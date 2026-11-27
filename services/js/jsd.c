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
 * jsd: the JavaScript service (registered as "js", protocol js/1, module
 * Js on the OCaml side; doc/decisions/browser.md, M6), QuickJS-ng
 * (third_party/quickjs-ng). A program makes a context (a page's), runs
 * code in it, and gets the value or the exception, and what console
 * printed. Each context is a runtime of its own: its memory limited, its
 * stack limited, a run stopped after RUN_MS. In C, a process of its own:
 * a page's scripts are untrusted, and a fault here does not take the
 * browser down. The DOM comes next: handles to the browser's nodes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mynos.h>
#include <mynos_wire.h>
#include "../../third_party/quickjs-ng/quickjs.h"

#define SERVICE  "js"
#define PROTOCOL "js/1"
#define MAXCTX 32
#define MEMORY (64 * 1024 * 1024)       /* a context's heap */
#define STACK (256 * 1024)               /* JavaScript's recursion */
#define RUN_MS 5000                      /* a run's time, then an exception */
#define CONSOLE_MAX (256 * 1024)         /* what console keeps of a run */

struct context {
  int used, id, owner;
  JSRuntime * rt;
  JSContext * cx;
  char * out;                            /* console's text in this run */
  size_t out_len, out_cap;
  long deadline;                         /* ms, while running */
  char dom[64];                          /* the DOM's service (the browser's), or "" */
};

static struct context ctxs[MAXCTX];
static int next_id = 1;

static long now_ms(void)
{
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* ---- replies ---- */

static void send_reply(int ch, wire_writer * w)
{
  if (w->error) {
    wire_writer_free(w);
    wire_writer_init(w);
    wire_reply_error(w, "jsd: out of memory");
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

static void reply_unit(int ch)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  send_reply(ch, &w);
}

/* ---- console ---- */

static void out_add(struct context * c, const char * s, size_t n)
{
  if (c->out_len + n > CONSOLE_MAX) n = CONSOLE_MAX > c->out_len ? CONSOLE_MAX - c->out_len : 0;
  if (n == 0) return;
  if (c->out_len + n + 1 > c->out_cap) {
    size_t cap = (c->out_len + n + 1) * 2;
    char * b = realloc(c->out, cap);
    if (!b) return;
    c->out = b; c->out_cap = cap;
  }
  memcpy(c->out + c->out_len, s, n);
  c->out_len += n;
}

/* console.log, .info, .warn, .error, .debug: the arguments as strings,
   separated by spaces, a line each call (warn and error marked) */
static JSValue console_print(JSContext * cx, JSValueConst this, int argc, JSValueConst * argv, int magic)
{
  struct context * c = JS_GetContextOpaque(cx);
  int i;
  (void)this;
  if (magic == 1) out_add(c, "warning: ", 9);
  if (magic == 2) out_add(c, "error: ", 7);
  for (i = 0; i < argc; i++) {
    size_t n;
    const char * s = JS_ToCStringLen(cx, &n, argv[i]);
    if (i > 0) out_add(c, " ", 1);
    if (s) { out_add(c, s, n); JS_FreeCString(cx, s); }
    else { JS_FreeValue(cx, JS_GetException(cx)); out_add(c, "?", 1); }
  }
  out_add(c, "\n", 1);
  return JS_UNDEFINED;
}

static int interrupt(JSContext * cx, void * opaque)
{
  struct context * c = opaque;
  (void)cx;
  return c->deadline > 0 && now_ms() > c->deadline;
}

/* __dom(op, ...args): the DOM's operation [op], at the browser's service
   (protocol dom/1: one request, call (op:S, args:L<S>) -> L<S>); the
   answer as an array of strings, an error thrown. The arguments are made
   strings; the DOM's API over it is JavaScript (Ariadne's prelude) */
#define DOM_PROTOCOL "dom/1"
#define DOM_WAIT_MS 30000                /* a fetch through the DOM's service may take a while */

static JSValue dom_call(JSContext * cx, JSValueConst this, int argc, JSValueConst * argv)
{
  struct context * c = JS_GetContextOpaque(cx);
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  int port, ch, i;
  (void)this;
  if (c->dom[0] == 0) return JS_ThrowReferenceError(cx, "no DOM in this context");
  if (argc < 1) return JS_ThrowTypeError(cx, "__dom: no operation");
  wire_writer_init(&w);
  wire_put_cstring(&w, DOM_PROTOCOL);
  wire_put_int(&w, 0);
  for (i = 0; i < argc; i++) {
    size_t n;
    const char * s = JS_ToCStringLen(cx, &n, argv[i]);
    if (!s) { wire_writer_free(&w); return JS_EXCEPTION; }
    if (i == 1) wire_put_int(&w, argc - 1);          /* the arguments: a list */
    wire_put_string(&w, s, (unsigned int)n);
    JS_FreeCString(cx, s);
  }
  if (argc == 1) wire_put_int(&w, 0);
  /* the time waited for the browser does not count against the run's */
  long t0 = now_ms();
  port = mynos_registryLookUp(c->dom);
  if (w.error || port < 0 || (ch = mynos_connectToPort(port)) < 0) {
    wire_writer_free(&w);
    return JS_ThrowInternalError(cx, "the DOM's service is not there");
  }
  mynos_send(ch, w.buf, w.len, 0);
  wire_writer_free(&w);
  if (mynos_recv(ch, &msg, 0, DOM_WAIT_MS) < 0) {
    mynos_freeChannel(ch);
    return JS_ThrowInternalError(cx, "the DOM's service did not answer");
  }
  mynos_freeChannel(ch);
  if (c->deadline > 0) c->deadline += now_ms() - t0;
  wire_reader_init(&r, msg->start, msg->size);
  if (wire_get_int(&r) != 0) {
    unsigned int n;
    const char * m = wire_get_string(&r, &n);
    JSValue e = r.error ? JS_ThrowPlainError(cx, "the DOM's service failed")
                        : JS_ThrowPlainError(cx, "%.*s", (int)n, m);
    mynos_freeMsg(&msg);
    return e;
  } else {
    long long count = wire_get_int(&r), k;
    JSValue arr = JS_NewArray(cx);
    for (k = 0; k < count && !r.error; k++) {
      unsigned int n;
      const char * s = wire_get_string(&r, &n);
      if (r.error) break;
      JS_SetPropertyUint32(cx, arr, (uint32_t)k, JS_NewStringLen(cx, s, n));
    }
    mynos_freeMsg(&msg);
    return arr;
  }
}

static int new_context(int owner, const char * dom, unsigned int dom_len)
{
  int i;
  struct context * c;
  JSValue global, console;
  for (i = 0; i < MAXCTX && ctxs[i].used; i++) ;
  if (i == MAXCTX) return -1;
  c = &ctxs[i];
  memset(c, 0, sizeof *c);
  c->rt = JS_NewRuntime();
  if (!c->rt) return -1;
  JS_SetMemoryLimit(c->rt, MEMORY);
  JS_SetMaxStackSize(c->rt, STACK);
  JS_SetInterruptHandler(c->rt, interrupt, c);
  c->cx = JS_NewContext(c->rt);
  if (!c->cx) { JS_FreeRuntime(c->rt); return -1; }
  JS_SetContextOpaque(c->cx, c);
  global = JS_GetGlobalObject(c->cx);
  console = JS_NewObject(c->cx);
  JS_SetPropertyStr(c->cx, console, "log", JS_NewCFunctionMagic(c->cx, console_print, "log", 1, JS_CFUNC_generic_magic, 0));
  JS_SetPropertyStr(c->cx, console, "info", JS_NewCFunctionMagic(c->cx, console_print, "info", 1, JS_CFUNC_generic_magic, 0));
  JS_SetPropertyStr(c->cx, console, "debug", JS_NewCFunctionMagic(c->cx, console_print, "debug", 1, JS_CFUNC_generic_magic, 0));
  JS_SetPropertyStr(c->cx, console, "warn", JS_NewCFunctionMagic(c->cx, console_print, "warn", 1, JS_CFUNC_generic_magic, 1));
  JS_SetPropertyStr(c->cx, console, "error", JS_NewCFunctionMagic(c->cx, console_print, "error", 1, JS_CFUNC_generic_magic, 2));
  JS_SetPropertyStr(c->cx, global, "console", console);
  if (dom_len > 0 && dom_len < sizeof c->dom) {
    memcpy(c->dom, dom, dom_len);
    c->dom[dom_len] = 0;
    JS_SetPropertyStr(c->cx, global, "__dom", JS_NewCFunction(c->cx, dom_call, "__dom", 1));
  }
  JS_FreeValue(c->cx, global);
  c->used = 1;
  c->id = next_id++;
  c->owner = owner;
  return i;
}

static void free_context(struct context * c)
{
  JS_FreeContext(c->cx);
  JS_FreeRuntime(c->rt);
  free(c->out);
  memset(c, 0, sizeof *c);
}

static struct context * owned(int ch, int id, int caller)
{
  int i;
  for (i = 0; i < MAXCTX; i++)
    if (ctxs[i].used && ctxs[i].id == id) {
      if (ctxs[i].owner != caller) { reply_error(ch, "not your context"); return NULL; }
      return &ctxs[i];
    }
  reply_error(ch, "no such context");
  return NULL;
}

/* a value as text: a string as it is, else JSON if it has a form there,
   else String(value) */
static void put_value(wire_writer * w, JSContext * cx, JSValueConst v)
{
  size_t n;
  const char * s;
  JSValue j = JS_UNDEFINED;
  if (JS_IsObject(v) && !JS_IsFunction(cx, v)) {
    j = JS_JSONStringify(cx, v, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(j)) { JS_FreeValue(cx, JS_GetException(cx)); j = JS_UNDEFINED; }
  }
  s = JS_ToCStringLen(cx, &n, JS_IsString(j) ? j : v);
  if (s) { wire_put_string(w, s, n); JS_FreeCString(cx, s); }
  else { JS_FreeValue(cx, JS_GetException(cx)); wire_put_cstring(w, "?"); }
  JS_FreeValue(cx, j);
}

/* an exception: its text, and its stack if it has one */
static void put_exception(wire_writer * w, JSContext * cx, JSValueConst e)
{
  const char * s = JS_ToCString(cx, e);
  JSValue stack = JS_IsObject(e) ? JS_GetPropertyStr(cx, e, "stack") : JS_UNDEFINED;
  const char * st = JS_IsString(stack) ? JS_ToCString(cx, stack) : NULL;
  char * b;
  size_t n = (s ? strlen(s) : 1) + (st ? strlen(st) + 1 : 0) + 1;
  b = malloc(n);
  if (b) {
    snprintf(b, n, "%s%s%s", s ? s : "?", st && *st ? "\n" : "", st ? st : "");
    wire_put_cstring(w, b);
    free(b);
  } else wire_put_cstring(w, "?");
  if (s) JS_FreeCString(cx, s);
  if (st) JS_FreeCString(cx, st);
  JS_FreeValue(cx, stack);
}

/* the contexts of programs that have ended: freed (checked at most once a
   second, before a request) */
static void owner_checks(void)
{
  static long last = 0;
  int i, j;
  if (now_ms() - last < 1000) return;
  last = now_ms();
  for (i = 0; i < MAXCTX; i++) {
    int owner = ctxs[i].owner, info;
    if (!ctxs[i].used) continue;
    for (j = 0; j < i; j++)
      if (ctxs[j].used && ctxs[j].owner == owner) break;
    if (j < i) continue;
    info = mynos_processInfo(owner);
    if (info >= 0 && (info & MYNOS_PROC_ALIVE)) continue;
    for (j = i; j < MAXCTX; j++)
      if (ctxs[j].used && ctxs[j].owner == owner) free_context(&ctxs[j]);
  }
}

/* ---- requests ---- */

static const wire_request_doc requests[] = {
  { 0, "create", "dom:S", "context:I",
    "A JavaScript context of its own (a page's): its globals, console; its memory and run time limited. "
    "dom: the service (dom/1) its __dom(op, ...args) calls, or \"\": none." },
  { 0, "eval", "(context:I,code:S,name:S)", "(ok:B,value:S,console:S)",
    "Run code (a script; name: its file, for the stack) in the context: whether it ended without an "
    "exception, its value (or the exception, with the stack), and what console printed." },
  { 0, "destroy", "context:I", "U", "Free a context." },
};

static void describe(int ch)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_description(&w, PROTOCOL,
    "JavaScript (jsd, in C: QuickJS-ng): contexts of their own, code run in them, console; "
    "for Ariadne and any program.",
    requests, sizeof requests / sizeof requests[0]);
  send_reply(ch, &w);
}

static void handle(int ch, int caller, const char * msg, unsigned int len)
{
  wire_reader r;
  unsigned int n;
  const char * id;
  int kind;
  struct context * c;

  wire_reader_init(&r, msg, len);
  id = wire_get_string(&r, &n);
  if (!r.error && n == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, n) && wire_at_end(&r)) {
    describe(ch);
    return;
  }
  if (r.error || n != strlen(PROTOCOL) || memcmp(id, PROTOCOL, n)) {
    reply_error(ch, "protocol: jsd speaks " PROTOCOL);
    return;
  }
#define END() if (!wire_at_end(&r) || r.error) { reply_error(ch, "malformed request"); return; }
  kind = wire_get_int(&r);
  switch (kind) {
  case 0: {                                        /* create */
    int i;
    unsigned int dlen;
    const char * dom = wire_get_string(&r, &dlen);
    wire_writer w;
    END();
    if ((i = new_context(caller, dom, dlen)) < 0) { reply_error(ch, "jsd: no more contexts"); return; }
    wire_writer_init(&w);
    wire_reply_ok(&w);
    wire_put_int(&w, ctxs[i].id);
    send_reply(ch, &w);
    break;
  }
  case 1: {                                        /* eval */
    int cid = wire_get_int(&r);
    unsigned int clen, nlen;
    const char * code = wire_get_string(&r, &clen);
    const char * name = wire_get_string(&r, &nlen);
    char * src, fname[128];
    JSValue v;
    wire_writer w;
    END();
    if (!(c = owned(ch, cid, caller))) return;
    /* JS_Eval wants the source ended by a 0 */
    src = malloc(clen + 1);
    if (!src) { reply_error(ch, "jsd: out of memory"); return; }
    memcpy(src, code, clen);
    src[clen] = 0;
    if (nlen >= sizeof fname) nlen = sizeof fname - 1;
    memcpy(fname, name, nlen);
    fname[nlen] = 0;
    c->out_len = 0;
    c->deadline = now_ms() + RUN_MS;
    v = JS_Eval(c->cx, src, clen, nlen ? fname : "<eval>", JS_EVAL_TYPE_GLOBAL);
    /* then the jobs it queued: promises' callbacks, async functions (their
       exceptions go to the console) */
    {
      JSContext * jc;
      int k;
      while ((k = JS_ExecutePendingJob(c->rt, &jc)) != 0) {
        if (k < 0) {
          JSValue e = JS_GetException(jc);
          const char * m = JS_ToCString(jc, e);
          out_add(c, "error: (in a promise) ", 22);
          if (m) { out_add(c, m, strlen(m)); JS_FreeCString(jc, m); }
          out_add(c, "\n", 1);
          JS_FreeValue(jc, e);
        }
      }
    }
    c->deadline = 0;
    free(src);
    wire_writer_init(&w);
    wire_reply_ok(&w);
    if (JS_IsException(v)) {
      JSValue e = JS_GetException(c->cx);
      wire_put_bool(&w, 0);
      put_exception(&w, c->cx, e);
      JS_FreeValue(c->cx, e);
    } else {
      wire_put_bool(&w, 1);
      put_value(&w, c->cx, v);
    }
    JS_FreeValue(c->cx, v);
    wire_put_string(&w, c->out ? c->out : "", (unsigned int)c->out_len);
    send_reply(ch, &w);
    break;
  }
  case 2: {                                        /* destroy */
    int cid = wire_get_int(&r);
    END();
    if (!(c = owned(ch, cid, caller))) return;
    free_context(c);
    reply_unit(ch);
    break;
  }
  default:
    reply_error(ch, "unknown request");
  }
}

int main(void)
{
  int port = mynos_registryRegister(SERVICE);
  if (port < 0) {
    mynos_log("jsd: cannot register (%d)\n", port);
    return 1;
  }
  mynos_log("jsd: QuickJS-ng %s, service %s\n", JS_GetVersion(), SERVICE);
  for (;;) {
    mynos_msg_t * m;
    int caller;
    int ch = mynos_listenPort(port);
    if (ch < 0) continue;
    if (mynos_recv(ch, &m, 0, 5000) < 0) { mynos_freeChannel(ch); continue; }
    caller = mynos_channelPeer(ch);
    owner_checks();
    handle(ch, caller, m->start, m->size);
    mynos_freeMsg(&m);
  }
  return 0;
}
