# 24. Reference pages

This chapter is the reference for programmers: one page per module of
the OCaml library `mynos.cma` (section 3), then the native calls as the
C library `libmynos` exposes them (section 2), grouped by subject. The
pages follow the old UNIX layout: NAME, SYNOPSIS, DESCRIPTION, then
RETURN VALUE or EXCEPTIONS, and SEE ALSO. The interfaces themselves,
`mynos-lib/ocaml/*.mli` and `mynos-lib/include/*.h`, are the final word;
the call numbers are in appendix A.8, the Linux calls MyNOS answers in
appendix D.

**Using the library.** OCaml programs compile against `mynos.cma`, which
holds all the modules below, and the runtime's list of primitives:

```
build machine:  ocamlc -use-prims mynos-runtime/primitives -I mynos-lib/ocaml \
                  mynos.cma -o prog.byte prog.ml
inside MyNOS:   ocamlc -use-prims /primitives mynos.cma -o /disk/prog.byte prog.ml
```

C programs include `<mynos.h>` (`-I mynos-lib/include`) and link with
`-lmynos` and the flags of `mynos.mk` (musl, static, loaded at
`0x40000000`).

**Errors, in general.** A native call that fails raises
`Mynos.Error (function, code)` in OCaml and returns a negative
`MYNOS_ERR_*` in C:

| Code | Name | Meaning |
|---|---|---|
| -1 | `full` | a table or a queue is full |
| -2 | `busy` | taken; someone else listens, receives, or records |
| -3 | `invalid` | no such object; a bad argument or pointer |
| -4 | `deny` | not the caller's; a privilege the caller lacks |
| -5 | `broken` | the other side is gone |
| -6 | `expired` | the timeout passed |

A typed request that the service refuses raises `Ipc.Remote_error
(service, message)`.

---

## 24.1 Mynos(3)

**NAME** — `Mynos`: the native calls, for OCaml.

**SYNOPSIS**

```ocaml
exception Error of string * int
val error_name : int -> string

val getpid : unit -> int
val log : string -> unit
val log_position : unit -> int
val log_read : int -> int -> string
val version : unit -> string
val uptime : unit -> float
val time : unit -> float
val sleep : float -> unit
type stats = { processes : int; threads : int; pid : int; ppid : int; free_pages : int }
val stats : unit -> stats

val alloc_port : unit -> int              val listen : int -> int
val connect : int -> int                  val free_port : int -> unit
val change_port_owner : int -> int -> unit
val send : int -> string -> unit
val recv : ?timeout:float -> int -> string
val free_channel : int -> unit

val sem_create : int -> int               val sem_p : int -> unit
val sem_try_p : int -> bool               val sem_v : int -> unit
val sem_free : int -> unit

val register : string -> int
val lookup : string -> int
val registered : unit -> (string * int * int) list

type status = Exited of int | Signaled of int
val spawn : ?env:string array -> ?io:bool -> string -> string array -> int
val wait : int -> status
val wait_any : unit -> int * status
val kill : int -> unit
val environment : unit -> string array
val channel_peer : int -> int
type process_info = { alive : bool; io : bool }
val process_info : int -> process_info option
type process = { p_pid : int; parent : int; p_io : bool; threads : int;
                 name : string; bytecode : bool }
val processes : unit -> process list

val inb : int -> int          val outb : int -> int -> unit
val inw : int -> int          val outw : int -> int -> unit
val insw : int -> int -> string
val outsw : int -> string -> unit
val driver_register : string -> int -> int
val enable_irq : int -> unit

val console_mode :
  canon:bool -> echo:bool -> ?isig:bool -> ?vmin:int -> ?vtime:int -> unit -> unit
val console_foreground : int -> unit
```

**DESCRIPTION** — Thin bindings to libmynos. *Time*: `uptime` is
seconds since boot, `time` seconds since 1970 (UTC, from the clock read
at boot), `sleep s` blocks the calling thread at least `s` seconds (10 ms
resolution). `log` writes a line to the kernel log (the serial log port,
and the kernel's 64 KB ring); `log_position ()` is how many bytes have
been logged since boot, `log_read from max` the logged bytes from a
position (the oldest kept, if older). `version ()` is the system's
version, as `uname` gives it (`2026.11-71dc1d2`).

*Ports and channels* (appendix C): a server allocates a port and
`listen`s on it, getting a new channel per client; a client `connect`s
to the port and gets its end. `send` and `recv` move whole messages as
strings; `recv ~timeout` waits at most that many seconds. `free_channel`
closes one's end.

*Semaphores*: `sem_create n` makes one with the count `n`; `sem_p` waits
(releasing the OCaml runtime lock), `sem_try_p` takes it only if it
would not wait, `sem_v` signals.

*The registry*: `register name` registers a name and returns the new
port, the caller's; `lookup name` gives a name's port; `registered ()`
lists `(name, port, owner)` for the live owners.

*Programs*: `spawn path argv` starts the ELF file `path` as a child (a
name without `/` is looked for at the RAM disk's root, then in the
current directory) and returns its pid; a bytecode program is started
as `spawn "ocamlrun" [| "ocamlrun"; "prog.byte"; ... |]`. The child gets
`env` (`~env:[||]`: none), or by default our environment; `~io:true` gives it the `io`
privilege, if we have it. `wait pid` and `wait_any ()` wait for a child's
end. `kill pid` ends a process as killed (`Signaled 9`). `environment
()` is our environment; a child's `MYNOS_STDIN`, `MYNOS_STDOUT` (`>>path`
appends) and `MYNOS_STDERR` redirect its standard files, `PWD` is its
directory. `channel_peer c` is the pid at the other end of one of our
channels; `process_info pid` tells whether a pid is alive and
privileged (`None`: it ended and was collected; pids are never reused);
`processes ()` lists the live processes.

*Drivers* (chapter 23): port I/O (`outb port byte`; `insw port n` reads
`n` words, `2n` bytes), and `driver_register name irq`, which returns a
semaphore `V`ed at each interrupt of the line, unmasked by `enable_irq`.
They need the `io` privilege: without it, an `in` or `out` ends the
process.

