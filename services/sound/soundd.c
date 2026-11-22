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
 * soundd: the sound server (mynos-7jn), in C, a driver (the io
 * privilege: "driver soundd" in init.rc). It drives a Sound Blaster 16
 * at 0x220 (QEMU's -device sb16, v86's) and mixes what programs play.
 *
 * The card reads its samples from the kernel's DMA area (mynos_dmaArea:
 * 64 KB of RAM below 16 MB, chosen at boot), by 16-bit auto-init DMA on
 * channel 5: two halves of BLOCK bytes, played in turn; the card's
 * interrupt (IRQ 5) at the end of each says which half to fill again,
 * with the next BLOCK bytes of the mix. The output is 22050 Hz, 16-bit,
 * stereo; programs send that (module Sound converts WAV files). When
 * nothing plays for a while the DMA pauses, and resumes with the next
 * sound.
 *
 * Protocol "sound/1" (typed IPC): info, open a stream, write samples to
 * it (the request waits while the stream holds more than a second: the
 * pace of the music is the card's), close it (it ends when played) or
 * stop it (at once), a tone (a square wave, for beeps and games), the
 * volume. A stream belongs to the process that opened it, and goes
 * when that process ends.
 *
 * Threads: requests (the main one), the card's interrupts; one lock.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <mynos.h>
#include <mynos_wire.h>

#define SERVICE  "sound"
#define PROTOCOL "sound/1"

#define SB 0x220
#define DSP_RESET (SB + 0x6)
#define DSP_READ (SB + 0xA)
#define DSP_WRITE (SB + 0xC)
#define DSP_STATUS (SB + 0xE)
#define DSP_ACK16 (SB + 0xF)
#define MIXER_ADDR (SB + 0x4)
#define MIXER_DATA (SB + 0x5)
#define SB_IRQ 5

#define RATE 22050
#define BLOCK 4096                 /* bytes: 1024 frames, 46 ms */
#define FRAMES (BLOCK / 4)
#define QUEUE (RATE)               /* a stream holds up to a second */
#define MAXSTREAM 8
#define MAXTONE 4
#define IDLE_BLOCKS 11             /* half a second of silence: pause */

/* ---- the card ---- */

static int dsp_write(unsigned char v)
{
  int n;
  for (n = 0; n < 100000; n++)
    if (!(inportb(DSP_WRITE) & 0x80)) { outportb(DSP_WRITE, v); return 0; }
  return -1;
}

static int dsp_read(void)
{
  int n;
  for (n = 0; n < 100000; n++)
    if (inportb(DSP_STATUS) & 0x80) return inportb(DSP_READ);
  return -1;
}

static int dsp_reset(void)
{
  int n;
  outportb(DSP_RESET, 1);
  for (n = 0; n < 100; n++) inportb(DSP_STATUS);       /* more than 3 us */
  outportb(DSP_RESET, 0);
  for (n = 0; n < 1000; n++)
    if ((inportb(DSP_STATUS) & 0x80) && inportb(DSP_READ) == 0xAA) return 0;
  return -1;
}

static int mixer_read(int reg)
{
  outportb(MIXER_ADDR, reg);
  return inportb(MIXER_DATA);
}

/* 16-bit DMA, channel 5 (the second controller): the two halves,
   auto-init, memory to the card. Its addresses and counts are in words */
static void dma16_program(unsigned long phys, int bytes)
{
  unsigned long words = phys >> 1;
  int count = (bytes >> 1) - 1;
  outportb(0xD4, 0x05);                         /* mask channel 5 */
  outportb(0xD8, 0);                            /* the flip-flop: low byte first */
  outportb(0xD6, 0x59);                         /* single, auto-init, read, channel 1 */
  outportb(0xC4, words & 0xFF);
  outportb(0xC4, (words >> 8) & 0xFF);
  outportb(0xC6, count & 0xFF);
  outportb(0xC6, (count >> 8) & 0xFF);
  outportb(0x8B, (phys >> 16) & 0xFF);          /* the page: address bits 23-17 */
  outportb(0xD4, 0x01);                         /* unmask */
}

/* ---- streams, tones, the mix (under the lock) ---- */

struct stream {
  int used, id, owner, closing;
  short q[QUEUE * 2];              /* stereo frames, a ring */
  int head, count;
  int waiting;                     /* a write's channel that waits, or -1 */
  int closer;                      /* close's channel, answered when played, or -1 */
  char * rest;                     /* what that write could not queue yet */
  unsigned int rest_len, rest_off;
};

/* a tone's phase: a cycle is 65536, it moves by step a sample (the
   frequency stays exact, not rounded to whole samples a period) */
struct tone { int used, step, left, phase; };

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct stream streams[MAXSTREAM];
static struct tone tones[MAXTONE];
static int next_id = 1, volume = 80;
static short * area;                 /* the DMA area, mapped */
static unsigned long area_phys;
static int playing = 0, started = 0, half = 0, idle = 0;
static unsigned long blocks = 0;

static void send_reply(int ch, wire_writer * w)
{
  if (w->error) {
    wire_writer_free(w);
    wire_writer_init(w);
    wire_reply_error(w, "soundd: out of memory");
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

static void reply_int(int ch, int v)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_ok(&w);
  wire_put_int(&w, v);
  send_reply(ch, &w);
}

/* queue frames (bytes of stereo 16-bit samples): how many bytes fit */
static unsigned int enqueue(struct stream * s, const char * data, unsigned int len)
{
  unsigned int frames = len / 4, room = QUEUE - s->count, i;
  if (frames > room) frames = room;
  for (i = 0; i < frames; i++) {
    int at = (s->head + s->count + i) % QUEUE;
    memcpy(&s->q[2 * at], data + 4 * i, 4);
  }
  s->count += frames;
  return frames * 4;
}

/* a waiting write: more of it queued; answered once all is */
static void feed(struct stream * s)
{
  if (s->waiting < 0) return;
  s->rest_off += enqueue(s, s->rest + s->rest_off, s->rest_len - s->rest_off);
  if (s->rest_len - s->rest_off < 4) {
    free(s->rest);
    s->rest = NULL;
    reply_unit(s->waiting);
    s->waiting = -1;
  }
}

static void drop(struct stream * s)
{
  if (s->waiting >= 0) { reply_error(s->waiting, "the stream was stopped"); s->waiting = -1; }
  if (s->closer >= 0) { reply_unit(s->closer); s->closer = -1; }
  free(s->rest);
  s->rest = NULL;
  s->used = 0;
}

/* the next BLOCK bytes of the mix, into the half [h]; whether there was
   anything to play */
static int mix(int h)
{
  short * out = area + h * (BLOCK / 2);
  int f, i, any = 0;
  for (f = 0; f < FRAMES; f++) {
    int l = 0, r = 0;
    for (i = 0; i < MAXSTREAM; i++) {
      struct stream * s = &streams[i];
      if (!s->used || s->count == 0) continue;
      l += s->q[2 * s->head];
      r += s->q[2 * s->head + 1];
      s->head = (s->head + 1) % QUEUE;
      s->count--;
      any = 1;
    }
    for (i = 0; i < MAXTONE; i++) {
      struct tone * t = &tones[i];
      int v;
      if (!t->used) continue;
      v = (t->phase < 32768) ? 6000 : -6000;
      l += v;
      r += v;
      t->phase = (t->phase + t->step) & 0xFFFF;
      if (--t->left <= 0) t->used = 0;
      any = 1;
    }
    l = l * volume / 100;
    r = r * volume / 100;
    out[2 * f] = l > 32767 ? 32767 : l < -32768 ? -32768 : l;
    out[2 * f + 1] = r > 32767 ? 32767 : r < -32768 ? -32768 : r;
  }
  /* streams: their waiting writes go on; the closed and played go;
     those of processes that ended go too (every second or so) */
  for (i = 0; i < MAXSTREAM; i++) {
    struct stream * s = &streams[i];
    if (!s->used) continue;
    feed(s);
    if (s->closing && s->count == 0 && s->waiting < 0) drop(s);
    else if (blocks % 22 == 0 && !(mynos_processInfo(s->owner) & MYNOS_PROC_ALIVE)) drop(s);
  }
  blocks++;
  return any;
}

/* something to play: the card starts, or resumes */
static void play(void)
{
  if (playing) return;
  idle = 0;
  if (!started) {
    half = 0;
    mix(0);
    mix(1);
    dma16_program(area_phys, 2 * BLOCK);
    dsp_write(0x41);                              /* the output rate */
    dsp_write(RATE >> 8);
    dsp_write(RATE & 0xFF);
    dsp_write(0xB6);                              /* 16-bit, output, auto-init, FIFO */
    dsp_write(0x30);                              /* signed, stereo */
    dsp_write((BLOCK / 2 - 1) & 0xFF);            /* a half, in samples, less one */
    dsp_write((BLOCK / 2 - 1) >> 8);
    started = 1;
  } else {
    /* the card resumes in the half it paused in (silence), then plays
       the other: the new sound goes there at once */
    mix(half ^ 1);
    dsp_write(0xD6);                              /* continue 16-bit DMA */
  }
  playing = 1;
}

static void * irq_thread(void * arg)
{
  int sem = (int)(long)arg;
  for (;;) {
    if (mynos_P(sem) < 0) return NULL;
    inportb(DSP_ACK16);                           /* the card's interrupt, seen */
    pthread_mutex_lock(&lock);
    if (playing) {
      /* the half just played is filled again; after half a second of
         silence the card pauses (on silence it fills) */
      if (mix(half)) idle = 0;
      else if (++idle >= IDLE_BLOCKS) {
        dsp_write(0xD5);                          /* pause 16-bit DMA */
        playing = 0;
      }
      half ^= 1;
    }
    pthread_mutex_unlock(&lock);
  }
  return NULL;
}

/* ---- requests ---- */

static const wire_request_doc requests[] = {
  { 1, "info", "U", "(rate:I,channels:I)",
    "The output: samples a second, and channels (16-bit signed samples, little-endian)." },
  { 0, "open", "U", "I", "A stream of samples, mixed with the others: its number." },
  { 0, "write", "(stream:I,samples:S)", "U",
    "Samples for a stream: stereo pairs of 16-bit signed little-endian samples at the "
    "output's rate. Waits while the stream holds more than a second." },
  { 0, "close", "stream:I", "U",
    "The stream ends when what it holds has played. Waits until then." },
  { 0, "stop", "stream:I", "U", "The stream ends at once." },
  { 0, "tone", "(hz:I,ms:I)", "U", "A tone (a square wave), mixed with the rest." },
  { 0, "volume", "level:I", "I", "The volume, 0 to 100 (-1: unchanged): the one in use." },
};

static void describe(int ch)
{
  wire_writer w;
  wire_writer_init(&w);
  wire_reply_description(&w, PROTOCOL,
    "Sound (soundd, in C): streams of samples mixed and played by a Sound Blaster 16, "
    "tones, the volume.",
    requests, sizeof requests / sizeof requests[0]);
  send_reply(ch, &w);
}

static struct stream * owned(int ch, int id, int caller)
{
  int i;
  for (i = 0; i < MAXSTREAM; i++)
    if (streams[i].used && streams[i].id == id) {
      if (streams[i].owner != caller) { reply_error(ch, "not your stream"); return NULL; }
      return &streams[i];
    }
  reply_error(ch, "no such stream");
  return NULL;
}

/* a request (under the lock); a write that waits keeps its channel */
static void handle(int ch, int caller, const char * msg, unsigned int len)
{
  wire_reader r;
  unsigned int n;
  const char * id;
  int kind, i;
  struct stream * s;

  wire_reader_init(&r, msg, len);
  id = wire_get_string(&r, &n);
  if (!r.error && n == strlen(WIRE_DESCRIBE) && !memcmp(id, WIRE_DESCRIBE, n) &&
      wire_at_end(&r)) { describe(ch); return; }
  if (r.error || n != strlen(PROTOCOL) || memcmp(id, PROTOCOL, n)) {
    reply_error(ch, "protocol: soundd speaks " PROTOCOL);
    return;
  }
#define END() if (!wire_at_end(&r) || r.error) { reply_error(ch, "malformed request"); return; }
  kind = wire_get_int(&r);
  switch (kind) {
  case 0: {                                        /* info */
    wire_writer o;
    END();
    wire_writer_init(&o);
    wire_reply_ok(&o);
    wire_put_int(&o, RATE);
    wire_put_int(&o, 2);
    send_reply(ch, &o);
    break;
  }
  case 1:                                          /* open */
    END();
    for (i = 0; i < MAXSTREAM && streams[i].used; i++) ;
    if (i == MAXSTREAM) { reply_error(ch, "too many streams"); return; }
    s = &streams[i];
    s->used = 1;
    s->id = next_id++;
    s->owner = caller;
    s->closing = 0;
    s->head = s->count = 0;
    s->waiting = -1;
    s->closer = -1;
    s->rest = NULL;
    reply_int(ch, s->id);
    break;
  case 2: {                                        /* write */
    int sid = wire_get_int(&r);
    unsigned int dlen;
    const char * data = wire_get_string(&r, &dlen);
    END();
    if (!(s = owned(ch, sid, caller))) return;
    if (s->waiting >= 0 || s->closing) { reply_error(ch, "the stream is busy or closed"); return; }
    n = enqueue(s, data, dlen);
    if (dlen - n >= 4) {
      /* the rest waits for room: the card plays at its pace */
      s->rest = malloc(dlen - n);
      if (!s->rest) { reply_error(ch, "out of memory"); return; }
      memcpy(s->rest, data + n, dlen - n);
      s->rest_len = dlen - n;
      s->rest_off = 0;
      s->waiting = ch;
    } else
      reply_unit(ch);
    play();
    break;
  }
  case 3:                                          /* close */
  case 4: {                                        /* stop */
    int sid = wire_get_int(&r);
    END();
    if (!(s = owned(ch, sid, caller))) return;
    if (kind == 4) { drop(s); reply_unit(ch); }
    else if (s->closer >= 0) reply_error(ch, "the stream is closing");
    else if (s->count == 0 && s->waiting < 0) { drop(s); reply_unit(ch); }
    else { s->closing = 1; s->closer = ch; }      /* answered when played */
    break;
  }
  case 5: {                                        /* tone */
    int hz = wire_get_int(&r), ms = wire_get_int(&r);
    END();
    if (hz < 20 || hz > 11000 || ms < 1 || ms > 10000) {
      reply_error(ch, "a tone of 20 to 11000 Hz, 1 to 10000 ms");
      return;
    }
    for (i = 0; i < MAXTONE && tones[i].used; i++) ;
    if (i == MAXTONE) i = 0;                       /* the oldest gives way */
    tones[i].used = 1;
    tones[i].step = hz * 65536 / RATE;
    tones[i].left = RATE / 1000 * ms + RATE % 1000 * ms / 1000;
    tones[i].phase = 0;
    reply_unit(ch);
    play();
    break;
  }
  case 6: {                                        /* volume */
    int v = wire_get_int(&r);
    END();
    if (v >= 0) volume = v > 100 ? 100 : v;
    reply_int(ch, volume);
    break;
  }
  default:
    reply_error(ch, "unknown request");
  }
}

int main(void)
{
  int major, minor, sem, port;
  pthread_t t;

  if (dsp_reset() < 0) {
    mynos_log("soundd: no Sound Blaster at 0x220: no sound\n");
    return 0;
  }
  dsp_write(0xE1);
  major = dsp_read();
  minor = dsp_read();
  /* the card's IRQ and DMA channels (mixer 0x80, 0x81): IRQ 5, DMA 5 */
  if (!(mixer_read(0x80) & 0x02) || !(mixer_read(0x81) & 0x20)) {
    mynos_log("soundd: the Sound Blaster is not on IRQ 5 and DMA 5: no sound\n");
    return 0;
  }
  area = mynos_dmaArea(&area_phys);
  if (!area) {
    mynos_log("soundd: no DMA area from the kernel: no sound\n");
    return 0;
  }
  sem = mynos_driverRegister("sb16", SB_IRQ, NULL, NULL);
  if (sem < 0) {
    mynos_log("soundd: no IRQ %d (%d): no sound\n", SB_IRQ, sem);
    return 0;
  }
  mynos_enableIrq(SB_IRQ);
  dsp_write(0xD1);                                /* the speaker on */
  pthread_create(&t, NULL, irq_thread, (void *)(long)sem);

  port = mynos_registryRegister(SERVICE);
  if (port < 0) {
    mynos_log("soundd: cannot register (%d)\n", port);
    return 1;
  }
  mynos_log("soundd: Sound Blaster 16 (DSP %d.%02d), %d Hz stereo, service %s\n",
            major, minor, RATE, SERVICE);

  for (;;) {
    mynos_msg_t * m;
    int caller;
    int ch = mynos_listenPort(port);
    if (ch < 0) continue;
    if (mynos_recv(ch, &m, 0, 1000) < 0) { mynos_freeChannel(ch); continue; }
    caller = mynos_channelPeer(ch);
    pthread_mutex_lock(&lock);
    handle(ch, caller, m->start, m->size);
    pthread_mutex_unlock(&lock);
    mynos_freeMsg(&m);
  }
  return 0;
}
