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
log6=$tmp/log6 log7=$tmp/log7 log8=$tmp/log8 log9=$tmp/log9 logf=$tmp/logf
logs=$tmp/logs logn=$tmp/logn

timeout "${WAIT:-10}" tools/run-qemu.sh \
    "$ocamlrun" \
    tests/hello/hello.byte \
    services/registry/registry \
    services/fs/memrofs/memrofsd \
    services/keyboard/keyboardd \
    services/serial/seriald \
    "tests/abi/abi one two" \
    tests/ramdisk/ramdisk.dsk \
    -- -display none -serial null -serial "file:$log" || true

# second boot: effect handlers (OCaml 5 only)
if [ -f tests/effects/effects.byte ]; then
    timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" tests/effects/effects.byte \
        -- -display none -serial null -serial "file:$log2" || true
    cat "$log2" >> "$log"
fi

# the network: netd (lwIP and the NE2000 driver) with QEMU's user network;
# on the host, a TCP server (47001), a client of MyNOS's port 80
# (forwarded from 47080) and HTTPS servers (47443-47445, tests/net/tls)
net_fetched=
if [ -f tests/net/ramdisk.dsk ]; then
    tools/net-peer.py echo 47001 & echo_pid=$!
    tools/net-peer.py fetch 47080 "$tmp/fetched" & fetch_pid=$!
    tls=tests/net/tls
    tools/net-peer.py https 47443 $tls/good.pem $tls/good.key & https_pid=$!
    tools/net-peer.py https 47444 $tls/untrusted.pem $tls/untrusted.key & https2_pid=$!
    tools/net-peer.py https 47445 $tls/wrongname.pem $tls/wrongname.key & https3_pid=$!
    NET=1 HTTP=47080 timeout "${WAIT_NET:-40}" tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        tests/net/ramdisk.dsk \
        -- -display none -serial null -serial "file:$logn" &
    qemu=$!
    i=0
    while [ $i -lt "${WAIT_NET:-40}" ] &&
          ! grep -aq 'net: all checks passed\|net: FAIL\|PANIC' "$logn" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    kill $qemu $echo_pid $fetch_pid $https_pid $https2_pid $https3_pid 2>/dev/null || true
    wait $qemu 2>/dev/null || true
    cat "$logn" >> "$log"
    grep -q "hello from a server in MyNOS" "$tmp/fetched" 2>/dev/null && net_fetched=yes
fi

# ninth boot: the ATA driver (OCaml) on a QEMU disk: 2048 sectors, each
# starting with "MYNOS SECTOR n"; the test writes sector 1000
disk_written=
if [ -f tests/storage/ramdisk.dsk ]; then
    python3 -c '
