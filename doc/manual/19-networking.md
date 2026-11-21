# 19. Networking

A MyNOS program reaches the network by sending typed requests to a
service, `net`, as it reaches files by sending requests to `fatfs`. There
are no sockets in the kernel and no socket calls in the C library. This
chapter shows how to use the network from OCaml: the service and its
requests (19.1–19.2), TCP clients and timeouts (19.3–19.4), a complete
TCP server (19.5), UDP (19.6), TLS (19.7), and the two modules built on
top, `Http` (19.8) and `Json` (19.9). The service itself, `netd`, is
described in appendix E.12.

## 19.1 The network is a service

`netd` is one process: the lwIP TCP/IP stack, the NE2000 card's driver
and mbedTLS. It registers the name `net` and speaks the protocol
**net/1**. Module `Net` (`mynos-lib/ocaml/net.mli`) gives the requests as
a GADT, each indexed by the type of its reply:

```
   your program                     netd (C, io privilege)
  ┌──────────────────┐   net/1     ┌──────────────────────────────┐
  │ Net.call n       │ ──────────► │ lwIP ── NE2000 (0x300, IRQ 9)│──► wire
  │  (Net.Recv (s,   │ ◄────────── │ mbedTLS (Connect_tls)        │
  │        4096))    │  Ok "..."   │ sockets: numbers, per process│
  └──────────────────┘             └──────────────────────────────┘
   Http, Json (OCaml, in your process)
```

| Request | Reply | What it does |
|---|---|---|
| `Config` | `config` | MAC, address, netmask, gateway, DNS server |
| `Ping (address, timeout_ms)` | `int` | round trip, in ms |
| `Resolve name` | `string` | an IPv4 address, by DNS |
| `Connect (address, port)` | `int` | a TCP socket |
| `Connect_tls (host, port)` | `int` | a TCP socket with TLS over it |
| `Listen port` | `int` | a listening TCP socket |
| `Accept socket` | `int * string * int` | a connection, its peer's address and port |
| `Send (socket, data)` | `int` | all of `data` sent; its length |
| `Recv (socket, max)` | `string` | at most `max` bytes (≤ 16384); `""` at the end |
| `Close socket` | `unit` | |
| `Set_timeout (socket, ms)` | `unit` | a bound on `Recv`, `Accept`, `Recv_from` |
| `Udp_bind port` | `int` | a UDP socket (0: any port) |
| `Send_to (socket, address, port, data)` | `int` | one datagram, at most 8192 bytes |
| `Recv_from (socket, max)` | `string * int * string` | the next datagram: sender, port, data |

Addresses are dotted IPv4 strings. A socket is a number that belongs to
the process that made it; another process that names it gets the error
`not your socket`. When a process ends, netd closes its sockets within a
second, so a restarted server can listen on its port again.

## 19.2 Connecting, and errors

`Net.connect ()` looks the service up (waiting up to 5 s for it to be
registered); `Net.call` sends one request and waits for its reply:

```ocaml
let n = Net.connect () in
let c = Net.call n Net.Config in
Printf.printf "%s via %s, DNS %s\n" c.Net.address c.gateway c.dns;
let ms = Net.call n (Net.Ping ("10.0.2.2", 1000)) in
let a = Net.call n (Net.Resolve "example.com") in
...
```

A value of type `Net.t` is only the service's name and its port: it holds
no connection, and every `call` makes one (appendix E.1). It may be
shared between threads and domains.

A request that netd cannot do raises `Ipc.Remote_error (service,
message)`. The messages are short and fixed, so a program can match
them:

| Message | When |
|---|---|
| `host not found` | `Resolve`, or a TLS or HTTP host name, unknown to DNS |
| `connection refused` | `Connect` to a port where nobody listens |
| `connection reset` | the other side reset an open connection |
| `timeout` | a `Recv`, `Accept` or `Recv_from` longer than `Set_timeout`; a `Ping` without answer; a `Connect` or `Connect_tls` after 20 s |
| `not your socket`, `not a socket` | a socket of another process, or none |
| `TLS: ...` | the handshake or the certificate failed (19.7) |

