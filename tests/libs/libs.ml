(* OCaml's libraries beyond the standard one (mynos-rld, mynos-yux) and the
   system calls they rely on (mynos-0xy, mynos-469, mynos-0r1). init.byte
   on its RAM disk: it starts tmpfs, then checks Str, Num, the CPU time,
   the user id, and O_EXCL on /tmp. *)

let check what ok =
  Printf.printf "libs: %-44s %s\n%!" what (if ok then "ok" else "FAIL");
  ok

let fails f = match f () with _ -> false | exception (Sys_error _ | Unix.Unix_error _) -> true

let rec wait_for path tries =
  if Sys.file_exists path || tries = 0 then ()
  else (Mynos.sleep 0.1; wait_for path (tries - 1))

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in
  ignore (Mynos.spawn "ocamlrun" [| "ocamlrun"; "tmpfs.byte" |]);
  wait_for "/tmp" 100;
  (* Str *)
  ok &&& check "Str: global_replace"
    (Str.global_replace (Str.regexp "[0-9]+") "N" "a1b22c333" = "aNbNcN");
  ok &&& check "Str: groups"
    (Str.string_match (Str.regexp "\\([a-z]+\\)@\\([a-z]+\\)") "joe@host" 0
     && Str.matched_group 2 "joe@host" = "host");
  ok &&& check "Str: split" (Str.split (Str.regexp " *, *") "x , y,z" = [ "x"; "y"; "z" ]);
  (* Num *)
  let open Num in
  ok &&& check "Num: 2^200"
    (string_of_num (power_num (Int 2) (Int 200))
     = "1606938044258990275541962092341162602522202993782792835301376");
  let rec fact n = if n = 0 then Int 1 else mult_num (Int n) (fact (n - 1)) in
  ok &&& check "Num: 50!"
    (string_of_num (fact 50)
     = "30414093201713378043612608166064768844377641568960512000000000000");
  ok &&& check "Num: 1/3 + 1/6 = 1/2"
    (string_of_num (add_num (div_num (Int 1) (Int 3)) (div_num (Int 1) (Int 6))) = "1/2");
  ok &&& check "Big_int: gcd"
    (Big_int.(string_of_big_int
                (gcd_big_int (big_int_of_string "123456789012345678901234567890")
                   (big_int_of_string "987654321098765432109876543210")))
     = "9000000000900000000090");
  ok &&& check "Num: through Marshal"
    (let v = power_num (Int 3) (Int 100) in
     eq_num (Marshal.from_string (Marshal.to_string v []) 0) v);
  (* the CPU time: getrusage, times *)
  let t0 = Sys.time () in
  let x = ref 0 in
  for i = 1 to 3_000_000 do x := !x + (i land 7) done;
  let t1 = Sys.time () in
  ok &&& check "Sys.time: small, and it grows" (t0 >= 0. && t0 < 1000. && t1 > t0);
  ok &&& check "Unix.times" ((Unix.times ()).Unix.tms_utime > 0.);
  ok &&& check "Unix.getuid, geteuid, getgid are 0"
    (Unix.getuid () = 0 && Unix.geteuid () = 0 && Unix.getgid () = 0);
  (* O_EXCL *)
  Out_channel.with_open_bin "/tmp/here" (fun oc -> output_string oc "x");
  ok &&& check "O_EXCL: an existing file is not created again"
    (fails (fun () -> Unix.openfile "/tmp/here" [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o644));
  ok &&& check "O_EXCL: a new file is"
    (let fd = Unix.openfile "/tmp/new" [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o644 in
     Unix.close fd; Sys.file_exists "/tmp/new");
  ok &&& check "Filename.temp_file: two different files"
    (let a = Filename.temp_file "t" "" and b = Filename.temp_file "t" "" in a <> b);
  print_endline (if !ok then "libs: all checks passed" else "libs: FAIL")
