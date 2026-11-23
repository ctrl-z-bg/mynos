# 16. IPC: Ports, Channels, the Name Registry

Processes in MyNOS talk through the kernel's IPC: a server owns a
**port**; a client connects to it and gets a **channel**; the two send
**messages** on it. A process that wants to be found registers a
**name** with the registry, an ordinary process at the well-known port 0.
This chapter shows how to use these from C and from OCaml, and ends with
a client and a server that exchange raw messages. Every service of MyNOS
speaks typed IPC (chapter 17), which is built on exactly these calls;
reading this chapter first explains what typed IPC does for you. How the
kernel keeps ports, channels and messages is in appendix C.

## 16.1 The calls

```
   server                                            client
   ──────                                            ──────
   port = register("upper") ──── registry ───── port = lookup("upper")
   ch = listen(port)   ◄──── a new channel ────►  ch = connect(port)
   msg = recv(ch)      ◄──────── request ───────  send(ch, request)
   send(ch, reply)     ──────── reply ─────────►  reply = recv(ch)
   free_channel(ch)                               free_channel(ch)
```

| What | C (`mynos.h`) | OCaml (`Mynos`) |
|---|---|---|
| a new port, ours | `mynos_allocPort()` | `alloc_port ()` |
| a well-known port 0–15 (`io` only) | `mynos_allocPortP(n)` | — |
| wait for a client: our end | `mynos_listenPort(port)` | `listen port` |
| connect: our end | `mynos_connectToPort(port)` | `connect port` |
| send a message | `mynos_send(ch, buf, size, flags)` | `send ch s` |
| receive the next message | `mynos_recv(ch, &msg, 0, timeout_ms)` | `recv ?timeout ch` |
| release a received message | `mynos_freeMsg(&msg)` | (a string: the GC) |
| close our end | `mynos_freeChannel(ch)` | `free_channel ch` |
| the pid at the other end | `mynos_channelPeer(ch)` | `channel_peer ch` |
| free a port / give it away | `mynos_freePort`, `mynos_changePortOwner` | `free_port`, `change_port_owner` |
| register a name: a new port | `mynos_registryRegister(name)` | `register name` |
| the port of a name | `mynos_registryLookUp(name)` | `lookup name` |
| every name | `mynos_registryList(buf, max)` | `registered ()` |

C calls return a negative `MYNOS_ERR_*` code on failure (14.2). The
OCaml functions raise `Mynos.Error (function, code)`; `Mynos.error_name
code` gives `"full"`, `"busy"`, `"invalid"`, `"deny"`, `"broken"` or
`"expired"`.

## 16.2 Ports and channels

A port is a number, owned by the process that allocated it. Only its
owner may `listen` on it, one thread at a time (a second listener gets
`MYNOS_ERR_BUSY`). `listen` waits until a client connects, and returns
the server's end of a new channel; `connect` waits until a listener
accepts, and returns the client's end. Neither has a timeout. Up to 10
clients can wait on a port at once; the eleventh `connect` fails with
`MYNOS_ERR_BUSY`. When a port's owner ends, the kernel frees the port
and wakes its waiting clients with `MYNOS_ERR_BROKEN`.

A channel has two ends with different ids; each process uses only its
own. Each end is freed by its process with `free_channel`. After one side
has freed its end, the other side's `send` fails with `MYNOS_ERR_BROKEN`,
and its `recv` returns what is still queued, then `MYNOS_ERR_BROKEN`. A
process that ends frees all its ends; that is how a service learns that
a client has gone, and a client that its service has.

A channel can carry any number of messages in both directions, and lasts
until both ends are freed. MyNOS's services use it for one call:
connect, send one request, receive one reply, free. A service that
listens on one port serves its clients one after the other, so a client
that connects and sends nothing must not be allowed to stop it: always
receive the first message with a timeout.

## 16.3 Messages

