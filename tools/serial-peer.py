#!/usr/bin/env python3
"""A terminal on MyNOS's second serial port, for the tests (tools/run-tests.sh;
doc/decisions/console.md).

  serial-peer.py SOCKET LOG INPUT

Connects to QEMU's serial port at the Unix socket SOCKET (retrying while
QEMU starts), writes everything MyNOS sends to LOG, and sends what is
appended to the file INPUT, as a terminal sends what is typed or pasted.
Runs until killed.
"""
import os
import socket
import sys
import threading
import time


def main(path, log, inp):
    s = socket.socket(socket.AF_UNIX)
    for _ in range(200):
        try:
            s.connect(path)
            break
        except OSError:
            time.sleep(0.1)
    out = open(log, "ab", buffering=0)

    def receive():
        while True:
            data = s.recv(4096)
            if not data:
                return
            out.write(data)

    threading.Thread(target=receive, daemon=True).start()
    sent = 0
    while True:
        try:
            data = open(inp, "rb").read()
        except OSError:
            data = b""
        if len(data) > sent:
            s.sendall(data[sent:])
            sent = len(data)
        time.sleep(0.1)


if __name__ == "__main__":
    main(*sys.argv[1:4])
