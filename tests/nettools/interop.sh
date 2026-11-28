#!/bin/sh
# nettools' SSH server (on the host: hostsshd.byte, built by run.sh) for
# the host's OpenSSH client, on 127.0.0.1:$PORT. Nothing of ~/.ssh is
# read or written: no config, no known_hosts, the throwaway key of
# run.sh (tests/nettools/_k).
#   tests/nettools/run.sh && tests/nettools/interop.sh
set -eu
d=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-47130}
"$d/_t/hostsshd.byte" "$PORT" "$d/_k/id.pub" > "$d/_k/server.log" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null || true' EXIT
sleep 1
o="-F /dev/null -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null
   -o StrictHostKeyChecking=no -o LogLevel=ERROR -o IdentitiesOnly=yes -o IdentityAgent=none -p $PORT"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fails=$((fails+1)); fi; }
out=$(ssh $o -i "$d/_k/id" -o BatchMode=yes test@127.0.0.1 'echo hi' 2>&1) && rc=0 || rc=$?
check "OpenSSH, key, exec" "$out" "ran: echo hi"
check "exit status" "$rc" 7
out=$(printf 'abc' | ssh $o -i "$d/_k/id" -o BatchMode=yes test@127.0.0.1 2>&1 | tr -d '\r') || true
check "OpenSSH, shell without a terminal" "$out" "no pty
ABC"
out=$(ssh $o -o BatchMode=yes -o PubkeyAuthentication=no test@127.0.0.1 x 2>&1) && rc=0 || rc=$?
check "no key, no password: refused" "$rc" 255
# key exchanges again and again: OpenSSH rekeys every 16 KB, here
out=$(ssh $o -i "$d/_k/id" -o BatchMode=yes -o RekeyLimit=16K test@127.0.0.1 big 2>&1 | md5sum | cut -c1-32)
want=$(python3 -c 'import sys; sys.stdout.write("".join("%1023d\n" % i for i in range(1024)))' | md5sum | cut -c1-32)
check "OpenSSH rekeying every 16 KB, 1 MB out" "$out" "$want"
out=$(head -c 300000 /dev/zero | ssh $o -i "$d/_k/id" -o BatchMode=yes -o RekeyLimit=16K test@127.0.0.1 2>&1 | tr -d '\r' | head -1)
check "OpenSSH rekeying every 16 KB, 300 KB in" "$out" "no pty"
# the password, through SSH_ASKPASS
printf '#!/bin/sh\necho secret\n' > "$d/_k/askpass"; chmod +x "$d/_k/askpass"
out=$(SSH_ASKPASS="$d/_k/askpass" SSH_ASKPASS_REQUIRE=force ssh $o -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 test@127.0.0.1 'pw' 2>&1 </dev/null) || true
check "OpenSSH, password" "$out" "ran: pw"
# a key file of ours, read by OpenSSH's ssh-keygen
out=$(ssh-keygen -y -f "$d/_k/ours" 2>&1 | cut -d' ' -f1-2)
check "ssh-keygen reads our key file" "$out" "$(cut -d' ' -f1-2 "$d/_k/ours.pub")"
# a shell with a terminal: script(1) gives ssh one
if command -v script >/dev/null; then
    out=$( (sleep 2; printf 'xy'; sleep 1; printf 'q') | script -qec "ssh $(echo $o) -tt -i $d/_k/id test@127.0.0.1" /dev/null 2>&1 | tr -d '\r') || true
    case $out in *"pty "*"XY"*bye*) check "OpenSSH, shell with a terminal" ok ok ;;
                 *) check "OpenSSH, shell with a terminal" "$out" "pty ...XY...bye" ;; esac
fi
echo "--- server"; cat "$d/_k/server.log"
[ $fails = 0 ]
