#!/bin/sh
# Publish the packages built in tmp/packages (tools/pkg-build.sh) into a
# clone of the packages' repository (ctrl-z-bg/mynos-packages): the new
# index.json, its archives and the packages' documentation. The archives
# the clone's index named until now stay, one generation: GitHub's raw
# files are cached for 5 minutes, and a cached index must still find the
# archives it names (a new archive has a new name: pkg-build.sh puts its
# hash in it). Older ones go. Then commit and push the clone.
#
# Usage: tools/pkg-publish.sh CLONE
set -eu
clone=${1:?usage: tools/pkg-publish.sh CLONE}
cd "$(dirname "$0")/.."
src=tmp/packages
[ -f "$src/index.json" ] || { echo "pkg-publish.sh: no $src/index.json: build first" >&2; exit 1; }
[ -d "$clone/.git" ] || { echo "pkg-publish.sh: $clone is not a clone" >&2; exit 1; }
archives() {   # the archives an index names, one per line
    python3 -c 'import json, sys
for p in json.load(open(sys.argv[1]))["packages"]: print(p["archive"])' "$1"
}
previous=$( [ -f "$clone/index.json" ] && archives "$clone/index.json" || true)
current=$(archives "$src/index.json")
mkdir -p "$clone/packages" "$clone/docs"
cp "$src"/packages/*.tar "$clone/packages/"
kept=0 removed=0
for f in "$clone"/packages/*.tar; do
    a=packages/$(basename "$f")
    if printf '%s\n' "$current" | grep -qxF "$a"; then :
    elif printf '%s\n' "$previous" | grep -qxF "$a"; then kept=$((kept + 1))
    else rm -f "$f"; removed=$((removed + 1))
    fi
done
rm -f "$clone"/docs/*.md
cp "$src"/docs/*.md "$clone/docs/"
cp "$src/index.json" "$clone/index.json"
# every archive the new index names: there, of its size and hash
python3 - "$clone" <<'PY'
import hashlib, json, os, sys
c = sys.argv[1]
for p in json.load(open(os.path.join(c, "index.json")))["packages"]:
    b = open(os.path.join(c, p["archive"]), "rb").read()
    assert len(b) == p["size"], p["name"]
    assert hashlib.blake2b(b, digest_size=32).hexdigest() == p["blake2b-256"], p["name"]
PY
echo "pkg-publish.sh: $(printf '%s\n' "$current" | wc -l) packages; $kept archives of the previous index kept, $removed older ones removed; now commit and push $clone"
