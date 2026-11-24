# 9. Networking

MyNOS has a network: a card, a TCP/IP stack, names, and encrypted
connections. This chapter shows how to look at it (`ifconfig`), how to
reach other machines (`ping`, `host`), how to fetch a page from the web
(`fetch`), how MyNOS checks who it is talking to (certificates), and how
to visit MyNOS from your own computer through its web server, `httpd`.
How the network is built is told in chapter 19 and appendix E.

## 9.1 Before you start

In QEMU, MyNOS has an NE2000 network card on QEMU's **user network**: a
small private network that QEMU builds inside itself, with a router, a
name server and a way out to the real network of your computer.

```
   ┌──────────────────────── QEMU ─────────────────────────┐
   │                                                       │
   │   MyNOS  10.0.2.15 ──────── 10.0.2.2  the router ─────┼──► your computer,
   │   (netd: NE2000,            10.0.2.3  the name server │    and the Internet
   │    lwIP, TLS)                                         │
   └───────────────────────────────────────────────────────┘
```

`tools/run-demo.sh` gives MyNOS the card unless you ask otherwise
(`NET= tools/run-demo.sh`, with an empty value, boots without one).
At boot, `netd`, the network service, asks for an address by DHCP; if no
answer comes, it takes QEMU's usual `10.0.2.15`. Seen from inside MyNOS,
**`10.0.2.2` is your computer**: a server you start on your computer
(on `127.0.0.1`) is reached from MyNOS at `10.0.2.2`.

Every command in this chapter talks to `netd`. If `netd` is not running,
they say `sh: no network (netd is not running)`.

## 9.2 Step 1: your address — `ifconfig`

Type `ifconfig` at the prompt:

```
mynos:/$ ifconfig
e0: 52:54:00:12:34:56
    address 10.0.2.15 netmask 255.255.255.0
    gateway 10.0.2.2 dns 10.0.2.3
```

The first line is the card's hardware (MAC) address; then the address
MyNOS has on the network, its netmask, the router it sends everything
through, and the name server it asks for names. `ifconfig` takes no
arguments: it only shows, it does not change.

## 9.3 Step 2: is it there? — `ping`

`ping HOST` sends a small packet (ICMP echo) to a machine and waits up to
two seconds for it to come back. It does this three times, a second
apart, or `COUNT` times if you give a number:

```
mynos:/$ ping 10.0.2.2 2
reply from 10.0.2.2: time 0 ms
reply from 10.0.2.2: time 0 ms
mynos:/$ ping example.com
reply from 104.20.23.154: time 10 ms
reply from 104.20.23.154: time 10 ms
reply from 104.20.23.154: time 10 ms
```

A name is first turned into an address (step 3). When a packet does not
come back, the line says why instead (`10.0.2.9: timeout`). Whether
pings reach the Internet depends on QEMU and on your computer: QEMU's
user network passes them on only where the host allows it.

## 9.4 Step 3: names — `host`

`host NAME` asks the name server for a machine's address:

```
mynos:/$ host example.com
example.com has address 104.20.23.154
mynos:/$ host nonexistent.invalid
sh: host not found
```

`example.com` has several addresses, which change: the name server may
give you another one than this book's.

`ifconfig`, `ping` and `host` are built into `sh`: they are typed
requests to `netd` (`Config`, `Ping`, `Resolve` of protocol `net/1`),
made by the shell itself.

## 9.5 Step 4: a page from the web — `fetch`

`fetch URL` asks a web server for a page and prints it. It speaks HTTP
and, for addresses starting with `https://`, HTTPS. It is a small
`curl`:

```
fetch [-i] [-o FILE] [-H 'Name: value']... [-d DATA|@FILE] [-X METHOD] URL
```

| Option | What it does |
|---|---|
| `-i` | print the status line and the headers before the body |
| `-o FILE` | write the body into `FILE` instead of the screen |
| `-H 'Name: value'` | add a header to the request (may be repeated) |
| `-d DATA` | send `DATA` with the request, which becomes a `POST` |
| `-d @FILE` | send the contents of `FILE` |
| `-X METHOD` | use another method (`PUT`, `DELETE`...) |

Options come before the URL. Each request opens one connection and
closes it. An answer that is not HTTP, a name that does not resolve or a
bad certificate ends with `fetch: ` and the reason. The exit status is 0
for an answer below 400, 1 otherwise, 2 for a mistake in the command
line (it then shows its usage).

**Example 1: a file from your computer.** Start a web server on your
computer, in a directory with a file `hello.txt` (for instance `python3
-m http.server 8000 --bind 127.0.0.1`), then in MyNOS:

```
mynos:/$ fetch http://10.0.2.2:8000/hello.txt
hello from the host
```

**Example 2: the headers, and the body into a file.**

```
mynos:/$ fetch -i -o /tmp/ex.html https://example.com/
200 OK
date: Thu, 19 Nov 2026 10:42:54 GMT
content-type: text/html; charset=utf-8
transfer-encoding: chunked
connection: close
server: cloudflare
...
mynos:/$ ls -l /tmp
     577  ex.html
```

