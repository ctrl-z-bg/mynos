#!/bin/sh
# Boot the whole system headless in QEMU, capture the kernel console (mirrored
# to COM2) and check the expected output. Build first with tools/build-all.sh.
#
# Usage: tools/run-tests.sh            exit status 0 if all checks pass
# The boots run in five lanes at once (about 11 minutes in all, lane e):
#   a  the first boots: bytecode, effects, the ATA disk, FAT, domains
#   b  the library, files, the kernel stress test, spawning, the console
#   c  without COM2, and restarting again and again
#   d  the graphical session (its windows, Graphics, the Packages window)
#   e  the network, then the whole system driven by the keyboard (the
#      seventh boot: the shell, the toplevel, the agent, kill, packages...)
# Environment: WAIT seconds to let the system run (default 10); SHOTS a
# directory where the graphical session's screens are kept; LANES the
# lanes to run (default "a b c d e": the checks of the others then fail);
# KEEP keeps the temporary files (logs, screens) and says where
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

ocamlrun=$(tools/ocamlrun-path.sh)
tmp=$(mktemp -d)
if [ -n "${KEEP:-}" ]; then echo "run-tests.sh: files kept in $tmp" >&2
else trap 'rm -rf "$tmp"' EXIT; fi
log=$tmp/log1 log2=$tmp/log2 log3=$tmp/log3 log4=$tmp/log4 log5=$tmp/log5
log6=$tmp/log6 log7=$tmp/log7 log8=$tmp/log8 log9=$tmp/log9 logf=$tmp/logf
logs=$tmp/logs logn=$tmp/logn

# The boots run in five lanes at once (they share nothing: each its own
# files, monitor sockets and host ports); within a lane, one after the
# other. Each lane appends its logs to its own part of the log, and writes
# the results the checks need to a file; the checks run once all are done.
results="virtio_disk virtio_net virtio_gui disk_reads files_ok net_fetched disk_written fat_checks nocom2 rebooted reboots_ok gui_ok powered_off gui_hangup pkgwin_ok history_saved kilo_saved edit_saved sh_saved trace_calls trace_json agent_marks serial_same_sh httpd_private httpd_upload sound_ok edit_utf8 log_shown"
save_results() {
    for v in $results; do
        eval "x=\${$v:-}"            # only what the lane found: an empty
        [ -z "$x" ] || printf "%s='%s'\n" "$v" "$x"   # one would hide another's
    done > "$tmp/results-$1"
}

sec_first() {
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
}

sec_effects() {
# second boot: effect handlers (OCaml 5 only)
if [ -f tests/effects/effects.byte ]; then
    timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" tests/effects/effects.byte \
        -- -display none -serial null -serial "file:$log2" || true
    cat "$log2" >> "$part"
fi
}

sec_storage() {
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
    cat "$log9" >> "$part"
    disk_written=$(python3 -c '
import sys
d = open(sys.argv[1], "rb").read()
print(d[1000 * 512:1000 * 512 + 16].decode("latin-1"))' "$tmp/disk.img")
fi
}

sec_fat() {
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
        sed "s/^fat: /fat ($img): /" "$logf" >> "$part"
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
}

sec_fpu() {
# each thread its own floating-point state (mynos-t6p): x87 and SSE
# registers, the control word, kept across preemptions
if [ -f tests/fpu/fpu ]; then
    timeout "${WAIT:-20}" tools/run-qemu.sh tests/fpu/fpu \
        -- -display none -serial null -serial "file:$tmp/logf" || true
    cat "$tmp/logf" >> "$part"
fi
}

sec_threads() {
# OCaml's threads (systhreads): Mutex, Condition, Event, and MyNOS calls
# that wait without stopping the other threads
if [ -f tests/threads/threads_test.byte ]; then
    MEM=128 timeout "${WAIT:-20}" tools/run-qemu.sh "$ocamlrun" \
        tests/threads/threads_test.byte services/registry/registry \
        -- -display none -serial null -serial "file:$tmp/logt" || true
    cat "$tmp/logt" >> "$part"
fi
}

sec_domains() {
# eighth boot: domains, i.e. Linux threads (clone, futex)
if [ -f tests/domains/domains.byte ]; then
    MEM=128 timeout "${WAIT:-15}" tools/run-qemu.sh "$ocamlrun" \
        tests/domains/domains.byte \
        -- -display none -serial null -serial "file:$log8" || true
    cat "$log8" >> "$part"
fi
}

sec_mlib() {
# third boot: the Mynos OCaml library, reading a file through memrofs
if [ -f tests/mynos-ocaml/mynos_test.byte ]; then
    timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" \
        tests/mynos-ocaml/mynos_test.byte services/registry/registry \
        services/fs/memrofs/memrofsd tests/ramdisk/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log3" || true
    cat "$log3" >> "$part"
fi
}

sec_files() {
# fifth boot: no bytecode module; ocamlrun loads init.byte from the RAM disk
# and it reads files through the standard library
if [ -f tests/files/ramdisk.dsk ]; then
    timeout "${WAIT:-10}" tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        tests/files/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log5" || true
    cat "$log5" >> "$part"
fi
}

sec_libs() {
# Str and Num, the CPU time, the user id, O_EXCL on tmpfs: init.byte from
# the RAM disk starts tmpfs and checks them
if [ -f tests/libs/ramdisk.dsk ]; then
    MEM=64 timeout "${WAIT:-15}" tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        tests/libs/ramdisk.dsk \
        -- -display none -serial null -serial "file:$tmp/logl" || true
    cat "$tmp/logl" >> "$part"
fi
}

sec_stress() {
# the kernel stress test (C): processes, IPC, timers,
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
    cat "$logs" >> "$part"
fi
}

sec_spawn() {
# sixth boot: init.byte starts other programs from the RAM disk (about
# twenty-five of them, one after the other)
if [ -f tests/spawn/ramdisk.dsk ]; then
    timeout "${WAIT:-15}" tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        tests/spawn/ramdisk.dsk \
        -- -display none -serial null -serial "file:$log6" || true
    cat "$log6" >> "$part"
fi
}

sec_console() {
# fourth boot: typing on the keyboard, read by OCaml through consoled
if [ -f tests/console/echo.byte ] && [ -f services/console/consoled ]; then
    # COM2 is a terminal too (doc/decisions/console.md): tools/serial-peer.py
    # logs it, and types what is appended to $tmp/com2.in
    : > "$tmp/com2.in"
    tools/run-qemu.sh "$ocamlrun" tests/console/echo.byte \
        services/registry/registry services/console/consoled \
        -- -display none -serial null \
           -chardev "socket,id=com2,path=$tmp/com2,server=on,wait=on" \
           -serial chardev:com2 \
           -monitor "unix:$tmp/mon,server,nowait" &
    qemu=$!
    tools/serial-peer.py "$tmp/com2" "$log4" "$tmp/com2.in" & peer=$!
    sleep 4
    keys() {
        for k in "$@"; do printf 'sendkey %s\n' "$k"; done |
            socat - "UNIX-CONNECT:$tmp/mon" >/dev/null
        sleep 0.5
    }
    keys h i ret
    keys shift-o shift-k x backspace ret
    # from the serial port: UTF-8, a Backspace (DEL) erasing a whole
    # character, Enter as \r
    printf 'from serial \303\250\177\303\251\r' >> "$tmp/com2.in"
    sleep 2
    # the cursor moved in the line: Left, Home, End (keyboard), then
    # Left, Delete, Home from the serial port's escape sequences
    keys a c left b home x end y ret
    printf '12\033[D\033[3~3\033[H0\r' >> "$tmp/com2.in"
    sleep 2
    keys ctrl-d
    sleep 2
    printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon" >/dev/null || true
    wait $qemu || true
    kill $peer 2>/dev/null || true
    cat "$log4" >> "$part"
fi
}

sec_nocom2() {
# the system as QEMU's window starts it: no second serial port (COM1 only).
# consoled must not wait for a port that is not there: the shell answers
# within seconds (read from the screen, through QEMU's monitor)
nocom2= rebooted=
if [ -f system/ramdisk.dsk ]; then
    MEM=256 tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        system/ramdisk.dsk \
        -- -no-reboot -display none -serial null -monitor "unix:$tmp/mon-nc,server,nowait" &
    qemu=$!
    sleep 5
    tools/type-keys.py "$tmp/mon-nc" 'X=ok; echo nocom2-$X\n'
    sleep 3
    printf 'xp /2000hx 0xb8000\n' | socat - "UNIX-CONNECT:$tmp/mon-nc" |
        grep -o ' 0x[0-9a-f]\{4\}' | python3 -c '
import sys
s = bytes(int(x, 16) & 0xFF for x in sys.stdin.read().split())
sys.exit(0 if b"nocom2-ok" in s else 1)' && nocom2=yes
    # restarting: init resets the machine (QEMU, with -no-reboot, ends)
    tools/type-keys.py "$tmp/mon-nc" 'shutdown -r\n'
    i=0
    while [ $i -lt 20 ] && kill -0 $qemu 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
    if kill -0 $qemu 2>/dev/null; then
        printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon-nc" >/dev/null || true
    else
        rebooted=yes
    fi
    wait $qemu || true
fi
}

sec_virtio() {
# virtio devices only (mynos-btq.2): a keyboard (the PC's controller is
# off: every key typed here comes through consoled's virtio driver), a
# disk, which vblkd serves as vblk0
# and fatfs mounts as /disk (a file written there is on the image the
# host reads), and a network card, which netd takes instead of the
# NE2000 (httpd answers the host through it); a GPU and a tablet, for
# the graphical session (no VGA: a click on the welcome window's Clock
# button, through QMP, opens the clock)
virtio_disk= virtio_net= virtio_gui=
if [ -f system/ramdisk.dsk ] && [ -f system/vblkd ] && [ -f tests/fat/fat16.img ]; then
    cp tests/fat/fat16.img tests/fat/run-virtio.img
    : > "$tmp/logv"
    MEM=256 tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        system/ramdisk.dsk \
        -- -display none -serial null -serial "file:$tmp/logv" \
           -machine pc,i8042=off -vga none -device virtio-gpu-pci \
           -device virtio-keyboard-pci -device virtio-tablet-pci \
           -qmp "unix:$tmp/qmp-v,server,nowait" \
           -drive "file=tests/fat/run-virtio.img,format=raw,if=none,id=vd" \
           -device virtio-blk-pci,drive=vd \
           -netdev user,id=vn,hostfwd=tcp:127.0.0.1:47181-:80 \
           -device virtio-net-pci,netdev=vn \
           -monitor "unix:$tmp/mon-v,server,nowait" &
    qemu=$!
    i=0
    while [ $i -lt 30 ] && ! grep -aq 'mynos:/' "$tmp/logv" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    tools/type-keys.py "$tmp/mon-v" 'X=ok; echo virtio-$X > /disk/v.txt; cat /disk/v.txt\n'; sleep 3
    i=0
    while [ $i -lt 20 ] && ! grep -aq 'netd: address' "$tmp/logv"; do sleep 0.5; i=$((i + 1)); done
    curl -s -m 5 -i http://127.0.0.1:47181/ | grep -q 'Server: MyNOS httpd' && virtio_net=yes
    qmp() { printf '{"execute":"qmp_capabilities"}\n%s\n' "$1" |
                socat -t1 - "UNIX-CONNECT:$tmp/qmp-v" >/dev/null; sleep 0.3; }
    tools/type-keys.py "$tmp/mon-v" 'gui\n'; sleep 8
    qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":7454}},{"type":"abs","data":{"axis":"y","value":18271}}]}}'
    qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"down":true,"button":"left"}}]}}'
    qmp '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"down":false,"button":"left"}}]}}'
    sleep 6
    printf 'screendump %s\n' "$tmp/gv.ppm" | socat - "UNIX-CONNECT:$tmp/mon-v" >/dev/null; sleep 1
    python3 - "$tmp/gv.ppm" <<'PY' && virtio_gui=yes
