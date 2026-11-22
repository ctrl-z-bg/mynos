# GAV's pictures, for MyNOS

From GAV, GPL Arcade Volleyball (https://github.com/ctrl-z-bg/gav,
commit 17b90605391fa6f8104a05417716504b9c8b81b4, 2022-04-26), GPL-2.0
(LICENSE): its "classic" theme, `themes/classic/`.

- `background.png`, `ball.png`, `plml.png`, `plmr.png`: as they are.
- `font.png`: `Font.png`, an RGBA picture, laid on black and written as
  RGB (black is GAV's transparent colour; MyNOS's PNG reader lays alpha
  on white).

The game itself was rewritten in OCaml: `packages/gav/gav.ml`.
