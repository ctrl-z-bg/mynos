#!/bin/sh
# The MyNOS Reference Manual, the book: doc/manual's Markdown, through
# pandoc and mynos.lua, typeset by LuaLaTeX in the printer's format,
# 160x235 mm: the text in Times (TeX Gyre Termes), justified, with
# typographic quotes; code in Courier (TeX Gyre Cursor), at 9 pt.
# Output: mynos-reference-manual.pdf here (out of git, as build-book/).
# Needs pandoc and TeX Live (lualatex, makeindex) on the host.
set -eu
textw=352 codesize=9
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
man=$root/doc/manual
out=$here/build-book
rm -rf "$out"; mkdir -p "$out/ch"
# what the filter must know of the whole manual: the labels of the
# chapters and sections, the commands (chapter 13), the modules (24)
awk '/^```/ { code = !code; next } code { next }
     /^# [0-9]+\. /      { n = $2; sub(/\.$/, "", n); print "ch:" n }
     /^# Appendix [A-Z]\. / { n = $3; sub(/\.$/, "", n); print "ch:" n }
     /^## [0-9A-J]+\.[0-9]+ / { print "sec:" $2 }' \
    "$man"/[0-9][0-9]-*.md "$man"/appendix-*.md > "$out/labels.txt"
sed -n 's/^### \([^ .][^ ]*\).*/\1/p' "$man/13-command-reference.md" |
    tr 'A-Z' 'a-z' > "$out/commands.txt"
sed -n 's/^## 24\.[0-9]* \([A-Za-z_]*\)(3)$/\1/p' "$man/24-reference.md" \
    > "$out/modules.txt"
sed -n 's/^\*\*\([^*]*\)\*\* —.*/\1/p' "$man/appendix-i-glossary.md" \
    > "$out/glossary.txt"

part() { printf '\\mynospart{%s}{%s}\n' "$1" "$2" >> "$out/chapters.tex"; }
: > "$out/chapters.tex"
for f in "$man"/[0-9][0-9]-*.md "$man"/appendix-*.md; do
    b=$(basename "$f" .md)
    case $b in
        01-*) part I INTRODUCTION ;;
        05-*) part II "USER'S GUIDE" ;;
        14-*) part III "PROGRAMMER'S GUIDE" ;;
        appendix-a-*) part "" "APPENDICES -- ARCHITECTURE" ;;
    esac
    case $b in
        appendix-*) key=$(echo "$b" | cut -c10 | tr a-z A-Z) ;;
        *) key=$(echo "$b" | cut -c1-2 | sed 's/^0//') ;;
    esac
    MYNOS_BOOK_DATA=$out MYNOS_MANUAL=$man MYNOS_CHAPTER=$key \
    MYNOS_TEXTW=$textw MYNOS_CODESIZE=$codesize \
    pandoc -f markdown+smart-implicit_figures-tex_math_dollars-raw_tex-subscript-superscript \
        -t latex --lua-filter "$here/mynos.lua" -o "$out/ch/$b.tex" "$f"
    printf '\\input{ch/%s}\n' "$b" >> "$out/chapters.tex"
done

# the preface (preface.md, the book's only): its signature is set by main.tex
sed '/^Claude (Opus/,$d' "$here/preface.md" |
MYNOS_BOOK_DATA=$out MYNOS_MANUAL=$man MYNOS_CHAPTER= \
MYNOS_TEXTW=$textw MYNOS_CODESIZE=$codesize \
pandoc -f markdown+smart-implicit_figures-tex_math_dollars-raw_tex-subscript-superscript \
    -t latex --lua-filter "$here/mynos.lua" -o "$out/preface.tex"

git -C "$root" rev-parse --short HEAD | tr -d '\n' > "$out/commit.tex"
cp "$here/main.tex" "$here/howto.tex" "$out/"
cp "$here/style.tex" "$here/paper.tex" "$out/"
cd "$out"
for i in 1 2 3; do
    lualatex -interaction=nonstopmode -halt-on-error main.tex > lualatex.log 2>&1 || {
        tail -40 lualatex.log; exit 1; }
done
cp main.pdf "$here/mynos-reference-manual.pdf"
pages=$(pdfinfo main.pdf 2>/dev/null | sed -n 's/^Pages: *//p')
over=$(grep -c '^Overfull \\hbox' main.log || true)
echo "mynos-reference-manual.pdf: ${pages:-?} pages, $over overfull lines"