import sys
with open(sys.argv[1], "wb") as f:
    for n in range(2048):
        s = ("MYNOS SECTOR %d\n" % n).encode()
        f.write(s + bytes(512 - len(s)))' "$tmp/disk.img"
    DISK=$tmp/disk.img MEM=64 timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        tests/storage/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log9" || true
    cat "$log9" >> "$log"
    disk_written=$(python3 -c '
import sys
d = open(sys.argv[1], "rb").read()
print(d[1000 * 512:1000 * 512 + 16].decode("latin-1"))' "$tmp/disk.img")
fi

# tenth and eleventh boots: fatfs (OCaml) on FAT16 and FAT32 images made by
# mkfs.fat and mtools; afterwards fsck.fat must find them consistent, and
# mtools must read what MyNOS wrote
fat_checks=
if [ -f tests/fat/ramdisk.dsk ]; then
    for img in fat16 fat32; do
        cp tests/fat/$img.img tests/fat/run-$img.img
        DISK=tests/fat/run-$img.img MEM=64 timeout "${WAIT:-20}" tools/run-qemu.sh "$ocamlrun" \
            services/registry/registry services/fs/memrofs/memrofsd \
            tests/fat/ramdisk.dsk \
            -- -display none -serial null -serial "file:$logf" || true
        sed "s/^fat: /fat ($img): /" "$logf" >> "$log"
        if fsck.fat -n tests/fat/run-$img.img >/dev/null 2>&1; then
            fat_checks="$fat_checks $img:fsck-ok"
        fi
        if [ "$(tools/in-container.sh dev mtype -i tests/fat/run-$img.img ::/new.ml 2>/dev/null)" = \
             "$(printf 'let answer = 42\nlet more = 1')" ] &&
           tools/in-container.sh dev mdir -i tests/fat/run-$img.img ::/projects 2>/dev/null |
             grep -q "A Longer Name Than Eight.txt"; then
            fat_checks="$fat_checks $img:mtools-ok"
        fi
        # the file's date: this century, from the clock (not 1980)
        if tools/in-container.sh dev mdir -i tests/fat/run-$img.img ::/new.ml 2>/dev/null |
             grep -q " 20[2-9][0-9]-"; then
            fat_checks="$fat_checks $img:date-ok"
        fi
        rm -f tests/fat/run-$img.img
    done
fi

# eighth boot: domains, i.e. Linux threads (clone, futex)
if [ -f tests/domains/domains.byte ]; then
    MEM=128 timeout "${WAIT:-15}" tools/run-qemu.sh "$ocamlrun" \
        tests/domains/domains.byte \
        -- -display none -serial null -serial "file:$log8" || true
    cat "$log8" >> "$log"
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

# the kernel stress test (C, both toolchains): processes, IPC, timers,
# semaphores, invalid arguments and pointers, memory coming back
if [ -f tests/stress/ramdisk.dsk ]; then
    timeout "${WAIT_STRESS:-120}" tools/run-qemu.sh \
        services/registry/registry services/fs/memrofs/memrofsd \
        tests/stress/stress tests/stress/ramdisk.dsk \
        -- -display none -serial null -serial "file:$logs" &
    qemu=$!
    i=0
    while [ $i -lt "${WAIT_STRESS:-120}" ] &&
          ! grep -aq 'stress: all checks passed\|checks failed\|PANIC' "$logs" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    kill $qemu 2>/dev/null || true
    wait $qemu 2>/dev/null || true
    cat "$logs" >> "$log"
fi

# sixth boot: init.byte starts other programs from the RAM disk (about
# twenty-five of them, one after the other)
if [ -f tests/spawn/ramdisk.dsk ]; then
    timeout "${WAIT:-15}" tools/run-qemu.sh "$ocamlrun" \
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

# seventh boot: the system RAM disk, init starts the services and sh, driven
# through the keyboard: the OCaml toplevel (ocaml), programs, sh again
history_saved= kilo_saved= edit_saved= sh_saved= trace_calls= trace_json=
if [ -f system/ramdisk.dsk ]; then
    # a disk, for /disk and the shell's history: a copy of the FAT16 test image
    [ -f tests/fat/fat16.img ] && cp tests/fat/fat16.img tests/fat/run-shell.img
    DISK=$([ -f tests/fat/run-shell.img ] && echo tests/fat/run-shell.img) \
    MEM=256 tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        system/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log7" \
           -monitor "unix:$tmp/mon7,server,nowait" &
    qemu=$!
    i=0
    while [ $i -lt 60 ] && ! grep -aq 'mynos:/' "$log7" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    for phrase in 'ec{tab}completed by tab\n' 'ocaml\n' '' '1 + 2;;\n' 'List.map (fun x -> x * x) [1; 2; 3];;\n' \
                  'cat "AUTOEXEC.BAT";;\n' 'ls ();;\n' \
                  'run "child.byte" ["4"];;\n' '1 + "one";;\n' \
                  '6 * 7;;\n' '{up}\n' '1 + 1;;\n' 'x{up}{up}{down}\n' \
                  'write "/tmp/t.ml" "let t = 6 * 9;;";;\n' \
                  '#use "/tmp/t.ml";;\n' 'ls ~dir:"/tmp" ();;\n' \
                  'write "/tmp/big" (String.make 40000 (Char.chr 97));;\n' \
                  'String.length (In_channel.with_open_bin "/tmp/big" In_channel.input_all);;\n' \
                  'write "AUTOEXEC.BAT" "";;\n' \
                  'write "/disk/aaa.ml" "let () = print_endline (String.make 3 (Char.chr 65))";;\n' \
                  'compile "/disk/aaa.ml";;\n' 'run "/disk/aaa.byte" [];;\n' \
                  'Sys.mkdir "/disk/src" 0o755; cd "/disk/src";;\n' \
                  'write "w.ml" "let () = print_endline (Sys.getcwd ())";;\n' \
                  'ignore (compile "w.ml"); run "w.byte" [];;\n' \
                  'run "kilo" ["/disk/k.txt"];;\n' 'typed in kilo' '{ctrl-s}' '{ctrl-q}' \
                  'edit "/disk/e.txt";;\n' '' 'second\n{up}first {ctrl-k}{ctrl-u}{ctrl-u}' '{ctrl-s}' '{ctrl-q}' \
                  'sh ();;\n' 'cd /disk; echo from sh > s.txt; X=4; echo "v$X" >> s.txt; cat s.txt | cat\n' \
                  'trace -o /disk/t.trc cat s.txt > /tmp/tout.txt\n' '' \
                  'trace calls /disk/t.trc > calls.txt; trace json /disk/t.trc t.json\n' '' \
                  'exit\n' \
                  '#quit;;\n' 'exit\n'; do
        tools/type-keys.py "$tmp/mon7" "$phrase"
        sleep 2
    done
    # init starts a new sh (the third banner: the first sh, the one started
    # from the toplevel, this one)
    i=0
    while [ $i -lt 30 ] && [ "$(grep -ac 'MyNOS sh. help' "$log7")" -lt 3 ]; do
        sleep 1; i=$((i + 1))
    done
    tools/type-keys.py "$tmp/mon7" 'echo restarted\n'
    sleep 2
    printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon7" >/dev/null || true
    wait $qemu || true
    cat "$log7" >> "$log"
    if [ -f tests/fat/run-shell.img ]; then
        tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/.history \
            2>/dev/null | grep -qx '6 \* 7;;' && history_saved=yes
        [ "$(tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/k.txt 2>/dev/null)" = \
          "typed in kilo" ] && kilo_saved=yes
        [ "$(tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/e.txt 2>/dev/null)" = \
          "$(printf 'first second\nfirst second\n')" ] && edit_saved=yes
        [ "$(tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/s.txt 2>/dev/null)" = \
          "$(printf 'from sh\nv4\n')" ] && sh_saved=yes
        tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/calls.txt \
            2>/dev/null > "$tmp/calls.txt" || true
        grep -q 'sh(.*-> fatfs(.*fs OPEN "s.txt"' "$tmp/calls.txt" &&
            grep -q '^ .*  fatfs(.*-> ata(.*block/1 Read' "$tmp/calls.txt" && trace_calls=yes
        tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/t.json \
            2>/dev/null > "$tmp/t.json" || true
        python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))["traceEvents"]