import sys
d = open(sys.argv[1], "rb").read()
parts = d.split(b"\n", 3)
w, h = map(int, parts[1].split())
pix = parts[3]
def px(x, y):
    i = (y * w + x) * 3
    return (pix[i] << 16) | (pix[i + 1] << 8) | pix[i + 2]
assert (w, h) == (1024, 768), (w, h)
assert px(150, 114) == 0x2D6CA2, hex(px(150, 114))   # the Clock's title bar, focused
assert px(214, 236) != px(214, 300)                 # a hand, on the dial
PY
    # (the session holds the keys: QEMU is stopped from its monitor, which
    # closes the disk's image with what was written)
    printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon-v" >/dev/null || true
    wait $qemu || true
    [ "$(tools/in-container.sh dev mtype -i tests/fat/run-virtio.img ::/v.txt 2>/dev/null)" = virtio-ok ] &&
        virtio_disk=yes
    cat "$tmp/logv" >> "$part"
    rm -f tests/fat/run-virtio.img
fi
}

sec_reboots() {
# restarting again and again (shutdown -r): after a reset memory holds the
# previous run's data, which the kernel once read as its own (a page given
# twice at the third boot); four boots, each must reach the shell
reboots_ok=
if [ -f system/ramdisk.dsk ] && [ -f init/shutdown.byte ]; then
    : > "$tmp/logr"
    MEM=256 tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        system/ramdisk.dsk \
        -- -display none -serial null -serial "file:$tmp/logr" \
           -monitor "unix:$tmp/mon-r,server,nowait" &
    qemu=$!
    k=1
    while [ $k -le 4 ]; do
        i=0
        while [ $i -lt 60 ] && [ "$(grep -ac 'MyNOS sh. help' "$tmp/logr")" -lt $k ] &&
              ! grep -aq PANIC "$tmp/logr"; do
            sleep 0.5; i=$((i + 1))
        done
        [ "$(grep -ac 'MyNOS sh. help' "$tmp/logr")" -lt $k ] && break
        [ $k -lt 4 ] && { sleep 1; tools/type-keys.py "$tmp/mon-r" 'shutdown -r\n'; }
        k=$((k + 1))
    done
    [ $k -gt 4 ] && reboots_ok=yes
    printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon-r" >/dev/null || true
    wait $qemu || true
    cat "$tmp/logr" >> "$part"
fi
}