*Console*: `console_mode ~canon ~echo ?isig ?vmin ?vtime ()` sets the
console's input mode as termios would (`~isig:false`: Ctrl-C is a key,
as editors want); `console_foreground pid` names
the program that Ctrl-C should end (0: none).

**EXCEPTIONS** — `Error (function, code)`: the call failed;
`error_name code` is `"full"`, `"busy"`, `"invalid"`, `"deny"`,
`"broken"` or `"expired"`. `recv ~timeout` raises `Error ("recv", -6)`
when nothing came; `lookup` of an unknown name raises
`Error ("registry_lookup", -3)`.

**SEE ALSO** — ipc(2), port(2), sem(2), process(2), driver(2);
appendices A, C, F.4.

---

## 24.2 Wire(3)

**NAME** — `Wire`: the wire format of typed IPC.

**SYNOPSIS**

```ocaml
exception Error of string
type 'a t
val unit : unit t   val bool : bool t   val int : int t
val string : string t   val float : float t
val option : 'a t -> 'a option t
val list : 'a t -> 'a list t        val array : 'a t -> 'a array t
val pair : 'a t -> 'b t -> ('a * 'b) t
val triple : 'a t -> 'b t -> 'c t -> ('a * 'b * 'c) t
val result : 'a t -> 'b t -> ('a, 'b) result t
val conv : ('a -> 'b) -> ('b -> 'a) -> 'b t -> 'a t
val field : string -> 'a t -> 'a t
type 'a case
val case : ?name:string -> int -> 'b t -> ('b -> 'a) -> ('a -> 'b option) -> 'a case
val variant : 'a case list -> 'a t
val fix : ?name:string -> ('a t -> 'a t) -> 'a t

type shape = Unit | Bool | Int | Float | String | Option of shape | List of shape
           | Tuple of shape list | Named of string * shape
           | Variant of (int * string * shape) list | Rec of string * shape | Var of string
val shape : 'a t -> shape
val shape_codec : shape t

type writer   val writer : unit -> writer
val write : writer -> 'a t -> 'a -> unit      val contents : writer -> string
type reader   val reader : string -> reader
val read : reader -> 'a t -> 'a               val at_end : reader -> bool
val to_string : 'a t -> 'a -> string          val of_string : 'a t -> string -> 'a
```

**DESCRIPTION** — A codec `'a t` writes and reads values of type `'a`.
Integers are zigzag LEB128, strings and lists are length-prefixed,
floats are 8 bytes, variants are a case number and the case's value
(the table in appendix E.2). `conv` writes a type as another (a record
as a tuple); `field` names a component, for descriptions only; `case`
and `variant` build a variant codec; `fix` a recursive one. `shape`
gives a codec's structure as data, which services send in their
descriptions and `Tools` reads. Reading checks every length against
the bytes left.

**EXCEPTIONS** — `Error`: a malformed message, a value beyond the
reader's `int`, bytes left over (`of_string`). `Invalid_argument`:
writing a value that no `case` recognizes.

**SEE ALSO** — Ipc(3), Tools(3), wire(3); `doc/decisions/typed-ipc.md`.

---

## 24.3 Ipc(3)

**NAME** — `Ipc`: typed IPC, clients and services.

**SYNOPSIS**

```ocaml
exception Remote_error of string * string     (* service, message *)
exception Protocol_error of string
type caller = { pid : int; io : bool }
val nobody : caller

type request_doc = { case : int; name : string; doc : string;
                     args : Wire.shape; reply : Wire.shape; safe : bool }
val request : ?safe:bool -> int -> string -> string -> 'a Wire.t -> 'b Wire.t -> request_doc
type description = { protocol : string; summary : string; requests : request_doc list }
val description_codec : description Wire.t
val describe : ?timeout:float -> string -> description

module type PROTOCOL = sig
  val id : string
  val summary : string
  val requests : request_doc list
  type 'a request
  type packed = Request : 'a request -> packed
  val write_request : Wire.writer -> 'a request -> unit
  val read_request : Wire.reader -> packed
  val reply : 'a request -> 'a Wire.t
end

module Make (P : PROTOCOL) : sig
  type client
  val connect : string -> client
  val service : client -> string
  val call : client -> 'a P.request -> 'a
  type handler = { handle : 'a. caller -> 'a P.request -> 'a }
  val serve : string -> handler -> 'b
  val serve_port : int -> handler -> 'b
  val decode : string -> (P.packed, string) result
  val reply : 'a P.request -> 'a -> string
  val error_reply : string -> string
  val request_message : 'a P.request -> string
  val answer : ?caller:caller -> handler -> string -> string
  val read_reply : string -> 'a P.request -> 'a
end
```

**DESCRIPTION** — A protocol is a GADT of requests indexed by their
replies' types, with an `id` (`"block/1"`), a summary, the list of its
requests, and the codecs. `Make (P)` gives a client whose `call`
returns the reply's type, and a service loop. `connect name` looks the
service up; each `call` makes one connection, sends the request, waits
for the reply and frees the channel; if the service has been restarted
it is looked up again (up to 3 s), and a request is never sent twice.
`serve name h` registers `name` and answers requests one at a time,
forever, calling `h.handle caller request`; an exception raised by the
handler becomes the error reply. A request whose sender sends nothing
within a second is dropped. `decode`, `reply` and `error_reply` let a
service keep a request waiting and answer later (consoles, displayd).
Every service answers a request of protocol `"describe"` with its
`description`; `describe name` asks for it (1 s by default).

**EXCEPTIONS** — `Remote_error (service, message)`: the service refused
or failed. `Protocol_error`: a malformed reply. `Mynos.Error`: no such
service, or the connection failed.

**SEE ALSO** — Wire(3), Tools(3); chapter 17; appendix E.2.

---

## 24.4 Fs(3)

**NAME** — `Fs`: fs/1, the protocol of the file services.

**SYNOPSIS**

