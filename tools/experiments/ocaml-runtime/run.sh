#!/bin/sh
# Reproduce the OCaml runtime evaluation (doc/decisions/ocaml-runtime.md):
# build OCaml 4.14.5 and 5.5.2 in the dev container, link their bytecode
# runtimes with musl for MyNOS, and run test programs on the MyNOS kernel.
#
# Usage: tools/experiments/ocaml-runtime/run.sh [workdir]
# Needs: the dev image, a built kernel (tools/build-all.sh), network.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
work=${1:-$root/build/ocaml-runtime}
mkdir -p "$work"
cp "$here"/*.ml "$here"/mynos_main.c "$work"/

for v in 4.14.5 5.5.2; do
  [ -f "$work/ocaml-$v.tar.gz" ] || \
    curl -fsSL -o "$work/ocaml-$v.tar.gz" \
      "https://github.com/ocaml/ocaml/archive/refs/tags/$v.tar.gz"
  podman run --rm --platform linux/386 -v "$work:/work:Z" mynos-dev sh -euc "
    apt-get update >/dev/null 2>&1
    apt-get install -y --no-install-recommends musl-tools musl-dev >/dev/null 2>&1
    mkdir -p /tmp/src && tar xzf /work/ocaml-$v.tar.gz -C /tmp/src --strip-components=1
    cd /tmp/src
    # 1. host compiler (glibc), to compile the test programs
    cp -a /tmp/src /tmp/host && cd /tmp/host
    ./configure --prefix=/tmp/inst --disable-native-compiler --disable-ocamldoc \
      --disable-ocamltest >/dev/null
    make -j4 >/dev/null && make install >/dev/null
    cd /work
    for t in hello effects domain; do
      /tmp/inst/bin/ocamlc -o \$t-$v.byte \$t.ml 2>/dev/null || true
    done
    # 2. the bytecode runtime, static with musl, linked at 0x40000000
    cd /tmp/src
    ./configure --build=i686-pc-linux-gnu --host=i686-pc-linux-gnu CC=musl-gcc \
      LDFLAGS=-static --disable-shared --disable-native-compiler \
      --disable-ocamldoc --disable-ocamltest --disable-debug-runtime \
      --disable-instrumented-runtime >/dev/null
    if grep -q '^ocamlrun' runtime/Makefile; then make -C runtime ocamlrun; \
      else make -j4 runtime/ocamlrun; fi >/dev/null
    cd runtime
    musl-gcc -c -o mynos_main.o /work/mynos_main.c
    LIBS=-lm; grep -q lpthread ../Makefile.config && LIBS='-lm -lpthread'
    musl-gcc -static -Wl,-Ttext-segment=0x40000000 -Wl,-z,noseparate-code \
      -Wl,--build-id=none -o /work/ocamlrun-$v mynos_main.o prims.o \
      libcamlrun.a \$LIBS
  "
  for t in hello effects domain; do
    [ -f "$work/$t-$v.byte" ] || continue
    echo "=== OCaml $v: $t"
    timeout 20 "$root/tools/run-qemu.sh" "$work/ocamlrun-$v" "$work/$t-$v.byte" \
      -- -display none -serial null -serial "file:$work/$t-$v.log" \
      >/dev/null 2>&1 || true
    sed -n '/-----------/,$p' "$work/$t-$v.log" | tail -n +2
  done
done
