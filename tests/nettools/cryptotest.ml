(* nettools' cryptography on the host: packages/nettools/selftest.ml's
   vectors (the same as `ssh-keygen --selftest` in MyNOS);
   tests/nettools/run.sh [--time] *)

let () =
  if not (Selftest.run ~now:Unix.gettimeofday ~timings:(Array.length Sys.argv > 1)) then exit 1