```ocaml
type _ request =
  | Open : string * int -> int request        | Close : int -> unit request
  | Read : int * int -> string request        | Write : int * string -> int request
  | Seek : int * int * int -> int request     | List : string -> (string * int) list request
  | Remove : string -> unit request           | Mkdir : string -> unit request
  | Rmdir : string -> unit request            | Rename : string * string -> unit request
val o_write : int   val o_creat : int   val o_trunc : int   val o_append : int
val o_excl : int
val io_max : int
val ok : int  val not_found : int  val too_many : int  val denied : int
val not_open : int  val invalid : int  val read_only : int  val no_space : int
val is_dir : int  val not_empty : int  val exists : int  val not_dir : int
val error_name : int -> string
val error_of : string -> int
val fail : int -> 'a
module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
type client
val connect : string -> client
val call : client -> 'a request -> 'a
type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
val serve : string -> handler -> 'b
```

**DESCRIPTION** — Programs use files through the standard library,
which speaks fs/1 for them; this module speaks it typed. `connect`
takes a service name (`"memrofs"`, `"tmpfs"`, `"fatfs"`); paths are
inside the service, without a leading slash (`"docs/a.txt"`). `Read`
returns `""` at the end; at most `io_max` (16384) bytes per `Read` or
`Write`. `List` gives names and sizes, -1 for a directory. A descriptor
belongs to the process that opened it. In a service, `fail code`
answers with that error.

**EXCEPTIONS** — `Ipc.Remote_error`, whose message starts with the
error's name (`"not_found: ..."`); `error_of` recovers the code.

**SEE ALSO** — `mynos_fs.h`; appendix E.7, E.10; chapter 18.

---

## 24.5 Block(3)

**NAME** — `Block`: block/1, sectors of a block device.

**SYNOPSIS**

```ocaml
val sector : int                (* 512 *)
val max_count : int             (* 32 *)
type _ request =
  | Info : int request
  | Read : int * int -> string request
  | Write : int * string -> unit request
module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
type t
val connect : ?service:string -> unit -> t
val call : t -> 'a request -> 'a
val sectors : t -> int
val read : t -> int -> int -> string
val write : t -> int -> string -> unit
type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
val serve : string -> handler -> 'b
val answer : ?caller:Ipc.caller -> handler -> string -> string
val request_message : 'a request -> string
val read_reply : string -> 'a request -> 'a
```

**DESCRIPTION** — `connect ()` is the device `ata0` (or `service`).
`Info` is its size in sectors; `Read (lba, count)` reads 1 to
`max_count` sectors; `Write (lba, bytes)` writes a whole number of
sectors, at most `max_count`. `read d lba count` and `write d lba bytes`
take any length and split it. `serve` makes a driver (chapter 23).

**EXCEPTIONS** — `call`: `Ipc.Remote_error` when the driver refuses
(out of the disk, a wrong size, `I/O error: ...`). `read`, `write`:
`Failure`.

**SEE ALSO** — chapter 23; appendix E.8.

---

## 24.6 Console(3)

**NAME** — `Console`: console/1, the protocol of the consoles.

**SYNOPSIS**

```ocaml
type _ request =
  | Read : int -> string request
  | Mode : int * int * int -> unit request
  | Keymap : int -> int request
  | Write : string -> unit request
  | Foreground : int -> unit request
val canon : int   val echo : int   val nosig : int
val layout_us : int   val layout_it : int
module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
type client
val connect : ?service:string -> unit -> client
val call : client -> 'a request -> 'a
val decode : string -> (Protocol.packed, string) result
val reply : 'a request -> 'a -> string
val error_reply : string -> string
```

**DESCRIPTION** — The protocol of `consoled` (`"console"`, the text
console) and of each terminal window (`term<pid>`). Programs normally
use it through the standard library (reads on fd 0, writes on 1 and 2,
termios). `Read max` returns a line in line mode, keys in raw mode, `""`
at the end; `Mode (flags, vmin, vtime)` takes `canon`, `echo` and
`nosig` or-ed together; `Keymap` sets `layout_us` or `layout_it`, or with
-1 tells the one in use; `Foreground pid` names the program Ctrl-C
ends. `decode`, `reply` and `error_reply` are for services that answer
later.

**SEE ALSO** — `mynos_console.h`; Mynos(3) (`console_mode`); appendix
E.11.

---

## 24.7 Registry(3)

**NAME** — `Registry`: registry/1, the name registry, typed.

**SYNOPSIS**

```ocaml
type _ request =
  | Register : string -> int request
  | Lookup : string -> int request
  | List : (string * int * int) list request
module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
val call : 'a request -> 'a
```

**DESCRIPTION** — The registry (in C) answers at the well-known port 0.
Programs use it through `Mynos.register`, `Mynos.lookup` and
`Mynos.registered`; this module describes the protocol and speaks it
directly. `Register` returns a new port, the caller's; a name belongs to
its process while it runs.

**EXCEPTIONS** — `Ipc.Remote_error` with `not_found`, `exists` or
`invalid`.

**SEE ALSO** — registry(3) (C); appendix E.5.

---

## 24.8 Power(3)

**NAME** — `Power`: power/1, turning the machine off or restarting it.

**SYNOPSIS**

```ocaml
type _ request = Shutdown : unit request | Reboot : unit request
module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
val shutdown : unit -> unit
val reboot : unit -> unit
type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
val serve : handler -> 'b
```

