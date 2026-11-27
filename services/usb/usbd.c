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
 * usbd: the USB (btq.8.2, btq.8.3), through an xHCI controller found on
 * PCI: QEMU's qemu-xhci on virt and the PC, a Raspberry Pi 4's or 400's
 * VL805 (behind the PCIe the kernel brings up: arch/aarch64/pcie4.c).
 *
 * The controller (xHCI 1.x, its chapter 4): reset, its slots, the
 * device context base array, the command ring, one event ring
 * (interrupter 0), scratchpad pages if it asks for them; then each root
 * port with something connected: reset (a USB 2 port), a slot, the
 * device addressed, its descriptors read (control transfers on endpoint
 * 0), and, for a keyboard or a mouse that speaks the boot protocol (HID,
 * subclass 1), its configuration set, the boot protocol chosen, its
 * interrupt endpoint configured and read. A USB 2 hub (btq.8.5: a Pi 4's
 * and 400's USB 2 devices all sit behind the VL805's own hub, the 400's
 * keyboard too) is configured, its ports powered and reset, and each
 * device on them attached the same way, reached by its route string; a
 * low- or full-speed one behind a high-speed hub through that hub's
 * transaction translator.
 *
 * A keyboard's reports (8 bytes: modifiers, six keys held) become a PC
 * keyboard's scan codes (set 1) for consoled's "keys" service: what was
 * pressed, what was let go, and a held key repeated (500 ms, then 30 a
 * second: a USB keyboard does not repeat by itself). A mouse's (buttons,
 * motion, the wheel) go to displayd's "pointer" service.
 *
 * One thread, polling the event ring every 5 ms. Rings and contexts are
 * DMA memory; their bytes are cleaned out of the processor's caches
 * before the controller reads them and dropped from them before the
 * processor reads what it wrote (a Pi 4's PCIe is not coherent with the
 * caches; elsewhere this costs nothing that matters). The devices are
 * found once, when usbd starts: none plugged in later yet.
 */

#include <string.h>
#include <stdio.h>
#include <time.h>
#include <mynos.h>
#include <mynos_wire.h>
#include <mynos_virtio.h>

#define PAGE 4096

/* ---- the controller's registers ---- */

static volatile unsigned char * mmio;
static volatile unsigned int * op, * rt, * db;
static unsigned int max_slots, max_ports, ctx_size;

#define R32(P, OFF)   (*(volatile unsigned int *)((volatile unsigned char *)(P) + (OFF)))

/* capability */
#define CAPLENGTH   0x00
#define HCSPARAMS1  0x04
#define HCSPARAMS2  0x08
#define HCCPARAMS1  0x10
#define DBOFF       0x14
#define RTSOFF      0x18
/* operational */
#define USBCMD      0x00
#define USBSTS      0x04
#define CRCR        0x18
#define DCBAAP      0x30
#define CONFIG      0x38
#define PORTSC(N)   (0x400 + 0x10 * ((N) - 1))
#define CMD_RS      (1u << 0)
#define CMD_HCRST   (1u << 1)
#define STS_HCH     (1u << 0)
#define STS_CNR     (1u << 11)
/* port status and control: the bits written 1 to clear, which a write
   that means something else must not touch; PED too (1 disables) */
#define PS_CCS      (1u << 0)
#define PS_PED      (1u << 1)
#define PS_PR       (1u << 4)
#define PS_PP       (1u << 9)
#define PS_SPEED(V) (((V) >> 10) & 0xF)
#define PS_CHANGES  (0x7Fu << 17)
#define PS_PRC      (1u << 21)
/* runtime: interrupter 0 */
#define IMAN        0x20
#define ERSTSZ      0x28
#define ERSTBA      0x30
#define ERDP        0x38

static void w64(volatile unsigned int * base, int off, unsigned long v)
{
  R32(base, off) = (unsigned int)v;
  R32(base, off + 4) = (unsigned int)(v >> 32);
}

/* ---- DMA memory and the caches ---- */

static void cache_clean(const volatile void * p, unsigned long len)
{
#ifdef __aarch64__
  unsigned long a = (unsigned long)p & ~63UL, end = (unsigned long)p + len;
  for (; a < end; a += 64) __asm__ volatile ("dc cvac, %0" : : "r"(a) : "memory");
  __asm__ volatile ("dsb sy" : : : "memory");
#else
  (void)p; (void)len;
  __asm__ volatile ("" : : : "memory");
#endif
}

static void cache_drop(const volatile void * p, unsigned long len)
{
#ifdef __aarch64__
  unsigned long a = (unsigned long)p & ~63UL, end = (unsigned long)p + len;
  __asm__ volatile ("dsb sy" : : : "memory");
  for (; a < end; a += 64) __asm__ volatile ("dc civac, %0" : : "r"(a) : "memory");
  __asm__ volatile ("dsb sy" : : : "memory");
#else
  (void)p; (void)len;
  __asm__ volatile ("" : : : "memory");
#endif
}

