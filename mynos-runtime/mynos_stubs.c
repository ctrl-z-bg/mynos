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
 * C primitives behind the OCaml library Mynos (mynos-lib/ocaml/mynos.ml):
 * thin wrappers around libmynos. Errors (negative MYNOS_ERR_* codes) raise
 * Mynos.Error (function name, code). Blocking calls release the runtime.
 *
 * Every "CAMLprim value caml_mynos_..." here is added to the runtime's
 * primitive table by gen_prims.sh.
 */

#include <sys/utsname.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <time.h>

#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/callback.h>
#include <caml/signals.h>

#include <caml/bigarray.h>
#include <mynos.h>
#include <sys/mman.h>

static void mynos_error(const char * fn, int code)
{
  static const value * exn = NULL;
  value args[2];
  if (exn == NULL) exn = caml_named_value("Mynos.Error");
  if (exn == NULL) caml_failwith(fn);
  args[0] = caml_copy_string(fn);
  args[1] = Val_int(code);
  caml_raise_with_args(*exn, 2, args);
}

static value check(const char * fn, int ret)
{
  if (ret < 0) mynos_error(fn, ret);
  return Val_int(ret);
}

/* ---- processes and time ---- */

CAMLprim value caml_mynos_getpid(value unit)
{
  return Val_int(getpid());
}

CAMLprim value caml_mynos_sleep_us(value usec)
{
  caml_enter_blocking_section();
  mynos_sleep(Long_val(usec));
  caml_leave_blocking_section();
  return Val_unit;
}

CAMLprim value caml_mynos_stats(value unit)
{
  CAMLparam1(unit);
  CAMLlocal1(r);
  mynos_stats_t st;
  mynos_stats(&st);
  r = caml_alloc_tuple(5);
  Store_field(r, 0, Val_int(st.numProcesses));
  Store_field(r, 1, Val_int(st.numThreads));
  Store_field(r, 2, Val_int(st.pid));
  Store_field(r, 3, Val_int(st.ppid));
  Store_field(r, 4, Val_int(st.freeppages));
  CAMLreturn(r);
}

/* ---- IPC ---- */

/* the message is copied out of the OCaml heap: the kernel maps the sender's
   pages into the receiver, and the GC may move or reuse OCaml memory */
CAMLprim value caml_mynos_send(value channel, value msg)
{
  CAMLparam2(channel, msg);
  int ret;
  size_t len = caml_string_length(msg);
  char * buf = malloc(len ? len : 1);
  if (buf == NULL) caml_raise_out_of_memory();
  memcpy(buf, String_val(msg), len);
  caml_enter_blocking_section();
  ret = mynos_send(Int_val(channel), buf, len, 0);
  caml_leave_blocking_section();
  free(buf);
  check("send", ret);
  CAMLreturn(Val_unit);
}

/* timeout in milliseconds, 0 = wait forever */
CAMLprim value caml_mynos_recv(value channel, value timeout_ms)
{
  CAMLparam2(channel, timeout_ms);
  CAMLlocal1(r);
  mynos_msg_t * msg = NULL;
  int ret;
  caml_enter_blocking_section();
  ret = mynos_recv(Int_val(channel), &msg, 0, Int_val(timeout_ms));
  caml_leave_blocking_section();
  if (ret < 0) mynos_error("recv", ret);   /* mynos_recv freed msg */
  r = caml_alloc_initialized_string(msg->size, msg->start ? msg->start : "");
  mynos_freeMsg(&msg);
  CAMLreturn(r);
}

CAMLprim value caml_mynos_free_channel(value channel)
{
  return check("free_channel", mynos_freeChannel(Int_val(channel)));
}

/* ---- ports ---- */

CAMLprim value caml_mynos_alloc_port(value unit)
{
  return check("alloc_port", mynos_allocPort());
}

CAMLprim value caml_mynos_connect(value port)
{
  int ret;
  caml_enter_blocking_section();
  ret = mynos_connectToPort(Int_val(port));
  caml_leave_blocking_section();
  return check("connect", ret);
}

CAMLprim value caml_mynos_listen(value port)
{
  int ret;
  caml_enter_blocking_section();
  ret = mynos_listenPort(Int_val(port));
  caml_leave_blocking_section();
  return check("listen", ret);
}