Header names are shown in lower case. The body is decoded from
"chunked" transfer; it is never compressed (MyNOS does not ask for it).

**Example 3: sending data.**

```
mynos:/$ fetch -d "q=1" -H "X-Test: yes" https://httpbin.org/post
{
  "headers": {
    "Content-Length": "3",
    "Host": "httpbin.org",
    "User-Agent": "MyNOS",
    "X-Test": "yes"
  },
  "method": "POST",
  "data": "q=1",
  ...
}
```

`fetch` adds `Host`, `User-Agent: MyNOS`, `Content-Length` and
`Connection: close` unless you give them; it adds no `Content-Type`, so
give one with `-H` when the server needs it (`-H 'Content-Type:
application/json'`). Each wait for the server is limited to 30 seconds.

`fetch -o` is also the simplest way to bring a file into MyNOS from your
computer: `fetch -o /disk/notes.txt http://10.0.2.2:8000/notes.txt`.

## 9.6 Certificates: who is at the other end

An `https://` address is encrypted with TLS (versions 1.2 and 1.3), and
MyNOS checks the server's **certificate** before it sends anything: it
must be signed by an authority MyNOS trusts, and it must name the host
you asked for. The authorities are read from two files:

| File | What it holds |
|---|---|
| `/cacert.pem` | Mozilla's list of authorities (from curl's `cacert.pem`), on the RAM disk |
| `/disk/ca.pem` | your own, if the file exists: PEM certificates, one after the other |

