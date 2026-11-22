# MyNOS Studio's pictures (tools/pkg-shots.sh studio): its README's.
# Studio opens on three example files (shots/), its window at (20, 52).
AGENT=1

terminal 'studio /disk/studio/shapes.ml /disk/studio/counter.ml /disk/studio/notes.ml &'; sleep 20

# an error: Build, the mistake underlined, Problems, the cursor on it
click 211 90; sleep 15
click 164 583; sleep 2
click 126 251; sleep 2
to 700 450; sleep 1
shot build-error

# completion: from Gui's interface, then from Sound's and the running
# sound service
key end; key ret; keys 'Gui.'; sleep 12
shot complete-interface
key esc; for i in 1 2 3 4; do key backspace; done; keys 'Sound.t'; sleep 5
shot complete-service
key esc; for i in 1 2 3 4 5 6 7; do key backspace; done; sleep 1

# Run: counter.ml, its window over Studio, three clicks
click 190 119; sleep 2
click 265 90; sleep 20
click 258 264; sleep 1; click 258 264; sleep 1; click 258 264; sleep 1
to 600 450; sleep 1
shot run

# Watch: notes.ml under the event recorder, whom it talked to
click 290 119; sleep 2
click 319 90; sleep 30
click 258 583; sleep 2
shot watch

# a service of one's own: New service (its name: hello), Run as service,
# the Services window
click 465 90; sleep 2
for i in 1 2 3 4 5 6 7 8 9; do key backspace; done; keys 'hello\n'; sleep 3
click 581 90; sleep 25
click 685 90; sleep 10
click 232 374; sleep 3
click 400 251; sleep 3
click 754 296; keys 'MyNOS'; click 621 332; sleep 3
to 800 600; sleep 1
shot service
click 946 198; sleep 2

# the agent (with a language model: llm.env): asked to fix shapes.ml,
# it reads it through Studio's ide/1 and proposes a change, shown as
# lines removed and added, waiting for Allow
if [ -f llm.env ]; then
    click 75 119; sleep 2
    click 870 676; keys 'Fix the error in shapes.ml'; click 971 706; sleep 90
    to 600 450; sleep 1
    shot agent
fi