assert any(e["ph"] == "X" and e["name"].startswith("block/1 Read") for e in d)
assert any(e["ph"] == "f" for e in d)' "$tmp/t.json" 2>/dev/null && trace_json=yes
        rm -f tests/fat/run-shell.img
    fi
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
if [ -f tests/stress/ramdisk.dsk ]; then
    expect "stress: all checks passed"
fi
if [ -f tests/net/ramdisk.dsk ]; then
    expect "net: all checks passed"
    if [ -n "$net_fetched" ]; then
        echo "ok    the host fetched a page from a server in MyNOS"
    else
        echo "FAIL  the host fetched a page from a server in MyNOS"; fail=1
    fi
fi
if [ -f tests/effects/effects.byte ]; then
    expect "effects ok"
fi
if [ -f tests/domains/domains.byte ]; then
    expect "domains: all checks passed"
fi
if [ -f tests/fat/ramdisk.dsk ]; then
    expect "fat (fat16): all checks passed"
    expect "fat (fat32): all checks passed"
    for c in fat16:fsck-ok fat32:fsck-ok fat16:mtools-ok fat32:mtools-ok \
             fat16:date-ok fat32:date-ok; do
        case " $fat_checks " in
            *" $c "*) echo "ok    host check $c" ;;
            *) echo "FAIL  host check $c"; fail=1 ;;
        esac
    done