sec_gui() {
# the graphical session (doc/decisions/gui.md): displayd, windows of
# programs, the mouse, back to text mode. QEMU's monitor moves the mouse
# relatively: vmmouse (absolute) is off, the PS/2 mouse is used
gui_ok= powered_off= gui_hangup= files_ok= pkgwin_ok=
if [ -f system/ramdisk.dsk ] && [ -f gui/gui.byte ]; then
    : > "$tmp/logg"
    # the agent window's model: the fake provider, as in the seventh boot,
    gdisk=
    if [ -f tests/fat/fat16.img ]; then
        gdisk=tests/fat/run-gui.img
        cp tests/fat/fat16.img "$gdisk"
        # its own port (the seventh boot, at the same time, has 47090)
        sed 's/:47090/:47091/' tests/net/llm-test.env > tests/fat/run-gui.env
        # the packages' repository: the host's copy (tools/pkg-build.sh)
        printf 'http://10.0.2.2:47102/\n' > tests/fat/run-gui.url
        tools/in-container.sh dev sh -c "mcopy -i $gdisk tests/fat/run-gui.env ::/llm.env && mcopy -i $gdisk tests/greeter/old-boot.trc ::/old-boot.trc && mcopy -i $gdisk tests/greeter/greeter.byte ::/greeter.byte && mcopy -i $gdisk graphics/gtest.byte ::/gtest.byte && mcopy -i $gdisk tests/keys/keys.byte ::/keys.byte && mmd -i $gdisk ::/pkg && mcopy -i $gdisk tests/fat/run-gui.url ::/pkg/url"
        rm -f tests/fat/run-gui.env tests/fat/run-gui.url
    fi
    tools/net-peer.py llm 47091 & llmg_pid=$!
    tools/net-peer.py files 47102 tmp/packages & filesg_pid=$!
    NET=1 DISK=$gdisk MEM=256 tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        system/ramdisk.dsk \
        -- -machine vmport=off -display none -serial null -serial "file:$tmp/logg" \
           -monitor "unix:$tmp/mon-g,server,nowait" &
    qemu=$!
    i=0
    while [ $i -lt 30 ] && ! grep -aq 'mynos:/' "$tmp/logg" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done
    mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:$tmp/mon-g" >/dev/null; sleep 0.12; }
    gx=512 gy=384                        # the pointer starts in the middle
    to() {
        dx=$(($1 - gx)) dy=$(($2 - gy)); gx=$1 gy=$2
        while [ $dx -ne 0 ] || [ $dy -ne 0 ]; do
            sx=$dx sy=$dy
            [ $sx -gt 40 ] && sx=40; [ $sx -lt -40 ] && sx=-40
            [ $sy -gt 40 ] && sy=40; [ $sy -lt -40 ] && sy=-40
            mon "mouse_move $sx $sy"; dx=$((dx - sx)) dy=$((dy - sy))
        done
    }
    click() { to "$1" "$2"; mon "mouse_button 1"; mon "mouse_button 0"; }
    tools/type-keys.py "$tmp/mon-g" 'gui check\n'; sleep 3
    tools/type-keys.py "$tmp/mon-g" 'gui\n'; sleep 8
    mon "screendump $tmp/gui1.ppm"
    click 233 428; sleep 8               # the welcome window's Clock button
    mon "screendump $tmp/gui2.ppm"
    # a terminal window (the menu's first item): sh runs in it, its console
    # is the window (MYNOS_CONSOLE); what it writes is checked from text mode
    click 20 10; sleep 1; click 40 39; sleep 10
    tools/type-keys.py "$tmp/mon-g" 'X=ok; echo term-$X > /tmp/term.txt\n'; sleep 4
    mon "screendump $tmp/gui4.ppm"
    # its scrollback: a long listing, then the wheel up over the window
    tools/type-keys.py "$tmp/mon-g" 'ls /\n'; sleep 5
    to 400 300
    for k in 1 2 3; do mon "mouse_move 0 0 3"; sleep 0.5; done; sleep 2
    mon "screendump $tmp/gui5.ppm"
    mon "sendkey backspace"; sleep 1                # a key: back to the bottom
    # Ctrl-C in the terminal window ends the program its sh waits for
    tools/type-keys.py "$tmp/mon-g" '/disk/greeter.byte\n'; sleep 5
    mon "sendkey ctrl-c"; sleep 2
    tools/type-keys.py "$tmp/mon-g" 'echo ctrlc-$? > /tmp/ctrlc.txt\n'; sleep 3
    # selecting with the mouse (mynos-b3k): a double click on a word of
    # the cleared screen's first row copies it, a right click pastes it
    tools/type-keys.py "$tmp/mon-g" 'clear; echo pick-ok\n'; sleep 3
    to 160 166; mon "mouse_button 1"; mon "mouse_button 0"; mon "mouse_button 1"; mon "mouse_button 0"; sleep 1
    tools/type-keys.py "$tmp/mon-g" 'echo sel-'; mon "mouse_button 2"; mon "mouse_button 0"; sleep 1
    tools/type-keys.py "$tmp/mon-g" ' > /tmp/sel.txt\n'; sleep 3
    # line mode in the terminal window: Up brings the last line back;
    # Home, Delete and a letter edit it, Left and End move in it
    tools/type-keys.py "$tmp/mon-g" 'cat > /tmp/hist.txt\n'; sleep 2
    tools/type-keys.py "$tmp/mon-g" 'hist-up\n'; sleep 1
    mon "sendkey up"; mon "sendkey ret"; sleep 1
    for k in up home delete shift-h left end ret; do mon "sendkey $k"; done
    sleep 1; mon "sendkey ctrl-d"; sleep 2
    # the agent window (the menu's fifth item, at 168,182): a task, the
    # confirmation it waits for, Allow (at the bottom of the window)
    click 20 10; sleep 1; click 40 127; sleep 10
    tools/type-keys.py "$tmp/mon-g" 'X=ok; echo agentwin-$X > /tmp/aw.txt\n'; sleep 8
    mon "screendump $tmp/gui6.ppm"
    click 230 695; sleep 8
    mon "screendump $tmp/gui7.ppm"
    # the task's recording (the agent window's Recording button), in the
    # recordings window (at 80,124): its timeline, then its calls, one
    # selected
    click 736 693; sleep 15
    mon "screendump $tmp/gui8.ppm"
    click 262 230; sleep 3                         # the first mark: its step
    mon "screendump $tmp/gui10.ppm"
    click 219 177; sleep 3; click 400 233; sleep 3
    mon "screendump $tmp/gui9.ppm"
    # the System window (the menu's seventh item, at 20,64): the system
    # live; the agent's recording replayed on it, three steps; then a new
    # process (a clock, from the menu) appears outlined
    click 20 10; sleep 1; click 40 171; sleep 12
    mon "screendump $tmp/gui11.ppm"
    click 100 119; sleep 1
    tools/type-keys.py "$tmp/mon-g" '/tmp/agent.trc'; sleep 1
    click 364 117; sleep 8
    for k in 1 2 3; do click 580 117; sleep 1; done; sleep 1
    mon "screendump $tmp/gui12.ppm"
    click 20 10; sleep 1; click 40 83; sleep 4
    mon "screendump $tmp/gui13.ppm"
    # the clock's close box (at 474,255): pressed, slipped off, released:
    # not closed; then a click: closed. The agent window's tab (the fourth
    # of six, at 516-652 in the top bar) brings it back from under the others
    to 474 255; mon "mouse_button 1"; to 474 330; mon "mouse_button 0"; sleep 2
    mon "screendump $tmp/gui14.ppm"
    click 474 255; sleep 3
    mon "screendump $tmp/gui15.ppm"
    click 580 12; sleep 3
    mon "screendump $tmp/gui16.ppm"
    # a recording of another boot (tests/greeter/old-boot.trc: greeter was
    # pid 14, which is gui here) in the System window (its tab, the sixth):
    # greeter, which served a call, a ghost among the services
    # (a click places the field's cursor: End first, then erase)
    click 850 12; sleep 2; click 100 119; sleep 1
    tools/type-keys.py "$tmp/mon-g" '{end}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}{backspace}/disk/old-boot.trc'
    click 364 117; sleep 5
    mon "screendump $tmp/gui17.ppm"
    # Files (the menu's eighth item, at 40,70): /tmp, aw.txt (the agent's),
    # Copy; /disk, Paste, Open (viewed); Back, New folder "newdir". The
    # copy and the folder are checked from text mode
    click 20 10; sleep 1; click 40 193; sleep 8
    mon "screendump $tmp/gui18.ppm"
    click 100 175; sleep 2; click 324 180; sleep 1; click 642 125; sleep 1
    click 100 199; sleep 2; click 762 125; sleep 2; click 310 125; sleep 2
    mon "screendump $tmp/gui19.ppm"
    click 848 161; sleep 1; click 400 125; sleep 1
    tools/type-keys.py "$tmp/mon-g" 'newdir\n'; sleep 2
    # the tour (the menu's ninth item, at 72,98): a lesson run and replayed
    # in a System window (at 20,64), at its first note
    click 20 10; sleep 1; click 40 215; sleep 8
    mon "screendump $tmp/gui20.ppm"
    click 197 203; sleep 1                  # the third lesson: a program is born
    click 402 469; sleep 30
    click 732 117; sleep 1                   # its first note: sh looks at hello.byte;
    click 732 117; sleep 2                   # the second: the birth of hello
    mon "screendump $tmp/gui21.ppm"
    # OCaml's Graphics (graphics/), from a new terminal window: its test
    # draws, reads the pixels back, writes the result to the log and
    # closes its window
    click 20 10; sleep 1; click 40 39; sleep 10
    tools/type-keys.py "$tmp/mon-g" '/disk/gtest.byte\n'; sleep 12
    # key releases (mynos-ap3): a window (tests/keys) gets Right and X held
    # at once, then their releases, then q, which ends it
    tools/type-keys.py "$tmp/mon-g" '/disk/keys.byte\n'; sleep 6
    # resizable windows (mynos-1e9): the same window (at 200,300, 240 x 60)
    # by its grip to 340 x 110, then maximized by a double click on its title
    to 437 357; mon "mouse_button 1"; to 537 407; mon "mouse_button 0"; sleep 2
    to 300 289; mon "mouse_button 1"; mon "mouse_button 0"; mon "mouse_button 1"; mon "mouse_button 0"; sleep 2
    mon "sendkey right-x 400"; sleep 1
    mon "sendkey q"; sleep 2
    # the Packages window (pkg/packages_window.ml), the menu's eleventh
    # item: with no index on the disk it reads one, through pkg, from the
    # repository /disk/pkg/url names (the host's copy)
    click 20 10; sleep 1; click 40 259; sleep 15
    mon "screendump $tmp/gui22.ppm"
    # Text, the session's text editor (the menu's thirteenth item, mynos-y87):
    # a line typed, Ctrl-S, the name it offers (/disk/untitled.txt) taken;
    # the file is read back from text mode
    click 20 10; sleep 1; click 40 303; sleep 6
    tools/type-keys.py "$tmp/mon-g" 'typed-in-text'; sleep 1
    mon "sendkey ctrl-s"; sleep 1
    tools/type-keys.py "$tmp/mon-g" '\n'; sleep 3
    # MyNOS Studio (the package studio, mynos-y87): installed from a
    # Terminal, started; Run builds its first program (/disk/studio/hello.ml)
    # with the ocamlc inside MyNOS and runs it (hello.byte, seen from text mode)
    click 20 10; sleep 1; click 40 39; sleep 8
    tools/type-keys.py "$tmp/mon-g" 'pkg install studio; studio &\n'; sleep 25
    click 265 91; sleep 20
    click 20 10; sleep 1; click 30 369; sleep 4    # the MyNOS menu, Exit
    tools/type-keys.py "$tmp/mon-g" 'X=ok; echo text-$X; cat /tmp/term.txt /tmp/aw.txt /disk/aw.txt /tmp/ctrlc.txt /tmp/sel.txt /tmp/hist.txt /disk/untitled.txt; ls /disk /disk/studio\n'; sleep 3
    mon "screendump $tmp/gui3.ppm"; sleep 1
    # the terminal closed with its sh running: a hang-up, sh ended too
    tools/type-keys.py "$tmp/mon-g" 'ps\n'; sleep 3
    tools/type-keys.py "$tmp/mon-g" 'cat /disk/pkg/index.json\n'; sleep 3
    # turning the machine off: init does it, QEMU ends by itself
    tools/type-keys.py "$tmp/mon-g" 'shutdown\n'
    i=0
    while [ $i -lt 20 ] && kill -0 $qemu 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
    if kill -0 $qemu 2>/dev/null; then
        printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon-g" >/dev/null || true
    else
        powered_off=yes
    fi
    wait $qemu || true
    kill $llmg_pid $filesg_pid 2>/dev/null; wait $llmg_pid $filesg_pid 2>/dev/null || true
    [ -n "${SHOTS:-}" ] && cp "$tmp"/gui*.ppm "$SHOTS"/   # SHOTS=DIR keeps the screens
    python3 - "$tmp/logg" <<'PY' && gui_hangup=yes
import re, sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
table = s[s.rfind("  pid  ppid thr"):].splitlines()[1:]
rows = [l.split() for l in table if re.match(r"\s+\d+\s+\d+\s+\d+\s", l)]
names = [r[4] if r[3] == "io" else r[3] for r in rows]
assert names.count("sh") == 1 and "terminal" not in names, names
PY
    python3 - "$tmp/logg" <<'PY' && files_ok=yes
import re, sys
s = open(sys.argv[1], "rb").read().decode("latin-1")
assert s.count("agentwin-ok") >= 2, "aw.txt copied to /disk by Files"
assert "newdir" in s, "a folder made by Files"
assert "ctrlc-137" in s, "Ctrl-C in the terminal window"
assert re.search(r"hist-up\s+hist-up\s+Hist-up", s), "Up, Home, Delete in the terminal window's line mode"
PY
    grep -aq '"name": "windtree"' "$tmp/logg" && pkgwin_ok=yes
    cat "$tmp/logg" >> "$part"
    python3 - "$tmp"/gui1.ppm "$tmp"/gui2.ppm "$tmp"/gui3.ppm "$tmp"/gui4.ppm "$tmp"/gui5.ppm \
              "$tmp"/gui6.ppm "$tmp"/gui7.ppm "$tmp"/gui8.ppm "$tmp"/gui9.ppm \
              "$tmp"/gui10.ppm "$tmp"/gui11.ppm "$tmp"/gui12.ppm "$tmp"/gui13.ppm \
              "$tmp"/gui14.ppm "$tmp"/gui15.ppm "$tmp"/gui16.ppm "$tmp"/gui17.ppm \
              "$tmp"/gui18.ppm "$tmp"/gui19.ppm "$tmp"/gui20.ppm "$tmp"/gui21.ppm <<'PY' && gui_ok=yes
import sys
def load(path):
    d = open(path, "rb").read()
    parts = d.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]
