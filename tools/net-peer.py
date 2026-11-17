#!/usr/bin/env python3
"""The host's side of the network test (tools/run-tests.sh).

  net-peer.py echo PORT          answer each connection's first line in
                                 capitals, then close (until killed)
  net-peer.py fetch PORT FILE    connect to localhost:PORT (QEMU forwards it
                                 to MyNOS) until it answers, send an HTTP
                                 request, write the answer to FILE
  net-peer.py https PORT CERT KEY
                                 an HTTPS server with that certificate:
                                 answers each request with "METHOD PATH
                                 BODY-IN-CAPITALS", chunked (until killed)
"""
import socket
import ssl
import sys
import time


def echo(port):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        with conn:
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            conn.sendall(data.upper())


def fetch(port, out, seconds=60):
    end = time.time() + seconds
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
                s.sendall(b"GET / HTTP/1.0\r\n\r\n")
                answer = b""
                while True:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    answer += chunk
                if answer:
                    open(out, "wb").write(answer)
                    return
        except OSError:
            pass
        time.sleep(0.5)


def https(port, cert, key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    while True:
        raw, _ = srv.accept()
        raw.settimeout(20)
        try:
            with ctx.wrap_socket(raw, server_side=True) as conn:
                data = b""
                while b"\r\n\r\n" not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                head, _, body = data.partition(b"\r\n\r\n")
                lines = head.decode("latin-1").split("\r\n")
                length = 0
                for line in lines[1:]:
                    name, _, value = line.partition(":")
                    if name.strip().lower() == "content-length":
                        length = int(value)
                while len(body) < length:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    body += chunk
                method, path = (lines[0].split(" ") + ["", ""])[:2]
                answer = ("%s %s " % (method, path)).encode() + body.upper()
                half = len(answer) // 2
                out = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" \
                      b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                for part in (answer[:half], answer[half:]):
                    out += b"%x\r\n%s\r\n" % (len(part), part)
                conn.sendall(out + b"0\r\n\r\n")
        except (OSError, ssl.SSLError):
            pass                        # a refused handshake: the next one


if __name__ == "__main__":
    if sys.argv[1] == "echo":
        echo(int(sys.argv[2]))
    elif sys.argv[1] == "https":
        https(int(sys.argv[2]), sys.argv[3], sys.argv[4])
    else:
        fetch(int(sys.argv[2]), sys.argv[3])
