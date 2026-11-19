#!/bin/sh
# MyNOS's version: the year and month of the build, and the commit it is
# built from (2026.11-71dc1d2). tools/build-all.sh writes it to VERSION,
# the one source the build reads (the kernel's banner and uname, ...).
cd "$(dirname "$0")/.."
hash=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
echo "$(date +%Y.%m)-$hash"
