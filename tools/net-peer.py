#!/usr/bin/env python3
"""The host's side of the network test (tools/run-tests.sh).

  net-peer.py echo PORT          answer each connection's first line in
                                 capitals, then close (until killed)
  net-peer.py fetch PORT FILE    connect to localhost:PORT (QEMU forwards it
                                 to MyNOS) until it answers, send an HTTP
                                 request, write the answer to FILE
"""
import socket
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


if __name__ == "__main__":
    if sys.argv[1] == "echo":
        echo(int(sys.argv[2]))
    else:
        fetch(int(sys.argv[2]), sys.argv[3])
