# 17. Typed IPC

Chapter 16 sent bytes. Every service of MyNOS sends **values** instead:
its protocol is an OCaml type, a request is a value of that type, and the
type checker ties each request to the type of its reply, on the client's
side and on the service's. This chapter shows how to write such a
protocol, serve it and call it: the codecs of `Wire`, the protocol as a
GADT, the functor `Ipc.Make`, the caller and the errors, the description
every service gives of itself, services that answer later, and calls
from the toplevel and from C. The format on the wire and the history are
in appendix E.2 and in `doc/decisions/typed-ipc.md`; the interfaces are
`mynos-lib/ocaml/wire.mli` and `ipc.mli`.

## 17.1 Codecs

A **codec** `'a Wire.t` writes values of type `'a` and reads them back.
Reading checks everything: a malformed message raises `Wire.Error` and
nothing else, so a service cannot be crashed or made to allocate much by
what a client sends.

| Codec | Values | On the wire |
|---|---|---|
| `unit`, `bool`, `int`, `float`, `string` | the basic types | nothing; one byte; zigzag LEB128; 8 bytes; length and bytes |
| `option c`, `list c`, `array c` | `'a option`, `'a list`, `'a array` | a `bool`, or a count, then the values |
| `pair a b`, `triple a b c` | tuples | the components in order |
| `result a b` | `('a, 'b) result` | case 0 `Ok`, case 1 `Error` |
| `conv f g c` | any `'a`, written as `c`'s type | as `c` |
| `variant [case ...]` | a sum type | the case number, then its value |
| `fix (fun t -> ...)` | a recursive type | |
| `field "name" c` | the same as `c` | the same; the name is for descriptions |

`Wire.to_string c v` and `Wire.of_string c s` encode and decode a whole
message; `Wire.writer`, `Wire.write`, `Wire.reader`, `Wire.read` and
`Wire.at_end` do it piece by piece. A record goes through `conv` as a
tuple; a sum type is a list of cases, each with its number, its codec,
how to build the value and how to recognize it:

```ocaml
type entry = { name : string; size : int }

let entry =
  Wire.(conv (fun e -> (e.name, e.size)) (fun (name, size) -> { name; size })
          (pair (field "name" string) (field "size" int)))

type figure = Circle of int | Rect of int * int

let figure =
  Wire.(variant [
      case ~name:"circle" 0 int (fun r -> Circle r)
        (function Circle r -> Some r | _ -> None);
      case ~name:"rect" 1 (pair int int) (fun (w, h) -> Rect (w, h))
        (function Rect (w, h) -> Some (w, h) | _ -> None) ])
```

`Wire.to_string (Wire.list entry) [ { name = "a.txt"; size = 300 } ]` is
the nine bytes `02 0A 61 2E 74 78 74 D8 04` (a count of 1, a string of
5, then 300); `Wire.to_string figure (Rect (2, 3))` is `02 04 06`; and
`Wire.of_string figure "\004"` raises `Wire.Error "unknown case 2"`.
Integers are zigzag-encoded, so small negative numbers are short too.

## 17.2 A protocol is a GADT

A protocol's requests are the constructors of one type, indexed by the
type of their reply:

```ocaml
type _ request = Hello : string -> string request
```

`Hello "Ada"` has type `string request`: a request whose reply is a
`string`. A service with several requests has one constructor each, with
different reply types (`Get : string -> string option request`,
`Keys : string list request`). From such a type, `Ipc.Make` derives
`call : client -> 'a request -> 'a`: the reply has the type the request
promised, checked at compile time, and the service's handler must return
it.

To be served, the type must come with its codecs, in a module of
signature `Ipc.PROTOCOL`:

| Member | What it is |
|---|---|
| `id : string` | name and version, `"greeter/1"`: a service refuses requests of another id |
| `summary : string` | what the service does, for people and language models |
| `requests : Ipc.request_doc list` | each request's case number, name, documentation, argument and reply codecs, and whether it is `safe` (it only reads) |
| `type 'a request` | the GADT |
| `type packed = Request : 'a request -> packed` | a request of any reply type, as the reader returns it |
| `write_request : Wire.writer -> 'a request -> unit` | the case number, then the arguments |
| `read_request : Wire.reader -> packed` | the inverse; `Wire.Error` on an unknown case |
| `reply : 'a request -> 'a Wire.t` | the codec of each request's reply |

The case numbers in `requests` must be those `write_request` writes. The
request codecs are written by hand, three small functions; a test that
encodes and decodes every request is cheap and worth having.