def px(img, x, y):
    w, h, d = img
    i = 3 * (y * w + x)
    return (d[i] << 16) | (d[i + 1] << 8) | d[i + 2]
(g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12, g13, g14, g15, g16, g17, g18, g19,
 g20, g21) = (load(p) for p in sys.argv[1:22])
assert g1[:2] == (1024, 768), "graphics mode"
assert px(g1, 500, 10) == 0x111820, "the top bar"
assert px(g1, 300, 86) == 0x2D6CA2, "the welcome window, focused"
# the logo, light on the welcome window's banner (86-235, 106-218)
assert sum(1 for x in range(86, 235) for y in range(106, 218)
           if px(g1, x, y) != 0x1B3A57) > 300, "the logo in the welcome window"
# and faint on the desktop (702-1000, 508-732): lighter than the gradient
# left of it, at the same height
def light(c): return (c >> 16) + ((c >> 8) & 255) + (c & 255)
assert sum(1 for x in range(702, 1000, 2) for y in range(508, 732, 2)
           if light(px(g1, x, y)) > light(px(g1, 690, y)) + 6) > 300, "the desktop's watermark"
assert px(g2, 150, 114) == 0x2D6CA2, "the clock's window, focused"
assert px(g2, 400, 86) == 0x4A5560, "the welcome window, behind"
assert g3[:2] == (720, 400), "text mode again"
assert px(g4, 500, 140) == 0x2D6CA2, "the terminal's window, focused"
assert px(g4, 600, 520) == 0x0F1419, "the terminal's background"
# the scrollbar (x 784-796): its thumb has left the bottom after the wheel
bar = [px(g5, 790, y) for y in range(154, 562)]
assert 0x5A6670 in bar, "the scrollbar's thumb"
assert bar[-6] == 0x1A2026, "scrolled back: the thumb is not at the bottom"
# the agent window (content at 168,182): focused, its header, a
# confirmation in the conversation; after Allow, no more
assert px(g6, 500, 172) == 0x2D6CA2, "the agent's window, focused"
assert px(g6, 400, 190) == 0x1B3A57, "the agent window's header"
def asking(img): return sum(1 for x in range(176, 920, 4) for y in range(222, 672, 4)
                            if px(img, x, y) == 0xFFF4E0)
assert asking(g6) > 100, "the agent asks: the confirmation"
assert asking(g7) == 0, "allowed: no confirmation left"
# the recordings window (content at 80,124): focused, a timeline with the
# agent's marks (orange) and calls in its lanes; then a call selected in
# the list of calls, and its details
assert px(g8, 500, 114) == 0x2D6CA2, "the recordings window, focused"
assert px(g8, 400, 134) == 0x1B3A57, "the recordings window's header"
assert sum(1 for x in range(220, 1004) if px(g8, x, 230) == 0xF29B38) >= 2, "the marks"
servers = {0x2D6CA2, 0x3E8E5E, 0xB5651D, 0x7B4FA0, 0xA23B5A, 0x2A8A8A, 0x8A7A2A, 0x5A6670}
def boxes(img): return [px(img, x, y) for x in range(250, 1004, 2) for y in range(244, 584, 4)
                        if px(img, x, y) in servers]
assert len(set(boxes(g8))) >= 2, "servers' boxes in the lanes"
assert len(boxes(g10)) > 3 * len(boxes(g8)), "a mark clicked: its step, wider"
assert px(g9, 300, 233) == 0x2D6CA2, "a call selected in the list"
assert sum(1 for x in range(98, 900) if px(g9, x, 606) == 0x1A2228) > 20, "its details"
# the System window (content at 20,64): its layers, live
def count(img, colour, x0, y0, x1, y1, step=2):
    return sum(1 for x in range(x0, x1, step) for y in range(y0, y1, step) if px(img, x, y) == colour)
assert px(g11, 500, 54) == 0x2D6CA2, "the System window, focused"
assert count(g11, 0xDCEAF7, 132, 270, 1010, 322) > 500, "services' boxes"
assert count(g11, 0xFBE3D0, 132, 332, 1010, 384) > 500, "drivers' boxes"
assert count(g11, 0x24313C, 132, 412, 1010, 512) > 2000, "the kernel"
assert count(g11, 0xE9ECEF, 132, 534, 1010, 578) > 1000, "the hardware"
assert count(g11, 0xE8762C, 132, 270, 1010, 322, 1) > 100, "OCaml tags (services)"
assert count(g11, 0x5A6670, 132, 332, 1010, 384, 1) > 100, "C tags (drivers)"
# replaying: a call's arrow (red), IPC lit in the kernel, an ended
# process of the recording as a ghost
assert count(g12, 0xD9534F, 132, 140, 1010, 520, 1) > 60, "a call's arrow"
assert count(g12, 0xF29B38, 300, 470, 500, 500) > 100, "IPC lit"
assert count(g12, 0xF1F2F3, 132, 140, 1010, 400) > 300, "a process that ended, as a ghost"
# a new process: outlined
assert count(g13, 0xF29B38, 128, 136, 1014, 240, 1) > 100, "a new process, outlined"
# the close box acts on release, on it
assert count(g14, 0xFFFFFF, 274, 276, 474, 506) > 4000, "a slip off the close box: still open"
assert count(g15, 0xFFFFFF, 274, 276, 474, 506) < 1000, "a click on it: closed"
# the top bar's tabs: the agent window's, focused, and its window in front
assert px(g16, 518, 19) == 0x2D6CA2, "the agent window's tab, focused"
assert px(g16, 500, 172) == 0x2D6CA2, "the agent window, in front again"
# another boot's recording: its server, a ghost among the services
assert count(g17, 0xF1F2F3, 132, 270, 1010, 322) > 300, "another boot's service, a ghost"
# Files (content at 40,70): focused, its places and listing; then a text
# viewed (its words, and the Back button)
assert px(g18, 500, 59) == 0x2D6CA2, "the Files window, focused"
assert px(g18, 340, 80) == 0x1B3A57, "the Files window's header"
assert count(g19, 0x1A2228, 230, 180, 900, 220, 1) > 40, "a text viewed"
assert px(g19, 820, 161) == 0x2D6CA2, "the viewer's Back button"
# the tour: its window, then a lesson in the System window, at the birth
# of hello: the green arrow, the processes taking no part faint
assert px(g20, 400, 108) == 0x1B3A57, "the tour's window"
assert count(g21, 0x2E8B57, 132, 140, 1010, 520, 1) > 100, "a lesson: hello is born"
assert count(g21, 0xF8F9FA, 132, 140, 1010, 400) > 300, "a lesson: the others faint"
PY
fi
}

sec_net() {
# the network: netd (lwIP and the NE2000 driver) with QEMU's user network;
# on the host, a TCP server (47001), a UDP one (47053), a client of MyNOS's port 80
# (forwarded from 47080), HTTPS servers (47443-47445, tests/net/tls) and a
# fake language model provider (47090, for llmd)
net_fetched=
if [ -f tests/net/ramdisk.dsk ]; then
    tools/net-peer.py echo 47001 & echo_pid=$!
    tools/net-peer.py udpecho 47053 & udp_pid=$!
    tools/net-peer.py fetch 47080 "$tmp/fetched" & fetch_pid=$!
    tls=tests/net/tls
    tools/net-peer.py https 47443 $tls/good.pem $tls/good.key & https_pid=$!
    tools/net-peer.py https 47444 $tls/untrusted.pem $tls/untrusted.key & https2_pid=$!
    tools/net-peer.py https 47445 $tls/wrongname.pem $tls/wrongname.key & https3_pid=$!
    tools/net-peer.py llm 47090 & llm_pid=$!
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
    kill $qemu $echo_pid $udp_pid $fetch_pid $https_pid $https2_pid $https3_pid $llm_pid 2>/dev/null || true
    wait $qemu 2>/dev/null || true
    cat "$logn" >> "$part"
    grep -q "hello from a server in MyNOS" "$tmp/fetched" 2>/dev/null && net_fetched=yes
fi
}