CAMLprim value caml_mynos_free_port(value port)
{
  return check("free_port", mynos_freePort(Int_val(port)));
}

CAMLprim value caml_mynos_change_port_owner(value port, value pid)
{
  return check("change_port_owner",
               mynos_changePortOwner(Int_val(port), Int_val(pid)));
}

/* ---- semaphores ---- */

CAMLprim value caml_mynos_sem_create(value n)
{
  return check("sem_create", mynos_initSem(Int_val(n)));
}

CAMLprim value caml_mynos_sem_p(value sem)
{
  int ret;
  caml_enter_blocking_section();
  ret = mynos_P(Int_val(sem));
  caml_leave_blocking_section();
  return check("sem_p", ret);
}

/* the kernel returns 0 if it took the semaphore, 1 if it would block */
CAMLprim value caml_mynos_sem_try_p(value sem)
{
  int ret = mynos_tryP(Int_val(sem));
  if (ret < 0) mynos_error("sem_try_p", ret);
  return Val_bool(ret == 0);
}

CAMLprim value caml_mynos_sem_v(value sem)
{
  return check("sem_v", mynos_V(Int_val(sem)));
}

CAMLprim value caml_mynos_sem_free(value sem)
{
  return check("sem_free", mynos_freeSem(Int_val(sem)));
}

/* ---- registry ---- */

CAMLprim value caml_mynos_registry_register(value name)
{
  int ret;
  char * n = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  ret = mynos_registryRegister(n);
  caml_leave_blocking_section();
  caml_stat_free(n);
  return check("registry_register", ret);
}

CAMLprim value caml_mynos_registry_lookup(value name)
{
  int ret;
  char * n = caml_stat_strdup(String_val(name));
  caml_enter_blocking_section();
  ret = mynos_registryLookUp(n);
  caml_leave_blocking_section();
  caml_stat_free(n);
  return check("registry_lookup", ret);
}

/* the registry's names: (name, port, owner) array */
CAMLprim value caml_mynos_registry_list(value unit)
{
  CAMLparam1(unit);
  CAMLlocal2(r, t);
  mynos_reg_entry_t es[128];
  int n, i;
  caml_enter_blocking_section();
  n = mynos_registryList(es, 128);
  caml_leave_blocking_section();
  if (n < 0) mynos_error("registry_list", n);
  r = caml_alloc(n, 0);
  for (i = 0; i < n; i++) {
    es[i].name[sizeof es[i].name - 1] = 0;
    t = caml_alloc_tuple(3);
    Store_field(t, 0, caml_copy_string(es[i].name));
    Store_field(t, 1, Val_int(es[i].port));
    Store_field(t, 2, Val_int(es[i].owner));
    Store_field(r, i, t);
  }
  CAMLreturn(r);
}

/* ---- processes ---- */

static char ** c_strings(value arr)
{
  mlsize_t i, n = Wosize_val(arr);
  char ** v = caml_stat_alloc((n + 1) * sizeof(char *));
  for (i = 0; i < n; i++) v[i] = caml_stat_strdup(String_val(Field(arr, i)));
  v[n] = NULL;
  return v;
}

static void free_strings(char ** v)
{
  char ** p;
  for (p = v; *p; p++) caml_stat_free(*p);
  caml_stat_free(v);
}

CAMLprim value caml_mynos_channel_peer(value channel)
{
  return check("channel_peer", mynos_channelPeer(Int_val(channel)));
}

CAMLprim value caml_mynos_process_info(value pid)
{
  return Val_int(mynos_processInfo(Int_val(pid)));
}

/* env: None, the child gets ours; Some array, exactly that one (even
   empty) */
CAMLprim value caml_mynos_spawn(value path, value argv, value env, value io)
{
  int ret;
  char * p = caml_stat_strdup(String_val(path));
  char ** a = c_strings(argv);
  char ** e = Is_block(env) ? c_strings(Field(env, 0)) : NULL;
  caml_enter_blocking_section();
  ret = mynos_spawnPriv(p, a, e, Bool_val(io) ? MYNOS_PRIV_IO : 0);
  caml_leave_blocking_section();
  caml_stat_free(p);
  free_strings(a);
  if (e) free_strings(e);
  return check("spawn", ret);
}