/* pages of DMA memory: their address here, their bus address in *bus */
static void * dma(int npages, unsigned long * bus)
{
  void * p = mynos_dmaAlloc(npages, bus);
  if (p) cache_clean(p, (unsigned long)npages * PAGE);
  return p;
}

/* ---- TRBs and rings ---- */

struct trb { unsigned long param; unsigned int status, control; };

#define TRB_TYPE(T)       ((unsigned int)(T) << 10)
#define TRB_GET_TYPE(C)   (((C) >> 10) & 0x3F)
#define T_NORMAL          1
#define T_SETUP           2
#define T_DATA            3
#define T_STATUS          4
#define T_LINK            6
#define T_ENABLE_SLOT     9
#define T_ADDRESS_DEVICE  11
#define T_CONFIGURE_EP    12
#define T_EVALUATE_CTX    13
#define T_EV_TRANSFER     32
#define T_EV_COMMAND      33
#define T_EV_PORT         34
#define C_CYCLE           (1u << 0)
#define C_TOGGLE          (1u << 1)   /* a link: the cycle flips */
#define C_ISP             (1u << 2)
#define C_IOC             (1u << 5)
#define C_IDT             (1u << 6)
#define C_DIR_IN          (1u << 16)

#define RING 64                       /* TRBs a ring, the last a link */

struct ring {
  volatile struct trb * t;
  unsigned long bus;
  int i, cycle;
};

static int ring_init(struct ring * r)
{
  r->t = dma(1, &r->bus);
  if (!r->t) return -1;
  r->i = 0;
  r->cycle = 1;
  r->t[RING - 1].param = r->bus;
  r->t[RING - 1].status = 0;
  r->t[RING - 1].control = TRB_TYPE(T_LINK) | C_TOGGLE;
  cache_clean(r->t, PAGE);
  return 0;
}

/* a TRB on the ring (its cycle bit the ring's, written last): its bus
   address */
static unsigned long ring_put(struct ring * r, unsigned long param, unsigned int status,
                              unsigned int control)
{
  volatile struct trb * t = &r->t[r->i];
  unsigned long at = r->bus + (unsigned long)r->i * sizeof *t;
  t->param = param;
  t->status = status;
  __asm__ volatile ("" : : : "memory");
  t->control = (control & ~C_CYCLE) | (r->cycle ? C_CYCLE : 0);
  cache_clean(t, sizeof *t);
  if (++r->i == RING - 1) {          /* the link: handed over, the cycle flips */
    volatile struct trb * l = &r->t[RING - 1];
    l->control = (TRB_TYPE(T_LINK) | C_TOGGLE) | (r->cycle ? C_CYCLE : 0);
    cache_clean(l, sizeof *l);
    r->i = 0;
    r->cycle ^= 1;
  }
  return at;
}

/* the event ring: one segment of a page (256 TRBs) */
#define EVENTS (PAGE / 16)
static volatile struct trb * ev;
static unsigned long ev_bus;
static int ev_i, ev_cycle = 1;

static struct ring cmd;

/* ---- devices ---- */

struct dev {
  int slot, port, speed;              /* port: the root port */
  unsigned int route;                 /* the hubs' ports below it, 4 bits each */
  int depth;                          /* the hubs above it */
  int tt_slot, tt_port;               /* a LS/FS device's high-speed hub */
  int hub_ports, ttt, power_ms;       /* a hub's ports, its TT's think time, its
                                         ports' time to power good */
  char loc[24];                       /* "5", "5.1", ...: for the log */
  void * in_ctx, * out_ctx;           /* the input and the device contexts */
  unsigned long in_bus, out_bus;
  struct ring ep0, intr;
  int intr_dci, intr_len, kind;       /* 1 a keyboard, 2 a mouse, 9 a hub */
  unsigned char * report;
  unsigned long report_bus;
  unsigned char last[8];              /* a keyboard's last report */
  int pending;                        /* a transfer queued on intr */
};

#define MAXDEV 16
static struct dev devs[MAXDEV];
static int ndevs;
static unsigned long * dcbaa;

/* the context at index i (0 the input control, then the slot, then the
   endpoints by DCI) of an input context; of a device context, from 0 */
static volatile unsigned int * ctx(void * base, int i)
{
  return (volatile unsigned int *)((unsigned char *)base + i * ctx_size);
}

/* the slot's context (xHCI 6.2.2): its route, speed, entries, root port,
   its hub's TT; a hub's own fields */
static void slot_ctx(volatile unsigned int * c, struct dev * d, int entries)
{
  c[0] = d->route | (unsigned int)d->speed << 20 | (unsigned int)entries << 27 |
         (d->hub_ports ? 1u << 26 : 0);
  c[1] = (unsigned int)d->port << 16 | (unsigned int)d->hub_ports << 24;
  c[2] = (unsigned int)d->tt_slot | (unsigned int)d->tt_port << 8 |
         (unsigned int)d->ttt << 16;
  c[3] = 0;
}

