(* utils: the commands of the package, in one program (each would weigh
   as much as all of them: most of a program is OCaml's library). pkg
   installs it as /disk/bin/utils.byte, and each command as a script of
   one line, "#!/disk/bin/utils.byte", that sh runs as
   "utils.byte /disk/bin/grep ARGS": the command is the script's name.
   "utils grep ARGS" runs one too. *)

let commands : (string * (unit -> unit)) list = [
  "grep", Grep.main; "wc", Wc.main; "head", Head.main; "tail", Tail.main;
  "sort", Sort.main; "uniq", Uniq.main; "find", Find.main; "du", Du.main;
  "hexdump", Hexdump.main; "tree", Tree.main; "df", Df.main; "clip", Clip.main;
]

let () =
  let run cmd rest =
    match List.assoc_opt cmd commands with
    | Some main -> Util.args := rest; main (); Util.finish ()
    | None -> prerr_endline ("utils: no command " ^ cmd); exit 2 in
  match List.tl (Array.to_list Sys.argv) with
  | script :: rest when String.contains script '/'
                        && List.mem_assoc (Filename.basename script) commands ->
    run (Filename.basename script) rest
  | cmd :: rest -> run cmd rest
  | [] ->
    print_endline ("utils: " ^ String.concat " " (List.map fst commands));
    exit 2
