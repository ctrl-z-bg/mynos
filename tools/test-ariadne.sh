#!/bin/sh
# Ariadne's core checked on the host (ariadne/tests/run_tests.ml): the test
# pages against their expected text, URLs, a deep tree. Seconds, against
# minutes for tools/run-tests.sh, which runs the same checks in MyNOS.
# In the dev container if there is one (the i386 build's tree), else in the
# x86-64 build's (tools/build-x86_64.sh: new files must be known to git).
# Usage: tools/test-ariadne.sh [make target: test (default), expected]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
target=${1:-test}
if podman image exists mynos-dev 2>/dev/null; then
    exec "$root/tools/in-container.sh" dev make -C ariadne "$target"
else
    exec "$root/tools/build-x86_64.sh" "make -C ariadne $target"
fi