/* ---- events ---- */

struct event { unsigned long param; unsigned int status, control; };

static void handle_transfer(struct event * e);

/* the next event, if any: 1 */
static int next_event(struct event * out)
{
  volatile struct trb * t = &ev[ev_i];
  cache_drop(t, sizeof *t);
  if ((t->control & C_CYCLE) != (unsigned int)ev_cycle) return 0;
  out->param = t->param;
  out->status = t->status;
  out->control = t->control;
  if (++ev_i == EVENTS) { ev_i = 0; ev_cycle ^= 1; }
  w64(rt, ERDP, (ev_bus + (unsigned long)ev_i * 16) | (1u << 3));   /* EHB cleared */
  return 1;
}

/* the completion of the command at bus address [at] (other events served
   meanwhile): its completion code, its slot in *slot; -1 if none came */
static int wait_command(unsigned long at, int * slot)
{
  int ms;
  struct event e;
  for (ms = 0; ms < 2000; ) {
    if (!next_event(&e)) { mynos_sleep(1000); ms++; continue; }
    if (TRB_GET_TYPE(e.control) == T_EV_COMMAND && e.param == at) {
      if (slot) *slot = e.control >> 24;
      return e.status >> 24;
    }
    if (TRB_GET_TYPE(e.control) == T_EV_TRANSFER) handle_transfer(&e);
  }
  return -1;
}

static int command(unsigned long param, unsigned int status, unsigned int control, int * slot)
{
  unsigned long at = ring_put(&cmd, param, status, control);
  db[0] = 0;
  return wait_command(at, slot);
}

/* the completion of a transfer on dev's ep0 (the last TRB: [at]) */
static int wait_transfer(struct dev * d, unsigned long at, int * residue)
{
  int ms;
  struct event e;
  for (ms = 0; ms < 2000; ) {
    if (!next_event(&e)) { mynos_sleep(1000); ms++; continue; }
    if (TRB_GET_TYPE(e.control) == T_EV_TRANSFER && (int)(e.control >> 24) == d->slot &&
        ((e.control >> 16) & 0x1F) == 1) {
      if (residue && e.param != at) *residue = e.status & 0xFFFFFF;
      if (e.param == at) return e.status >> 24;
      if ((e.status >> 24) != 1 && (e.status >> 24) != 13) return e.status >> 24;
      continue;                      /* (a short packet's event: the status's comes) */
    }
    if (TRB_GET_TYPE(e.control) == T_EV_TRANSFER) handle_transfer(&e);
  }
  return -1;
}

/* ---- control transfers ---- */

static unsigned char * ctl_buf;      /* a page for the data stage */
static unsigned long ctl_bus;

/* a request on endpoint 0: setup (type, request, value, index, length),
   the data stage IN (into ctl_buf) if length; the bytes that came, or -1 */
static int control(struct dev * d, int type, int req, int value, int index, int length)
{
  unsigned long setup = (unsigned long)(type & 0xFF) | (unsigned long)(req & 0xFF) << 8 |
                        (unsigned long)(value & 0xFFFF) << 16 |
                        (unsigned long)(index & 0xFFFF) << 32 |
                        (unsigned long)(length & 0xFFFF) << 48;
  int in = (type & 0x80) != 0, cc, residue = 0;
  unsigned long at;
  /* transfer type: 3 IN data, 2 OUT data, 0 none */
  ring_put(&d->ep0, setup, 8, TRB_TYPE(T_SETUP) | C_IDT |
           ((length ? (in ? 3u : 2u) : 0u) << 16));
  if (length) {
    cache_drop(ctl_buf, length);
    ring_put(&d->ep0, ctl_bus, (unsigned int)length, TRB_TYPE(T_DATA) | C_ISP |
             (in ? C_DIR_IN : 0));
  }
  at = ring_put(&d->ep0, 0, 0, TRB_TYPE(T_STATUS) | C_IOC |
                ((length && in) ? 0 : C_DIR_IN));
  db[d->slot] = 1;
  cc = wait_transfer(d, at, &residue);
  if (cc != 1 && cc != 13) return -1;  /* success, short packet */
  if (length) cache_drop(ctl_buf, length);
  return length - residue;
}

/* ---- the keyboard's reports ---- */

