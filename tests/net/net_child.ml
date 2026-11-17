(* A second process for the network test (net_test.ml): sockets belong to
   their process (doc/decisions/identity-and-permissions.md).

     net_child.byte close N     Close another process's socket N: exit 0 if
                                netd refuses ("not your socket")
     net_child.byte listen P    Listen on port P, then end without closing:
                                netd must close it *)

let () =
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