sec_seventh() {
# seventh boot: the system RAM disk, init starts the services and sh, driven
# through the keyboard: the OCaml toplevel (ocaml), programs, sh again
history_saved= kilo_saved= edit_saved= edit_utf8= log_shown= sh_saved= trace_calls= trace_json= agent_marks= sound_ok=
disk_reads=
serial_same_sh=
if [ -f system/ramdisk.dsk ]; then
    # a disk, for /disk and the shell's history: a copy of the FAT16 test image
    [ -f tests/fat/fat16.img ] && cp tests/fat/fat16.img tests/fat/run-shell.img
    # the agent's model: the fake provider (tests/net/llm-test.env); a file
    # of characters the screen's font lacks (doc/decisions/console.md)
    if [ -f tests/fat/run-shell.img ]; then
        printf '\303\210 cos\303\254: \342\202\2545\n' > tests/fat/run-utf8.txt
        # a WAV file for play (mynos-7jn): half a second of 440 Hz, 8-bit mono 11025 Hz
        python3 -c 'import wave, math
w = wave.open("tests/fat/run-a440.wav", "wb"); w.setnchannels(1); w.setsampwidth(1); w.setframerate(11025)
w.writeframes(bytes(int(128 + 100 * math.sin(2 * math.pi * 440 * i / 11025)) for i in range(5512))); w.close()'
        tools/in-container.sh dev sh -c "mcopy -i tests/fat/run-shell.img tests/net/llm-test.env ::/llm.env && mcopy -i tests/fat/run-shell.img tests/fat/run-utf8.txt ::/utf8.txt && mcopy -i tests/fat/run-shell.img tests/greeter/greeter.byte ::/greeter.byte && mcopy -i tests/fat/run-shell.img tests/stdio/stdio ::/stdio-test && mcopy -i tests/fat/run-shell.img tests/zmachine/czech.z5 ::/czech.z5 && mcopy -i tests/fat/run-shell.img tests/fat/run-a440.wav ::/a440.wav && mmd -i tests/fat/run-shell.img ::/web && mcopy -i tests/fat/run-shell.img tests/greeter/greeter.byte ::/web/greeter.byte && mcopy -i tests/fat/run-shell.img tests/net/llm-test.env ::/web/llm.env"
        rm -f tests/fat/run-utf8.txt tests/fat/run-a440.wav
    fi
    tools/net-peer.py llm 47090 & llm7_pid=$!
    # the packages' repository (tools/pkg-build.sh), served by the host
    tools/net-peer.py files 47101 tmp/packages & files7_pid=$!
    # a Sound Blaster 16, recorded into a WAV file (mynos-7jn)
    NET=1 HTTP=47180 DISK=$([ -f tests/fat/run-shell.img ] && echo tests/fat/run-shell.img) \
    SOUND="wav:$tmp/sound7.wav" MEM=256 tools/run-qemu.sh "$ocamlrun" \
        services/registry/registry services/fs/memrofs/memrofsd \
        system/ramdisk.dsk \
        -- -display none -serial null \
           -chardev "socket,id=com2,path=$tmp/com2-7,server=on,wait=on" \
           -serial chardev:com2 \
           -monitor "unix:$tmp/mon7,server,nowait" &
    qemu=$!
    # COM2: the log, and a terminal (tools/serial-peer.py)
    : > "$tmp/com2-7.in"
    tools/serial-peer.py "$tmp/com2-7" "$log7" "$tmp/com2-7.in" & peer7=$!
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
                  'write "sz.ml" "let () = print_endline (Str.global_replace (Str.regexp (String.make 1 (Char.chr 97))) (String.make 1 (Char.chr 122)) (String.make 5 (Char.chr 97)))";;\n' \
                  'ignore (compile "sz.ml"); run "sz.byte" [];;\n' \
                  'run "kilo" ["/disk/k.txt"];;\n' 'typed in kilo' '{ctrl-s}' '{ctrl-q}' \
                  'edit "/disk/e.txt";;\n' '' 'second\n{up}first {ctrl-k}{ctrl-u}{ctrl-u}' '{ctrl-s}' '{ctrl-q}' \
                  'sh ();;\n' 'cd /disk; echo from sh > s.txt; X=4; echo "v$X" >> s.txt; cat s.txt | cat\n' \
                  'trace -o /disk/t.trc cat Makefile > /tmp/tout.txt\n' '' \
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
    # the console (doc/decisions/console.md). The screen's characters, read
    # from VGA's memory through QEMU's monitor
    screen() {
        printf 'xp /2000hx 0xb8000\n' | socat - "UNIX-CONNECT:$tmp/mon7" | python3 -c '
import re, sys
cells = []
for line in sys.stdin:
    m = re.match(r"^[0-9a-f]+:((?: 0x[0-9a-f]{4})+)", line.strip())
    if m:
        cells += [int(x, 16) & 0xFF for x in m.group(1).split()]
sys.stdout.buffer.write(bytes(cells))' > "$1"
    }
    waitfor() {   # a text in the log, within $2 seconds
        i=0
        while [ $i -lt "$2" ] && ! grep -aqF -- "$1" "$log7"; do sleep 1; i=$((i + 1)); done
    }
    # the Italian layout (and AltGr), typed characters as UTF-8
    tools/type-keys.py "$tmp/mon7" 'keymap it\n'; sleep 1
    tools/type-keys.py "$tmp/mon7" 'echo caff{bracket_left} perch{shift-bracket_left} a{alt_r-semicolon}b{ctrl-alt-semicolon}\n'
    sleep 2
    tools/type-keys.py "$tmp/mon7" 'keymap us\n'; sleep 1
    tools/type-keys.py "$tmp/mon7" 'cat /disk/utf8.txt\n'; sleep 2
    screen "$tmp/screen1"
    # the scrollback: Shift+PgUp shows older lines, marked top right
    printf 'sendkey shift-pgup\n' | socat - "UNIX-CONNECT:$tmp/mon7" >/dev/null; sleep 1
    screen "$tmp/screen2"
    printf 'sendkey shift-pgdn\n' | socat - "UNIX-CONNECT:$tmp/mon7" >/dev/null; sleep 1
    # the agent writes OCaml: run once it type-checks, refused when not
    # (the fake model calls the tool named in brackets)
    tools/type-keys.py "$tmp/mon7" "agent -y '[run_ocaml] let () = print_endline (string_of_int (6 * 7) ^ {shift-apostrophe}-from-ocaml{shift-apostrophe})'\n"
    waitfor "42-from-ocaml" 90
    tools/type-keys.py "$tmp/mon7" "agent -y '[run_ocaml] let () = print_endline 42'\n"
    waitfor "It does not compile" 90
    sleep 2
    # its recording: the steps it marked, among the calls
    tools/type-keys.py "$tmp/mon7" 'trace calls /tmp/agent.trc > /disk/agent-calls.txt\n'; sleep 4
    # a program built into a file (build_ocaml: the fake model takes a JSON
    # object as the tool's input), then run from sh
    tools/type-keys.py "$tmp/mon7" "agent -y '[build_ocaml] {\"output\": \"/tmp/b.byte\", \"code\": \"let () = print_int (6 * 7 * 1000 + 1); print_newline ()\"}'\n"
    waitfor "Built /tmp/b.byte" 90; sleep 2
    tools/type-keys.py "$tmp/mon7" '/tmp/b.byte\n'; sleep 3
    # a service started by the agent, left running (sh's &): ps shows it
    # with its name, and a client gets its answer
    tools/type-keys.py "$tmp/mon7" "agent -y '[run_command] /disk/greeter.byte &'\n"
    sleep 20
    tools/type-keys.py "$tmp/mon7" 'ps\n'; sleep 2
    tools/type-keys.py "$tmp/mon7" '/disk/greeter.byte agent\n'; sleep 3
    # kill: the agent's service, by its name; one of ours, by $!; not init
    tools/type-keys.py "$tmp/mon7" 'kill greeter\n'; sleep 2
    tools/type-keys.py "$tmp/mon7" '/disk/greeter.byte again\n'; sleep 3
    tools/type-keys.py "$tmp/mon7" '/disk/greeter.byte & kill $!\n'; sleep 3
    tools/type-keys.py "$tmp/mon7" 'kill 1\n'; sleep 2
    # a window outside the graphical session: said, and ended; Ctrl-C ends
    # the program sh waits for
    tools/type-keys.py "$tmp/mon7" '/clock.byte\n'; sleep 6
    tools/type-keys.py "$tmp/mon7" '/disk/greeter.byte\n'; sleep 4
    printf 'sendkey ctrl-c\n' | socat - "UNIX-CONNECT:$tmp/mon7" >/dev/null; sleep 2
    tools/type-keys.py "$tmp/mon7" 'echo st-$?\n'; sleep 2
    # services come back: fatfs killed, restarted by init, found again by
    # sh (libmynos); a client of greeter (OCaml, Ipc) that finds it again
    # after it was killed and started anew
    # a program with a thread, compiled inside MyNOS (unix.cma, threads.cma
    # on the RAM disk; -noautolink: the runtime has their primitives)
    # ... which also asks consoled (C) to describe console/1, as console.ml does
    tools/type-keys.py "$tmp/mon7" "echo 'let () = let t = Thread.create (fun () -> print_endline (\"from-a-\" ^ \"thread\")) () in Thread.join t' > /disk/th.ml\n"; sleep 2
    tools/type-keys.py "$tmp/mon7" "echo 'let () = let d = Ipc.describe \"console\" in if d.Ipc.summary = Console.Protocol.summary && d.requests = Console.Protocol.requests then print_endline (\"console-\" ^ \"described\")' >> /disk/th.ml\n"; sleep 2
    tools/type-keys.py "$tmp/mon7" 'ocamlc -use-prims /primitives mynos.cma unix.cma threads.cma -noautolink -o /disk/th.byte /disk/th.ml && /disk/th.byte\n'; sleep 25
    # httpd serves /disk/web (made before this boot: kept as it is), not
    # the rest of /disk, and not its .env files (mynos-n16), neither by
    # name nor in the listing
    httpd_private=
    if curl -s -m 5 http://127.0.0.1:47180/ | grep -q 'greeter.byte' &&
       ! curl -s -m 5 http://127.0.0.1:47180/ | grep -qi 'llm.env' &&
       [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:47180/llm.env)" = 404 ] &&
       [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:47180/LLM.ENV)" = 404 ] &&
       [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:47180/utf8.txt)" = 404 ]; then
        httpd_private=yes
    fi
    # httpd receives files from the host (QEMU's 10.0.2.2): PUT, into a
    # new directory too, and a form of two; not llm.env, not with another
    # site's Origin; MyNOS reads what came (cat, below)
    httpd_upload=
    u=http://127.0.0.1:47180
    printf 'put-by-the-host\n' > "$tmp/up1.txt"; head -c 200000 /dev/urandom > "$tmp/up2.bin"
    if curl -s -m 20 -f -T "$tmp/up1.txt" $u/up/a/up1.txt >/dev/null &&
       [ "$(curl -s -m 20 -o /dev/null -w '%{http_code}' -F file=@"$tmp/up1.txt" -F file=@"$tmp/up2.bin" \
             -H "Origin: $u" $u/up/)" = 303 ] &&
       curl -s -m 20 $u/up/up2.bin | cmp -s - "$tmp/up2.bin" &&
       [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' -T "$tmp/up1.txt" $u/llm.env)" = 404 ] &&
       [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' -T "$tmp/up1.txt" -H 'Origin: http://example.com' $u/x.txt)" = 403 ] &&
       curl -s -m 10 $u/up/ | grep -q 'multipart/form-data'; then
        httpd_upload=yes
    fi
    tools/type-keys.py "$tmp/mon7" 'cat /disk/web/up/a/up1.txt /disk/web/up/up1.txt\n'; sleep 2
    # the kernel's log, read inside MyNOS (mynos-lfv): its boot messages
    # come back on the console, so the log port sees them twice
    tools/type-keys.py "$tmp/mon7" 'log\n'; sleep 4
    # the version: the boot's banner, and sh's version (uname, mynos-nec)
    tools/type-keys.py "$tmp/mon7" 'version\n'; sleep 2
    [ "$(grep -ac 'Calibrating delay loop' "$log7")" -ge 2 ] && log_shown=yes
    # C's stdio (mynos-d6k): files through fopen, a typed line, a piped one
    tools/type-keys.py "$tmp/mon7" '/disk/stdio-test\n'; sleep 4
    tools/type-keys.py "$tmp/mon7" 'typed-line\n'; sleep 3
    tools/type-keys.py "$tmp/mon7" 'echo piped-line | /disk/stdio-test\n'; sleep 5
    tools/type-keys.py "$tmp/mon7" 'echo into-a-file | /disk/stdio-test > /tmp/so.txt; cat /tmp/so.txt\n'; sleep 5
    # MyNOS reaches its own address (lwIP's loopback), and httpd refuses
    # the .env files from inside too
    tools/type-keys.py "$tmp/mon7" 'fetch -i http://10.0.2.15/llm.env\n'; sleep 4
    # packages (mynos-vcd), from the host's copy of their repository: 2048
    # installed as its bytecode, windtree compiled from its sources (-s);
    # both found on PATH (windtree has no session to open its window in),
    # 2048 removed
    tools/type-keys.py "$tmp/mon7" 'MYNOS_PKG_URL=http://10.0.2.2:47101; pkg list\n'
    waitfor "A tree in the wind" 30
    tools/type-keys.py "$tmp/mon7" 'pkg install 2048\n'
    waitfor "pkg: 2048 1.0 installed" 60
    tools/type-keys.py "$tmp/mon7" 'pkg install -s windtree\n'
    waitfor "pkg: windtree 1.0 installed" 180
    tools/type-keys.py "$tmp/mon7" 'which windtree; windtree; echo windtree-$?; pkg list -i\n'; sleep 8
    tools/type-keys.py "$tmp/mon7" 'pkg remove 2048; ls /disk/bin\n'; sleep 4
    # a package of several commands, scripts that run its program (utils:
    # "#!/disk/bin/utils.byte"), and one on Num (calc); a script of sh's
    # run by its name
    tools/type-keys.py "$tmp/mon7" 'pkg install utils calc\n'
    waitfor "pkg: calc 1.0 installed" 90
    tools/type-keys.py "$tmp/mon7" "echo zeta > /tmp/s; echo alpha >> /tmp/s; sort /tmp/s | head -n 1 | grep -n alpha; calc '2^100' '1/3 + 1/6'\n"; sleep 8
    tools/type-keys.py "$tmp/mon7" "echo '#!/sh.byte' > /disk/bin/hi; echo 'echo script-\$1' >> /disk/bin/hi; hi ran\n"; sleep 4
    # df: the file systems' space, each asked (fs/1 space); clip: the
    # clipboard service, set and read back
    tools/type-keys.py "$tmp/mon7" 'df; X=ok; clip clip-$X; clip; ps -f\n'; sleep 5
    # the external pager (mynos-vzp): files mapped, each page read by pagerd
    # at its first touch, compared with the files read as usual
    # memory of the pager past its budget (16 pages: through /disk/swap), a
    # shared mapping written to its file, a private one that must not be
    tools/type-keys.py "$tmp/mon7" 'mapcat -c /disk/czech.z5 /AUTOEXEC.BAT; mapcat -a 64 16; echo 12345 file to map > /disk/mw.txt; mapcat -w /disk/mw.txt HOWDY; mapcat -p /disk/mw.txt; cat /disk/mw.txt; mapcat -s; X=done; echo mapcat-$X\n'
    waitfor "mapcat-done" 90
    # GAV (mynos-0ns): installed with its pictures, which it reads before
    # it asks for a window (none in text mode)
    tools/type-keys.py "$tmp/mon7" 'pkg install gavml; gavml\n'
    waitfor "gavml.byte: no graphical session" 60
    # the browser (mynos-asr), as text: a page of the disk, its entities,
    # its link made absolute; the start page
    tools/type-keys.py "$tmp/mon7" "pkg install browser; echo '<title>T</title><h1>T&eacute;st</h1><p>a <a href=x.html>link</a> &copy; 2026</p><form><input name=q value=hi size=6> <input type=submit value=Go></form><table><tr><td>a</td><td>bb</td></tr><tr><td>ccc</td><td>d</td></tr></table>' > /tmp/t.html; browser --dump /tmp/t.html; browser --dump about:start > /tmp/start.txt; grep -c ocaml.org /tmp/start.txt; X=done; echo browser-\$X\n"
    waitfor "browser-done" 90
    # the Z-machine interpreter, in the terminal (no session), against
    # Czech's tests (tests/zmachine)
    tools/type-keys.py "$tmp/mon7" 'pkg install zmachine; echo | zmachine /disk/czech.z5 > /tmp/cz.txt; grep Failed /tmp/cz.txt\n'
    waitfor "Passed: 406, Failed: 0" 120
    # Scheme (OCS, third_party/ocs) runs a file; man prints chapter 13's
    # entry of a command, from the package manual
    tools/type-keys.py "$tmp/mon7" 'pkg install scheme manual; echo "(display (expt 3 50))" > /tmp/a.scm; scheme /tmp/a.scm; echo; man pkg | head -n 3\n'
    waitfor "Installs packages: demos" 120
    tools/type-keys.py "$tmp/mon7" 'pkg install minotaur; echo help | minotaur\n'
    # sound (mynos-7jn): soundd's protocol as module Sound has it, a WAV
    # file converted and played, a tone; the recording is checked below
    waitfor "Directions: north" 90; sleep 2
    tools/type-keys.py "$tmp/mon7" 'play check; play /disk/a440.wav; play -t 1320 300\n'; sleep 5
    waitfor "Directions: north, south" 60
    # Ctrl-C on a program waiting for a line: the next line is sh's, not
    # swallowed by the program it ended (mynos-5dd)
    tools/type-keys.py "$tmp/mon7" '/disk/stdio-test\n'; sleep 4
    printf 'sendkey ctrl-c\n' | socat - "UNIX-CONNECT:$tmp/mon7" >/dev/null; sleep 2
    tools/type-keys.py "$tmp/mon7" 'X=ctrlc; echo after-$X\n'; sleep 2
    # Tab completes a name with a space, in quotes (mynos-f7k)
    tools/type-keys.py "$tmp/mon7" 'X=content; echo spaced-$X > "/disk/my file.txt"\n'; sleep 2
    tools/type-keys.py "$tmp/mon7" 'cat /disk/my{tab}\n'; sleep 3
    # a rename that changes only the case keeps the file (mynos-qaw)
    tools/type-keys.py "$tmp/mon7" 'echo case-kept > /disk/case.txt; mv /disk/case.txt /disk/CASE.txt; cat /disk/CASE.txt\n'; sleep 3
    tools/type-keys.py "$tmp/mon7" 'kill fatfs\n'; sleep 4
    tools/type-keys.py "$tmp/mon7" 'X=back; echo fatfs-$X > /disk/back.txt; cat /disk/back.txt\n'; sleep 3
    tools/type-keys.py "$tmp/mon7" '/disk/greeter.byte &\n'; sleep 3
    tools/type-keys.py "$tmp/mon7" '/disk/greeter.byte reborn 9 &\n'; sleep 3
    tools/type-keys.py "$tmp/mon7" 'kill greeter\n'; sleep 1
    tools/type-keys.py "$tmp/mon7" '/disk/greeter.byte &\n'; sleep 10
    # fatfs reads: a file of 100 KB not read yet in this boot (docs/big.bin,
    # 2 KB clusters), read twice, recorded: the disk is asked for runs of
    # sectors (not a request per cluster), then not at all (the cache)
    tools/type-keys.py "$tmp/mon7" 'trace -o /disk/r1.trc cat /disk/docs/big.bin > /tmp/r1\n'; sleep 10
    tools/type-keys.py "$tmp/mon7" 'trace -o /disk/r2.trc cat /disk/docs/big.bin > /tmp/r2\n'; sleep 10
    tools/type-keys.py "$tmp/mon7" 'trace calls /disk/r1.trc > /disk/r1.txt; trace calls /disk/r2.trc > /disk/r2.txt\n'; sleep 15
    # the host's terminal on COM2: a line typed, then two pasted at once
    # (a burst: the shell must not read an end of file), then the keyboard
    banners=$(grep -ac 'MyNOS sh. help' "$log7")
    printf 'X=seriale; echo dal-$X\r' >> "$tmp/com2-7.in"
    waitfor "dal-seriale" 15
    printf 'echo incollata-1\recho incollata-2\r' >> "$tmp/com2-7.in"
    waitfor "incollata-2" 15
    tools/type-keys.py "$tmp/mon7" 'echo still-$X\n'
    waitfor "still-seriale" 15
    [ "$(grep -ac 'MyNOS sh. help' "$log7")" = "$banners" ] && serial_same_sh=yes
    # edit takes UTF-8 (mynos-wv4): accented letters typed on the serial
    # terminal, a backspace over one of them, then Ctrl-S and Ctrl-Q
    printf 'edit /disk/u.txt\r' >> "$tmp/com2-7.in"; sleep 4
    printf 'perch\303\251 \303\250 cos\303\254\303\254\177' >> "$tmp/com2-7.in"; sleep 2
    printf '\023' >> "$tmp/com2-7.in"; sleep 2
    printf '\021' >> "$tmp/com2-7.in"; sleep 2
    printf 'quit\n' | socat - "UNIX-CONNECT:$tmp/mon7" >/dev/null || true
    wait $qemu || true
    kill $llm7_pid $files7_pid $peer7 2>/dev/null || true
    cat "$log7" >> "$part"
    # what the sound card played: half a second at 440 Hz, then 0.3 s at
    # 1320 Hz (windows of 0.1 s, their zero crossings)
    python3 - "$tmp/sound7.wav" <<'PY' && sound_ok=yes
import sys, wave, struct
w = wave.open(sys.argv[1]); n = w.getnframes(); rate = w.getframerate()
s = struct.unpack('<%dh' % (n * w.getnchannels()), w.readframes(n))[::w.getnchannels()]
step = rate // 10; hz = []
for i in range(0, len(s) - step, step):
    seg = s[i:i + step]
    if max(abs(v) for v in seg) > 1000:
        hz.append(sum(1 for a, b in zip(seg, seg[1:]) if (a < 0) != (b < 0)) / 2 / 0.1)
low = sum(1 for f in hz if 430 <= f <= 450); high = sum(1 for f in hz if 1300 <= f <= 1340)
sys.exit(0 if low >= 3 and high >= 2 else 1)
PY
    if [ -f tests/fat/run-shell.img ]; then
        tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/.history \
            2>/dev/null | grep -qx '6 \* 7;;' && history_saved=yes
        [ "$(tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/k.txt 2>/dev/null)" = \
          "typed in kilo" ] && kilo_saved=yes
        [ "$(tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/e.txt 2>/dev/null)" = \
          "$(printf 'first second\nfirst second\n')" ] && edit_saved=yes
        [ "$(tools/in-container.sh dev mcopy -i tests/fat/run-shell.img ::/u.txt - 2>/dev/null)" = \
          "$(printf 'perch\303\251 \303\250 cos\303\254\n')" ] && edit_utf8=yes
        [ "$(tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/s.txt 2>/dev/null)" = \
          "$(printf 'from sh\nv4\n')" ] && sh_saved=yes
        tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/calls.txt \
            2>/dev/null > "$tmp/calls.txt" || true
        grep -q 'sh(.*-> fatfs(.*fs/1 Open ("Makefile", 0)' "$tmp/calls.txt" &&
            grep -q '^ .*  fatfs(.*-> ata(.*block/1 Read' "$tmp/calls.txt" && trace_calls=yes
        for r in r1 r2; do
            tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/$r.txt \
                2>/dev/null > "$tmp/$r.txt" || true
        done
        python3 - "$tmp/r1.txt" "$tmp/r2.txt" <<'PY' && disk_reads="$(cat "$tmp/r-counts")"
import re, sys
def counts(path):
    s = open(path, encoding="latin-1").read()
    reads = len(re.findall(r"-> fatfs\(\d+\)\s+fs/1 Read", s))
    disk = len(re.findall(r"fatfs\(\d+\) -> ata\(\d+\)\s+block/1 Read", s))
    return reads, disk
(r1, d1), (r2, d2) = counts(sys.argv[1]), counts(sys.argv[2])
open(sys.argv[1].replace("r1.txt", "r-counts"), "w").write("%d %d %d %d" % (r1, d1, r2, d2))
assert r1 >= 7 and r2 >= 7, (r1, r2)            # the file was read, in 16 KB requests
assert 0 < d1 <= 2 * r1, (r1, d1)                # runs, not a request per cluster (49)
assert d2 <= 2, (r2, d2)                         # read again: from the cache
PY
        tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/agent-calls.txt \
            2>/dev/null > "$tmp/agent-calls.txt" || true
        grep -q '# agent([0-9]*): model call 1' "$tmp/agent-calls.txt" &&
            grep -q '# agent([0-9]*): run_ocaml: let () = print_endline 42' "$tmp/agent-calls.txt" &&
            grep -q 'agent(.*-> llmd(.*llm/1 Chat' "$tmp/agent-calls.txt" && agent_marks=yes
        tools/in-container.sh dev mtype -i tests/fat/run-shell.img ::/t.json \
            2>/dev/null > "$tmp/t.json" || true
        python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))["traceEvents"]
assert any(e["ph"] == "X" and e["name"].startswith("block/1 Read") for e in d)
assert any(e["ph"] == "f" for e in d)' "$tmp/t.json" 2>/dev/null && trace_json=yes
        rm -f tests/fat/run-shell.img
    fi
fi
}