**DESCRIPTION** — `init` serves it as `power`. `shutdown` and `reboot`
return once `init` has the request; it ends the graphical session, then
acts (ACPI, or the keyboard controller's reset line). Any process may
ask.

**SEE ALSO** — appendix E.16.

---

## 24.9 Net(3)

**NAME** — `Net`: net/1, the network service.

**SYNOPSIS**

```ocaml
type config = { mac : string; address : string; netmask : string;
                gateway : string; dns : string }
type _ request =
  | Config : config request
  | Ping : string * int -> int request
  | Resolve : string -> string request
  | Connect : string * int -> int request
  | Listen : int -> int request
  | Accept : int -> (int * string * int) request
  | Send : int * string -> int request
  | Recv : int * int -> string request
  | Close : int -> unit request
  | Set_timeout : int * int -> unit request
  | Connect_tls : string * int -> int request
  | Udp_bind : int -> int request
  | Send_to : int * string * int * string -> int request
  | Recv_from : int * int -> (string * int * string) request
module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
type t
val connect : ?service:string -> unit -> t
val call : t -> 'a request -> 'a
val config_codec : config Wire.t
```

**DESCRIPTION** — `connect ()` waits up to 5 s for `net`. Addresses are
dotted IPv4; sockets are numbers owned by their process. `Recv` returns
at most `max` (≤ 16384) bytes, `""` at the end; `Recv`, `Accept` and
`Recv_from` wait, bounded by `Set_timeout (socket, ms)` (0: forever).
`Connect_tls (host, port)` checks the server's certificate against
`/cacert.pem` and `/disk/ca.pem`; `Send` and `Recv` then carry clear
bytes. `Udp_bind 0` takes any port; a datagram is at most 8192 bytes.

**EXCEPTIONS** — `Ipc.Remote_error ("net", m)`, `m` such as `host not
found`, `connection refused`, `connection reset`, `timeout`, `not your socket`, `TLS: ...`.
`Mynos.Error` without the service.

**SEE ALSO** — Http(3); chapter 19; appendix E.12.

---

## 24.10 Http(3)

**NAME** — `Http`: HTTP/1.1 and HTTPS clients.

**SYNOPSIS**

```ocaml
type response = { status : int; reason : string;
                  headers : (string * string) list; body : string }
exception Error of string
val request : ?net:Net.t -> ?meth:string -> ?headers:(string * string) list ->
  ?body:string -> ?timeout:int -> string -> response
val get : ?net:Net.t -> ?headers:(string * string) list -> ?timeout:int ->
  string -> response
val post : ?net:Net.t -> ?headers:(string * string) list -> ?timeout:int ->
  body:string -> string -> response
val header : string -> response -> string option
val parse_url : string -> bool * string * int * string
val parse_response : string -> response
```

**DESCRIPTION** — One connection per request (`Connection: close`),
TLS for `https://` (in netd). `meth` is `GET`, or `POST` with a
`body`; `Host`, `User-Agent`, `Content-Length` and `Connection` are
added unless given. `timeout` (ms, default 30000) bounds each wait for
the server. A chunked body is decoded; nothing is decompressed; no
redirect is followed. Header names are in lower case; `header` finds one
in any case. `parse_url` gives `(tls, host, port, path)`.

**RETURN VALUE** — The response, whatever its status.

**EXCEPTIONS** — `Error`: a bad URL, a network error (its message), an
answer that is not HTTP.

**SEE ALSO** — Net(3), Json(3); chapter 19.

---

## 24.11 Json(3)

**NAME** — `Json`: JSON values.

**SYNOPSIS**

```ocaml
type t = Null | Bool of bool | Number of float | String of string
       | Array of t list | Object of (string * t) list
exception Error of string
val of_string : string -> t
val to_string : t -> string
val member : string -> t -> t
val index : int -> t -> t
val to_string_value : t -> string
val to_int : t -> int
val to_float : t -> float
val to_bool : t -> bool
val to_list : t -> t list
```

**DESCRIPTION** — RFC 8259, strings in UTF-8. `to_string` is compact
and writes integral numbers without a fraction. `member` gives `Null`
for a missing field; `index` an element of an array.

**EXCEPTIONS** — `Error`: malformed text, a value of another kind than
asked, `member` of a non-object, `index` out of range.

**SEE ALSO** — Http(3), Tools(3).

---

## 24.12 Llm(3)

**NAME** — `Llm`: llm/1, language models.

**SYNOPSIS**

```ocaml
type block =
  | Text of string
  | Tool_call of { id : string; name : string; input : string }
  | Tool_result of { id : string; content : string; error : bool }
  | Opaque of string
type role = User | Assistant
type message = { role : role; content : block list }
type tool = { name : string; description : string; schema : string }
type chat = { profile : string; system : string; messages : message list;
              tools : tool list; max_tokens : int }
type stop = End | Tool_use | Max_tokens | Refusal | Other of string
type answer = { content : block list; stop : stop; model : string;
                input_tokens : int; output_tokens : int }
type _ request =
  | Profiles : (string * string * string) list request
  | Chat : chat -> answer request
module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
type t
val connect : ?service:string -> unit -> t
val call : t -> 'a request -> 'a
val chat : chat
val user : string -> message
val text : answer -> string
val ask : ?profile:string -> ?system:string -> t -> string -> string
type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
val answer : ?caller:Ipc.caller -> handler -> string -> string
```

**DESCRIPTION** — `connect ()` waits up to 5 s for `llm`. `Profiles`
lists `(name, api, model)`, the default first. `Chat` sends a
conversation: `profile` `""` is the default, `max_tokens` 0 the
profile's. A tool's `schema` and a call's `input` are JSON text.
`Opaque` blocks must be given back unchanged. `chat` is an empty chat to
fill; `user s` a user message; `text a` the answer's text; `ask` one
question, one answer. `answer` is the service's side (llmd).

**EXCEPTIONS** — `Ipc.Remote_error ("llm", m)`: no configuration
(`no model configured: ...`), an unknown profile, the provider's error
(`PROFILE: STATUS TYPE: message`), the network's.

**SEE ALSO** — Tools(3), Agent(3); chapter 21; appendix E.13.

---

## 24.13 Tools(3)

**NAME** — `Tools`: typed services as a model's tools.

**SYNOPSIS**

```ocaml
val schema : Wire.shape -> Json.t
val args_schema : Wire.shape -> Json.t
val write_json : Wire.shape -> Wire.writer -> Json.t -> unit
val read_json : Wire.shape -> Wire.reader -> Json.t
type t = { service : string; protocol : string;
           request : Ipc.request_doc; tool : Llm.tool }
val of_description : string -> Ipc.description -> t list
val of_service : string -> t list
val find : t list -> string -> t
val call : t -> string -> string
```

**DESCRIPTION** — `of_service name` asks a service for its description
and makes each request a tool named `SERVICE_REQUEST`, with a JSON
Schema of its arguments (`args_schema`: always an object; arguments
that are not named components go under `"value"`). `call t input` writes
the JSON object `input` as the protocol's bytes, sends the request, and
returns the reply as JSON text. Unit is `null`; a tuple of named
components an object; a variant its case's name, or `{"name": value}`.
`call` does not check `t.request.safe`.

**EXCEPTIONS** — `find`: `Not_found`. `call`: `Failure` for input that
does not fit the shape, `Ipc.Remote_error` for the service's refusal,
`Ipc.Protocol_error`, `Mynos.Error`. `of_service`: as `Ipc.describe`.

**SEE ALSO** — Ipc(3), Llm(3); chapter 21; `doc/decisions/llm.md`.

---

## 24.14 Agent(3)

**NAME** — `Agent`: a task carried out by a model with tools.

**SYNOPSIS**

```ocaml
type event =
  | Task of string | Said of string | Action of string
  | Result of { text : string; error : bool } | Note of string
type answer = Yes | No | All
type t
val create : ?profile:string -> ?services:string list -> ?max_turns:int ->
  ?trace_file:string -> ?yes_to_all:bool -> ?warn:(string -> unit) -> unit -> t
val run : t -> emit:(event -> unit) -> confirm:(string -> answer) -> string -> int
val tokens : t -> int * int
val trace_file : t -> string
val set_yes_to_all : t -> bool -> unit
val forget : t -> unit
```

**DESCRIPTION** — `create` makes a session: the default profile, the
services `["net"]`, 20 model calls a task, the recording in
`/tmp/agent.trc`; `warn` is told of a service whose description could
not be had. `run a ~emit ~confirm task` carries a task out in the
conversation so far, telling `emit` what happens and asking `confirm`
before any command, write, program or unsafe request (`All`: yes to the
rest). Each task is recorded, with marks.

**RETURN VALUE** — `run`: 0 when the model answered, 1 when it stopped
(an error, a refusal, a cut answer, too many calls).

**EXCEPTIONS** — `create`: `Failure` without the `llm` service.

**SEE ALSO** — Llm(3), Tools(3), Tracer(3); chapter 21.

---

## 24.15 Tracer(3)

**NAME** — `Tracer`: the event recorder and its player.

**SYNOPSIS**

```ocaml
type kind = Process | Spawn | Exit | Connect | Send | Recv | Free | Irq | Mark
          | Other of int
type event = { seq : int; time : float; kind : kind; pid : int; tid : int;
               peer : int; channel : int; size : int; arg : int; data : string }
type recording = { events : event array; dropped : int;
                   names : (int, (int * string) list) Hashtbl.t }
exception Busy
val start : unit -> unit
val stop : unit -> unit
val free : unit -> unit
val mark : string -> unit
val read : unit -> string
type info = { recording : bool; pending : int; dropped_now : int; khz : float }
val info : unit -> info
val save : string -> raw:string -> info -> unit
val load : string -> recording
val of_raw : raw:string -> info -> recording
val stop_and_get : unit -> recording
val stop_and_save : string -> recording
val name : recording -> ?seq:int -> int -> string
val program : recording -> ?seq:int -> int -> string
val describe : recording -> event -> string
val print_events : out_channel -> recording -> unit
type call = { client : int; server : int; start : float; finish : float;
              request : string; reply : string; depth : int;
              client_tid : int; server_tid : int;
              server_start : float; server_finish : float;
              request_bytes : string; reply_bytes : string;
              request_size : int; reply_size : int }
val calls : recording -> call list
val print_calls : out_channel -> recording -> unit
val to_json : recording -> string
```

**DESCRIPTION** — `start` begins a recording of the whole system (8,192
events in the kernel); `stop` ends it; `read` takes the raw events
waiting (96 bytes each) and removes them; `free` gives the buffer back
and frees the recorder for others; `stop_and_get` does all three and
decodes; `stop_and_save file` also saves the recording in `file`. `mark s` labels the moment, if a recording is on. `info` tells
the state and the clock's rate. `save` and `load` handle the recording
file (`MYNOSTR1`). `calls` rebuilds requests and replies, nested;
`print_events`, `print_calls` and `to_json` (Chrome trace format, for
Perfetto) are the ready views; `describe` puts one message in words;
`name r pid` is `"fatfs(8)"`. Times are milliseconds from the first
event; a call's `finish` is `nan` when its reply is not recorded.

**EXCEPTIONS** — `start`: `Busy` if another process records.
`stop`, `read`: `Mynos.Error (_, -4)` (`deny`) for a recording not the
caller's. `load`: `Failure "FILE: not a MyNOS recording"`, `Sys_error`.
`mark` and `free` raise nothing.

**SEE ALSO** — trace(2); chapter 22; appendix G.

---

## 24.16 Display(3)

**NAME** — `Display`: display/1, windows and their events.

**SYNOPSIS**

```ocaml
type event =
  | Key of string | Mouse of { x : int; y : int; buttons : int }
  | Close | Tick | Focus of bool | Wheel of int | Key_up of string
type _ request =
  | Info : (int * int) request
  | Create : string * int * int -> int request
  | Attach : int -> unit request
  | Damage : int * int * int * int * int -> unit request
  | Next_event : int * int -> event request
  | Destroy : int -> unit request
  | Set_title : int * string -> unit request
  | Start : unit request
  | Wait_session : unit request
  | Stop : unit request
  | Move : int * int * int -> unit request
module Protocol : Ipc.PROTOCOL with type 'a request = 'a request
type t
val connect : unit -> t
val call : t -> 'a request -> 'a
type window = { display : t; id : int; pixels : Gfx.t }
val window : ?display:t -> ?title:string -> int -> int -> window
val damage : ?x:int -> ?y:int -> ?w:int -> ?h:int -> window -> unit
val next_event : ?timeout:float -> window -> event
val set_title : window -> string -> unit
val move : window -> int -> int -> unit
val destroy : window -> unit
```

**DESCRIPTION** — `window ~title w h` makes a window of that content
size and shares its pixels with `displayd`; draw in `pixels`, then
`damage` the part that changed (all by default). `next_event ~timeout`
waits for the window's next event, `Tick` after `timeout` seconds (0:
forever). `Key` is UTF-8 or a VT100 sequence; `Mouse` is in window
coordinates, `buttons` 1 left, 2 right, 4 middle; `Wheel` is in notches,
positive downwards. `Start`, `Stop` and `Wait_session` drive the
graphical session (the `gui` command).