`send` takes a buffer and its size. A message of at most 8 bytes
(`MYNOS_SHORT_MESSAGE_SIZE`) is copied through the kernel; a longer one
is not copied at all: its pages are mapped into the receiver,
copy-on-write in both processes (appendix C.4). Two consequences matter
to a program:

- **`send` waits** until the receiver has taken the message, unless the
  flag `MYNOS_IPC_NONBLOCK` is given; then it returns once the message
  is queued (10 at most per end: then `MYNOS_ERR_FULL`). A send to a
  process that never receives waits for ever, or until that process
  ends.
- **Whole pages travel.** The receiver can read whatever else the sender
  kept in the first and last page of a long message. Send from a buffer
  that holds nothing else: a page-aligned one (`posix_memalign`) when it
  matters. OCaml's `send` copies the string into a buffer of its own
  first, because the garbage collector may move it.

`recv` waits for the next message. Its last argument is a timeout in
milliseconds (0: wait for ever), counted in 1 ms ticks; when it passes,
`recv` returns `MYNOS_ERR_EXPIRED`. Only one thread may receive on an end
at a time (`MYNOS_ERR_BUSY`). In C the message comes as a description:

```c
typedef struct {
  void * start;          /* the bytes: in a small buffer, or in pages
                            mapped for this message */
  unsigned int size;
  int isShort;
} mynos_msg_t;
```

`mynos_recv` allocates it; `mynos_freeMsg(&msg)` releases it, unmapping
the pages of a long message. Release every message, or the pages stay
mapped. In OCaml, `recv` returns the bytes as a `string`, and
`~timeout` is in seconds:

```ocaml
match Mynos.recv ~timeout:2.0 ch with
| msg -> ...
| exception Mynos.Error (_, code) when Mynos.error_name code = "expired" -> ...
```

A message may be empty: `mynos_signalSync(ch)` sends one,
`mynos_waitSync(ch)` waits for one; a pure synchronization.

## 16.4 The registry

The kernel knows ports by number; names are kept by the **registry**
(`services/registry/registry.c`), a process that answers at port 0 and
speaks registry/1 (appendix E.5). `libmynos` talks to it for you:

- `register name` asks for a **new port**, owned by the caller, under
  `name` (at most 20 characters). A name belongs to its process while it
  runs; registering one that is taken fails (`MYNOS_ERR_INVALID` in C,
  `Mynos.Error ("registry_register", -3)` in OCaml).
- `lookup name` gives the port of a name, or fails the same way.
- `registered ()` lists `(name, port, owner)` for the live processes (at
  most 128 in OCaml); in C `mynos_registryList` fills
  `mynos_reg_entry_t` records.

At boot the registry starts together with everything else; `libmynos`
retries the connection to port 0 for two seconds, so an early lookup
waits for the registry rather than failing. It does not wait for the
name: a client started at the same time as its service looks the name up
again until it is there (16.5). When a service ends, its names go with
it; when `init` restarts it, it registers again and gets a **new port**.
A client that kept the old port must look the name up again: typed IPC
clients (chapter 17) and `libmynos`'s file and console requests do.

The OCaml module `Registry` speaks registry/1 typed, with the errors as
text:

```ocaml
# Registry.call (Registry.Lookup "greeter");;
- : int = 20024
# Registry.call (Registry.Lookup "nobody");;
Exception: Ipc.Remote_error ("registry", "not_found: no such name").
```

The command `ps` in `sh` shows each process with the names it registered.

## 16.5 A complete example: upper

A service that answers every message with the same bytes in capitals,
and two clients of it. First the service, in C:

```c
/* upper.c: a service of raw messages. It registers the name "upper"
   and answers every message with the same bytes in capitals. */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <mynos.h>

int main(void)
{
  int port = mynos_registryRegister("upper");
  if (port < 0) {
    printf("upper: cannot register (%d)\n", port);
    return 1;
  }
  for (;;) {
    mynos_msg_t * msg;
    char * reply;
    unsigned int i;
    int ch = mynos_listenPort(port);       /* wait for a client */
    if (ch < 0) continue;
    /* a client that connects and sends nothing must not stop us: 1 s */
    if (mynos_recv(ch, &msg, 0, 1000) < 0) {
      mynos_freeChannel(ch);
      continue;
    }
    mynos_log("upper: %u bytes from pid %d", msg->size, mynos_channelPeer(ch));
    if ((reply = malloc(msg->size + 1)) != NULL) {
      for (i = 0; i < msg->size; i++)
        reply[i] = toupper(((unsigned char *)msg->start)[i]);
      mynos_send(ch, reply, msg->size, 0);
      free(reply);
    }
    mynos_freeMsg(&msg);
    mynos_freeChannel(ch);
  }
}
```

The service learns who calls from the kernel (`mynos_channelPeer`), not
from the message. A client in C, which looks the name up until the
service has registered, and waits at most two seconds for the reply:

```c
/* lower.c: a client of "upper" */
#include <stdio.h>
#include <string.h>
#include <mynos.h>

int main(int argc, char ** argv)
{
  char * text = argc > 1 ? argv[1] : "hello, world";
  mynos_msg_t * msg;
  int port = -1, ch, r, tries;

  /* at boot the service may not have registered yet: try for 2 s */
  for (tries = 0; tries < 20; tries++) {
    if ((port = mynos_registryLookUp("upper")) >= 0) break;
    mynos_sleep(100000);
  }
  if (port < 0) { printf("lower: no service \"upper\"\n"); return 1; }

  if ((ch = mynos_connectToPort(port)) < 0) return 1;
  if (mynos_send(ch, text, strlen(text), 0) < 0) return 1;
  r = mynos_recv(ch, &msg, 0, 2000);       /* the reply, within 2 s */
  if (r == MYNOS_ERR_EXPIRED)
    printf("lower: no answer\n");
  else if (r >= 0) {
    printf("lower: %.*s\n", (int)msg->size, (char *)msg->start);
    mynos_freeMsg(&msg);
  }
  mynos_freeChannel(ch);
  return 0;
}
```

The same client in OCaml. `Fun.protect` frees the channel whatever
happens:

```ocaml
(* lower.ml: a client of "upper", in OCaml *)
let ask text =
  let ch = Mynos.connect (Mynos.lookup "upper") in
  Fun.protect ~finally:(fun () -> Mynos.free_channel ch) (fun () ->
      Mynos.send ch text;
      Mynos.recv ~timeout:2.0 ch)

let () =
  Mynos.sleep 1.0;                        (* let the service register *)
  match ask "hello from OCaml" with
  | answer -> print_endline answer
  | exception Mynos.Error (fn, code) ->
    Printf.printf "lower: %s: %s\n" fn (Mynos.error_name code)
```

And the service in OCaml, for comparison:

```ocaml
(* upper.ml: the same service in OCaml *)
let () =
  let port = Mynos.register "upper" in
  while true do
    let ch = Mynos.listen port in
    (try
       let msg = Mynos.recv ~timeout:1.0 ch in
       Mynos.log (Printf.sprintf "upper: %d bytes from pid %d"
                    (String.length msg) (Mynos.channel_peer ch));
       Mynos.send ch (String.uppercase_ascii msg)
     with Mynos.Error (fn, code) ->
       Mynos.log (Printf.sprintf "upper: %s: %s" fn (Mynos.error_name code)));
    Mynos.free_channel ch
  done
```

Started as boot modules, the C service with both clients (`lower shout`
and `lower.byte`), the log shows:

```
upper: 5 bytes from pid 4
lower: SHOUT
upper: 16 bytes from pid 1
HELLO FROM OCAML
```

and the OCaml service with the C client (`lower from-c`):

```
upper: 6 bytes from pid 3
lower: FROM-C
```

The two services are interchangeable: a client sees a name, a port and
bytes, and cannot tell which language answers. That is also the weakness
of raw messages. Nothing says what the bytes mean, what a malformed
request gets, or how an error is told from an answer: the service and
its clients agree by convention only. Typed IPC (chapter 17) writes the
agreement down as an OCaml type, and its wire format can be spoken from
C too (`mynos_wire.h`).

