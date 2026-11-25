#!/bin/sh
# The test suite of every architecture at once: i386 in the sources,
# x86_64 in build/x86_64/tree (tools/build-x86_64.sh), each in a test
# container (tools/containers/test) with a network of its own, so that
# their host ports do not meet. Build both first (tools/build-all.sh,
# tools/build-x86_64.sh). Each suite's output goes to tmp/tests-ARCH.log;
# a summary is printed at the end; exit status 0 if all passed.
#
# Usage: tools/run-tests-all.sh [ARCH...]     (default: i386 x86_64)
# Environment: LANES, WAIT as for tools/run-tests.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
[ $# -gt 0 ] || set -- i386 x86_64

# the 64-bit tree gets the scripts as they are now (the tracked files of
# tools/), not a new VERSION: its build keeps the one it was built with
case " $* " in *" x86_64 "*)
    git ls-files -z tools | rsync -a --from0 --files-from=- ./ build/x86_64/tree/ ;;
esac

suite() {   # ARCH
    case $1 in
        i386) dir=$root ;;
        x86_64) dir=$root/build/x86_64/tree ;;
        *) echo "run-tests-all.sh: no architecture $1" >&2; return 2 ;;
    esac
    podman run --rm --platform linux/amd64 -v "$dir:/mynos:Z" -w /mynos \
        -e ARCH="$1" ${LANES:+-e LANES="$LANES"} ${WAIT:+-e WAIT="$WAIT"} \
        mynos-test tools/run-tests.sh > "tmp/tests-$1.log" 2>&1
}

start=$(date +%s)
pids=
for a in "$@"; do suite "$a" & pids="$pids $a:$!"; done
fail=0
for p in $pids; do
    a=${p%%:*}
    if wait "${p#*:}"; then status=passed; else status=FAILED; fail=1; fi
    log=tmp/tests-$a.log
    printf '%-7s %s: %s checks ok, %s failed; the longest lane %s s (%s)\n' "$a" "$status" \
        "$(grep -ac '^ok' "$log")" "$(grep -ac '^FAIL' "$log")" \
        "$(sed -n 's/^time  [a-z] (lane) *\([0-9]*\) s$/\1/p' "$log" | sort -n | tail -1)" "$log"
    grep -a '^FAIL' "$log" | head -20 | sed "s/^/  $a: /"
done
echo "run-tests-all.sh: $(($(date +%s) - start)) s in all"
exit $fail