**EXCEPTIONS** — `window`: `Ipc.Remote_error` outside the graphical
session (`no graphical session: start it with gui`); `Mynos.Error`
without `displayd`. `destroy` raises nothing.

**SEE ALSO** — Gfx(3), Gui(3); chapter 20; appendix E.14.

---

## 24.17 Gfx(3)

**NAME** — `Gfx`: drawing on buffers of 32-bit pixels.

**SYNOPSIS**

```ocaml
type t = private { pixels : (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t;
                   width : int; height : int }
val create : int -> int -> t
val char_w : int        val char_h : int
val fill : t -> int -> int -> int -> int -> int -> unit
val rect : t -> int -> int -> int -> int -> int -> unit
val line : t -> int -> int -> int -> int -> int -> unit
val text : ?bold:bool -> ?max:int -> t -> int -> int -> string -> int -> int
val cells : string -> int
val blit : t -> int -> int -> t -> int -> int -> int -> int -> unit
val get : t -> int -> int -> int
val with_clip : int -> int -> int -> int -> (unit -> 'a) -> 'a
val clip : unit -> (int * int * int * int) option
val rgb : int -> int -> int -> int
val mix : int -> int -> float -> int
val send_shared : int -> t -> unit
type mask = { mask_width : int; mask_height : int; grey : string }
val load_mask : string -> mask
val mask_of_pgm : string -> mask
val draw_mask : ?opacity:int -> t -> int -> int -> mask -> int -> unit
```