/* HID usages (page 7) 0x04-0x65 as set 1 scan codes (0x100: E0 first) */
static const unsigned short hid_set1[0x66] = {
  0, 0, 0, 0,
  0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26,   /* a-l */
  0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D,   /* m-x */
  0x15, 0x2C,                                                             /* y z */
  0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,             /* 1-0 */
  0x1C, 0x01, 0x0E, 0x0F, 0x39,                       /* Enter Esc BS Tab Space */
  0x0C, 0x0D, 0x1A, 0x1B, 0x2B, 0x2B, 0x27, 0x28, 0x29, 0x33, 0x34, 0x35, /* - = [ ] \ # ; ' ` , . / */
  0x3A,                                                                   /* Caps Lock */
  0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58, /* F1-F12 */
  0x137, 0x46, 0x145,                                 /* PrtSc ScrLk Pause */
  0x152, 0x147, 0x149, 0x153, 0x14F, 0x151,           /* Ins Home PgUp Del End PgDn */
  0x14D, 0x14B, 0x150, 0x148,                         /* Right Left Down Up */
  0x45, 0x135, 0x37, 0x4A, 0x4E, 0x11C,               /* NumLk KP/ KP* KP- KP+ KPEnter */
  0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49, 0x52, 0x53,       /* KP1-9 0 . */
  0x56, 0x15D                                         /* the 102nd key (< >), Menu */
};
/* the modifiers' bits: LCtrl LShift LAlt LGUI RCtrl RShift RAlt RGUI */
static const unsigned short mod_set1[8] = {
  0x1D, 0x2A, 0x38, 0x15B, 0x11D, 0x36, 0x138, 0x15C
};

static unsigned char keys_out[64];
static int keys_n;

static void key_code(unsigned short code, int released)
{
  if (keys_n > (int)sizeof keys_out - 2) return;
  if (code & 0x100) keys_out[keys_n++] = 0xE0;
  keys_out[keys_n++] = (unsigned char)((code & 0x7F) | (released ? 0x80 : 0));
}

static int keys_port = -1;

/* the keys gathered, to consoled's "keys" service (keys/1: request 0) */
static void keys_flush(void)
{
  wire_writer w;
  int ch;
  mynos_msg_t * reply;
  if (keys_n == 0) return;
  if (keys_port < 0) keys_port = mynos_registryLookUp("keys");
  if (keys_port >= 0) {
    wire_writer_init(&w);
    wire_put_cstring(&w, "keys/1");
    wire_put_int(&w, 0);
    wire_put_string(&w, (const char *)keys_out, keys_n);
    ch = w.error ? -1 : mynos_connectToPort(keys_port);
    if (ch < 0) keys_port = -1;      /* consoled restarted: looked up again */
    else {
      if (mynos_send(ch, w.buf, w.len, 0) >= 0 && mynos_recv(ch, &reply, 0, 1000) >= 0)
        mynos_freeMsg(&reply);
      mynos_freeChannel(ch);
    }
    wire_writer_free(&w);
  }
  keys_n = 0;
}

static unsigned short held_code;      /* the key repeated, 0: none */
static long held_next;                /* when, in ms */

static long now_ms(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000L + ts.tv_nsec / 1000000;
}

static int in_report(const unsigned char * r, int code)
{
  int i;
  for (i = 2; i < 8; i++) if (r[i] == code) return 1;
  return 0;
}

static void keyboard_report(struct dev * d, const unsigned char * r)
{
  int i;
  if (r[2] == 1) return;              /* too many keys held (rollover): nothing new */
  for (i = 0; i < 8; i++)             /* the modifiers */
    if ((r[0] ^ d->last[0]) & (1 << i)) key_code(mod_set1[i], !(r[0] & (1 << i)));
  for (i = 2; i < 8; i++)             /* let go */
    if (d->last[i] >= 4 && d->last[i] < 0x66 && !in_report(r, d->last[i])) {
      key_code(hid_set1[d->last[i]], 1);
      if (hid_set1[d->last[i]] == held_code) held_code = 0;
    }
  for (i = 2; i < 8; i++)             /* pressed */
    if (r[i] >= 4 && r[i] < 0x66 && hid_set1[r[i]] && !in_report(d->last, r[i])) {
      key_code(hid_set1[r[i]], 0);
      held_code = hid_set1[r[i]];
      held_next = now_ms() + 500;
    }
  memcpy(d->last, r, 8);
  keys_flush();
}

static void repeat_keys(void)
{
  long t;
  if (!held_code) return;
  t = now_ms();
  if (t < held_next) return;
  key_code(held_code, 0);
  held_next = t + 33;
  keys_flush();
}

/* ---- the mouse's reports: to displayd's "pointer" service (pointer/1,
   request 0: dx, dy, buttons, wheel) ---- */

static int pointer_port = -1;

static void mouse_report(const unsigned char * r, int len)
{
  wire_writer w;
  int ch;
  mynos_msg_t * reply;
  if (len < 3) return;
  if (pointer_port < 0) pointer_port = mynos_registryLookUp("pointer");
  if (pointer_port < 0) return;       /* no display server (yet) */
  wire_writer_init(&w);
  wire_put_cstring(&w, "pointer/1");
  wire_put_int(&w, 0);
  wire_put_int(&w, (signed char)r[1]);
  wire_put_int(&w, (signed char)r[2]);
  wire_put_int(&w, r[0] & 7);
  wire_put_int(&w, len > 3 ? (signed char)r[3] : 0);
  ch = w.error ? -1 : mynos_connectToPort(pointer_port);
  if (ch < 0) pointer_port = -1;
  else {
    if (mynos_send(ch, w.buf, w.len, 0) >= 0 && mynos_recv(ch, &reply, 0, 1000) >= 0)
      mynos_freeMsg(&reply);
    mynos_freeChannel(ch);
  }
  wire_writer_free(&w);
}

