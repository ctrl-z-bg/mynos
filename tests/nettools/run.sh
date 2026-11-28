#!/bin/sh
# nettools' modules on the host, in the dev container, as bytecode:
# tests/nettools/cryptotest.ml (vectors of OpenSSL's and the RFCs') and
# sshtest.ml (the SSH client against the server, over a pair of sockets;
# a key file of the host's ssh-keygen, if there is one); it builds
# hostsshd.byte for interop.sh. Num's C is
# built in (-custom). The container is i386's (linux/386): ints of 31
# bits, as in MyNOS, where the same vectors are `ssh-keygen --selftest`.
#   tests/nettools/run.sh [--time]
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
k=$root/tests/nettools/_k
rm -rf "$k"; mkdir -p "$k"
if command -v ssh-keygen >/dev/null; then
    ssh-keygen -q -t ed25519 -N "" -C test@openssh -f "$k/id" </dev/null
fi
exec "$root/tools/in-container.sh" dev sh -euc '
cd tests/nettools
rm -rf _t && mkdir _t
n=../../third_party/num
p=../../packages/nettools
cp $n/int_misc.mli $n/int_misc.ml $n/nat.mli $n/nat.ml $n/big_int.mli $n/big_int.ml \
   $n/nat_stubs.c $n/bng.c $n/bng.h $n/bng_digit.c $n/nat.h \
   $p/sha2.ml $p/chacha20.ml $p/poly1305.ml $p/curve25519.ml \
   $p/ssh_wire.ml $p/selftest.ml $p/ssh_keys.ml $p/ssh_transport.ml $p/ssh_chan.ml $p/ssh_server.ml $p/ssh_client.ml \
   cryptotest.ml sshtest.ml hostsshd.ml _t/
cd _t
NUM="nat_stubs.c bng.c int_misc.mli int_misc.ml nat.mli nat.ml big_int.mli big_int.ml"
CRYPTO="sha2.ml chacha20.ml poly1305.ml curve25519.ml"
ocamlc -w -a -custom -I +unix unix.cma $NUM $CRYPTO ssh_wire.ml selftest.ml cryptotest.ml -o cryptotest.byte
ocamlc -w +a-4-9-40-41-42-44-45-70 -custom -I +unix -I +threads unix.cma threads.cma $NUM $CRYPTO \
  ssh_wire.ml ssh_keys.ml ssh_transport.ml ssh_chan.ml ssh_server.ml ssh_client.ml sshtest.ml -o sshtest.byte
ocamlc -w -a -custom -I +unix -I +threads unix.cma threads.cma $NUM $CRYPTO \
  ssh_wire.ml ssh_keys.ml ssh_transport.ml ssh_chan.ml ssh_server.ml ssh_client.ml hostsshd.ml -o hostsshd.byte
./cryptotest.byte "$@"
if [ -f ../_k/id ]; then ./sshtest.byte ../_k/id ../_k/id.pub; else ./sshtest.byte; fi
' sh "$@"
