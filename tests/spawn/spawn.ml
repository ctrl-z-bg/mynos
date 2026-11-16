(* Starting programs from OCaml: init.byte, loaded by ocamlrun from the RAM
   disk, starts child.byte through ocamlrun (also on the RAM disk) with
   Mynos.spawn and collects the exit status with Mynos.wait. *)

let check what ok =
  Printf.printf "spawn: %-36s %s (free pages %d)\n%!" what
    (if ok then "ok" else "FAIL") (Mynos.stats ()).Mynos.free_pages;
  ok

let run args = Mynos.spawn "ocamlrun" (Array.append [| "ocamlrun"; "child.byte" |] args)

let fails f = match f () with _ -> false | exception Mynos.Error _ -> true

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in
  let pid = run [| "hello"; "world" |] in
  ok &&& check "spawn returns a new pid" (pid > Mynos.getpid ());
  ok &&& check "child exit code 3" (Mynos.wait pid = Mynos.Exited 3);
  let a = run [| "5" |] in
  let b = run [| "7" |] in
  let r1 = Mynos.wait_any () and r2 = Mynos.wait_any () in
  ok &&& check "wait_any collects both children"
    (List.sort compare [ r1; r2 ]
     = List.sort compare [ (a, Mynos.Exited 5); (b, Mynos.Exited 7) ]);
  ok &&& check "wait with no children left fails"
    (fails (fun () -> Mynos.wait_any ()));
  ok &&& check "spawn of a missing file fails"
    (fails (fun () -> Mynos.spawn "nothing" [| "nothing" |]));
  ok &&& check "spawn of a non-ELF file fails"
    (fails (fun () -> Mynos.spawn "child.byte" [| "child.byte" |]));
  let c = run [| "crash" |] in
  ok &&& check "an uncaught exception: exit code 2"
    (Mynos.wait c = Mynos.Exited 2);
  (* processes give their memory back when they end (mynos-pg6). First
     let this program touch all of its minor heap (1 MB, whose pages are
     allocated on first use), so that only the children count. *)
  let free () = (Mynos.stats ()).Mynos.free_pages in
  for _ = 1 to 400_000 do ignore (Sys.opaque_identity (ref 0)) done;
  let before = free () in
  for _ = 1 to 20 do ignore (Mynos.wait (run [| "0" |])) done;
  let after = free () in
  Printf.printf "spawn: 20 runs, free pages %d -> %d\n%!" before after;
  ok &&& check "20 runs give their memory back" (before - after <= 4);
  print_endline (if !ok then "spawn: all checks passed" else "spawn: FAIL")