/* ---- interrupt endpoints ---- */

static void queue_report(struct dev * d)
{
  cache_drop(d->report, d->intr_len);
  ring_put(&d->intr, d->report_bus, (unsigned int)d->intr_len,
           TRB_TYPE(T_NORMAL) | C_IOC | C_ISP);
  db[d->slot] = (unsigned int)d->intr_dci;
  d->pending = 1;
}

static void handle_transfer(struct event * e)
{
  int slot = e->control >> 24, dci = (e->control >> 16) & 0x1F, i, cc = e->status >> 24;
  for (i = 0; i < ndevs; i++) {
    struct dev * d = &devs[i];
    if (d->slot != slot || d->intr_dci != dci) continue;
    d->pending = 0;
    if (cc == 1 || cc == 13) {
      cache_drop(d->report, d->intr_len);
      if (d->kind == 1) keyboard_report(d, d->report);
      else if (d->kind == 2) mouse_report(d->report, d->intr_len - (int)(e->status & 0xFFFFFF));
      else return;                    /* a hub's port changes: not read again yet */
    }
    queue_report(d);
    return;
  }
}

/* ---- a device, on a root port or a hub's ---- */

static int max_packet0(int speed)
{
  switch (speed) {
  case 2: return 8;                  /* low speed */
  case 3: return 64;                 /* high */
  case 4: return 512;                /* super */
  default: return 8;                 /* full: 8 to 64, read from its descriptor */
  }
}

static const char * speed_name(int s)
{
  return s == 1 ? "full" : s == 2 ? "low" : s == 3 ? "high" : s == 4 ? "super" : "?";
}

/* the interval of an interrupt endpoint, as the slot's context wants it
   (2^n x 125 us): from its descriptor's bInterval */
static int ep_interval(int speed, int b)
{
  int n = 3;
  if (speed == 3 || speed == 4) return b >= 1 && b <= 16 ? b - 1 : 3;
  if (b < 1) b = 1;
  while ((1 << (n - 3)) * 2 <= b && n < 10) n++;
  return n;                          /* full and low speed: b ms */
}

static void hub_scan(struct dev * h);

/* a device at root port [port], [route] below it, of [speed]: [hub] the
   hub it is on (NULL: a root port), [hub_port] its port there */