# a section, timed: the seconds it took, by lane, in $tmp/times (printed
# at the end, to see where the suite's time goes)
timed() {
    t0=$(date +%s)
    "$1" || true
    echo "$lane $1 $(($(date +%s) - t0))" >> "$tmp/times"
}

for v in $results; do eval "$v="; done   # a lane not run finds nothing
pids=
for lane in ${LANES:-a b c d e}; do
    (
        trap - EXIT
        part=$tmp/part-$lane
        : > "$part"
        case $lane in
            a) timed sec_first; timed sec_effects; timed sec_storage; timed sec_fat; timed sec_domains; timed sec_threads; timed sec_fpu ;;
            b) timed sec_mlib; timed sec_files; timed sec_libs; timed sec_stress; timed sec_spawn; timed sec_console ;;
            c) timed sec_nocom2; timed sec_reboots; timed sec_virtio ;;
            d) timed sec_gui ;;
            e) timed sec_net; timed sec_seventh ;;
        esac
        save_results "$lane"
    ) &
    pids="$pids $!"
done
lanes_ok=yes
for p in $pids; do wait "$p" || lanes_ok=; done
for f in "$tmp"/results-*; do [ -f "$f" ] && . "$f"; done
cat "$tmp"/part-* >> "$log"

fail=0
expect() {
    if grep -aqF -- "$1" "$log"; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n' "$1"; fail=1
    fi
}
if [ -z "$lanes_ok" ]; then
    echo "FAIL  a lane of boots stopped early (a command failed in it)"; fail=1