Without the service (no NE2000 card: netd ended at boot), `Net.connect`
raises `Mynos.Error` after its 5 s.

## 19.3 A TCP client

A client connects, sends, and reads until the server closes:

```ocaml
let n = Net.connect () in
let s = Net.call n (Net.Connect ("10.0.2.2", 8000)) in
ignore (Net.call n (Net.Send (s, "GET /hello.txt HTTP/1.0\r\n\r\n")));
let b = Buffer.create 1024 in
let rec loop () =
  match Net.call n (Net.Recv (s, 16384)) with
  | "" -> ()                                   (* the server closed *)
  | data -> Buffer.add_string b data; loop () in
loop ();
Net.call n (Net.Close s);
print_string (Buffer.contents b)
```

`Connect` takes an address: resolve a name first with `Resolve`. `Send`
returns only once all the bytes are taken; `Recv` returns what has
arrived, at most `max` bytes, waiting if nothing has; the empty string
means the other side closed. Each `Recv` is a request, so read with a
large `max` (16384, the largest) rather than a byte at a time.

## 19.4 Timeouts

By default `Recv`, `Accept` and `Recv_from` wait forever. `Set_timeout
(s, ms)` bounds every later wait on that socket; when it passes the
request fails with `timeout`, and the socket stays usable:

```ocaml
Net.call n (Net.Set_timeout (s, 5000));
match Net.call n (Net.Recv (s, 4096)) with
| data -> ...
| exception Ipc.Remote_error (_, "timeout") -> (* five seconds of silence *)
```

`Ping` carries its own timeout. `Connect` and `Connect_tls` (with its
handshake) have a fixed one: 20 seconds without a connection and they
fail with `timeout` (lwIP alone would give up after some 27 seconds,
with `connection aborted`).

## 19.5 A complete example: a TCP echo server

`echod` listens on a port (7 by default) and sends back what each client
sends, until the client closes or is silent for 30 seconds:

```ocaml
(* echod: a TCP echo server.  echod [PORT]  (7 by default)
   Each connection gets back what it sends, until it closes; one
   connection at a time. *)

let port = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 7

(* one connection: echo until the peer closes, or 30 s of silence *)
let serve n s =
  Net.call n (Net.Set_timeout (s, 30_000));
  let rec loop total =
    match Net.call n (Net.Recv (s, 4096)) with
    | "" -> total                                   (* the peer closed *)
    | data ->
      ignore (Net.call n (Net.Send (s, data)));
      loop (total + String.length data)
    | exception Ipc.Remote_error (_, "timeout") -> total in
  Fun.protect ~finally:(fun () -> Net.call n (Net.Close s))
    (fun () -> loop 0)

let () =
  let n = Net.connect () in
  let l = Net.call n (Net.Listen port) in
  Printf.printf "echod: listening on port %d\n%!" port;
  while true do
    let s, address, p = Net.call n (Net.Accept l) in
    match serve n s with
    | bytes -> Printf.printf "echod: %s:%d, %d bytes\n%!" address p bytes
    | exception Ipc.Remote_error (_, m) ->
      Printf.printf "echod: %s:%d: %s\n%!" address p m
  done
```

`Listen` gives a listening socket; each `Accept` waits for a connection
and returns a new socket for it, with the peer's address and port. The
`Fun.protect` closes the connection's socket whatever happens, and a
client's error (it reset the connection) ends that client only.

Compile it on the build machine, or inside MyNOS (F.9):

```
$ ocamlc -use-prims /primitives mynos.cma -o /disk/echod.byte /disk/echod.ml
$ /disk/echod.byte &
```

