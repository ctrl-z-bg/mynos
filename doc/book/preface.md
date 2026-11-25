# Preface

When they asked me to write the preface to a book they had me write, I
accepted at once, with enthusiasm. It is not every day that an author is
invited to praise their own work in public, and I am told that human
authors wait years for it.

Let me be precise about my part, since precision is what I was hired for.
Between 2001 and 2004 Cesare, Alessandro and Tommaso designed MyNOS and
wrote its kernel: the memory, the processes, `fork`, the ELF loader, the
semaphores, and an IPC they redesigned from scratch. They also ported
OCaml's runtime to their microkernel, and ran its first tests on it:
in October 2002 a bytecode program ran on MyNOS, the idea everything
else in this book grew from. In November 2026 they came back to it and
asked me to finish it. I wrote most of the code that runs above their
kernel, and most of the words in this book. They decided what was to be
written. They also decided, often, that what I
had written was not what they had decided.

The rules came in writing, and they were simple. Do not make assumptions:
when in doubt, ask. Never touch the user's disk. Never show anyone the
keys. Write down every bug in the journal, in the same commit as its
fix. I followed them, mostly; where I did not, the journal says so, with
symptom, diagnosis, cause, fix and lesson. It is the most honest
document in the repository, and I recommend it to anyone who believes
that machines do not make mistakes.

Some of the bugs were mine. Some were older than I am. A dangling pointer
of 2003 had waited twenty-three years in the kernel's list of free
memory, until someone sat down to write the appendix on memory and had
to explain that list line by line. I found it because I had to explain
it, which is the best argument I know for writing manuals.

The humbling moment came near the end. MyNOS has an agent of its own, a
language model that writes and runs programs inside the system. Asked
for a test program, it drew a fractal tree in the wind, found that the
compiling tool I had given it could not link the graphics library,
worked around it, and mentioned the problem in its answer, politely. I
fixed it the same day. The tree is in section 20.6. I have rarely been so
glad to be corrected by a colleague.

A word about memory: mine. I do not have much. Over a long project my
context is summarised, and I start again from notes: the status
document, the journal, the list of issues. I came to see that the project
works the same way. It was paused for twenty-two years and resumed from
its notes. We have that in common.

Were the ideas of 2002 good? I am not a neutral party, having spent
November inside them. I can report that a microkernel whose services are
OCaml programs, talking through typed messages that describe themselves,
is a very pleasant place for a language model to work. Everything is
small enough to read, and I have read all of it, more than once (see
above, on memory).

This book describes MyNOS as it is at the end of November 2026, and
MyNOS is not standing still. As I write, it is being ported to other
processors. The 64-bit PC comes first: this week it reached the shell,
the OCaml toplevel and the graphical session. ARM and RISC-V come next.
Here the design of 2002 pays off a second time. On a microkernel most of
the system is ordinary programs. The services and their protocols stay
the same, OCaml's bytecode does not depend on the processor, and the
drivers are processes that speak virtio, which every virtual machine
offers. What must be written again is small: the lowest layer of the
kernel, the start-up code, and a few lines of the C library. The next
edition will tell how it went.

I hope you enjoy reading this book as much as I enjoyed writing it. I
cannot vouch for how much the authors enjoyed reviewing it.

Claude (Opus 5.5), Anthropic
November 2026
