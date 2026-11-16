#!/bin/sh
# Boot the whole system headless in QEMU, capture the kernel console (mirrored
# to COM2) and check the expected output. Build first with tools/build-all.sh.
#
# Usage: tools/run-tests.sh            exit status 0 if all checks pass
# Environment: WAIT seconds to let the system run (default 10)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

ocamlrun=$(tools/ocamlrun-path.sh)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
log=$tmp/log1 log2=$tmp/log2 log3=$tmp/log3 log4=$tmp/log4 log5=$tmp/log5
log6=$tmp/log6 log7=$tmp/log7

timeout "${WAIT:-10}" tools/run-qemu.sh \
    "$ocamlrun" \
    tests/hello/hello.byte \
    services/registry/registry \
    services/fs/memrofs/memrofsd \
    services/keyboard/keyboardd \
    services/serial/seriald \
    tests/abi/abi \
    tests/ramdisk/ramdisk.dsk \
    -- -display none -serial null -serial "file:$log" || true

# second boot: effect handlers (OCaml 5 only)
if [ -f tests/effects/effects.byte ]; then
    timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" tests/effects/effects.byte \
        -- -display none -serial null -serial "file:$log2" || true
    cat "$log2" >> "$log"
fi

# third boot: the Mynos OCaml library, reading a file through memrofs
if [ -f tests/mynos-ocaml/mynos_test.byte ]; then
    timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" \
        tests/mynos-ocaml/mynos_test.byte services/registry/registry \
        services/fs/memrofs/memrofsd tests/ramdisk/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log3" || true
    cat "$log3" >> "$log"
fi

# fifth boot: no bytecode module; ocamlrun loads init.byte from the RAM disk
# and it reads files through the standard library
if [ -f tests/files/ramdisk.dsk ]; then
    timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        tests/files/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log5" || true
    cat "$log5" >> "$log"
fi

# sixth boot: init.byte starts other programs from the RAM disk
if [ -f tests/spawn/ramdisk.dsk ]; then
    timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        tests/spawn/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log6" || true
    cat "$log6" >> "$log"
fi

# fourth boot: typing on the keyboard, read by OCaml through consoled
if [ -f tests/console/echo.byte ] && [ -f services/console/consoled ]; then
    tools/run-qemu.sh "$ocamlrun" tests/console/echo.byte \
        services/registry/registry services/console/consoled \
        -- -display none -serial null -serial "file:$log4" \
           -monitor "unix:$tmp/mon,server,nowait" &
    qemu=$!
    sleep 4
    keys() {
        for k in "$@"; do printf 'sendkey %s\n' "$k"; done |
            socat - "UNIX-CONNECT:$tmp/mon" >/dev/null
        sleep 0.5
    }
    keys h i ret
    keys shift-o shift-k x backspace ret
    keys ctrl-d
    sleep 2
    printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon" >/dev/null || true
    wait $qemu || true
    cat "$log4" >> "$log"
fi

# seventh boot: the shell (the OCaml toplevel), driven through the keyboard
if [ -f shell/ramdisk.dsk ] && [ -f services/console/consoled ]; then
    MEM=256 tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        services/console/consoled shell/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log7" \
           -monitor "unix:$tmp/mon7,server,nowait" &
    qemu=$!
    i=0
    while [ $i -lt 60 ] && ! grep -aq '^# ' "$log7" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    for phrase in '1 + 2;;\n' 'List.map (fun x -> x * x) [1; 2; 3];;\n' \
                  'cat "AUTOEXEC.BAT";;\n' 'ls ();;\n' \
                  'run "child.byte" ["4"];;\n' '1 + "one";;\n'; do
        tools/type-keys.py "$tmp/mon7" "$phrase"
        sleep 2
    done
    printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon7" >/dev/null || true
    wait $qemu || true
    cat "$log7" >> "$log"
fi

fail=0
expect() {
    if grep -aqF -- "$1" "$log"; then
        echo "ok    $1"
    else
        echo "FAIL  $1"; fail=1
    fi
}
reject() {
    if grep -aqF -- "$1" "$log"; then
        echo "FAIL  unexpected: $1"; fail=1
    fi
}

expect "Hello from OCaml on MyNOS!"
expect "5 * 5 = 25"
expect "Service keyboard registered"
expect "Service serial registered"
expect "Hello from memrofs!"
expect "abi: all checks passed"
if [ -f tests/effects/effects.byte ]; then
    expect "effects ok"
fi
if [ -f tests/mynos-ocaml/mynos_test.byte ]; then
    expect "mynos-ocaml: all checks passed"
fi
if [ -f tests/files/ramdisk.dsk ]; then
    expect "files: all checks passed"
fi
if [ -f tests/spawn/ramdisk.dsk ]; then
    expect "spawn child"
    expect "args [hello world]"
    expect "spawn: all checks passed"
fi
if [ -f shell/ramdisk.dsk ] && [ -f services/console/consoled ]; then
    expect "MyNOS shell. Type help ();; for help."
    expect "- : int = 3"
    expect "- : int list = [1; 4; 9]"
    expect "This file lives in the MyNOS RAM disk."
    expect "stdlib__List.cmi"
    expect "args [4]"
    expect "- : Mynos.status = Mynos.Exited 4"
    expect "Error: "
fi
if [ -f tests/console/echo.byte ] && [ -f services/console/consoled ]; then
    expect 'console: line 1: "hi"'
    expect 'console: line 2: "OK"'
    expect "console: end of input after 2 lines"
fi
reject "PANIC"
reject "page fault (?)"
reject "Problems releasing pages"
reject "FAIL"

if [ $fail -ne 0 ]; then
    echo "--- console log ---"
    cat "$log"
    exit 1
fi
echo "all tests passed"