/* the system's version, as uname tells it (Mynos.version) */
CAMLprim value caml_mynos_version(value unit)
{
  struct utsname u;
  if (uname(&u) != 0) return caml_copy_string("unknown");
  return caml_copy_string(u.release);
}

/* the kernel's log: the position now (Mynos.log_position) */
CAMLprim value caml_mynos_klog_position(value unit)
{
  return Val_int(mynos_klog(0, NULL, 0));
}

/* the kernel's log from a position, at most max bytes (Mynos.log_read) */
CAMLprim value caml_mynos_klog_read(value from, value max)
{
  CAMLparam2(from, max);
  CAMLlocal1(r);
  int m = Int_val(max), n;
  char * buf;
  if (m < 1) m = 1;
  if (m > 65536) m = 65536;
  buf = malloc(m);
  if (buf == NULL) caml_raise_out_of_memory();
  n = mynos_klog(Int_val(from), buf, m);
  if (n < 0) { free(buf); check("klog", n); }
  r = caml_alloc_initialized_string(n, buf);
  free(buf);
  CAMLreturn(r);
}

/* (pid, Linux wait status) of a child that ended: pid > 0 for that child,
   -1 for any */
CAMLprim value caml_mynos_wait(value pid)
{
  CAMLparam1(pid);
  CAMLlocal1(r);
  int status = 0, ret;
  caml_enter_blocking_section();
  ret = waitpid(Int_val(pid), &status, 0);
  caml_leave_blocking_section();
  if (ret < 0) mynos_error("wait", MYNOS_ERR_INVALID);
  r = caml_alloc_tuple(2);
  Store_field(r, 0, Val_int(ret));
  Store_field(r, 1, Val_int(status));
  CAMLreturn(r);
}

/* ---- log ---- */

CAMLprim value caml_mynos_log(value msg)
{
  mynos_log("%s", String_val(msg));
  return Val_unit;
}

/* seconds since boot (CLOCK_MONOTONIC) */
CAMLprim value caml_mynos_uptime(value unit)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return caml_copy_double(ts.tv_sec + ts.tv_nsec / 1e9);
}

/* ---- drivers: port I/O and interrupts ----
   MyNOS processes run with IOPL 3: in and out work in user space. */

CAMLprim value caml_mynos_inb(value port)
{
  unsigned char v;
  __asm__ volatile ("inb %w1, %0" : "=a"(v) : "Nd"((unsigned short)Int_val(port)));
  return Val_int(v);
}

CAMLprim value caml_mynos_outb(value port, value v)
{
  __asm__ volatile ("outb %b0, %w1"
		    : : "a"((unsigned char)Int_val(v)),
		        "Nd"((unsigned short)Int_val(port)));
  return Val_unit;
}

CAMLprim value caml_mynos_inw(value port)
{
  unsigned short v;
  __asm__ volatile ("inw %w1, %0" : "=a"(v) : "Nd"((unsigned short)Int_val(port)));
  return Val_int(v);
}

CAMLprim value caml_mynos_outw(value port, value v)
{
  __asm__ volatile ("outw %w0, %w1"
		    : : "a"((unsigned short)Int_val(v)),
		        "Nd"((unsigned short)Int_val(port)));
  return Val_unit;
}

/* n 16-bit words from a port (rep insw), as a string of 2n bytes */
CAMLprim value caml_mynos_insw(value port, value n)
{
  CAMLparam2(port, n);
  CAMLlocal1(s);
  int words = Int_val(n);
  void * buf;
  if (words < 0) caml_invalid_argument("Mynos.insw");
  s = caml_alloc_string(2 * words);
  buf = Bytes_val(s);
  __asm__ volatile ("cld; rep insw"
		    : "+D"(buf), "+c"(words)
		    : "d"((unsigned short)Int_val(port)) : "memory");
  CAMLreturn(s);
}

/* the bytes of a string (even length) to a port, 16 bits at a time */
CAMLprim value caml_mynos_outsw(value port, value s)
{
  const void * buf = String_val(s);
  int words = caml_string_length(s) / 2;
  __asm__ volatile ("cld; rep outsw"
		    : "+S"(buf), "+c"(words)
		    : "d"((unsigned short)Int_val(port)) : "memory");
  return Val_unit;
}