**DESCRIPTION** — Colours are `0xRRGGBB`. `create w h` is white and page
aligned. `fill g x y w h c`, `rect` (an outline), `line g x0 y0 x1 y1 c`,
`blit src sx sy dst dx dy w h`; all are clipped to the buffer and to the
clip of `with_clip`, which nests. `text g x y s c` draws UTF-8 in the
Terminus 8 × 16 font (`char_w`, `char_h`) and returns the cells written;
`cells s` counts characters. `get` reads a pixel (-1 outside). A mask is
a grey PGM image drawn as ink. `send_shared` sends the pixels on a
channel as shared memory (what `Display.window` does).

**EXCEPTIONS** — `load_mask`, `mask_of_pgm`: `Failure` if not a binary
8-bit PGM.

**SEE ALSO** — Display(3), Gui(3); appendix F.5.

---

## 24.18 Gui(3)

**NAME** — `Gui`: an immediate-mode toolkit.

**SYNOPSIS**

```ocaml
type ui = { window : Display.window; g : Gfx.t;
            mutable mx : int; mutable my : int; mutable buttons : int;
            mutable clicked : bool; mutable press : int * int;
            mutable keys : string list; mutable focused : bool;
            mutable tick : bool; mutable field : int; mutable wheel : int;
            mutable released : string list; mutable held : string list }
val background : int  val foreground : int  val muted : int
val accent : int      val panel_colour : int
val label : ?colour:int -> ?bold:bool -> ui -> int -> int -> string -> unit
val paragraph : ?colour:int -> ui -> int -> int -> int -> string -> int
val panel : ?colour:int -> ui -> int -> int -> int -> int -> unit
val button : ?h:int -> ui -> int -> int -> int -> string -> bool
val hovered : ui -> int -> int -> int -> int -> bool
val scroll : ?colour:int -> ui -> int -> int -> int -> int -> int -> (int -> int) -> unit
val scroll_to_end : ui -> int -> unit
val text_field : ui -> int -> int -> int -> int -> string -> string
val list_item : ui -> int -> int -> int -> selected:bool -> string -> bool
type entry = { name : string; is_dir : bool; size : int }
val entries : string -> entry list
val size_text : int -> string
val parent : string -> string
val join : string -> string -> string
type picked = Picked of string | Cancelled
val open_file_picker : ?title:string -> ?dir:string -> ?filter:(string -> bool) -> int -> unit
val file_picker : ui -> int -> picked option
exception Quit
val run : ?title:string -> ?tick:float -> int -> int -> 'a -> (ui -> 'a -> 'a) -> unit
val spawn : ?args:string list -> string -> unit
```

**DESCRIPTION** — `run w h state frame` makes a window and calls
`frame ui state` at every event (and every `tick` seconds without one),
keeping what it returns as the next state, until the window is closed
or `frame` raises `Quit`. Widgets draw and answer in one call: `button`
is `true` in the frame it is clicked, `text_field ui id x y w v` returns
`v` edited by this frame's keys, `list_item` is `true` when clicked,
`scroll ui id x y w h content` draws `content top` clipped and scrolled.
`id`s tell a window's fields and boxes apart. The file picker is a
modal panel: open it with `open_file_picker id`, draw it last with
`file_picker ui id`. `entries`, `size_text`, `parent`, `join` help with
files; `spawn prog` starts a bytecode program of the RAM disk.

**EXCEPTIONS** — `run` outside the graphical session prints why and
exits with status 2.

**SEE ALSO** — Display(3), Gfx(3); chapter 20.

---

## 24.19 ipc(2)

**NAME** — `mynos_send`, `mynos_recv`, `mynos_freeMsg`,
`mynos_signalSync`, `mynos_waitSync`, `mynos_freeChannel`: messages on
channels.

**SYNOPSIS**

```c
#include <mynos.h>
typedef struct { void * start; unsigned int size; int isShort; } mynos_msg_t;
int  mynos_send(int channel, void * buf, unsigned int size, unsigned int flags);
int  mynos_recv(int channel, mynos_msg_t ** pmsg, unsigned int flags,
                unsigned int timeout);
int  mynos_freeMsg(mynos_msg_t ** pmsg);
void mynos_signalSync(int channel);
void mynos_waitSync(int channel);
int  mynos_freeChannel(int c);
```

**DESCRIPTION** — `mynos_send` sends `size` bytes on the caller's end of
a channel; flags `MYNOS_IPC_SHARED` (the pages are shared, not copied)
and `MYNOS_IPC_NONBLOCK` (do not wait for the receiver to take it). It
returns when the receiver has the message, or it is queued.
`mynos_recv` waits for the next message, at most `timeout` ms (0:
forever), and allocates `*pmsg`; the data is at `(*pmsg)->start`.
Free it with `mynos_freeMsg`. `signalSync` and `waitSync` send and
receive an empty message. `mynos_freeChannel` closes the caller's end.

