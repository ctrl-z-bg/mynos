(* Pkgdb: what pkg (pkg.ml) and the Packages window (packages_window.ml)
   both read: where the packages live, the index, the installed ones
   (mynos-vcd, doc/decisions/packages.md). *)

let default_url = "https://raw.githubusercontent.com/ctrl-z-bg/mynos-packages/main/"
let root = "/disk/pkg"
let bin = "/disk/bin"
let index_file = root ^ "/index.json"

exception Fail of string
let fail fmt = Printf.ksprintf (fun s -> raise (Fail s)) fmt

(* the repository: MYNOS_PKG_URL, else the first line of /disk/pkg/url
   (it holds for every program, the Packages window too), else GitHub *)
let base () =
  let slash u = if String.ends_with ~suffix:"/" u then u else u ^ "/" in
  match Sys.getenv_opt "MYNOS_PKG_URL" with
  | Some u when u <> "" -> slash u
  | _ ->
    match In_channel.with_open_bin (root ^ "/url") In_channel.input_line with
    | Some u when String.trim u <> "" -> slash (String.trim u)
    | _ | exception Sys_error _ -> default_url

let read path = In_channel.with_open_bin path In_channel.input_all
let write path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)

(* {1 The index} *)

type entry = {
  name : string;
  version : string;
  description : string;
  license : string;
  archive : string;       (* its path, from the repository's root *)
  size : int;
  hash : string;          (* BLAKE2b-256 of the archive, in hexadecimal *)
  mynos : string;         (* the MyNOS its bytecode was built on *)
  depends : string list;  (* the packages it needs, installed first *)
  programs : string list; (* its commands; none: a package of data *)
}

(* an optional list of strings: [] when the field is not there *)
let strings k v =
  match Json.member k v with
  | Json.Null -> []
  | l -> Json.(to_list l |> List.map to_string_value)

let entries text =
  try
    let open Json in
    let v = of_string text in
    if member "format" v |> to_int <> 1 then fail "index: a format this pkg does not know";
    member "packages" v |> to_list |> List.map (fun p ->
        let s k = member k p |> to_string_value in
        { name = s "name"; version = s "version"; description = s "description";
          license = s "license"; archive = s "archive"; size = member "size" p |> to_int;
          hash = s "blake2b-256"; mynos = s "mynos";
          depends = strings "depends" p; programs = strings "programs" p })
  with Json.Error m -> fail "index: %s" m

(* the installed version, and how it was installed *)
let installed name =
  match String.split_on_char '\n' (read (Printf.sprintf "%s/%s/installed" root name)) with
  | version :: how :: _ -> Some (version, how)
  | _ -> None
  | exception Sys_error _ -> None

(* the copy of the index on /disk, if there is one *)
let cached_index () =
  try entries (read index_file) with Fail _ | Sys_error _ -> []

(* the packages installed, by name *)
let installed_names () =
  (try Array.to_list (Sys.readdir root) with Sys_error _ -> [])
  |> List.filter (fun n -> installed n <> None)
  |> List.sort compare

(* {1 An installed package's package.json} *)

type program = { file : string; sources : string list }

type manifest = {
  progs : program list;        (* in /disk/bin *)
  commands : string list;      (* scripts in /disk/bin that run the program *)
  libraries : string list;
  needs : string list;         (* "depends" *)
  run : string list;           (* the window to start, and its arguments *)
  doc : string option;         (* a file of the package: its documentation *)
}

(* "programs", or (the first packages) one "program" and its "sources" *)
let manifest_of text =
  let open Json in
  let v = of_string text in
  let programs =
    match member "programs" v with
    | Null ->
      (match member "program" v with
       | Null -> []
       | p -> [ { file = to_string_value p; sources = strings "sources" v } ])
    | l -> List.map (fun p -> { file = member "program" p |> to_string_value;
                                sources = strings "sources" p }) (to_list l) in
  let run = match member "run" v with
    | Null -> (match programs with
        | [ p ] when member "programs" v = Null -> [ p.file ]   (* the first packages: windows *)
        | _ -> [])
    | String s -> [ s ]
    | l -> List.map to_string_value (to_list l) in
  { progs = programs; commands = strings "commands" v; libraries = strings "libraries" v; needs = strings "depends" v; run;
    doc = (match member "doc" v with Null -> None | d -> Some (to_string_value d)) }

let manifest name =
  try Some (manifest_of (read (Printf.sprintf "%s/%s/package.json" root name)))
  with Sys_error _ | Json.Error _ -> None

(* the installed packages that need [name] *)
let needed_by name =
  List.filter (fun n ->
      match manifest n with Some m -> List.mem name m.needs | None -> false)
    (installed_names ())