## 16.6 Shared messages

With the flag `MYNOS_IPC_SHARED`, the pages of a message are mapped into
the receiver **shared** instead of copy-on-write: from then on each sees
the other's writes, until the receiver unmaps them (`mynos_freeMsg`).
That is how a window's pixels reach the display server (chapter 20). A
service that writes into its client's page:

```c
/* ticker.c: a service that writes into its client's memory. The client
   sends a page with MYNOS_IPC_SHARED; the service writes a line in it
   five times, then answers "done". */
#include <stdio.h>
#include <mynos.h>

int main(void)
{
  int port = mynos_registryRegister("ticker");
  for (;;) {
    mynos_msg_t * msg;
    int ch = mynos_listenPort(port), i;
    if (ch < 0) continue;
    if (mynos_recv(ch, &msg, 0, 1000) < 0) { mynos_freeChannel(ch); continue; }
    for (i = 1; i <= 5; i++) {
      snprintf(msg->start, msg->size, "tick %d from the service", i);
      mynos_sleep(200000);
    }
    mynos_send(ch, "done", 4, 0);
    mynos_freeMsg(&msg);                     /* unmaps the shared page */
    mynos_freeChannel(ch);
  }
}
```

The client sends one page of its own, aligned so that nothing else is
shared, and looks at it each time its `recv` times out:

```c
/* watch.c: a client of "ticker": it watches its own page change */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mynos.h>

int main(void)
{
  char * page;
  mynos_msg_t * msg;
  int ch, port = -1, tries;

  for (tries = 0; tries < 20 && port < 0; tries++) {
    port = mynos_registryLookUp("ticker");
    if (port < 0) mynos_sleep(100000);
  }
  if (port < 0 || posix_memalign((void **)&page, 4096, 4096)) return 1;
  strcpy(page, "nothing yet");
  ch = mynos_connectToPort(port);
  mynos_send(ch, page, 4096, MYNOS_IPC_SHARED);
  /* wait for the reply in steps of 300 ms, looking at the page meanwhile */
  while (mynos_recv(ch, &msg, 0, 300) == MYNOS_ERR_EXPIRED)
    printf("watch: the page says \"%s\"\n", page);
  printf("watch: reply \"%.*s\", the page says \"%s\"\n",
         (int)msg->size, (char *)msg->start, page);
  mynos_freeMsg(&msg);
  mynos_freeChannel(ch);
  return 0;
}
```

```
watch: the page says "tick 2 from the service"
watch: the page says "tick 3 from the service"
watch: the page says "tick 5 from the service"
watch: reply "done", the page says "tick 5 from the service"
```

(Without a console service, the first `printf` waits about a second for
one, chapter 14.7, and the first lines are missing.) A shared page is
memory that two processes write: they must agree who writes when, here
by the reply. `Mynos.send` in OCaml never shares; `Gfx.send_shared` is
the one OCaml call that does, for windows.

## 16.7 Writing a raw service

A service must survive any client (appendix E.1). With raw messages
that is the programmer's job:

- receive the first message with a timeout, and free the channel on
  every path;
- check the size before reading a message, and never trust its bytes:
  a length inside it is a claim, not a fact;
- ask the kernel who calls (`channel_peer`), never believe a pid or a
  name written in the request;
- reply to every request, errors included, in a form the client can
  tell from an answer;
- send replies from buffers that hold nothing else (16.3).

A new service should rather be written with typed IPC, which does all of
this once, for every protocol (chapter 17).

## 16.8 Known limits

- `connect` and `listen` have no timeout.
- One receiver per end, one listener per port; 10 messages queued per
  end, 10 clients waiting per port.
- There is no call that waits on several channels at once: use a thread
  or a domain for each wait (chapter 15).
- A long message reveals the rest of its first and last page (16.3).
- Registry names are at most 20 characters.