/* register as the driver of an IRQ: returns the semaphore the kernel V's
   at each interrupt */
CAMLprim value caml_mynos_driver_register(value name, value irq)
{
  int ret;
  char * n = caml_stat_strdup(String_val(name));
  ret = mynos_driverRegister(n, Int_val(irq), NULL, NULL);
  caml_stat_free(n);
  return check("driver_register", ret);
}

CAMLprim value caml_mynos_enable_irq(value irq)
{
  return check("enable_irq", mynos_enableIrq(Int_val(irq)));
}

/* seconds since 1970 (CLOCK_REALTIME: the CMOS clock read at boot) */
CAMLprim value caml_mynos_time(value unit)
{
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return caml_copy_double(ts.tv_sec + ts.tv_nsec / 1e9);
}

/* ---- console ---- */

/* (a request to the console service: other threads run meanwhile) */
/* isig: 1 Ctrl-C an interrupt, 0 a key, -1 unchanged */
CAMLprim value caml_mynos_console_mode(value canon, value echo, value isig,
				       value vmin, value vtime)
{
  int c = Bool_val(canon), e = Bool_val(echo), s = Int_val(isig),
      m = Int_val(vmin), t = Int_val(vtime);
  caml_enter_blocking_section();
  mynos_consoleModeSig(c, e, s, m, t);
  caml_leave_blocking_section();
  return Val_unit;
}

CAMLprim value caml_mynos_console_foreground(value pid)
{
  int p = Int_val(pid);
  caml_enter_blocking_section();
  mynos_consoleForeground(p);
  caml_leave_blocking_section();
  return Val_unit;
}

/* ---- environment ---- */

extern char ** environ;

/* our environment, as "NAME=value" strings */
CAMLprim value caml_mynos_environment(value unit)
{
  CAMLparam1(unit);
  CAMLlocal1(r);
  int n = 0, i;
  while (environ && environ[n]) n++;
  r = caml_alloc(n, 0);
  for (i = 0; i < n; i++) Store_field(r, i, caml_copy_string(environ[i]));
  CAMLreturn(r);
}

/* ---- the event recorder ---- */

/* start, stop, free the buffer */
CAMLprim value caml_mynos_trace_control(value op)
{
  return check("trace", mynos_trace(Int_val(op), NULL, 0));
}

/* the events recorded so far, at most max of them (96 bytes each) */
CAMLprim value caml_mynos_trace_read(value max)
{
  CAMLparam1(max);
  CAMLlocal1(r);
  int n = Int_val(max);
  char * buf;
  if (n < 1) n = 1;
  buf = malloc(n * MYNOS_TRACE_EVENT_SIZE);
  if (buf == NULL) caml_raise_out_of_memory();
  n = mynos_trace(MYNOS_TRACE_READ, buf, n);
  if (n < 0) { free(buf); mynos_error("trace", n); }
  r = caml_alloc_initialized_string(n * MYNOS_TRACE_EVENT_SIZE, buf);
  free(buf);
  CAMLreturn(r);
}

/* a label in the recording (an event Mark), if one is on */
CAMLprim value caml_mynos_trace_mark(value label)
{
  return check("trace", mynos_trace(MYNOS_TRACE_MARK, (void *)String_val(label),
                                    caml_string_length(label)));
}

/* end a process */
CAMLprim value caml_mynos_kill(value pid)
{
  check("kill", mynos_kill(Int_val(pid)));
  return Val_unit;
}

/* the live processes: (pid, parent, privileges, threads, name) array */
CAMLprim value caml_mynos_processes(value unit)
{
  CAMLparam1(unit);
  CAMLlocal2(r, t);
  mynos_process_t ps[256];
  int n = mynos_processes(ps, 256), i;
  if (n < 0) mynos_error("processes", n);
  r = caml_alloc(n, 0);
  for (i = 0; i < n; i++) {
    char name[17];
    memcpy(name, ps[i].name, 16);
    name[16] = 0;
    t = caml_alloc_tuple(5);
    Store_field(t, 0, Val_int(ps[i].pid));
    Store_field(t, 1, Val_int(ps[i].ppid));
    Store_field(t, 2, Val_int(ps[i].privileges));
    Store_field(t, 3, Val_int(ps[i].threads));
    Store_field(t, 4, caml_copy_string(name));
    Store_field(r, i, t);
  }
  CAMLreturn(r);
}