fi
if [ -f tests/storage/ramdisk.dsk ]; then
    expect "ata: disk of 2048 sectors"
    expect "storage: all checks passed"
    if [ "$disk_written" = "WRITTEN BY MYNOS" ]; then
        echo "ok    the disk image holds what MyNOS wrote"
    else
        echo "FAIL  the disk image holds what MyNOS wrote"; fail=1
    fi
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
if [ -f system/ramdisk.dsk ]; then
    expect "init: started consoled"
    expect "init: started sh.byte"
    expect "MyNOS shell. Type help ();; for help."
    expect "- : int = 3"
    expect "- : int list = [1; 4; 9]"
    expect "This file lives in the MyNOS RAM disk."
    expect "stdlib__List.cmi"
    expect "args [4]"
    expect "- : Mynos.status = Mynos.Exited 4"
    expect "Error: "
    # history: Up recalls "6 * 7;;"; Up, Up, Down recalls "1 + 1;;"
    if [ "$(grep -acx -- '- : int = 42' "$log7")" -ge 2 ] &&
       [ "$(grep -acx -- '- : int = 2' "$log7")" -ge 2 ]; then
        echo "ok    shell history (Up, Down)"
    else
        echo "FAIL  shell history (Up, Down)"; fail=1
    fi
    expect "init: started tmpfs.byte"
    expect "val t : int = 54"
    expect "t.ml"
    expect "- : int = 40000"
    expect "AUTOEXEC.BAT: Read-only file system"
    expect "init: sh.byte (pid"
    if [ -n "$trace_calls" ]; then
        echo "ok    trace: sh -> fatfs -> ata0, nested calls"
    else
        echo "FAIL  trace: sh -> fatfs -> ata0, nested calls"; fail=1
    fi
    if [ -n "$trace_json" ]; then
        echo "ok    trace: a Perfetto file"
    else
        echo "FAIL  trace: a Perfetto file"; fail=1
    fi
    if grep -aqx 'completed by tab' "$log7"; then
        echo "ok    sh: Tab completes a command"
    else
        echo "FAIL  sh: Tab completes a command"; fail=1
    fi
    if [ -n "$sh_saved" ] || [ ! -f tests/fat/fat16.img ]; then
        echo "ok    sh: variables, redirections, a pipe, on /disk"
    else
        echo "FAIL  sh: variables, redirections, a pipe, on /disk"; fail=1
    fi
    if [ -n "$edit_saved" ] || [ ! -f tests/fat/fat16.img ]; then
        echo "ok    edit (OCaml, Notty) saves a file on /disk"
    else
        echo "FAIL  edit (OCaml, Notty) saves a file on /disk"; fail=1
    fi
    if [ -n "$kilo_saved" ] || [ ! -f tests/fat/fat16.img ]; then
        echo "ok    kilo (terminal: VT100, raw mode) saves a file on /disk"
    else
        echo "FAIL  kilo (terminal: VT100, raw mode) saves a file on /disk"; fail=1
    fi
    if grep -aqx '/disk/src' "$log7"; then
        echo "ok    cd: a program compiled and run in /disk/src"
    else
        echo "FAIL  cd: a program compiled and run in /disk/src"; fail=1
    fi
    if grep -aqx 'AAA' "$log7"; then
        echo "ok    a program compiled by ocamlc inside MyNOS runs"
    else
        echo "FAIL  a program compiled by ocamlc inside MyNOS runs"; fail=1
    fi
    if [ -n "$history_saved" ] || [ ! -f tests/fat/fat16.img ]; then
        echo "ok    the shell history is saved on /disk"
    else
        echo "FAIL  the shell history is saved on /disk"; fail=1
    fi
    if [ "$(grep -ac 'MyNOS sh. help' "$log7")" -ge 3 ] &&
       grep -aqx -- 'restarted' "$log7"; then
        echo "ok    init restarts sh after exit"
    else
        echo "FAIL  init restarts sh after exit"; fail=1
    fi
fi
if [ -f tests/console/echo.byte ] && [ -f services/console/consoled ]; then
    expect 'console: line 1: "hi"'
    expect 'console: line 2: "OK"'
    expect "console: end of input after 2 lines"
fi
reject "PANIC"
reject "page fault (?)"
reject "Problems releasing pages"
reject "kernel heap:"
reject "FAIL"

if [ $fail -ne 0 ]; then
    echo "--- console log ---"
    cat "$log"
    exit 1
fi
echo "all tests passed"
