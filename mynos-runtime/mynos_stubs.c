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

#include <mynos.h>

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

CAMLprim value caml_mynos_spawn(value path, value argv, value env)
{
  int ret;
  char * p = caml_stat_strdup(String_val(path));
  char ** a = c_strings(argv);
  char ** e = c_strings(env);
  caml_enter_blocking_section();
  ret = mynos_spawn(p, a, e);
  caml_leave_blocking_section();
  caml_stat_free(p);
  free_strings(a);
  free_strings(e);
  return check("spawn", ret);
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