**RETURN VALUE** — 0 or a positive value on success; a `MYNOS_ERR_*`:
`BROKEN` when the other end is gone, `EXPIRED` (recv) after the
timeout, `BUSY` (recv) when another thread receives on the end, `FULL`
(send) when the receiver's queue (10 messages) or address space is
full.

**SEE ALSO** — port(2); appendix C.4, C.7.

---

## 24.20 port(2)

**NAME** — `mynos_allocPort`, `mynos_allocPortP`, `mynos_listenPort`,
`mynos_connectToPort`, `mynos_freePort`, `mynos_changePortOwner`,
`mynos_channelPeer`: ports and connections.

**SYNOPSIS**

```c
int mynos_allocPort();
int mynos_allocPortP(int port);
int mynos_listenPort(int port);
int mynos_connectToPort(int port);
int mynos_freePort(int port);
int mynos_changePortOwner(int port, int newpid);
int mynos_channelPeer(int channel);
```

**DESCRIPTION** — `allocPort` gives a new port, the caller's;
`allocPortP` a given one below `MYNOS_FIRST_FREE_PORT` (16), for
privileged processes. `listenPort` waits for a client and returns a new
channel to it; `connectToPort` connects and returns the client's end.
`channelPeer` is the pid at the other end of one of the caller's
channels: who calls a service.

**RETURN VALUE** — A port, a channel, a pid, or 0; a `MYNOS_ERR_*`.
`connectToPort` returns `BROKEN` when the port's owner ended.

**SEE ALSO** — ipc(2), registry(3); appendix C.2, C.3.

---

## 24.21 sem(2)

**NAME** — `mynos_initSem`, `mynos_P`, `mynos_tryP`, `mynos_V`,
`mynos_freeSem`: semaphores.

**SYNOPSIS**

```c
int mynos_initSem(unsigned int n);
int mynos_P(int sem);
int mynos_tryP(int sem);
int mynos_V(int sem);
int mynos_freeSem(int sem);
```

**DESCRIPTION** — `initSem` makes a counting semaphore with the value
`n`; `P` waits until it can decrement it; `tryP` decrements it only if
that does not wait; `V` increments it, waking a waiter.

**RETURN VALUE** — `initSem`: a semaphore. `tryP`: 0 taken, 1 would
block. Others: 0. A `MYNOS_ERR_*` on error.

**SEE ALSO** — driver(2); appendix A.6.

---

## 24.22 driver(2)

**NAME** — `mynos_driverRegister`, `mynos_enableIrq`,
`mynos_disableIrq`, `mynos_mapPhysical`, `mynos_dmaArea`, `inportb`, `outportb`: device
access, for processes with the `io` privilege.

**SYNOPSIS**

```c
int  mynos_driverRegister(char * name, unsigned int irq,
                          unsigned int * io, unsigned int * mem);
int  mynos_enableIrq(unsigned short n);
int  mynos_disableIrq(unsigned short n);
void * mynos_mapPhysical(unsigned long phys, int npages);
void * mynos_dmaArea(unsigned long * phys);
unsigned char inportb(unsigned short port);
void outportb(unsigned short port, unsigned char value);
```

**DESCRIPTION** — `driverRegister` makes the caller the driver of line
`irq` (1, 3–15) and returns a semaphore that the kernel `V`s at each of
its interrupts, after acknowledging the controllers; `io` and `mem` are
not used (pass `NULL`). `enableIrq` and `disableIrq` unmask and mask one
of the caller's lines. `mapPhysical` maps `npages` pages of device
memory (page-aligned, beyond RAM) into the caller. `dmaArea` maps the
kernel's DMA area (`MYNOS_DMA_AREA_SIZE`, 64 KB below 16 MB, for ISA
DMA: appendix B) and puts its physical address in `*phys`. `inportb` and
`outportb` are the `in` and `out` instructions.