QEMU's user network lets the host in only through forwarded ports.
`tools/run-qemu.sh` forwards one (`HTTP=PORT` to MyNOS's port 80, which
`httpd` holds); for port 7, start QEMU with a netdev of your own, such as
`-netdev user,id=n0,hostfwd=tcp:127.0.0.1:4707-:7`. Then, on the host,
two lines sent to 4707 come back, and the server logs:

```
echod: listening on port 7
echod: 10.0.2.2:60640, 12 bytes
echod: 10.0.2.2:37418, 24 bytes
```

(the peer is QEMU's gateway, `10.0.2.2`, for every host connection).

**Many clients at once.** `echod` serves one connection at a time: a
second client waits in `Accept`'s queue. A server that must not wait
hands each connection to another domain, as `httpd` does (its main domain
accepts; 8 worker domains serve, each with a 10 s timeout):

```ocaml
let s, _, _ = Net.call n (Net.Accept l) in
ignore (Domain.spawn (fun () -> ignore (serve n s)))
```

A domain is not free: it is a thread with its backup thread and a minor
heap of its own (appendix F.7). A long-running service is better served
by a fixed pool of domains fed by a queue, as `httpd` and `llmd` do.

## 19.6 UDP

A UDP socket is bound to a port (0: any free one); `Send_to` sends one
datagram, `Recv_from` waits for the next, and `Set_timeout` bounds the
wait as for TCP:

```ocaml
let u = Net.call n (Net.Udp_bind 0) in
Net.call n (Net.Set_timeout (u, 2000));
ignore (Net.call n (Net.Send_to (u, "10.0.2.2", 47053, "ping")));
let address, port, data = Net.call n (Net.Recv_from (u, 512)) in
Net.call n (Net.Close u)
```

A datagram longer than `max` is cut to `max` bytes. Up to 32 datagrams
wait to be read on a socket; netd drops later ones, as UDP allows.

## 19.7 TLS

`Connect_tls (host, port)` opens a TCP connection and makes a TLS 1.2 or
1.3 session over it, in netd. `host` is a name (resolved by DNS) or an
address; the server's certificate must be valid for it and come from an
authority netd trusts: Mozilla's list, `/cacert.pem` on the RAM disk,
and the user's own, `/disk/ca.pem` if present, both read at the first
`Connect_tls`. Afterwards `Send` and `Recv` carry the clear bytes, and
the program does nothing else differently:

```ocaml
let s = Net.call n (Net.Connect_tls ("example.com", 443)) in
ignore (Net.call n (Net.Send (s, "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n")));
let first = Net.call n (Net.Recv (s, 16384)) in
...
```

A refused certificate is an `Ipc.Remote_error` whose message starts with
`TLS: `, and says why (an unknown authority, a name that does not
match). Only clients: netd does not serve TLS.

> **THE MyNOS FACTOR — The certificates stay in one place.**
> The TLS library, the trusted authorities and the session keys live in
> netd. A program that fetches `https://` pages links no cryptography
> and opens no certificate file: it sends `Connect_tls`, then clear
> bytes. Updating the authorities, or fixing the TLS library, is done
> once, in one process, for every program in the system.

## 19.8 HTTP: module `Http`

`Http` (`mynos-lib/ocaml/http.mli`) is an HTTP/1.1 client written in
OCaml over `Net`. It runs in the calling process.

```ocaml
let r = Http.get "https://example.com/" in
r.Http.status;                        (* 200 *)
Http.header "content-type" r;         (* Some "text/html" *)
let r = Http.post ~headers:[ "content-type", "application/json" ]
          ~body:{|{"q": 1}|} "https://api.example.com/search" in
...
```

`Http.request ?net ?meth ?headers ?body ?timeout url` is the general
form; `get` and `post` are shorthands. It sends `Host`, `User-Agent:
MyNOS`, `Content-Length` and `Connection: close` unless `headers` gives
them, opens one connection per request (`Connect_tls` for `https://`),
reads the whole answer, and decodes a chunked body. It does not follow
redirects and asks for no compression. A `response` has `status`,
`reason`, `headers` (names in lower case) and `body`.

An answer with a status of 404 or 500 is an answer, not an exception;
`Http.Error` is raised only for a bad URL, an error of the network (its
message: `host not found`, `TLS: ...`, `timeout`) or bytes that are not
HTTP. `timeout` (ms, 30000 by default) bounds each wait for the server
once the connection is made.

**A complete example: geturl.** A small `curl`:

```ocaml
(* geturl: fetch a URL, print the answer.  geturl [-i] URL
   -i: the status line and the headers too. *)

let () =
  let head, url =
    match List.tl (Array.to_list Sys.argv) with
    | [ "-i"; url ] -> true, url
    | [ url ] -> false, url
    | _ -> prerr_endline "usage: geturl [-i] URL"; exit 2 in
  match Http.get ~timeout:10_000 url with
  | r ->
    if head then begin
      Printf.printf "%d %s\n" r.Http.status r.reason;
      List.iter (fun (k, v) -> Printf.printf "%s: %s\n" k v) r.headers;
      print_newline ()
    end;
    print_string r.body;
    exit (if r.status < 400 then 0 else 1)
  | exception Http.Error m -> prerr_endline ("geturl: " ^ m); exit 1
  | exception Mynos.Error _ -> prerr_endline "geturl: no network service"; exit 1
```

Against a web server on the host (Python's `http.server`, port 8000):

```
$ geturl.byte -i http://10.0.2.2:8000/hello.txt
200 OK
server: SimpleHTTP/0.6 Python/3.14.4
date: Thu, 19 Nov 2026 10:44:59 GMT
content-type: text/plain
content-length: 23
last-modified: Thu, 19 Nov 2026 10:44:42 GMT

Hello from a FAT disk!
$ geturl.byte ftp://x
geturl: ftp://x: not an http:// or https:// URL
```

The system's own `fetch` command (`fetch/`) is the same idea with more
options.

## 19.9 JSON: module `Json`

Web APIs speak JSON. `Json` (`mynos-lib/ocaml/json.mli`) reads and writes
it as a variant:

```ocaml
type t = Null | Bool of bool | Number of float | String of string
       | Array of t list | Object of (string * t) list
```

`of_string` parses (RFC 8259; `\u` escapes become UTF-8), `to_string`
writes compactly, an integral number without a fraction. The accessors
`member`, `index`, `to_string_value`, `to_int`, `to_float`, `to_bool` and
`to_list` read a value and raise `Json.Error` when it is of another kind;
`member` gives `Null` for a missing field, so optional fields need no
exception:

```ocaml
let r = Http.get "http://10.0.2.2:8000/info.json" in
(* {"name": "MyNOS", "year": 2002, "tags": ["microkernel", "ocaml"]} *)
let v = Json.of_string r.Http.body in
let name = Json.(member "name" v |> to_string_value)          (* "MyNOS" *)
and year = Json.(member "year" v |> to_int)                   (* 2002 *)
and tags = Json.(member "tags" v |> to_list |> List.map to_string_value) in
Json.member "nope" v;                                         (* Null *)
Json.to_string (Json.Object [ "ok", Json.Bool true; "n", Json.Number 3. ])
                                                    (* {"ok":true,"n":3} *)
```

`Json.to_int (Json.String "x")` raises `Json.Error "JSON: a string, not a
number"`.

## 19.10 Known limits

- IPv4 only; one card (NE2000), one address, by DHCP or QEMU's defaults.
- At most 64 sockets in the whole system; a `Recv` returns at most
  16384 bytes and a datagram is at most 8192.
- TLS for clients only; no client certificates.
- `Http`: no redirects, no keep-alive, no compression, the whole answer
  in memory; its `timeout` does not cover connecting.
- `Connect` cannot be bounded by a timeout of the program's own.