## 17.3 The example: greeter, piece by piece

`tests/greeter/greeter.ml` is a whole service in 41 lines: one program
that serves, or calls the service, depending on its arguments. The
tests start it from `sh` and from the agent, kill it, and check that a
client finds it again after it is restarted.

```ocaml
type _ request = Hello : string -> string request
```

The protocol type, outside the module, so that clients write `Hello
name` without a prefix.

```ocaml
module Protocol = struct
  let id = "greeter/1"
  let summary = "Greets: an example service."
  let requests = Ipc.[
      request ~safe:true 0 "hello" "A greeting for someone." Wire.string Wire.string ]
```

The identity and the documentation. `Ipc.request ~safe case name doc
args reply` makes one `request_doc`: case 0, its name, a sentence, the
codec of its argument and of its reply. `~safe:true` says that it
changes nothing; a language model may call it without asking (chapter
21).

```ocaml
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
```

`PROTOCOL` asks for a type `'a request` inside the module. These two
lines make the module's `request` equal to the GADT outside it (`r` only
names the outer type before the inner one hides it), so that `Hello` is
a `Protocol.request` too.

```ocaml
  let write_request (type a) w (r : a request) =
    match r with Hello name -> Wire.write w Wire.int 0; Wire.write w Wire.string name
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request (Hello (Wire.read r Wire.string))
    | n -> raise (Wire.Error (Printf.sprintf "greeter: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function Hello _ -> Wire.string
end
```

The codecs. `(type a)` and `type a.` give the functions the
polymorphism a GADT needs: in the branch `Hello _` the checker knows that
`a` is `string`, so `Wire.string` is an `a Wire.t`.

```ocaml
module I = Ipc.Make (Protocol)
```

The client and the server of greeter/1.

```ocaml
let () =
  match Sys.argv with
  | [| _; name |] -> print_endline (I.call (I.connect "greeter") (Hello name))
  | [| _; name; secs |] ->
    let c = I.connect "greeter" in
    print_endline (I.call c (Hello name));
    Mynos.sleep (float_of_string secs);
    print_endline (I.call c (Hello (name ^ " again")))
  | _ ->
    I.serve "greeter" { I.handle = fun (type a) _ (r : a request) : a ->
        match r with Hello name -> "Hello, " ^ name ^ ", from MyNOS!" }
```

With a name, the program is a client: `I.connect "greeter"` looks the
name up, `I.call` sends one request and returns its reply, a `string`.
With two arguments it calls twice on the same client, a while apart: if
the service was restarted meanwhile, under a new port, `call` finds it
again by its name. With none, the program is the service: `I.serve`
registers the name and answers for ever. The handler is a record
because it must be polymorphic, `'a. caller -> 'a request -> 'a`: one
function that answers every request with the reply's own type. Its first
argument, ignored here, is the caller (17.5).

```
mynos:/$ /disk/greeter.byte &
[25]
mynos:/$ /disk/greeter.byte Ada
Hello, Ada, from MyNOS!
```

## 17.4 What `Ipc.Make` gives

| Function | For | What it does |
|---|---|---|
| `connect name` | clients | a client of the service registered under `name` (it is looked up now) |
| `call c req` | clients | connect, send `req`, wait for the reply, free the channel: the reply, typed |
| `serve name h` | services | register `name`, then answer requests one at a time, for ever |
| `serve_port port h` | services | the same on a port already owned |
| `decode msg` | services that answer later | `Ok (Request r)`, or `Error reply` to send at once |
| `reply req v`, `error_reply m` | the same | the reply message, Ok or Error |
| `request_message`, `answer`, `read_reply` | tests | a request's bytes; a handler's reply to them; a reply read |

`serve` waits at most a second for a client's request, so a client that
connects and sends nothing cannot stop the service; it asks the kernel
for the caller's pid and privilege, answers, and frees the channel; a
failure on one channel is written to the log and the loop goes on.
`call` has no timeout: it waits as long as the service takes. When the
service's port has gone, `call` looks the name up again for up to three
seconds (while `init` restarts it) and connects to the new port; a
request is never sent twice.

## 17.5 The caller, and errors

The handler's first argument says who sent the request, from the
kernel, not from the message (appendix E.1):

```ocaml
type caller = { pid : int; io : bool }   (* Ipc.caller *)
```

