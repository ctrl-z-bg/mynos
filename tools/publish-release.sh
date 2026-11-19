#!/bin/sh
# Publish a release of MyNOS (mynos-sc9, mynos-2a2), from a built,
# committed and pushed tree:
#   1. tools/make-release.sh: tmp/release/mynos-VERSION.tar.gz, .sha256
#   2. tools/make-web.sh: tmp/web, MyNOS in the browser
#   3. a GitHub release, tag vVERSION, with the archive and its checksum,
#      and the notes of tools/release/release-notes.md (@VERSION@ filled in)
#   4. GitHub Pages: tmp/web pushed, alone, to the gh-pages branch
# Needs gh (GitHub's command line), logged in: gh auth login.
#
# Usage: tools/build-all.sh && tools/publish-release.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
command -v gh >/dev/null || { echo "publish-release.sh: gh is needed (GitHub CLI)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "publish-release.sh: gh is not logged in: gh auth login" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "publish-release.sh: commit first" >&2; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "publish-release.sh: push first (HEAD is not origin/main)" >&2; exit 1; }
remote=$(git remote get-url origin)
repo=$(echo "$remote" | sed -e 's|^git@github.com:||' -e 's|^https://github.com/||' -e 's|\.git$||')

tools/make-release.sh
version=$(cat VERSION)
name=mynos-$version
tools/make-web.sh "tmp/release/$name" tmp/web

tag=v$version
notes=tmp/release/release-notes.md
sed -e "s|@VERSION@|$version|g" tools/release/release-notes.md > "$notes"
gh release create "$tag" -R "$repo" --target "$(git rev-parse HEAD)" \
    --title "MyNOS $version" --notes-file "$notes" \
    "tmp/release/$name.tar.gz" "tmp/release/$name.tar.gz.sha256"

# the site: one commit, replacing the branch (its history is not needed)
(
    cd tmp/web
    rm -rf .git
    git init -q -b gh-pages
    git add -A
    git commit -q -m "MyNOS $version, in the browser (tools/make-web.sh)"
    git push -q --force "$remote" gh-pages
    rm -rf .git
)
# GitHub usually enables Pages by itself on the first push of gh-pages
# (then the request answers 409, already enabled)
if ! gh api "repos/$repo/pages" >/dev/null 2>&1; then
    gh api -X POST "repos/$repo/pages" -f "source[branch]=gh-pages" -f "source[path]=/" \
        >/dev/null 2>&1 || true
fi
owner=${repo%%/*}; project=${repo#*/}
echo "publish-release.sh: https://github.com/$repo/releases/tag/$tag"
echo "publish-release.sh: https://$owner.github.io/$project/ (GitHub Pages takes a minute or two)"
