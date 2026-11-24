(* A second process for the network test (net_test.ml): sockets belong to
   their process (doc/decisions/identity-and-permissions.md).

     net_child.byte close N     Close another process's socket N: exit 0 if
                                netd refuses ("not your socket")
     net_child.byte listen P    Listen on port P, then end without closing:
                                netd must close it
     net_child.byte unix        A line to the host's 47001 through OCaml's
                                Unix sockets (libmynos's, mynos-t9l): exit
                                0 if it comes back in capitals *)

let unix_sockets () =
  let ai = List.hd (Unix.getaddrinfo "10.0.2.2" "47001"
                      [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]) in
  let s = Unix.socket ai.Unix.ai_family ai.ai_socktype 0 in
  Unix.connect s ai.ai_addr;
  let line = "hello unix\n" in
  ignore (Unix.write_substring s line 0 (String.length line));
  let buf = Bytes.create 64 in
  let rec read_all acc =
    match Unix.read s buf 0 64 with
    | 0 -> acc
    | k -> read_all (acc ^ Bytes.sub_string buf 0 k) in
  let answer = read_all "" in
  Unix.close s;
  print_string ("net: Unix sockets: the host says: " ^ answer);
  exit (if answer = "HELLO UNIX\n" then 0 else 1)

let () =
  if Array.length Sys.argv = 2 && Sys.argv.(1) = "unix" then
    (try unix_sockets ()
     with e -> print_endline ("net: " ^ Printexc.to_string e); exit 2);
  let n = Net.connect () in
  match Sys.argv with
  | [| _; "close"; s |] ->
    (match Net.call n (Net.Close (int_of_string s)) with
     | () -> exit 1
     | exception Ipc.Remote_error (_, "not your socket") -> exit 0
     | exception _ -> exit 2)
  | [| _; "listen"; p |] ->
    ignore (Net.call n (Net.Listen (int_of_string p)));
    exit 0
  | _ -> exit 3