**RETURN VALUE** — `driverRegister`: a semaphore, or `DENY` (no
privilege), `INVALID` (line 0, 2 or beyond 15), `BUSY` (another live
driver's). `mapPhysical`: an address, or `NULL`.

**SEE ALSO** — sem(2); chapter 23; appendix A.7, B.9.

---

## 24.23 process(2)

**NAME** — `mynos_spawn`, `mynos_spawnPriv`, `mynos_spawnImage`,
`mynos_processInfo`, `mynos_processes`, `mynos_kill`, `mynos_stats`:
processes.

**SYNOPSIS**

```c
int mynos_spawn(const char * path, char ** argv, char ** envp);
int mynos_spawnPriv(const char * path, char ** argv, char ** envp, int privileges);
int mynos_spawnImage(void * elf, unsigned int len, char ** argv, char ** envp);
int mynos_processInfo(int pid);
typedef struct { int pid, ppid; unsigned int privileges; unsigned int threads;
                 char name[16]; } mynos_process_t;
int mynos_processes(mynos_process_t * buf, int max);
int mynos_kill(int pid);
void mynos_stats(mynos_stats_t * st);
```

**DESCRIPTION** — `spawn` starts the ELF file `path` as a child, with
`argv` and `envp` (NULL-terminated; `envp` NULL: ours); a bare name is
looked for at the RAM disk's root, then in the current directory; wait
for it with `waitpid`. `spawnPriv` gives it privileges
(`MYNOS_PRIV_IO`), at most the caller's; `spawnImage` starts an image in
memory. `processInfo` returns a process's privileges, with
`MYNOS_PROC_ALIVE` while it runs. `processes` fills `buf` with the live
processes (`MYNOS_PROC_BYTECODE` in `privileges` for OCaml programs).
`kill` ends a process as killed, not `init` and not one with privileges
the caller lacks. `stats` fills counts of processes, threads and free
pages.

**RETURN VALUE** — `spawn*`: a pid or a `MYNOS_ERR_*` (`DENY` for a
privilege the caller lacks). `processInfo`: the bits, or `INVALID` for a
pid that is gone. `processes`: how many. `kill`: 0 or an error.

**SEE ALSO** — Mynos(3); appendix A.4, A.9; appendix D for `fork`,
`execve` and `waitpid`.

---

## 24.24 thread(2)

**NAME** — `mynos_threadCreate`, `mynos_threadExit`,
`mynos_threadSelf`: native threads.

**SYNOPSIS**

```c
int  mynos_threadCreate(void * (*start_routine)(void *), void * arg,
                        void * stack, unsigned int flags);
void mynos_threadExit(void * retval);
int  mynos_threadSelf();
```

**DESCRIPTION** — The threads of 2002: `threadCreate` starts
`start_routine(arg)` on the stack whose top is `stack` (the caller
allocates it; `consoled` passes `buffer + 0x4000` and flags 0); returning
from the routine calls `threadExit`. They share the process's TLS: a
program that uses the C library from several threads should use
pthreads (Linux threads, appendix D.7) instead.

**RETURN VALUE** — `threadCreate`: the new thread's id, or an error.

**SEE ALSO** — appendix A.4.

---

## 24.25 misc(2)

**NAME** — `mynos_sleep`, `mynos_setTimer`, `mynos_log`,
`mynos_consoleMode`, `mynos_consoleForeground`: time, the log, the
console.

**SYNOPSIS**

```c
int  mynos_sleep(unsigned long usec);
int  mynos_setTimer(unsigned long usec);          /* old name of mynos_sleep */
void mynos_log(const char * fmt, ...);
int  mynos_consoleMode(int canon, int echo, int vmin, int vtime);
int  mynos_consoleForeground(int pid);
```

**DESCRIPTION** — `sleep` blocks the calling thread at least `usec`
microseconds, in 10 ms ticks. `log` writes a formatted line to the kernel
log (the serial log port). `consoleMode` sets the console's input mode
(as `tcsetattr` does); `consoleForeground` names the program Ctrl-C ends
(0: none).

**RETURN VALUE** — `consoleForeground`: -1 without a console.

**SEE ALSO** — Mynos(3); appendix A.5.

---

## 24.26 trace(2)

**NAME** — `mynos_trace`: the event recorder.

**SYNOPSIS**

```c
int mynos_trace(int op, void * arg1, unsigned int arg2);
/* op: MYNOS_TRACE_START, _STOP, _READ, _INFO, _FREE, _MARK
   MYNOS_TRACE_EVENT_SIZE  96 */
```

**DESCRIPTION** — `START` begins a recording; `STOP` ends it; `READ`
copies at most `arg2` events into the buffer `arg1` and removes them;
`INFO` writes 9 words to `arg1`; `FREE` releases the kernel's buffer;
`MARK` records the label `arg1` of `arg2` bytes (56 kept). The layout of
an event and of `INFO`'s words is in appendix G.3 and G.5.

**RETURN VALUE** — `READ`: the number of events. `START`: `BUSY` if
another process records; `STOP`, `READ`, `FREE`: `DENY` for another's
recording.

**SEE ALSO** — Tracer(3); appendix G.

---

## 24.27 registry(3)

**NAME** — `mynos_registryRegister`, `mynos_registryLookUp`,
`mynos_registryList`: the name registry, from C.

**SYNOPSIS**

```c
#include <mynos.h>        /* includes mynos_registry.h */
typedef struct { char name[24]; int port; int owner; } mynos_reg_entry_t;
int mynos_registryRegister(char * name);
int mynos_registryLookUp(char * name);
int mynos_registryList(mynos_reg_entry_t * buf, int max);
```

**DESCRIPTION** — Requests of registry/1 to the registry at port 0:
register a name (a new port, the caller's), look one up, list the names
of live processes. Names are at most 20 characters (`MAXNAMELEN`).

**RETURN VALUE** — A port, or `MYNOS_ERR_INVALID` (taken, or no such
name); `List`: how many entries.

**SEE ALSO** — Registry(3); appendix E.5.

---

## 24.28 wire(3)

**NAME** — `wire_*`: typed IPC from C.

**SYNOPSIS**

```c
#include <mynos_wire.h>
void wire_writer_init(wire_writer * w);        void wire_writer_free(wire_writer * w);
void wire_put_int(wire_writer * w, long long v);
void wire_put_bool(wire_writer * w, int b);
void wire_put_string(wire_writer * w, const void * s, unsigned int len);
void wire_put_cstring(wire_writer * w, const char * s);
void wire_put_float(wire_writer * w, double f);
void wire_reader_init(wire_reader * r, const void * msg, unsigned int len);
long long wire_get_int(wire_reader * r);
int wire_get_bool(wire_reader * r);
const char * wire_get_string(wire_reader * r, unsigned int * len);
void wire_get_cstring(wire_reader * r, char * buf, unsigned int size);
double wire_get_float(wire_reader * r);
int wire_at_end(const wire_reader * r);
int wire_check_protocol(wire_reader * r, const char * id);
void wire_reply_ok(wire_writer * w);
void wire_reply_error(wire_writer * w, const char * message);
int wire_put_shape(wire_writer * w, const char * notation);
void wire_reply_description(wire_writer * w, const char * protocol,
     const char * summary, const wire_request_doc * requests, int n);
```

**DESCRIPTION** — The format of Wire(3), for services and clients in
C (`netd`, `displayd`, `consoled`, the registry). Reading never fails
loudly: a malformed message sets `r->error` and the getters return
empty values, to be checked at the end. `wire_check_protocol` reads a
request's id (0 if it is `id`); `wire_reply_ok` starts an `Ok` reply,
`wire_reply_error` writes a whole `Error` reply. A service describes
itself with `wire_reply_description`, its shapes written in a compact
notation: `U B I F S`, `O<x>`, `L<x>`, `(x,y)`, `name:x`,
`V(0:a=x,1:b=y)`; for instance `"(socket:I,max:I)"`.

**SEE ALSO** — Wire(3), Ipc(3); appendix E.2.

---

## 24.29 Obsolete calls

`mynos_serviceRegister` and `mynos_clientRegister` (calls 11 and 12)
reach a name table inside the kernel, from 2002, which no program uses:
names are the registry's (registry(3)). `mynos_setTimer` is the old
name of `mynos_sleep`.
