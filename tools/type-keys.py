#!/usr/bin/env python3
"""Type text on a MyNOS machine through the QEMU monitor (sendkey).

Usage: tools/type-keys.py MONITOR_SOCKET TEXT...
       Each TEXT is typed in turn; "\\n" in it is Enter, "^D" is Ctrl-D,
       "{name}" is the QEMU key name (e.g. {up}, {down}).
The keyboard is a US layout (services/keyboard/keymap.h).
"""
import re
import socket
import sys
import time

SHIFTED = {
    '!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7',
    '*': '8', '(': '9', ')': '0', '_': 'minus', '+': 'equal',
    '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash',
    ':': 'semicolon', '"': 'apostrophe', '<': 'comma', '>': 'dot',
    '?': 'slash', '~': 'grave_accent',
}
PLAIN = {
    ' ': 'spc', '\n': 'ret', '-': 'minus', '=': 'equal',
    '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
    ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot',
    '/': 'slash', '`': 'grave_accent',
}


# {up}, {down}, {ctrl-p}...: a QEMU key name; "{ x = 1 }" is just text
KEYNAME = re.compile(r'\{([a-z0-9_-]+)\}')


def keys(text):
    i = 0
    while i < len(text):
        c = text[i]
        if text.startswith('^D', i):
            yield 'ctrl-d'
            i += 2
            continue
        m = KEYNAME.match(text, i)
        if m:
            yield m.group(1)
            i = m.end()
            continue
        if c.isascii() and c.isalpha():
            yield ('shift-' + c.lower()) if c.isupper() else c
        elif c.isdigit():
            yield c
        elif c in PLAIN:
            yield PLAIN[c]
        elif c in SHIFTED:
            yield 'shift-' + SHIFTED[c]
        else:
            raise SystemExit('cannot type %r' % c)
        i += 1


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sys.argv[1])
    for text in sys.argv[2:]:
        for k in keys(text.replace('\\n', '\n')):
            s.sendall(('sendkey %s\n' % k).encode())
            time.sleep(0.05)
    time.sleep(0.3)
    s.close()


if __name__ == '__main__':
    main()
