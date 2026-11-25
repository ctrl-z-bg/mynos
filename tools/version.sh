#!/bin/sh
# MyNOS's version, from git:
#   1.0                     built from the commit tagged v1.0
#   1.0+3-a1b2c3d           3 commits after v1.0, on main
#   1.0+14-x86-64-591c1f4   on another branch: its name too
#   ...-dirty               with changes not committed yet
# (a tree with no version tag behind it: the build's year and month,
# 2026.11-a1b2c3d). tools/build-all.sh writes it to VERSION, the one
# source the build reads (the kernel's banner and uname, ...).
cd "$(dirname "$0")/.."
set -f          # the patterns below are git's, not the shell's
hash=$(git rev-parse --short HEAD 2>/dev/null) || { echo unknown; exit 0; }
# the version tags: v1.0, v2.0... (not v1.0-book and the like)
tags="--tags --match v[0-9]* --exclude v*-*"
dirty=
[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=-dirty
if tag=$(git describe $tags --exact-match 2>/dev/null); then
    echo "${tag#v}$dirty"
    exit 0
fi
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')
case $branch in main|HEAD|"") at= ;; *) at=$branch- ;; esac
if long=$(git describe $tags --long 2>/dev/null); then
    # v1.0-14-g591c1f4
    n=${long%-g*}; n=${n##*-}; tag=${long%-*-g*}
    echo "${tag#v}+$n-$at$hash$dirty"
else
    echo "$(date +%Y.%m)-$at$hash$dirty"
fi
