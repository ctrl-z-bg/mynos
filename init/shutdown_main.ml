(* shutdown: turn the machine off (init does it: module Power).

     shutdown        turn it off
     shutdown -r     restart it *)

let () =
  match Array.to_list Sys.argv with
  | [ _ ] -> Power.shutdown ()
  | [ _; "-r" ] -> Power.reboot ()
  | _ -> prerr_endline "usage: shutdown [-r]"; exit 2