static void attach(int port, unsigned int route, int speed, struct dev * hub, int hub_port)
{
  struct dev * d;
  int slot = 0, cc, n, i, cfg_len, config, iface = -1, proto = 0, ep_addr = 0, ep_len = 0,
      ep_int = 10, mps, kind = 0;
  volatile unsigned int * c;
  unsigned char * p;
  if (ndevs == MAXDEV) return;
  d = &devs[ndevs];
  memset(d, 0, sizeof *d);
  d->port = port;
  d->route = route;
  d->speed = speed;
  if (hub) {
    d->depth = hub->depth + 1;
    snprintf(d->loc, sizeof d->loc, "%.20s.%u", hub->loc, hub_port & 15u);
    if ((speed == 1 || speed == 2) && hub->speed == 3) {
      d->tt_slot = hub->slot;         /* the high-speed hub's TT */
      d->tt_port = hub_port;
    } else {
      d->tt_slot = hub->tt_slot;      /* (or the one above it, if any) */
      d->tt_port = hub->tt_port;
    }
  } else
    snprintf(d->loc, sizeof d->loc, "%d", port);
  cc = command(0, 0, TRB_TYPE(T_ENABLE_SLOT), &slot);
  if (cc != 1 || slot <= 0 || slot > (int)max_slots) {
    mynos_log("usbd: port %s: no slot (%d)\n", d->loc, cc);
    return;
  }
  d->slot = slot;
  d->in_ctx = dma(1, &d->in_bus);
  d->out_ctx = dma(1, &d->out_bus);
  if (!d->in_ctx || !d->out_ctx || ring_init(&d->ep0) < 0) return;
  dcbaa[slot] = d->out_bus;
  cache_clean(&dcbaa[slot], 8);
  /* the input context: add the slot and endpoint 0 */
  c = ctx(d->in_ctx, 0); c[1] = 0x3;
  slot_ctx(ctx(d->in_ctx, 1), d, 1);
  mps = max_packet0(speed);
  c = ctx(d->in_ctx, 2);              /* endpoint 0: control, its first TRB */
  c[1] = 3u << 1 | 4u << 3 | (unsigned int)mps << 16;
  c[2] = (unsigned int)d->ep0.bus | 1;
  c[3] = (unsigned int)(d->ep0.bus >> 32);
  c[4] = 8;
  cache_clean(d->in_ctx, PAGE);
  cc = command(d->in_bus, 0, TRB_TYPE(T_ADDRESS_DEVICE) | (unsigned int)slot << 24, NULL);
  if (cc != 1) {
    mynos_log("usbd: port %s: no address (%d)\n", d->loc, cc);
    return;
  }
  ndevs++;
  /* the device descriptor's first 8 bytes: its endpoint 0's size */
  if (control(d, 0x80, 6, 0x100, 0, 8) < 0) {
    mynos_log("usbd: port %s: no descriptor\n", d->loc);
    ndevs--;
    return;
  }
  if (speed == 1 && ctl_buf[7] != mps && ctl_buf[7] >= 8) {
    mps = ctl_buf[7];                 /* a full-speed device's: evaluate */
    c = ctx(d->in_ctx, 0); c[0] = 0; c[1] = 0x2;
    c = ctx(d->in_ctx, 2); c[1] = (c[1] & 0xFFFF) | (unsigned int)mps << 16;
    cache_clean(d->in_ctx, PAGE);
    command(d->in_bus, 0, TRB_TYPE(T_EVALUATE_CTX) | (unsigned int)slot << 24, NULL);
  }
  if (control(d, 0x80, 6, 0x100, 0, 18) < 18) { ndevs--; return; }
  mynos_log("usbd: port %s: %s speed, %04x:%04x, class %d\n", d->loc, speed_name(speed),
            ctl_buf[8] | ctl_buf[9] << 8, ctl_buf[10] | ctl_buf[11] << 8, ctl_buf[4]);
  /* the configuration: its interfaces, the first HID boot one's (or a
     hub's) interrupt IN endpoint */
  if (control(d, 0x80, 6, 0x200, 0, 9) < 9) return;
  cfg_len = ctl_buf[2] | ctl_buf[3] << 8;
  if (cfg_len > PAGE) cfg_len = PAGE;
  if (control(d, 0x80, 6, 0x200, 0, cfg_len) < cfg_len) return;
  config = ctl_buf[5];
  for (p = ctl_buf, n = 0; n + 2 <= cfg_len && p[0] >= 2; n += p[0], p += p[0]) {
    if (p[1] == 4 && iface < 0 && p[3] == 0 &&
        ((p[5] == 3 && p[6] == 1 && (p[7] == 1 || p[7] == 2)) || p[5] == 9)) {
      iface = p[2];
      proto = p[7];
      kind = p[5] == 9 ? 9 : proto;
    } else if (p[1] == 4 && iface >= 0 && !ep_addr)
      break;                          /* the next interface: none found in it */
    else if (p[1] == 5 && iface >= 0 && !ep_addr && (p[2] & 0x80) && (p[3] & 3) == 3) {
      ep_addr = p[2];
      ep_len = p[4] | (p[5] & 7) << 8;
      ep_int = p[6];
    }
  }
  if (iface < 0 || !ep_addr) return;  /* not a keyboard, a mouse or a hub */
  if (kind == 9 && speed == 4) {
    mynos_log("usbd: port %s: a USB 3 hub: not yet\n", d->loc);
    return;
  }
  if (control(d, 0x00, 9, config, 0, 0) < 0) return;            /* SET_CONFIGURATION */
  if (kind == 9) {
    /* the hub's descriptor: its ports, its TT's think time (its slot's
       context says it is a hub when its endpoint is configured) */
    if (control(d, 0xA0, 6, 0x2900, 0, 7) < 7) return;
    d->hub_ports = ctl_buf[2] > 15 ? 15 : ctl_buf[2];
    d->ttt = speed == 3 ? (ctl_buf[3] >> 5) & 3 : 0;
    d->power_ms = ctl_buf[5] * 2;
  } else {
    control(d, 0x21, 0x0B, 0, iface, 0);                        /* SET_PROTOCOL: boot */
    control(d, 0x21, 0x0A, 0, iface, 0);                        /* SET_IDLE: only changes */
  }
  /* its interrupt endpoint: configured, then read */
  d->kind = kind;
  d->intr_dci = (ep_addr & 0xF) * 2 + 1;
  d->intr_len = ep_len;               /* (a boot report: its first 8 bytes) */
  d->report = dma(1, &d->report_bus);
  if (!d->report || ring_init(&d->intr) < 0) return;
  memset(d->in_ctx, 0, PAGE);
  c = ctx(d->in_ctx, 0); c[1] = 1u | 1u << d->intr_dci;
  slot_ctx(ctx(d->in_ctx, 1), d, d->intr_dci);
  c = ctx(d->in_ctx, 1 + d->intr_dci);  /* interrupt IN (7), its interval */
  c[0] = (unsigned int)ep_interval(speed, ep_int) << 16;
  c[1] = 3u << 1 | 7u << 3 | (unsigned int)ep_len << 16;
  c[2] = (unsigned int)d->intr.bus | 1;
  c[3] = (unsigned int)(d->intr.bus >> 32);
  c[4] = (unsigned int)ep_len | (unsigned int)ep_len << 16;
  cache_clean(d->in_ctx, PAGE);
  cc = command(d->in_bus, 0, TRB_TYPE(T_CONFIGURE_EP) | (unsigned int)slot << 24, NULL);
  if (cc != 1) {
    mynos_log("usbd: port %s: its endpoint refused (%d)\n", d->loc, cc);
    return;
  }
  if (kind == 9) {
    mynos_log("usbd: port %s: a hub, %d ports\n", d->loc, d->hub_ports);
    hub_scan(d);
    return;
  }
  mynos_log("usbd: port %s: a %s\n", d->loc, proto == 1 ? "keyboard" : "mouse");
  for (i = 0; i < 8; i++) d->last[i] = 0;
  queue_report(d);
}

