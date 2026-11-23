/*
 * The MyNOS surface (mynos-1g0): a window of MyNOS's display service,
 * displayd, protocol display/1 (services/display/displayd.c). The
 * pixels are a shared message: NetSurf draws, a damage request shows
 * them. Events: keys (UTF-8, VT100 sequences), the mouse, the wheel,
 * close, resize.
 *
 * The MyNOS calls are weak: the same libnsfb links on Linux, where this
 * surface fails to start.
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "libnsfb.h"
#include "libnsfb_plot.h"
#include "libnsfb_event.h"

#include "nsfb.h"
#include "surface.h"
#include "plot.h"

#include <mynos.h>
#include <mynos_wire.h>
#include <mynos_registry.h>

#pragma weak mynos_send
#pragma weak mynos_recv
#pragma weak mynos_freeMsg
#pragma weak mynos_freeChannel
#pragma weak mynos_connectToPort
#pragma weak mynos_registryLookUp
#pragma weak wire_writer_init
#pragma weak wire_writer_free
#pragma weak wire_put_int
#pragma weak wire_put_cstring
#pragma weak wire_reader_init
#pragma weak wire_get_int
#pragma weak wire_get_string
#pragma weak mynos_log

#define PROTOCOL "display/1"

static int port = -1;
static int window = -1;
static size_t pixels_size;

/* ---- display/1 ---- */

static void start(wire_writer *w, int kind)
{
    wire_writer_init(w);
    wire_put_cstring(w, PROTOCOL);
    wire_put_int(w, kind);
}

/* send w (and the pixels, if any, shared), the reply in *msg: r reads
   its value. -1 for an error reply or a failed call */
static int request(wire_writer *w, void *pixels, size_t size,
                   wire_reader *r, mynos_msg_t **msg)
{
    int ch = mynos_connectToPort(port), ret = -1;
    if (ch < 0) { wire_writer_free(w); return -1; }
    if (mynos_send(ch, w->buf, w->len, 0) >= 0 &&
        (pixels == NULL || mynos_send(ch, pixels, size, MYNOS_IPC_SHARED) >= 0) &&
        mynos_recv(ch, msg, 0, 0) >= 0) {
        wire_reader_init(r, (*msg)->start, (*msg)->size);
        if (wire_get_int(r) == 0) ret = 0;
        else {
            unsigned int n;
            const char *e = wire_get_string(r, &n);
            fprintf(stderr, "nsfb mynos: display: %.*s\n", (int)n, e ? e : "");
            mynos_freeMsg(msg);
        }
    }
    mynos_freeChannel(ch);
    wire_writer_free(w);
    return ret;
}

static int simple(wire_writer *w)
{
    wire_reader r;
    mynos_msg_t *msg;
    if (request(w, NULL, 0, &r, &msg) < 0) return -1;
    mynos_freeMsg(&msg);
    return 0;
}

