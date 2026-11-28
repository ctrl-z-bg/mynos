(* Ed25519 keys in OpenSSH's files: the private key (openssh-key-v1, not
   encrypted), the public line ("ssh-ed25519 BASE64 comment"),
   authorized_keys and known_hosts. *)

open Ssh_wire

let alg = "ssh-ed25519"

type key = { seed : string; pub : string; comment : string }

let blob pub = str alg ^ str pub

let pub_of_blob b =
  let r = reader b in
  match get_str r with
  | a when a = alg -> let p = get_str r in if String.length p = 32 then Some p else None
  | _ -> None
  | exception Bad _ -> None

let pub_line k = alg ^ " " ^ base64 (blob k.pub) ^ (if k.comment = "" then "" else " " ^ k.comment)

let fingerprint pub =
  let b = base64 (Sha2.sha256 (blob pub)) in
  "SHA256:" ^ (match String.index_opt b '=' with Some i -> String.sub b 0 i | None -> b)

let generate ~comment =
  let seed = random 32 in
  { seed; pub = Curve25519.ed25519_public seed; comment }

(* {1 The private key file} *)

let magic = "openssh-key-v1\000"
let pem_begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
let pem_end = "-----END OPENSSH PRIVATE KEY-----"

let to_file k =
  let check = random 4 in
  let priv = check ^ check ^ str alg ^ str k.pub ^ str (k.seed ^ k.pub) ^ str k.comment in
  let priv = priv ^ String.init ((8 - String.length priv mod 8) mod 8) (fun i -> Char.chr (i + 1)) in
  let body = magic ^ str "none" ^ str "none" ^ str "" ^ u32 1 ^ str (blob k.pub) ^ str priv in
  let b = base64 body in
  let lines = List.init ((String.length b + 69) / 70)
      (fun i -> String.sub b (70 * i) (min 70 (String.length b - 70 * i))) in
  String.concat "\n" ((pem_begin :: lines) @ [ pem_end; "" ])

let of_file text =
  let lines = List.map String.trim (String.split_on_char '\n' text) in
  let rec inside acc = function
    | l :: _ when l = pem_end -> Some (String.concat "" (List.rev acc))
    | l :: rest -> inside (l :: acc) rest
    | [] -> None in
  let rec find = function
    | l :: rest when l = pem_begin -> inside [] rest
    | _ :: rest -> find rest
    | [] -> None in
  match find lines with
  | None -> Error "not an OpenSSH private key"
  | Some b64 ->
    try
      let d = unbase64 b64 in
      if String.length d < String.length magic || String.sub d 0 (String.length magic) <> magic
      then Error "not an OpenSSH private key"
      else
        let r = reader ~pos:(String.length magic) d in
        let cipher = get_str r in
        let _kdf = get_str r and _opts = get_str r in
        if cipher <> "none" then Error "the key is encrypted (a passphrase): not supported"
        else if get_u32 r <> 1 then Error "more than one key in the file"
        else begin
          let _pub = get_str r in
          let p = reader (get_str r) in
          let c1 = get_raw p 4 in
          let c2 = get_raw p 4 in
          if c1 <> c2 then Error "the key file is damaged"
          else if get_str p <> alg then Error "not an Ed25519 key (only ssh-ed25519 is supported)"
          else
            let pub = get_str p in
            let sk = get_str p in
            let comment = get_str p in
            if String.length sk <> 64 || String.length pub <> 32 then Error "the key file is damaged"
            else Ok { seed = String.sub sk 0 32; pub; comment }
        end
    with Bad m -> Error m

(* {1 Lines of public keys} *)

(* the key of a line "[options] ssh-ed25519 BASE64 [comment]" *)
let pub_of_line line =
  let words = List.filter (( <> ) "") (String.split_on_char ' ' (String.trim line)) in
  let rec go = function
    | a :: b64 :: _ when a = alg -> (try pub_of_blob (unbase64 b64) with Bad _ -> None)
    | _ :: rest -> go rest
    | [] -> None in
  if line = "" || line.[0] = '#' then None else go words

let read_lines file =
  match In_channel.with_open_bin file In_channel.input_all with
  | s -> String.split_on_char '\n' s
  | exception Sys_error _ -> []

let authorized file = List.filter_map pub_of_line (read_lines file)

(* known_hosts: "HOST ssh-ed25519 BASE64", HOST "[name]:port" off port 22 *)
let host_name host port = if port = 22 then host else Printf.sprintf "[%s]:%d" host port

let known file host port =
  let name = host_name host port in
  List.filter_map (fun l ->
      match String.index_opt l ' ' with
      | Some i when List.mem name (String.split_on_char ',' (String.sub l 0 i)) ->
        pub_of_line (String.sub l (i + 1) (String.length l - i - 1))
      | _ -> None) (read_lines file)

let remember file host port pub =
  Out_channel.with_open_gen [ Open_append; Open_creat; Open_binary ] 0o600 file (fun oc ->
      output_string oc (host_name host port ^ " " ^ alg ^ " " ^ base64 (blob pub) ^ "\n"))