/* a hub's port's status (wPortStatus) and changes (wPortChange << 16),
   or -1 */
static int hub_port_status(struct dev * h, int n)
{
  if (control(h, 0xA3, 0, 0, n, 4) < 4) return -1;
  return ctl_buf[0] | ctl_buf[1] << 8 | ctl_buf[2] << 16 | ctl_buf[3] << 24;
}

#define HUB_SET_FEATURE(H, F, N)   control(H, 0x23, 3, F, N, 0)
#define HUB_CLEAR_FEATURE(H, F, N) control(H, 0x23, 1, F, N, 0)
#define F_PORT_RESET     4
#define F_PORT_POWER     8
#define F_C_CONNECTION   16
#define F_C_RESET        20

/* a USB 2 hub's ports (USB 2.0, chapter 11.24): powered, those with a
   device reset, each device attached */
static void hub_scan(struct dev * h)
{
  int n, ms, st, speed;
  if (h->depth >= 5) return;          /* the route string's five tiers */
  for (n = 1; n <= h->hub_ports; n++) HUB_SET_FEATURE(h, F_PORT_POWER, n);
  /* power good, then the connections seen (at least 100 ms) */
  mynos_sleep((h->power_ms < 100 ? 100 : h->power_ms) * 1000);
  for (n = 1; n <= h->hub_ports; n++) {
    st = hub_port_status(h, n);
    if (st < 0 || !(st & 1)) continue;             /* nothing connected */
    HUB_CLEAR_FEATURE(h, F_C_CONNECTION, n);
    HUB_SET_FEATURE(h, F_PORT_RESET, n);
    for (ms = 0; ms < 500; ms += 10) {
      mynos_sleep(10000);
      st = hub_port_status(h, n);
      if (st >= 0 && (st & (0x10 << 16))) break;   /* C_PORT_RESET */
    }
    if (st < 0 || !(st & 2)) {
      mynos_log("usbd: port %s.%d: not enabled (%08x)\n", h->loc, n, st);
      continue;
    }
    HUB_CLEAR_FEATURE(h, F_C_RESET, n);
    speed = (st & 0x200) ? 2 : (st & 0x400) ? 3 : 1;   /* low, high, full */
    mynos_sleep(20000);               /* the device's recovery after the reset */
    attach(h->port, h->route | (unsigned int)n << (4 * h->depth), speed, h, n);
  }
}

/* a root port's device: the port reset (a USB 2 port's; a USB 3 one's
   is enabled by itself), its speed */
static void port_scan(int n)
{
  unsigned int v = R32(op, PORTSC(n)), keep = PS_PP;
  int ms;
  if (!(v & PS_CCS)) return;
  if (!(v & PS_PED)) {
    R32(op, PORTSC(n)) = keep | PS_PR;
    for (ms = 0; ms < 500 && !(R32(op, PORTSC(n)) & PS_PRC); ms++) mynos_sleep(1000);
  }
  v = R32(op, PORTSC(n));
  R32(op, PORTSC(n)) = keep | (v & PS_CHANGES);     /* the changes acknowledged */
  if (!(v & PS_PED)) {
    mynos_log("usbd: port %d: not enabled (%08x)\n", n, v);
    return;
  }
  mynos_sleep(20000);                 /* the device's recovery after the reset */
  attach(n, 0, PS_SPEED(v), NULL, 0);
}

/* ---- the controller ---- */

static int find_xhci(int * bus_out, int * dev_out)
{
  int bus, dev;
  for (bus = 0; bus < 2; bus++)
    for (dev = 0; dev < 32; dev++) {
      unsigned int id = pci_read32(bus, dev, 0, 0), class;
      if (id == 0xFFFFFFFF || id == 0) continue;
      class = pci_read32(bus, dev, 0, 8) >> 8;
      if (class == 0x0C0330) { *bus_out = bus; *dev_out = dev; return 0; }
    }
  return -1;
}