**Errors.** Any exception raised by a handler becomes the reply: an
Error with the exception's message (that of `Failure`, `Invalid_argument`
and `Sys_error`, else `Printexc.to_string`). The client's `call` then
raises `Ipc.Remote_error (service, message)`. By convention a message
starts with a name and a colon (`not_found: ...`, `denied: ...`), so
that a program can tell errors apart (`Fs.error_of` does it for fs/1).
A request the service cannot decode, of another protocol, or with bytes
left over, gets an Error reply too, and the service goes on. A reply the
client cannot decode raises `Ipc.Protocol_error`; a service that is not
there, `Mynos.Error`. Expected failures can also be part of the reply's
type: `Get : string -> string option request`.

`kv.ml` is a small table of strings that shows both. It has three
requests, a record of arguments, an option in a reply, and a rule that
depends on the caller:

```ocaml
(* kv.ml: a typed service, "kv/1": a table of strings in memory.

     kv                 serve, forever
     kv set KEY VALUE   ask the service
     kv get KEY
     kv keys *)

type _ request =
  | Set : string * string -> unit request
  | Get : string -> string option request
  | Keys : string list request

module Protocol = struct
  let id = "kv/1"
  let summary = "A table of strings, kept in memory."

  let key = Wire.(field "key" string)
  let set_args = Wire.(pair key (field "value" string))

  let requests = Ipc.[
      request 0 "set" "Give a key a value (keys sys.* only from drivers)."
        set_args Wire.unit;
      request ~safe:true 1 "get" "The value of a key, if it has one."
        key Wire.(option string);
      request ~safe:true 2 "keys" "Every key, in order." Wire.unit Wire.(list string) ]

  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    match r with
    | Set (k, v) -> Wire.write w Wire.int 0; Wire.write w set_args (k, v)
    | Get k -> Wire.write w Wire.int 1; Wire.write w key k
    | Keys -> Wire.write w Wire.int 2; Wire.write w Wire.unit ()

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> let k, v = Wire.read r set_args in Request (Set (k, v))
    | 1 -> Request (Get (Wire.read r key))
    | 2 -> Wire.read r Wire.unit; Request Keys
    | n -> raise (Wire.Error (Printf.sprintf "kv: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Set _ -> Wire.unit
    | Get _ -> Wire.(option string)
    | Keys -> Wire.(list string)
end

module Kv = Ipc.Make (Protocol)

let table : (string, string) Hashtbl.t = Hashtbl.create 16

let handle : type a. Ipc.caller -> a request -> a = fun caller r ->
  match r with
  | Set (k, v) ->
    if k = "" then invalid_arg "invalid: an empty key";
    if String.starts_with ~prefix:"sys." k && not caller.Ipc.io then
      failwith "denied: sys.* keys are for drivers";
    Hashtbl.replace table k v
  | Get k -> Hashtbl.find_opt table k
  | Keys -> List.sort compare (Hashtbl.fold (fun k _ l -> k :: l) table [])

let () =
  match Sys.argv with
  | [| _ |] -> Kv.serve "kv" { Kv.handle = handle }
  | [| _; "set"; k; v |] -> Kv.call (Kv.connect "kv") (Set (k, v))
  | [| _; "get"; k |] ->
    print_endline (Option.value ~default:"(none)" (Kv.call (Kv.connect "kv") (Get k)))
  | [| _; "keys" |] -> List.iter print_endline (Kv.call (Kv.connect "kv") Keys)
  | _ -> prerr_endline "usage: kv [set KEY VALUE | get KEY | keys]"; exit 2
```

A handler written as a `let` with `type a.` is polymorphic, and can be
put in the record as it is. Run as the service and then as clients, from
a program without the `io` privilege:

```
$ kv.byte set colour green
$ kv.byte set sys.mode fast
Fatal error: exception Ipc.Remote_error("kv", "denied: sys.* keys are for drivers")
$ kv.byte get colour
green
$ kv.byte keys
colour
```

## 17.6 Descriptions and tools

Every service made with `Ipc.Make` answers a request whose protocol id is
`"describe"` with its description: the `id`, the `summary` and the
`requests`, with the **shapes** of their arguments and replies
(`Wire.shape`: the structure of a codec, as data). `Ipc.describe name`
asks for it:

```ocaml
let d = Ipc.describe "kv" in
Printf.printf "%s: %s\n" d.Ipc.protocol d.Ipc.summary;
List.iter (fun (r : Ipc.request_doc) ->
    Printf.printf "  %d %s%s: %s\n" r.case r.name (if r.safe then " (safe)" else "") r.doc)
  d.Ipc.requests
```

```
kv/1: A table of strings, kept in memory.
  0 set: Give a key a value (keys sys.* only from drivers).
  1 get (safe): The value of a key, if it has one.
  2 keys (safe): Every key, in order.
```