static void *new_pixels(int width, int height)
{
    void *p;
    pixels_size = ((size_t)width * height * 4 + 4095) & ~(size_t)4095;
    p = mmap(NULL, pixels_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

/* attach (1st) or resize: the request, then the pixels shared */
static int give_pixels(nsfb_t *nsfb, int resize)
{
    wire_writer w;
    wire_reader r;
    mynos_msg_t *msg;
    void *p = new_pixels(nsfb->width, nsfb->height);
    if (p == NULL) return -1;
    start(&w, resize ? 11 : 2);
    wire_put_int(&w, window);
    if (resize) { wire_put_int(&w, nsfb->width); wire_put_int(&w, nsfb->height); }
    if (request(&w, p, (size_t)nsfb->width * nsfb->height * 4, &r, &msg) < 0) return -1;
    mynos_freeMsg(&msg);
    nsfb->ptr = p;
    nsfb->linelen = nsfb->width * 4;
    return 0;
}

/* ---- events: display/1's, turned into libnsfb's, through a queue ---- */

#define QUEUE 128
static nsfb_event_t queue[QUEUE];
static int qhead, qlen;
static int buttons;

static void push(enum nsfb_event_type_e type, int code)
{
    nsfb_event_t *e;
    if (qlen == QUEUE) return;
    e = &queue[(qhead + qlen++) % QUEUE];
    e->type = type;
    e->value.keycode = code;
}

static void key(int code, int shift, int ctrl)
{
    if (shift) push(NSFB_EVENT_KEY_DOWN, NSFB_KEY_LSHIFT);
    if (ctrl) push(NSFB_EVENT_KEY_DOWN, NSFB_KEY_LCTRL);
    push(NSFB_EVENT_KEY_DOWN, code);
    push(NSFB_EVENT_KEY_UP, code);
    if (ctrl) push(NSFB_EVENT_KEY_UP, NSFB_KEY_LCTRL);
    if (shift) push(NSFB_EVENT_KEY_UP, NSFB_KEY_LSHIFT);
}

/* an ASCII character on a US keyboard (the frontend's keymap) */
static void ascii(int c)
{
    static const char shifted[] = "!@#$%^&*()_+{}|:\"<>?~";
    static const char base[] =    "1234567890-=[]\\;',./`";
    const char *s;
    if (c >= 'A' && c <= 'Z') key(c - 'A' + 'a', 1, 0);
    else if (c >= 1 && c <= 26 && c != 8 && c != 9 && c != 10 && c != 13)
        key('a' + c - 1, 0, 1);                       /* Ctrl-letter */
    else if (c != 0 && (s = strchr(shifted, c)) != NULL) key(base[s - shifted], 1, 0);
    else if (c == '\n' || c == '\r') key(NSFB_KEY_RETURN, 0, 0);
    else if (c == 127 || c == 8) key(NSFB_KEY_BACKSPACE, 0, 0);
    else if (c >= 32 && c < 127) key(c, 0, 0);
    else if (c == 9 || c == 27) key(c, 0, 0);
}

static void keys(const char *s, unsigned int n)
{
    static const struct { const char *seq; int code; } vt[] = {
        { "\033[A", NSFB_KEY_UP }, { "\033[B", NSFB_KEY_DOWN },
        { "\033[C", NSFB_KEY_RIGHT }, { "\033[D", NSFB_KEY_LEFT },
        { "\033[H", NSFB_KEY_HOME }, { "\033[F", NSFB_KEY_END },
        { "\033[1~", NSFB_KEY_HOME }, { "\033[4~", NSFB_KEY_END },
        { "\033[3~", NSFB_KEY_DELETE }, { "\033[5~", NSFB_KEY_PAGEUP },
        { "\033[6~", NSFB_KEY_PAGEDOWN }, { "\033[2~", NSFB_KEY_INSERT } };
    unsigned int i = 0, k;
    while (i < n) {
        int done = 0;
        if (s[i] == 27 && i + 1 < n)
            for (k = 0; k < sizeof vt / sizeof vt[0]; k++) {
                size_t l = strlen(vt[k].seq);
                if (i + l <= n && memcmp(s + i, vt[k].seq, l) == 0) {
                    key(vt[k].code, 0, 0); i += l; done = 1; break;
                }
            }
        if (!done) {
            unsigned char c = (unsigned char)s[i];
            if (c < 128) ascii(c);          /* other UTF-8: not on the keymap */
            i++;
        }
    }
}

static void mouse(int x, int y, int b)
{
    static const struct { int bit, code; } map[] = {
        { 1, NSFB_KEY_MOUSE_1 }, { 4, NSFB_KEY_MOUSE_2 }, { 2, NSFB_KEY_MOUSE_3 } };
    unsigned int i;
    nsfb_event_t *e;
    if (qlen < QUEUE) {
        e = &queue[(qhead + qlen++) % QUEUE];
        e->type = NSFB_EVENT_MOVE_ABSOLUTE;
        e->value.vector.x = x; e->value.vector.y = y; e->value.vector.z = 0;
    }
    for (i = 0; i < 3; i++)
        if ((b ^ buttons) & map[i].bit)
            push(b & map[i].bit ? NSFB_EVENT_KEY_DOWN : NSFB_EVENT_KEY_UP, map[i].code);
    buttons = b;
}

/* the next display/1 event into the queue; false: none in time */
static bool fetch(int timeout_ms, nsfb_t *nsfb)
{
    wire_writer w;
    wire_reader r;
    mynos_msg_t *msg;
    long long kind;
    start(&w, 4);
    wire_put_int(&w, window);
    wire_put_int(&w, timeout_ms);
    if (request(&w, NULL, 0, &r, &msg) < 0) {
        push(NSFB_EVENT_CONTROL, NSFB_CONTROL_QUIT);
        return true;
    }
    kind = wire_get_int(&r);
    if (getenv("NSFB_DEBUG") != NULL && kind != 3 && mynos_log != NULL)
        mynos_log("nsfb mynos: event %d (%u bytes)\n", (int)kind, msg->size);
    switch (kind) {
    case 0: {                                   /* key */
        unsigned int n;
        const char *s = wire_get_string(&r, &n);
        if (s) keys(s, n);
        break;
    }
    case 1: {                                   /* mouse */
        int x = (int)wire_get_int(&r), y = (int)wire_get_int(&r);
        mouse(x, y, (int)wire_get_int(&r));
        break;
    }
    case 2:                                     /* close */
        push(NSFB_EVENT_CONTROL, NSFB_CONTROL_QUIT);
        break;
    case 5: {                                   /* wheel: notches, down positive */
        int n = (int)wire_get_int(&r), code = n > 0 ? NSFB_KEY_MOUSE_5 : NSFB_KEY_MOUSE_4;
        if (n < 0) n = -n;
        if (n > 8) n = 8;
        while (n-- > 0) { push(NSFB_EVENT_KEY_DOWN, code); push(NSFB_EVENT_KEY_UP, code); }
        break;
    }
    case 7: {                                   /* resize: the size asked for */
        int width = (int)wire_get_int(&r), height = (int)wire_get_int(&r);
        if (qlen < QUEUE) {
            nsfb_event_t *e = &queue[(qhead + qlen++) % QUEUE];
            e->type = NSFB_EVENT_RESIZE;
            e->value.resize.w = width;
            e->value.resize.h = height;
        }
        break;
    }
    default:                                    /* tick (none in time), focus, key_up */
        break;
    }
    (void)nsfb;
    mynos_freeMsg(&msg);
    return kind != 3;
}

/* ---- the surface ---- */

static int mynos_defaults(nsfb_t *nsfb)
{
    nsfb->width = 800;
    nsfb->height = 600;
    nsfb->format = NSFB_FMT_ABGR8888;      /* in memory B G R A: 0xAARRGGBB */
    select_plotters(nsfb);
    return 0;
}

static int mynos_initialise(nsfb_t *nsfb)
{
    wire_writer w;
    wire_reader r;
    mynos_msg_t *msg;
    const char *title = getenv("NSFB_TITLE");
    if (mynos_connectToPort == NULL) {
        fprintf(stderr, "nsfb mynos: not MyNOS\n");
        return -1;
    }
    port = mynos_registryLookUp("display");
    if (port < 0) {
        fprintf(stderr, "nsfb mynos: no display service\n");
        return -1;
    }
    start(&w, 1);                                /* create */
    wire_put_cstring(&w, title ? title : "NetSurf");
    wire_put_int(&w, nsfb->width);
    wire_put_int(&w, nsfb->height);
    if (request(&w, NULL, 0, &r, &msg) < 0) return -1;
    window = (int)wire_get_int(&r);
    mynos_freeMsg(&msg);
    if (give_pixels(nsfb, 0) < 0) return -1;
    start(&w, 12);                               /* resizable */
    wire_put_int(&w, window);
    wire_put_int(&w, 320);
    wire_put_int(&w, 240);
    simple(&w);
    return 0;
}

static int mynos_finalise(nsfb_t *nsfb)
{
    wire_writer w;
    if (window >= 0) {
        start(&w, 5);                            /* destroy */
        wire_put_int(&w, window);
        simple(&w);
        window = -1;
    }
    if (nsfb->ptr) munmap(nsfb->ptr, pixels_size);
    nsfb->ptr = NULL;
    return 0;
}

static int mynos_geometry(nsfb_t *nsfb, int width, int height, enum nsfb_format_e format)
{
    void *old = nsfb->ptr;
    size_t old_size = pixels_size;
    if (width > 0) nsfb->width = width;
    if (height > 0) nsfb->height = height;
    if (format != NSFB_FMT_ANY) nsfb->format = format;
    select_plotters(nsfb);
    if (window >= 0 && old != NULL) {            /* a window already: new pixels */
        if (give_pixels(nsfb, 1) < 0) return -1;
        munmap(old, old_size);
    }
    nsfb->linelen = nsfb->width * 4;
    return 0;
}

static bool mynos_input(nsfb_t *nsfb, nsfb_event_t *event, int timeout)
{
    /* nsfb: -1 waits for ever, 0 not at all; display/1: 0 for ever,
       negative not at all */
    if (qlen == 0 && window >= 0)
        fetch(timeout < 0 ? 0 : timeout == 0 ? -1 : timeout, nsfb);
    if (qlen == 0) return false;
    *event = queue[qhead];
    qhead = (qhead + 1) % QUEUE;
    qlen--;
    return true;
}

static int mynos_update(nsfb_t *nsfb, nsfb_bbox_t *box)
{
    wire_writer w;
    int x0 = box->x0 < 0 ? 0 : box->x0, y0 = box->y0 < 0 ? 0 : box->y0;
    int x1 = box->x1 > nsfb->width ? nsfb->width : box->x1;
    int y1 = box->y1 > nsfb->height ? nsfb->height : box->y1;
    if (window < 0 || x1 <= x0 || y1 <= y0) return 0;
    start(&w, 3);                                /* damage */
    wire_put_int(&w, window);
    wire_put_int(&w, x0);
    wire_put_int(&w, y0);
    wire_put_int(&w, x1 - x0);
    wire_put_int(&w, y1 - y0);
    return simple(&w);
}

const nsfb_surface_rtns_t mynos_rtns = {
    .defaults = mynos_defaults,
    .initialise = mynos_initialise,
    .finalise = mynos_finalise,
    .input = mynos_input,
    .geometry = mynos_geometry,
    .update = mynos_update,
};

NSFB_SURFACE_DEF(mynos, NSFB_SURFACE_MYNOS, &mynos_rtns)
