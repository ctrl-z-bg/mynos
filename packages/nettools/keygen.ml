(* ssh-keygen: Ed25519 keys in OpenSSH's format.

     ssh-keygen [-f FILE] [-C COMMENT]   a new key (default /disk/ssh/id_ed25519)
     ssh-keygen -y [-f FILE]             the public line of a private key
     ssh-keygen -l [-f FILE]             a key's fingerprint
     ssh-keygen --selftest [-v]          the cryptography against known vectors *)

let main args =
  let file = ref (Filename.concat Net_io.ssh_dir "id_ed25519") and comment = ref "user@mynos" in
  let mode = ref `New and timings = ref false in
  let rec opts = function
    | "-f" :: f :: rest -> file := f; opts rest
    | "-C" :: c :: rest -> comment := c; opts rest
    | "-y" :: rest -> mode := `Public; opts rest
    | "-l" :: rest -> mode := `Fingerprint; opts rest
    | "--selftest" :: rest -> mode := `Selftest; opts rest
    | "-v" :: rest -> timings := true; opts rest
    | "-t" :: "ed25519" :: rest -> opts rest
    | [] -> ()
    | _ -> prerr_endline "usage: ssh-keygen [-f FILE] [-C COMMENT] | -y [-f FILE] | -l [-f FILE] | --selftest [-v]";
      exit 2 in
  opts args;
  let load f = match Ssh_keys.of_file (Net_io.read_file f) with
    | Ok k -> k
    | Error e -> prerr_endline ("ssh-keygen: " ^ f ^ ": " ^ e); exit 1
    | exception Sys_error e -> prerr_endline ("ssh-keygen: " ^ e); exit 1 in
  match !mode with
  | `Selftest -> if not (Selftest.run ~now:Mynos.uptime ~timings:!timings) then exit 1
  | `Public -> print_endline (Ssh_keys.pub_line (load !file))
  | `Fingerprint ->
    let pub = match Ssh_keys.pub_of_line (try Net_io.read_file !file with Sys_error _ -> "") with
      | Some p -> p
      | None -> (load !file).pub in
    print_endline ("256 " ^ Ssh_keys.fingerprint pub ^ " " ^ !file ^ " (ED25519)")
  | `New ->
    if Sys.file_exists !file then (prerr_endline ("ssh-keygen: " ^ !file ^ " is there already"); exit 1);
    if !file = Filename.concat Net_io.ssh_dir "id_ed25519" then Net_io.ensure_dir ();
    let k = Ssh_keys.generate ~comment:!comment in
    Net_io.write_file !file (Ssh_keys.to_file k);
    Net_io.write_file ~perm:0o644 (!file ^ ".pub") (Ssh_keys.pub_line k ^ "\n");
    Printf.printf "Your key: %s\nIts public line: %s.pub\nFingerprint: %s %s\n" !file !file
      (Ssh_keys.fingerprint k.pub) !comment;
    print_endline (Ssh_keys.pub_line k)