static int start(int bus, int dev)
{
  unsigned long bar = pci_read32(bus, dev, 0, 0x10), dcbaa_bus, erst_bus;
  unsigned long * erst;
  unsigned int caplen, scratch, i, ms;
  if ((bar & 6) == 4) bar |= (unsigned long)pci_read32(bus, dev, 0, 0x14) << 32;
  bar &= ~0xFUL;
  pci_write32(bus, dev, 0, 4, pci_read32(bus, dev, 0, 4) | 0x6);  /* memory, bus master */
  mmio = mynos_mapPhysical(bar, 16);
  if (!mmio) { mynos_log("usbd: cannot map the controller at %lx\n", bar); return -1; }
  caplen = mmio[CAPLENGTH];
  op = (volatile unsigned int *)(mmio + caplen);
  rt = (volatile unsigned int *)(mmio + (R32(mmio, RTSOFF) & ~0x1Fu));
  db = (volatile unsigned int *)(mmio + (R32(mmio, DBOFF) & ~0x3u));
  max_slots = R32(mmio, HCSPARAMS1) & 0xFF;
  max_ports = R32(mmio, HCSPARAMS1) >> 24;
  ctx_size = (R32(mmio, HCCPARAMS1) & 4) ? 64 : 32;
  scratch = (R32(mmio, HCSPARAMS2) >> 27 & 0x1F) | (R32(mmio, HCSPARAMS2) >> 21 & 0x1F) << 5;
  if (max_slots > MAXDEV) max_slots = MAXDEV;
  /* stopped, reset */
  R32(op, USBCMD) &= ~CMD_RS;
  for (ms = 0; ms < 100 && !(R32(op, USBSTS) & STS_HCH); ms++) mynos_sleep(1000);
  R32(op, USBCMD) |= CMD_HCRST;
  for (ms = 0; ms < 1000 && (R32(op, USBCMD) & CMD_HCRST); ms++) mynos_sleep(1000);
  for (ms = 0; ms < 1000 && (R32(op, USBSTS) & STS_CNR); ms++) mynos_sleep(1000);
  if (R32(op, USBSTS) & STS_CNR) { mynos_log("usbd: the controller is not ready\n"); return -1; }
  R32(op, CONFIG) = max_slots;
  /* the device context base array (entry 0: the scratchpad's array) */
  dcbaa = dma(1, &dcbaa_bus);
  if (!dcbaa) return -1;
  if (scratch) {
    unsigned long arr_bus, pg_bus;
    unsigned long * arr = dma(1, &arr_bus);
    if (!arr || scratch > 256) return -1;
    for (i = 0; i < scratch; i++) {
      if (!dma(1, &pg_bus)) return -1;
      arr[i] = pg_bus;
    }
    cache_clean(arr, PAGE);
    dcbaa[0] = arr_bus;
  }
  cache_clean(dcbaa, PAGE);
  w64(op, DCBAAP, dcbaa_bus);
  /* the command ring */
  if (ring_init(&cmd) < 0) return -1;
  w64(op, CRCR, cmd.bus | 1);
  /* the event ring: its segment table (one), interrupter 0 */
  ev = dma(1, &ev_bus);
  erst = dma(1, &erst_bus);
  if (!ev || !erst) return -1;
  erst[0] = ev_bus;
  erst[1] = EVENTS;
  cache_clean(erst, 16);
  R32(rt, ERSTSZ) = 1;
  w64(rt, ERDP, ev_bus);
  w64(rt, ERSTBA, erst_bus);
  R32(rt, IMAN) = 0x3;                /* (polled: its pending bit cleared) */
  ctl_buf = dma(1, &ctl_bus);
  if (!ctl_buf) return -1;
  R32(op, USBCMD) |= CMD_RS;
  for (ms = 0; ms < 100 && (R32(op, USBSTS) & STS_HCH); ms++) mynos_sleep(1000);
  mynos_log("usbd: xHCI %x.%02x, %u ports, %u slots%s\n", R32(mmio, 0) >> 24,
            (R32(mmio, 0) >> 16) & 0xFF, max_ports, max_slots,
            ctx_size == 64 ? ", 64-byte contexts" : "");
  return 0;
}

int main(void)
{
  int bus, dev, n;
  struct event e;
  if (find_xhci(&bus, &dev) < 0) {
    mynos_log("usbd: no USB controller (xHCI)\n");
    return 0;                         /* by choice: init does not start it again */
  }
  if (start(bus, dev) < 0) return 1;
  mynos_sleep(100000);                /* the ports' connections seen */
  for (n = 1; n <= (int)max_ports; n++) port_scan(n);
  for (;;) {
    while (next_event(&e))
      if (TRB_GET_TYPE(e.control) == T_EV_TRANSFER) handle_transfer(&e);
    repeat_keys();
    mynos_sleep(5000);
  }
  return 0;
}