From a description alone, module `Tools` makes each request a tool
named `SERVICE_REQUEST`, and calls it with JSON: the arguments are
written as the protocol's bytes, the reply read back as JSON. Named
components (`Wire.field`) become an object's members; arguments with no
name go under `"value"`:

```ocaml
let tools = Tools.of_service "kv" in
List.iter (fun t -> print_endline t.Tools.tool.Llm.name) tools;
print_endline (Tools.call (Tools.find tools "kv_get") {|{"key": "colour"}|});
print_endline (Tools.call (Tools.find tools "kv_keys") "{}")
```

```
kv_set
kv_get
kv_keys
"green"
["colour"]
```

No code of kv's own was needed: this is how a language model calls any
service (chapter 21), and how the service explorer window builds a form
for each request. Give requests their documentation and their `field`
names with that reader in mind. A description is checked by nothing but
its use; the tests compare the C services' descriptions with the OCaml
modules' (appendix E.2).

The idea is old: a Smalltalk object can be asked which messages it
understands, and Smalltalk's inspector shows any object of the running
system (chapter 3.2). Here the object is a process, possibly written in
C, and what it understands travels as data, in its description.

## 17.7 Services that answer later

`serve` answers one request before it takes the next. A request that
must wait (a read until a key comes, a client waiting for an event)
would stop the service. Such a service runs its own loop: it decodes
each request with `decode`, answers the quick ones at once, and keeps
the channel of the others, to send their reply when it can. `bell.ml`
keeps clients waiting until another client rings:

```ocaml
(* bell.ml: a service that answers later, "bell/1".

     bell             serve, forever
     bell wait        wait for the next ring, print its message
     bell ring TEXT   ring: every waiting client gets TEXT *)

type _ request =
  | Wait : string request            (* the message of the next ring *)
  | Ring : string -> int request     (* how many were waiting *)

module Protocol = struct
  let id = "bell/1"
  (* summary, requests and the codecs: as in kv.ml *)
  ...
end

module Bell = Ipc.Make (Protocol)

(* send a reply and close the channel; a client that has gone is no error *)
let answer ch msg =
  (try Mynos.send ch msg with Mynos.Error _ -> ());
  (try Mynos.free_channel ch with Mynos.Error _ -> ())

let waiting = ref []                  (* channels of clients in Wait *)

let handle (type a) ch (r : a request) =
  match r with
  | Wait -> waiting := ch :: !waiting                 (* no answer yet *)
  | Ring text ->
    let n = List.length !waiting in
    List.iter (fun w -> answer w (Bell.reply Wait text)) (List.rev !waiting);
    waiting := [];
    answer ch (Bell.reply r n)

let serve () =
  let port = Mynos.register "bell" in
  while true do
    let ch = Mynos.listen port in
    match Mynos.recv ~timeout:1.0 ch with
    | exception Mynos.Error _ -> (try Mynos.free_channel ch with Mynos.Error _ -> ())
    | msg ->
      match Bell.decode msg with
      | Error reply -> answer ch reply          (* "describe", or an error *)
      | Ok (Protocol.Request r) -> handle ch r
  done

let () =
  match Sys.argv with
  | [| _ |] -> serve ()
  | [| _; "wait" |] -> print_endline (Bell.call (Bell.connect "bell") Wait)
  | [| _; "ring"; text |] ->
    Printf.printf "%d were waiting\n" (Bell.call (Bell.connect "bell") (Ring text))
  | _ -> prerr_endline "usage: bell [wait | ring TEXT]"; exit 2
```

`decode` answers `"describe"` and malformed requests itself: its `Error`
is a reply ready to send. `Bell.reply Wait text` builds the reply of a
`Wait` request, typed by the request. With the service running, two
clients waiting and a third ringing:

```
$ bell.byte wait &
$ bell.byte wait &
$ bell.byte ring dinner
dinner
dinner
2 were waiting
```

A terminal window's console service (`gui/terminal.ml`) works this way:
a `Console.Read` with no input to give is kept, with its channel, in a
list of pending reads, and answered by the domain that receives the
keys (`serve_reads`). Such a service must also forget a client that
gave up: a `send` to it fails, and is ignored, as `answer` does above.

## 17.8 From the toplevel

The toplevel (`ocaml` at `sh`) has the whole library loaded, with
`Fs`, `Block`, `Console`, `Registry`, `Net` and the others: a service
whose module is in the library is called directly. A protocol of one's
own is typed in, or read from a file with `#use`. With greeter running,
and its protocol (the first lines of `greeter.ml`, down to
`module G = Ipc.Make (Protocol)`) in `/disk/greet.ml`:

```
# #use "/disk/greet.ml";;
type _ request = Hello : string -> string request
module Protocol : sig ... end
module G : sig ... end
# G.call (G.connect "greeter") (Hello "toplevel");;
- : string = "Hello, toplevel, from MyNOS!"
# (Ipc.describe "greeter").Ipc.summary;;
- : string = "Greets: an example service."
# Tools.call (Tools.find (Tools.of_service "greeter") "greeter_hello") {|{"value": "JSON"}|};;
- : string = "\"Hello, JSON, from MyNOS!\""
# Registry.call (Registry.Lookup "greeter");;
- : int = 20024
# Fs.call (Fs.connect "tmpfs") (Fs.List "");;
- : (string * int) list = [("c.txt", 29); ("o.txt", 73)]
```

(The toplevel prints the two modules' signatures in full.) A wrong
request is refused before anything is sent: `G.call c (Hello 3)` is a
type error, and so is using its reply as an `int`.

> **THE MyNOS FACTOR — A service is a type.**
> A Unix service is reached through a socket and a byte stream, and what
> the bytes mean lives in a document beside the code. A MyNOS service is
> a GADT: each request is a constructor, each reply has the type its
> request declares, and the compiler checks both ends against the same
> definition. The definition also travels: every service describes
> itself on request, so the toplevel, the service explorer and a
> language model can call a service they were never compiled against.
> The kernel still moves bytes, as in 2002; the types live in the
> library, one module per protocol.

## 17.9 From C

A C program speaks a typed protocol with `mynos_wire.h`: a writer that
grows a buffer, a reader that sets `r->error` on a malformed message
instead of failing, and the Ok and Error replies. The registry,
`memrofs`, `consoled` and `netd` are C services written this way;
`libmynos` is a C client of fs/1, console/1, registry/1, net/1 (sockets)
and pager/1 (`mmap`). A client of kv/1:

```c
/* kvget.c: a C client of kv/1, with mynos_wire.h */
#include <stdio.h>
#include <mynos.h>
#include <mynos_wire.h>

int main(int argc, char ** argv)
{
  wire_writer w;
  wire_reader r;
  mynos_msg_t * msg;
  const char * s;
  unsigned int len;
  int port, ch;

  if (argc != 2 || (port = mynos_registryLookUp("kv")) < 0) return 2;
  wire_writer_init(&w);                   /* the request: */
  wire_put_cstring(&w, "kv/1");           /*   the protocol */
  wire_put_int(&w, 1);                    /*   case 1, Get */
  wire_put_cstring(&w, argv[1]);          /*   its argument, the key */
  if (w.error || (ch = mynos_connectToPort(port)) < 0) return 1;
  mynos_send(ch, w.buf, w.len, 0);
  wire_writer_free(&w);
  if (mynos_recv(ch, &msg, 0, 2000) < 0) { mynos_freeChannel(ch); return 1; }
  mynos_freeChannel(ch);

  wire_reader_init(&r, msg->start, msg->size);   /* the reply: */
  if (wire_get_int(&r) != 0) {                   /*   case 1: Error */
    s = wire_get_string(&r, &len);
    printf("kvget: error: %.*s\n", (int)len, s);
  } else if (!wire_get_bool(&r))                 /*   Ok None */
    printf("kvget: %s has no value\n", argv[1]);
  else {                                         /*   Ok (Some v) */
    s = wire_get_string(&r, &len);
    if (!r.error && wire_at_end(&r)) printf("kvget: %s = %.*s\n", argv[1], (int)len, s);
  }
  if (r.error) printf("kvget: a malformed reply\n");
  mynos_freeMsg(&msg);
  return 0;
}
```

```
kvget: colour = blue
kvget: size has no value
```

A C service answers `"describe"` with `wire_reply_description`, its
requests' shapes written in a compact notation (`"(key:S,value:S)"`,
`"O<S>"`, `"L<S>"`; `mynos_wire.h` lists it). The C side has no type
checker to keep it honest: compare its description with the OCaml
module's in a test, as `tests/mynos-ocaml` does for the registry and
memrofs.

## 17.10 Known limits

- One request per connection, and `serve` takes one at a time (17.7
  shows the way around it); `call` has no timeout.
- The codecs are written by hand: only a test checks that `requests`,
  `write_request` and `read_request` agree.
- A change that clients cannot read needs a new id (`"kv/2"`).
