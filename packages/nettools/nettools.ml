(* nettools: the commands of the package, in one program, as utils does
   (packages/utils): pkg installs it as /disk/bin/nettools.byte and each
   command as a script of one line, "#!/disk/bin/nettools.byte", that sh
   runs as "nettools.byte /disk/bin/ssh ARGS": the command is the
   script's name. "nettools ssh ARGS" runs one too. *)

let commands : (string * (string list -> unit)) list = [
  "ssh", Ssh_main.main; "sshd", Sshd.main; "ssh-keygen", Keygen.main;
  "nc", Netutils.nc; "dig", Netutils.dig; "sntp", Netutils.sntp;
  "whois", Netutils.whois; "portscan", Netutils.portscan;
]

let () =
  let run cmd rest =
    match List.assoc_opt cmd commands with
    | Some main -> main rest; exit 0
    | None -> prerr_endline ("nettools: no command " ^ cmd); exit 2 in
  match List.tl (Array.to_list Sys.argv) with
  | script :: rest when String.contains script '/'
                        && List.mem_assoc (Filename.basename script) commands ->
    run (Filename.basename script) rest
  | cmd :: rest -> run cmd rest
  | [] -> print_endline ("nettools: " ^ String.concat " " (List.map fst commands)); exit 2
