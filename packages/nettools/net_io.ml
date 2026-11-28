(* MyNOS's network (Net, netd) for the commands: names resolved, a TCP
   connection as the bytes SSH's transport reads and writes. *)

let net = lazy (Net.connect ())
let call r = Net.call (Lazy.force net) r

let error = function
  | Ipc.Remote_error (_, m) -> m
  | Mynos.Error (f, c) -> f ^ ": " ^ Mynos.error_name c
  | e -> Printexc.to_string e

let is_address s =
  match List.map int_of_string_opt (String.split_on_char '.' s) with
  | [ Some a; Some b; Some c; Some d ] -> List.for_all (fun x -> x >= 0 && x < 256) [ a; b; c; d ]
  | _ -> false

let resolve host = if is_address host then host else call (Net.Resolve host)

let connect host port = call (Net.Connect (resolve host, port))

(* a socket's bytes: reads by one connection to netd, writes by another
   (a Recv that waits does not hold the writers back) *)
let io sock =
  let r = Net.connect () and w = Net.connect () in
  { Ssh_transport.read = (fun () -> try Net.call r (Net.Recv (sock, 16384)) with _ -> "");
    write = (fun s ->
        let n = String.length s in
        let rec go o =
          if o < n then begin
            let k = min 16384 (n - o) in
            (try ignore (Net.call w (Net.Send (sock, String.sub s o k)))
             with e -> raise (Ssh_transport.Disconnected (error e)));
            go (o + k)
          end in
        go 0);
    close = (fun () -> try Net.call w (Net.Close sock) with _ -> ()) }

let ssh_dir = "/disk/ssh"

let ensure_dir () =
  if not (Sys.file_exists ssh_dir) then Sys.mkdir ssh_dir 0o700

let write_file ?(perm = 0o600) f s =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm f
    (fun oc -> output_string oc s)

let read_file f = In_channel.with_open_bin f In_channel.input_all

(* standard input's next bytes, read only when there are some (select):
   a read left waiting when the program ends would take the keys typed
   next, which the console gives to it, gone, and not to the shell. [""]
   at the end, or once [stop] says so. *)
let rec read_input buf stop =
  if stop () then ""
  else match Unix.select [ Unix.stdin ] [] [] 0.05 with
    | [], _, _ -> read_input buf stop
    | _ -> (match Unix.read Unix.stdin buf 0 (Bytes.length buf) with
        | 0 -> ""
        | n -> Bytes.sub_string buf 0 n
        | exception Unix.Unix_error _ -> "")
    | exception Unix.Unix_error _ -> ""