/* the page faults resolved: a process's, or the system's (pid 0) */
CAMLprim value caml_mynos_faults(value pid)
{
  CAMLparam1(pid);
  CAMLlocal1(r);
  unsigned int out[2];
  int e = mynos_faults(Int_val(pid), out);
  if (e < 0) mynos_error("faults", e);
  r = caml_alloc_tuple(2);
  Store_field(r, 0, Val_long(out[0]));
  Store_field(r, 1, Val_long(out[1]));
  CAMLreturn(r);
}

/* ---- the external pager (native 37, module Pager) ---- */

CAMLprim value caml_mynos_pager_register(value unit)
{
  int r = mynos_pagerRegister();
  if (r < 0) mynos_error("pager_register", r);
  return Val_int(r);
}

/* a region of pid's memory: its first page's number (addresses do not fit
   in OCaml's 31-bit ints) */
CAMLprim value caml_mynos_pager_region(value pid, value npages, value token, value writable)
{
  void * a = mynos_pagerRegion(Int_val(pid), Long_val(npages), Long_val(token),
                               Bool_val(writable));
  if (a == NULL) mynos_error("pager_region", MYNOS_ERR_INVALID);
  return Val_long((unsigned long)a >> 12);
}

/* the next page waited for: (pid, page, token, write); waits on the
   pager's semaphore, letting other threads run */
CAMLprim value caml_mynos_pager_wait(value sem)
{
  CAMLparam1(sem);
  CAMLlocal1(r);
  mynos_pager_fault_t f;
  while (mynos_pagerNext(&f) != 1) {
    caml_enter_blocking_section();
    mynos_P(Int_val(sem));
    caml_leave_blocking_section();
  }
  r = caml_alloc_tuple(4);
  Store_field(r, 0, Val_int(f.pid));
  Store_field(r, 1, Val_long(f.addr >> 12));
  Store_field(r, 2, Val_long(f.token));
  Store_field(r, 3, Val_bool(f.write));
  CAMLreturn(r);
}

/* a page for pid at page: the bytes of data (at most 4096, then zeros),
   moved through a page of ours that the kernel gives away (and makes
   fresh again); data None: no page, that process ends */
static char * pager_page;
CAMLprim value caml_mynos_pager_supply(value pid, value page, value data)
{
  int r;
  void * at = (void *)((unsigned long)Long_val(page) << 12);
  if (Is_none(data)) r = mynos_pagerSupply(Int_val(pid), at, NULL);
  else {
    value s = Some_val(data);
    size_t n = caml_string_length(s);
    if (n > 4096) n = 4096;
    if (pager_page == NULL &&
        (pager_page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)) == MAP_FAILED) {
      pager_page = NULL;
      caml_raise_out_of_memory();
    }
    memcpy(pager_page, String_val(s), n);
    memset(pager_page + n, 0, 4096 - n);
    r = mynos_pagerSupply(Int_val(pid), at, pager_page);
  }
  if (r < 0) mynos_error("pager_supply", r);
  return Val_unit;
}

/* npages of our memory from page on, as bytes (a region the pager gives) */
CAMLprim value caml_mynos_pager_bytes(value page, value npages)
{
  return caml_ba_alloc_dims(CAML_BA_UINT8 | CAML_BA_C_LAYOUT | CAML_BA_EXTERNAL, 1,
                            (void *)((unsigned long)Long_val(page) << 12),
                            (intnat)Long_val(npages) * 4096);
}

CAMLprim value caml_mynos_pager_unmap(value page, value npages)
{
  if (munmap((void *)((unsigned long)Long_val(page) << 12), Long_val(npages) * 4096) != 0)
    mynos_error("munmap", MYNOS_ERR_INVALID);
  return Val_unit;
}

/* the recorder's state: 9 words, as a 36-byte string */
CAMLprim value caml_mynos_trace_info(value unit)
{
  unsigned int w[9];
  int ret = mynos_trace(MYNOS_TRACE_INFO, w, 0);
  if (ret < 0) mynos_error("trace", ret);
  return caml_alloc_initialized_string(sizeof w, (char *)w);
}