fi
reject() {
    if grep -aqF -- "$1" "$log"; then
        echo "FAIL  unexpected: $1"; fail=1
    fi
}

expect "Hello from OCaml on MyNOS!"
expect "5 * 5 = 25"
expect "keyboardd: sem = "                          # the drivers got their IRQs
expect "seriald: sem = "
expect "Hello from memrofs!"
expect "fpu: all checks passed"
expect "Welcome to MyNOS - v$(cat VERSION 2>/dev/null)"      # the boot's banner
expect "MyNOS $(cat VERSION 2>/dev/null)"                    # sh's version (uname)
expect "threads: all checks passed"
expect "abi: all checks passed"
if [ -f tests/stress/ramdisk.dsk ]; then
    expect "stress: all checks passed"
fi
if [ -f tests/net/ramdisk.dsk ]; then
    expect "net: all checks passed"
    expect "asked-ok"           # ask in sh: the proposed command ran
    expect "agent-ran"          # agent: the command it was allowed to run ran
    expect "agent-local"
    expect "The user did not allow this command."
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
if [ -f tests/libs/ramdisk.dsk ]; then
    expect "libs: all checks passed"
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
    if [ -n "$disk_reads" ]; then
        echo "ok    fatfs: reads in runs, then from the cache (READs, disk requests: $disk_reads)"
    else
        echo "FAIL  fatfs: reads in runs, then from the cache"; fail=1
    fi
    if [ -n "$agent_marks" ]; then
        echo "ok    trace: the agent's steps marked in its recording"
    else
        echo "FAIL  trace: the agent's steps marked in its recording"; fail=1
    fi
    expect "io  consoled        console"     # ps: a driver, its service
    expect "greeter         greeter"         # ps: the service the agent started
    expect "Hello, agent, from MyNOS!"
    expect "42001"                                   # built by the agent, run by sh
    expect "(greeter) killed by"                     # kill greeter
    expect "done, status 137"                        # & then kill $!
    expect "kill: 1: not allowed (init, or a driver)"
    expect "no graphical session: start it with gui"  # a window, from text mode
    expect "st-137"                                    # Ctrl-C ended greeter
    expect "init: restarting fatfs.byte"               # a killed service, back
    expect "fatfs-back"                                # and found again by sh
    expect "from-a-thread"                             # threads, compiled in MyNOS
    expect "console-described"                         # consoled speaks console/1
    expect "stdio: all checks passed"                  # C stdio: fopen...
    expect "stdio: read [typed-line]"                  # ... stdin, typed
    expect "stdio: poll on stdin, at once: 0"          # poll: nothing typed yet...
    expect "stdio: poll on stdin, waiting: 1"          # ... then the line
    expect "stdio: poll on stdin, at once: 1"          # ... a pipe's file: ready
    expect "stdio: read [piped-line]"                  # ... and redirected
    expect "stdio: isatty(1) 1"                        # a terminal...
    expect "stdio: isatty(1) 0"                        # ... or a file
    expect "stdio: read [into-a-file]"                 # all of stdout in the file
    expect "case-kept"                                 # mv to other letters
    expect "spaced-content"                            # Tab quoted a name
    expect "after-ctrlc"                               # Ctrl-C swallows nothing
    expect "server: MyNOS httpd"                       # our own address...
    expect "404 Not Found"                             # ... and no llm.env
    expect "pkg: 2048 1.0 installed (its bytecode): 2048"   # packages
    expect "pkg: windtree 1.0 installed (compiled from its sources): windtree"
    expect "/disk/bin/windtree.byte"
    expect "windtree-2"                                # ran: no session
    expect "windtree   1.0      compiled from its sources"   # pkg list -i
    expect "pkg: 2048 removed"
    expect "pkg: utils 1.2 installed (its bytecode): grep wc head tail sort uniq find du df hexdump tree clip top"
    expect "1:alpha"                                  # sort | head | grep
    expect "1267650600228229401496703205376"          # calc
    expect "1/2 = 0.5"
    expect "script-ran"                               # #!/sh.byte
    expect "Passed: 406, Failed: 0"                   # zmachine, Czech
    expect "717897987691852588770249"                 # scheme
    expect "Purpose Installs packages: demos"         # man
    expect "Directions: north, south"                 # minotaur
    expect "%  /disk"                                 # df
    expect "clip-ok"                                  # clip, the clipboard service
    expect "      since boot "                        # ps -f: page faults counted
    expect "mapcat: /disk/czech.z5: the same (13312 bytes, 4 pages)"  # the external pager
    expect "mapcat: /AUTOEXEC.BAT: the same (59 bytes, 1 pages)"
    expect "mapcat: 64 pages of memory: the same (swap:"  # past the budget, through the swap
    expect "mapcat: /disk/mw.txt: written through the mapping"
    expect "mapcat: /disk/mw.txt: changed in memory, not in the file"
    expect "HOWDY file to map"                          # the file, changed by the shared one
    expect "0 mappings, "                                # mapcat -s: all unmapped
    expect "stdio: mmap MAP_SHARED: the change written to the file ok"  # C's mmap of a file
    expect "pkg: gavml 1.3 installed"                 # GavML (GAV)...
    expect "gavml.byte: no graphical session"         # ... its pictures read first
    expect "Tést"                                     # the browser: entities,
    expect "a link © 2026"                            # inline text,
    expect "1. file:/tmp/x.html"                      # links made absolute
    expect "[hi____] [ Go ]"                          # a form's fields
    expect "ccc  d"                                   # a table as a grid
    expect "soundd: Sound Blaster 16 (DSP 4.05)"
    expect "play: soundd describes sound/1 as sound.ml does"
    if [ -n "$sound_ok" ]; then
        echo "ok    sound: a WAV file and a tone, as the card played them"
    else
        echo "FAIL  sound: a WAV file and a tone, as the card played them"; fail=1
    fi
    if [ -n "$httpd_private" ]; then
        echo "ok    httpd: serves /disk/web, not its .env files"
    else
        echo "FAIL  httpd: serves /disk/web, not its .env files"; fail=1
    fi
    if [ -n "$httpd_upload" ] && [ "$(grep -ac 'put-by-the-host' "$log7")" -ge 2 ]; then
        echo "ok    httpd: receives files from the host (PUT, a form)"
    else
        echo "FAIL  httpd: receives files from the host (PUT, a form)"; fail=1
    fi
    expect "Hello, reborn again, from MyNOS!"          # by an OCaml client too
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
    if [ -n "$log_shown" ]; then
        echo "ok    log: the kernel's log read inside MyNOS"
    else
        echo "FAIL  log: the kernel's log read inside MyNOS"; fail=1
    fi
    if [ -n "$edit_utf8" ] || [ ! -f tests/fat/fat16.img ]; then
        echo "ok    edit: accented letters typed, erased, saved (UTF-8)"
    else
        echo "FAIL  edit: accented letters typed, erased, saved (UTF-8)"; fail=1
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
    if grep -aqx 'zzzzz' "$log7"; then
        echo "ok    compile links Str when the program names it"
    else
        echo "FAIL  compile links Str when the program names it"; fail=1
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
    expect "caffè perché a@b@"
    python3 - "$tmp/screen1" "$tmp/screen2" <<'PY' && echo "ok    console: UTF-8 shown in code page 437 (È, €: redrawn glyphs)" || { echo "FAIL  console: UTF-8 shown in code page 437 (È, €: redrawn glyphs)"; fail=1; }