Put in `/disk/ca.pem` the authority of a server of your own (a test
server with a self-made certificate, a company's proxy). Both files are
read at the first `https://` connection after boot, which takes about a
second and a half; later connections take a few tenths of a second.
`netd` reads them again when `/disk/ca.pem` changes (its size or date),
at the next `https://` connection.

When the check fails, the request fails, with the reason:

```
fetch: TLS: bad certificate: The certificate is not correctly signed by the trusted CA
```

(The wording after `bad certificate:` is mbedTLS's.) There is no way to
skip the check. MyNOS is a TLS client only: `httpd` (9.7) speaks plain
HTTP, and certificates are not checked for revocation.

## 9.7 MyNOS as a web server — `httpd`

`init` starts `httpd` at boot. It serves the files of `/disk/web` over
HTTP on port 80: a directory is shown as a list of links, a file is sent
as it is. `httpd` makes `/disk/web` at its first start, empty: what you
put there is on the web, the rest of `/disk` is not.

**From your computer.** `tools/run-demo.sh` forwards your computer's port
8080 to MyNOS's port 80, if 8080 is free, and says so:

```
run-demo.sh: http://localhost:8080/ is MyNOS's httpd
```

Open `http://localhost:8080/` in your browser, or:

```
$ curl -i http://localhost:8080/
HTTP/1.0 200 OK
Content-Type: text/html; charset=utf-8
Content-Length: 345
Server: MyNOS httpd
Connection: close

<!doctype html>
<html><head><meta charset="utf-8"><title>MyNOS /</title></head>
<body><h1>MyNOS: /</h1>
<ul>
<li><a href="Makefile">Makefile</a></li>
<li><a href="docs/">docs/</a></li>
<li><a href="hello.txt">hello.txt</a></li>
...
```

To use another port, set `HTTP` (`HTTP=9090 tools/run-demo.sh`); with
`HTTP=` (empty) nothing is forwarded. The forwarding listens on
`127.0.0.1` only: other computers cannot reach it.

What `httpd` does, exactly:

- it answers `GET`, and `PUT` and `POST` to receive files (below), with
  HTTP/1.0, and closes the connection after each answer;
- a path containing `..` gets `403 Forbidden`; a missing file `404 Not
  Found`; names starting with `.` are left out of listings;
- the type is guessed from the extension: `.html` and `.htm` are HTML;
  `.txt`, `.ml`, `.mli`, `.c`, `.h`, `.md`, `.rc`, `.bat` and names
  without an extension are text; `.png`, `.jpg`, `.css` have their types;
  the rest is sent as binary data;
- it serves eight connections at once; one that sends nothing for ten
  seconds is closed;
- each request is written to the kernel log (`httpd: 10.0.2.2 GET /
  HTTP/1.1`), not on the screen.

**Files from your computer into MyNOS.** `httpd` also receives files:

```
$ curl -T notes.txt http://localhost:8080/           (/disk/web/notes.txt)
$ curl -T photo.png http://localhost:8080/img/a.png  (/disk/web/img/a.png)
```

Missing directories are made, and a file of the same name is replaced
once the new one has arrived whole. In the browser, each directory's
listing ends with an **Upload** form, which sends one or more files into
it. Writing is allowed only to the computer QEMU runs on (in QEMU,
connections forwarded from it come from 10.0.2.2), and only to requests
that name MyNOS in `Host` and, if they carry one, in `Origin`, so that
a page of another site, open in your browser, cannot write to
`/disk/web`. `httpd -w` allows writing to anyone who can reach it: for a real
network, think first. `.env` files are never written.

Downloading through `httpd` is the way out of MyNOS: a recording
converted for Perfetto (chapter 11) is written to `/disk/web` and opened
from your browser.

`httpd` can serve another directory or port: `httpd [-w] [DIR [PORT]]`, for
instance `httpd /tmp 8081 &`, or the whole disk with `httpd /disk 8081 &`. A program inside MyNOS can reach MyNOS's
own address too: `fetch http://10.0.2.15/` asks `httpd` (the packets go
back in through lwIP's loopback, without the card). Whatever its
directory, `httpd` serves neither hidden files nor `.env` files, which
hold configuration and keys: they are not sent, nor listed.

> **THE MyNOS FACTOR — The network is a program you can watch.**
> In MyNOS the TCP/IP stack and the card's driver are one ordinary
> process, `netd`. Type `trace ping 10.0.2.2 1` and the recording shows
> `sh` asking `netd` for a `Ping`, and the card's interrupt (IRQ 9)
> waking `netd`'s thread before the answer goes back. The fourth lesson
> of the Tour (chapter 11) replays exactly this, with words at each step.

## 9.8 Packages — `pkg`

New demos and programs come as packages, from a repository on the web:
`ctrl-z-bg/mynos-packages` on GitHub. `pkg` lists them, installs them on
`/disk` and removes them:

```
mynos:/$ pkg list
pkg: 27 packages in the index (https://raw.githubusercontent.com/ctrl-z-bg/
mynos-packages/main/index.json)
2048       1.0                   2048, the sliding tile game, in a window ...
...
windtree   1.0                   A tree in the wind: a fractal tree under ...
...
mynos:/$ pkg install 2048
pkg: 2048 1.0: downloading 440320 bytes
pkg: 2048 1.0 installed (its bytecode): 2048
```

The program goes to `/disk/bin`, which is on `sh`'s `PATH`: from a
Terminal window of the graphical session, `2048` starts the game. The
package's files stay in `/disk/pkg/2048`. Some packages are commands for
the terminal (`utils` brings `grep`, `sort`, `head` and others), some
need another package, which `pkg` installs first (a story needs the
interpreter that plays it). This manual is a package too: after `pkg
install manual`, `man pkg` prints this command's entry of chapter 13.

The list grows after this book: the packages, with their documentation
up to date, are described on the repository's page,
https://github.com/ctrl-z-bg/mynos-packages.

| Command | What it does |
|---|---|
| `pkg list` | the packages of the index; `installed` beside those on `/disk` |
| `pkg list -i` | only the installed packages, with their version and how they were installed; it reads `/disk` alone, without the network |
| `pkg info NAME` | description, version, licence, size, the MyNOS it was built on, whether installed |
| `pkg install NAME...` | download, check, install (again, if it is installed) |
| `pkg install -s NAME...` | the same, compiled from its sources |
| `pkg remove NAME...` | remove the program and its files |
| `pkg search WORD` | the packages whose name or description has the word |
| `pkg update` | read the index again |
| `pkg upgrade` | read it, and install the newer versions of the installed packages |

The first command reads the index (`index.json`) and keeps a copy in
`/disk/pkg/index.json`; `pkg update` reads it again, to see new
packages and versions. A package is a `tar` archive with its program as
OCaml bytecode, its sources and its licence. `pkg install` checks the
archive's size and its BLAKE2b hash against the index's before it opens
it. Then it looks at the bytecode: if this MyNOS can run it (the same
format of bytecode, and every primitive it calls in the runtime), the
bytecode is installed; if not, `pkg` compiles the sources with `ocamlc`,
which takes some seconds more and gives the same program, made for this
MyNOS. The last word of the line says which happened.

The index can come from elsewhere: `MYNOS_PKG_URL` names another
repository with the same files, for instance one served from your
computer (`MYNOS_PKG_URL=http://10.0.2.2:8000/ pkg list`); the file
`/disk/pkg/url`, one line, does the same for every program, the
graphical session's Packages window too (chapter 10, 10.14); `run-demo.sh`
removes a `10.0.2.2` address from it at the next start, unless
`PKG=local` (H.9). Appendix H.9
tells how packages are built and published.

## 9.9 When something does not work

| You see | What it means |
|---|---|
| `sh: no network (netd is not running)` | MyNOS was started without a card (`NET=`), or `netd` did not start: see the log |
| `sh: the network service is not answering` | `netd` ended while you used it |
| `sh: host not found`, `fetch: host not found` | the name server does not know the name, or the computer has no Internet |
| `10.0.2.2: timeout` | no answer to a ping within two seconds |
| `fetch: timeout` | the server did not answer within 30 seconds |
| `fetch: TLS: bad certificate: ...` | the server's certificate is not signed by a trusted authority, or names another host (9.6) |
| `run-demo.sh: port 8080 is busy, no web server forwarding` | another program on your computer uses 8080: choose another with `HTTP=PORT` |
| `pkg: NAME: no such package` | the index does not have it: `pkg list` shows what it has, `pkg update` reads it again |
| `pkg: ...: its BLAKE2b hash is not the index's` | the archive is not the one the index describes: nothing was installed; try again later, or `pkg update` |
