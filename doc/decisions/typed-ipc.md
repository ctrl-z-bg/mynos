# Decision: typed IPC between OCaml programs and services

- **Issue:** mynos-tc3 (typed IPC), before the network (mynos-4f6)
- **Date:** 2026-11-17
- **Status:** accepted and implemented (2026-11-17), by the owner after re-reading the 2002
  presentation (`doc/website/why.html`)

## Why

`why.html` wants MyNOS to give programs "a different, new, higher level and
yet strong abstraction to the machine through OCaml". After two days spent
on the Unix-like floor (files, a shell, a terminal), the services still talk
like C programs: fixed structs of 32-bit fields built by hand with
`Bytes.set_int32_le`, a status code, a second message for the data. Each
service and each client repeats that by hand, nothing checks that the two
sides agree, and from the OCaml toplevel a service is not something you can
call.

Typed IPC: a service's protocol is an OCaml type, and calling a service is
calling a function whose result has the type of the request:

```ocaml
type _ request =
  | Info  : int request                      (* the size, in sectors *)
  | Read  : int * int -> string request      (* lba, count -> bytes *)
  | Write : int * string -> unit request     (* lba, bytes *)

let disk = Block.connect ()
let mbr : string = Block.call disk (Read (0, 1))
```

The Unix-like layer stays (libmynos, the file services, `sh`): it is the
floor, for C programs and for the user's first steps. Typed IPC is what
OCaml programs, new services and the toplevel use.

## Choices

### What a protocol is

A module with a GADT of requests, indexed by the type of the reply, and
the codecs for both:

```ocaml
module type PROTOCOL = sig
  val id : string                        (* "block/1": name and version *)
  type 'a request
  type packed = Request : 'a request -> packed
  val write_request : Wire.writer -> 'a request -> unit
  val read_request : Wire.reader -> packed
  val reply : 'a request -> 'a Wire.t    (* the codec of each reply *)
end
```

`Ipc.Make (P)` gives the client (`connect`, `call : client -> 'a
P.request -> 'a`) and the server (`serve name { handle }`, with
`handle : 'a. 'a P.request -> 'a`). The type checker ties every request to
its reply on both sides. The request codecs are written by hand, so a test
encodes and decodes every request of every protocol.

### How values travel: a small wire format of our own (`Wire`)

Combinators (`int`, `string`, `list`, `option`, `pair`, `variant`...)
build a codec `'a Wire.t` that both writes and reads. The format:

| Value | Bytes |
|---|---|
| `int` | zigzag LEB128 (1 byte up to ±63, at most 10 bytes); out of range of the reader's `int`: an error |
| `bool` | one byte, 0 or 1 |
| `string` | its length as an `int`, then the bytes |
| `float` | IEEE 754 double, 8 bytes little endian |
| `option` | `bool`, then the value if present |
| `list`, `array` | the count as an `int`, then the elements |
| tuples, records | the fields in order |
| variants | the case number as an `int`, then its fields |

A message: request = protocol id (`string`) then the request; reply =
`0` then the value, or `1` then an error message (`string`).

Alternatives:

- **`Marshal`.** No code to write, but the reader trusts the bytes: a
  malformed or malicious message can crash a service, and the format is
  OCaml's (no C side) and changes with OCaml versions. Rejected: a
  service must survive any client.
- **A ppx deriving the codecs** (`ppx_deriving`, `bin_prot`): needs ppxlib
  in the build and inside MyNOS's `ocamlc`; the combinators are a few
  hundred lines and work in the toplevel. Possible later.
- **Protocol Buffers, Cap'n Proto, XDR:** schemas in another language and
  a generator; heavier than what MyNOS needs. Our format is close to a
  subset of protobuf's varints, simple to write in C (the network service,
  lwIP, will be in C: libmynos gets a `mynos_wire.h` then).

### Connections, errors

- One connection per call, as the existing services: connect, send the
  request, receive the reply, free the channel. Sessions (several calls on
  one channel, a service serving clients concurrently) can come later
  without changing the protocols.
- A request the service cannot decode, of another protocol (version) or
  with bytes left over gets an error reply; the service goes on.
- An exception raised by `handle` becomes the error reply: the client
  raises `Ipc.Remote_error (service, message)`. Protocols may also put
  expected errors in their reply types (`(_, error) result`).

## First users

1. The block protocol (`ata0`): `ata.ml` serves `Block.Protocol`, `Block`
   is its client (`fatfs` unchanged). Its C header `mynos_block.h` goes
   away: no C program uses it.
2. Then the network service (mynos-4f6), with the C side of `Wire`.
3. The file services (2026-11-18, mynos-7a1): **fs/1** replaces the C
   structs of `mynos_fs.h` (an 84-byte request, an 8-byte reply, data in
   extra messages). `Fs` (`mynos-lib/ocaml/fs.mli`) defines it: open,
   close, read, write, seek, list (a directory in one reply), remove,
   mkdir, rmdir, rename; errors are messages starting with a name
   (`not_found: ...`). tmpfs and fatfs serve it with a typed handler;
   memrofs (C, 2002) speaks it through `mynos_wire.h` and describes
   itself the same way (a test compares its description with `fs.ml`'s);
   libmynos is its client for every program. The client is the caller the
   kernel names (`channelPeer`), not a pid written in the request.
4. **The registry and the consoles** (2026-11-18, mynos-nty): the last two
   C protocols. registry/1 (register, lookup, list; module `Registry`)
   in the C registry, which is now in its own table as "registry" so that
   it can be described like any service; console/1 (read, mode, keymap,
   write, foreground; module `Console`) in consoled (C) and in each
   terminal window (OCaml). A terminal keeps reads waiting until there is
   input: `Ipc.Make` gained `decode` and `reply`, for services that answer
   later. libmynos speaks both for every program, with the same results as
   before. Tests compare consoled's and the registry's descriptions with
   the OCaml modules'. Every service of MyNOS now speaks typed IPC.