import sys
s = open(sys.argv[1], "rb").read()
assert b"caff\x8a perch\x82 a@b@" in s, "è é"
assert b"\x9f cos\x8d: \xf95" in s, "È ì €"
PY
    python3 - "$tmp/screen2" <<'PY' && echo "ok    console: Shift+PgUp shows the scrollback" || { echo "FAIL  console: Shift+PgUp shows the scrollback"; fail=1; }
import re, sys
s = open(sys.argv[1], "rb").read()
assert re.search(rb"\[-\d+\]$", s[:80]), s[:80]
PY
    if [ -n "$nocom2" ]; then
        echo "ok    without COM2 (QEMU's window), the shell answers within seconds"
    else
        echo "FAIL  without COM2 (QEMU's window), the shell answers within seconds"; fail=1
    fi
    if [ -n "$gui_ok" ]; then
        echo "ok    gui: a session, windows of programs, a click, back to text"
    else
        echo "FAIL  gui: a session, windows of programs, a click, back to text"; fail=1
    fi
    expect "gui: displayd describes display/1 as display.ml does"
    expect "graphics: all checks passed"
    expect "typed-in-text"                             # Text saved a file
    expect "hello.byte"                                # Studio built and ran hello.ml
    expect "keys: size 340x110"                        # a grip dragged
    expect "keys: size 1022x720"                       # maximized
    expect "keys: down x, held ESC[C x"                # two keys held at once
    expect "keys: up x, held ESC[C"
    expect "keys: up ESC[C, held"
    expect "keys: up q, held"
    expect "vblkd: virtio disk, 32768 sectors"
    expect "netd: virtio card, IRQ"
    expect "consoled: virtio keyboard, IRQ"
    expect "virtio GPU, no PS/2 mouse, virtio tablet"
    if [ -n "$virtio_gui" ]; then
        echo "ok    virtio: the graphical session on a virtio GPU, a click of a virtio tablet"
    else
        echo "FAIL  virtio: the graphical session on a virtio GPU, a click of a virtio tablet"; fail=1
    fi
    if [ -n "$virtio_net" ]; then
        echo "ok    virtio: netd on a virtio card, httpd reached by the host"
    else
        echo "FAIL  virtio: netd on a virtio card, httpd reached by the host"; fail=1
    fi
    if [ -n "$virtio_disk" ]; then
        echo "ok    virtio: a file written on a virtio disk, read by the host"
    else
        echo "FAIL  virtio: a file written on a virtio disk, read by the host"; fail=1
    fi
    if [ -n "$files_ok" ]; then
        echo "ok    files: a file copied between services, a folder made; Ctrl-C and line editing in a terminal"
    else
        echo "FAIL  files: a file copied between services, a folder made; Ctrl-C and line editing in a terminal"; fail=1
    fi
    if [ -n "$pkgwin_ok" ]; then
        echo "ok    gui: the Packages window read the index through pkg"
    else
        echo "FAIL  gui: the Packages window read the index through pkg"; fail=1
    fi
    if [ -n "$gui_hangup" ]; then
        echo "ok    gui: a terminal closed ends its sh (a hang-up)"
    else
        echo "FAIL  gui: a terminal closed ends its sh (a hang-up)"; fail=1
    fi
    expect "init: shutdown asked by pid"
    if [ -n "$powered_off" ]; then
        echo "ok    shutdown: init turned the machine off (ACPI)"
    else
        echo "FAIL  shutdown: init turned the machine off (ACPI)"; fail=1
    fi
    if [ -n "$reboots_ok" ]; then
        echo "ok    shutdown -r three times: four boots reach the shell"
    else
        echo "FAIL  shutdown -r three times: four boots reach the shell"; fail=1
    fi
    if [ -n "$rebooted" ]; then
        echo "ok    shutdown -r: init restarted the machine"
    else
        echo "FAIL  shutdown -r: init restarted the machine"; fail=1
    fi
    expect "gui: the graphical session ended"
    expect "text-ok"
    expect "term-ok"
    expect "sel-pick-ok"                              # a word selected, pasted
    expect "agentwin-ok"        # the agent window: the command allowed by its button ran
    expect "dal-seriale"
    expect "incollata-2"
    expect "still-seriale"
    if [ -n "$serial_same_sh" ]; then
        echo "ok    console: input from COM2 (a paste), the same shell goes on"
    else
        echo "FAIL  console: input from COM2 (a paste), the same shell goes on"; fail=1
    fi
    expect "42-from-ocaml"
    expect "It does not compile"
    expect "but an expression was expected of type"
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
    expect 'console: line 3: "from serial \195\169"'
    expect 'console: line 4: "xabcy"'
    expect 'console: line 5: "013"'
    expect "console: end of input after 5 lines"
fi
reject "PANIC"
reject "page fault (?)"
reject "Problems releasing pages"
reject "kernel heap:"
reject "FAIL"

# the time of each section, and of each lane (the suite's is the longest)
if [ -f "$tmp/times" ]; then
    awk '{ printf "time  %s %-14s %4d s\n", $1, $2, $3; t[$1] += $3 }
         END { for (l in t) printf "time  %s (lane)         %4d s\n", l, t[l] }' \
        "$tmp/times" | sort
fi

if [ $fail -ne 0 ]; then
    echo "--- console log ---"
    cat "$log"
    exit 1
fi
echo "all tests passed"
