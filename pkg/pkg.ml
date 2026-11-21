(* pkg: MyNOS's package manager (mynos-vcd, doc/decisions/packages.md).

     pkg list                  the packages of the index, and which are installed
     pkg list -i               the installed packages only (without the network)
     pkg search WORD           the packages whose name or description has WORD
     pkg info NAME             a package's description, version, licence, size
     pkg install [-s] NAME...  download, check, install in /disk/pkg/NAME, with
                               the packages it needs; its programs go to
                               /disk/bin, on sh's PATH
     pkg remove NAME...        uninstall
     pkg update                read the index again
     pkg upgrade               read it, install the newer versions it has

   The index (index.json) and the packages (tar archives) are files of a
   repository on the web, by default ctrl-z-bg/mynos-packages on GitHub;
   MYNOS_PKG_URL names another. A package holds its program as bytecode
   and its sources: the bytecode is installed when this MyNOS can run it
   (the same bytecode format, every primitive it needs in the runtime);
   otherwise, or with -s, the sources are compiled here by ocamlc. The
   index and the installed packages are read by module Pkgdb, which the
   graphical session's Packages window shares. *)

open Pkgdb

(* {1 Files} *)

let rec mkdir_p d =
  if not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    Sys.mkdir d 0o755
  end

(* fatfs does not remove a file that is open: one another program reads
   at that moment (the Applications window, its package.json) is tried
   again, for a second *)
let remove_file f =
  let rec go n =
    try Sys.remove f with Sys_error _ when n > 0 -> Mynos.sleep 0.1; go (n - 1) in
  go 10

let rec rm_rf p =
  if Sys.is_directory p then begin
    Array.iter (fun n -> rm_rf (Filename.concat p n)) (Sys.readdir p);
    Sys.rmdir p
  end else remove_file p

(* {1 The network} *)

let download url =
  match Http.get ~timeout:60000 url with
  | { Http.status = 200; body; _ } -> body
  | r -> fail "%s: %d %s" url r.Http.status r.reason
  | exception Http.Error m -> fail "%s: %s" url m

let update () =
  let url = base () ^ "index.json" in
  let text = download url in
  let n = List.length (entries text) in
  mkdir_p root;
  write index_file text;
  Printf.printf "pkg: %d packages in the index (%s)\n%!" n url

let index () =
  if not (Sys.file_exists index_file) then update ();
  entries (read index_file)

let find name =
  match List.find_opt (fun e -> e.name = name) (index ()) with
  | Some e -> e
  | None -> fail "%s: no such package (pkg update reads the index again)" name

(* {1 Archives: tar (ustar)} *)

let untar data dir =
  let n = String.length data in
  let field off len =
    let s = String.sub data off len in
    match String.index_opt s '\000' with Some i -> String.sub s 0 i | None -> s in
  let octal s =
    match String.trim s with "" -> 0 | t -> int_of_string ("0o" ^ t) in
  let rec go off =
    if off + 512 <= n && field off 100 <> "" then begin
      let name = field off 100 and prefix = field (off + 345) 155 in
      let name = if prefix = "" then name else prefix ^ "/" ^ name in
      let size = octal (field (off + 124) 12) in
      let parts = List.filter (fun p -> p <> "" && p <> ".") (String.split_on_char '/' name) in
      if List.mem ".." parts || (name <> "" && name.[0] = '/') then
        fail "the archive names a file outside its directory: %s" name;
      if off + 512 + size > n then fail "the archive is cut short";
      let path = List.fold_left Filename.concat dir parts in
      (match data.[off + 156] with
       | '5' -> mkdir_p path
       | '0' | '\000' when parts <> [] ->
         mkdir_p (Filename.dirname path);
         write path (String.sub data (off + 512) size)
       | _ -> ());   (* links, devices: packages have none *)
      go (off + 512 + (size + 511) / 512 * 512)
    end in
  go 0

(* {1 Bytecode: can this MyNOS run it?} *)

(* A bytecode file ends with its sections' table: for each section a name
   of 4 bytes and a length of 4 (big-endian), then their number, then the
   magic number of its format, 12 bytes. The sections come before the
   table, in its order. *)
let trailer path =
  let s = read path in
  let n = String.length s in
  let be32 o = (Char.code s.[o] lsl 24) lor (Char.code s.[o + 1] lsl 16)
               lor (Char.code s.[o + 2] lsl 8) lor Char.code s.[o + 3] in
  if n < 16 then None
  else
    let k = be32 (n - 16) in
    let table = n - 16 - 8 * k in
    if k < 1 || k > 64 || table < 0 then None
    else
      let entries = List.init k (fun i ->
          (String.sub s (table + 8 * i) 4, be32 (table + 8 * i + 4))) in
      let total = List.fold_left (fun a (_, l) -> a + l) 0 entries in
      if total > table then None
      else
        let _, sections = List.fold_left (fun (pos, acc) (name, len) ->
            (pos + len, (name, String.sub s pos len) :: acc))
            (table - total, []) entries in
        Some (String.sub s (n - 12) 12, sections)

(* the magic number of a file, from its last 12 bytes only *)
let magic path =
  In_channel.with_open_bin path (fun ic ->
      let len = Int64.to_int (In_channel.length ic) in
      In_channel.seek ic (Int64.of_int (len - 12));
      really_input_string ic 12)

let compatible program =
  match trailer program with
  | None -> false
  | Some (m, sections) ->
    m = magic "/ocamlc.byte"
    && (match List.assoc_opt "PRIM" sections with
        | None -> true
        | Some prim ->
          let have = Hashtbl.create 1024 in
          List.iter (fun p -> Hashtbl.replace have p ())
            (String.split_on_char '\n' (read "/primitives"));
          List.for_all (fun p -> p = "" || Hashtbl.mem have p)
            (String.split_on_char '\000' prim))

(* {1 Compiling from the sources} *)

let libraries names =
  List.fold_left (fun acc l ->
      let cmas = match l with
        | "unix" -> [ "unix.cma" ]
        | "threads" -> [ "unix.cma"; "threads.cma" ]
        | "str" -> [ "str.cma" ]
        | "num" | "nums" -> [ "nums.cma" ]
        | "graphics" -> [ "graphics.cma" ]
        | l -> fail "unknown library %s" l in
      acc @ List.filter (fun c -> not (List.mem c acc)) cmas) [] names

let compile dir sources libs target =
  let env = Array.of_list (
      List.filter (fun kv -> not (String.starts_with ~prefix:"OCAMLLIB=" kv))
        (Array.to_list (Mynos.environment ())) @ [ "OCAMLLIB=/" ]) in
  let argv = [ "ocamlrun"; "/ocamlc.byte"; "-use-prims"; "/primitives";
               "-noautolink"; "mynos.cma" ] @ libraries libs
             @ [ "-o"; target ] @ sources in
  let here = Sys.getcwd () in
  (* in the sources' directory: a module of the package's comes before a
     library's of the same name (2048 has a Gui, as mynos.cma has) *)
  Sys.chdir dir;
  let status =
    Fun.protect ~finally:(fun () -> Sys.chdir here) (fun () ->
        Mynos.wait (Mynos.spawn ~env "ocamlrun" (Array.of_list argv))) in
  Array.iter (fun f ->
      if Filename.check_suffix f ".cmo" || Filename.check_suffix f ".cmi" then
        Sys.remove (Filename.concat dir f)) (Sys.readdir dir);
  if status <> Mynos.Exited 0 then fail "ocamlc could not compile the sources"

(* {1 The commands} *)

(* an installed package's files in /disk/bin *)
let remove_programs m =
  List.iter (fun f ->
      let f = Filename.concat bin f in
      if Sys.file_exists f then remove_file f)
    (List.map (fun p -> p.file) m.progs @ m.commands)

(* [name] and the packages it needs, not yet installed in the index's
   version, those it needs first *)
let rec install ~source ?(chain = []) name =
  if List.mem name chain then
    fail "%s: the packages need each other (%s)" name (String.concat ", " (List.rev chain));
  let e = find name in
  List.iter (fun d ->
      match installed d with
      | Some (v, _) when v = (find d).version -> ()
      | _ ->
        Printf.printf "pkg: %s needs %s\n%!" name d;
        install ~source ~chain:(name :: chain) d) e.depends;
  Printf.printf "pkg: %s %s: downloading %d bytes\n%!" e.name e.version e.size;
  let data = download (base () ^ e.archive) in
  if String.length data <> e.size then
    fail "%s: %d bytes, the index says %d" e.archive (String.length data) e.size;
  if Digest.BLAKE256.(to_hex (string data)) <> e.hash then
    fail "%s: its BLAKE2b hash is not the index's" e.archive;
  let dir = Filename.concat root name in
  (* an older version: its programs go, the new one may have others *)
  Option.iter remove_programs (manifest name);
  if Sys.file_exists dir then rm_rf dir;
  mkdir_p dir;
  untar data dir;
  let m = try manifest_of (read (Filename.concat dir "package.json"))
    with Json.Error m | Failure m -> fail "%s: package.json: %s" name m in
  if m.progs <> [] then mkdir_p bin;
  let hows = List.map (fun p ->
      if Filename.basename p.file <> p.file then fail "%s: a bad program name" name;
      let target = Filename.concat bin p.file in
      let bytecode = Filename.concat dir p.file in
      if not source && Sys.file_exists bytecode && compatible bytecode then begin
        write target (read bytecode);
        `Bytecode
      end else begin
        Printf.printf "pkg: %s: compiling %s\n%!" (Filename.remove_extension p.file)
          (String.concat " " p.sources);
        compile (Filename.concat dir "src") p.sources m.libraries target;
        `Compiled
      end) m.progs in
  (* each command: a script that runs the program (which tells the
     commands apart by the script's name), or, in a package of data, the
     window it runs (a story and its interpreter) *)
  let interpreter = match m.progs, m.run with
    | p :: _, _ -> Some (Filename.concat bin p.file)
    | [], prog :: args -> Some (String.concat " " (Filename.concat bin prog :: args))
    | [], [] -> None in
  Option.iter (fun line ->
      List.iter (fun c ->
          if Filename.basename c <> c then fail "%s: a bad command name" name;
          write (Filename.concat bin c) (Printf.sprintf "#!%s\n" line)) m.commands) interpreter;
  let how =
    if m.progs = [] then "data"
    else if List.for_all (( = ) `Bytecode) hows then "its bytecode"
    else if List.for_all (( = ) `Compiled) hows then "compiled from its sources"
    else "bytecode and sources" in
  write (Filename.concat dir "installed") (e.version ^ "\n" ^ how ^ "\n");
  Printf.printf "pkg: %s %s installed (%s)%s\n%!" name e.version how
    (match m.commands, m.progs with
     | [], [] -> ""
     | [], ps -> ": " ^ String.concat " " (List.map (fun p -> Filename.remove_extension p.file) ps)
     | cs, _ -> ": " ^ String.concat " " cs)

let remove name =
  let dir = Filename.concat root name in
  if not (Sys.file_exists (Filename.concat dir "installed")) then fail "%s: not installed" name;
  (match needed_by name with
   | [] -> ()
   | ns -> Printf.printf "pkg: %s was needed by %s\n%!" name (String.concat ", " ns));
  Option.iter remove_programs (manifest name);
  rm_rf dir;
  Printf.printf "pkg: %s removed\n%!" name

(* the index read again, then every installed package it has a newer
   version of *)
let upgrade () =
  update ();
  let index = index () in
  let old = List.filter_map (fun n ->
      match installed n, List.find_opt (fun e -> e.name = n) index with
      | Some (v, _), Some e when v <> e.version -> Some n
      | _ -> None) (installed_names ()) in
  if old = [] then print_endline "pkg: every installed package is the index's version"
  else List.iter (fun n -> install ~source:false n) old

let search word =
  let w = String.lowercase_ascii word in
  let has s =
    let s = String.lowercase_ascii s in
    let n = String.length w in
    let rec go i = i + n <= String.length s && (String.sub s i n = w || go (i + 1)) in
    go 0 in
  match List.filter (fun e -> has e.name || has e.description) (index ()) with
  | [] -> Printf.printf "pkg: no package about %s\n" word
  | es -> List.iter (fun e -> Printf.printf "%-10s %-8s %s\n" e.name e.version e.description) es

let list () =
  List.iter (fun e ->
      let mark = match installed e.name with
        | Some (v, _) when v = e.version -> "installed"
        | Some (v, _) -> "installed " ^ v
        | None -> "" in
      Printf.printf "%-10s %-8s %-12s %s\n" e.name e.version mark e.description)
    (index ())

(* the packages installed, from /disk/pkg alone; the index, if a copy is
   there, tells which have a newer version *)
let list_installed () =
  let index = cached_index () in
  let names = installed_names () in
  List.iter (fun name ->
      Option.iter (fun (v, how) ->
          let newer = match List.find_opt (fun e -> e.name = name) index with
            | Some e when e.version <> v -> Printf.sprintf " (the index has %s)" e.version
            | _ -> "" in
          Printf.printf "%-10s %-8s %s%s\n" name v how newer) (installed name)) names;
  if names = [] then print_endline "pkg: no package is installed"

let info name =
  let e = find name in
  Printf.printf "%s %s\n%s\nlicence: %s\narchive: %s, %d bytes\nbuilt on MyNOS %s\n"
    e.name e.version e.description e.license e.archive e.size e.mynos;
  if e.programs <> [] then Printf.printf "commands: %s\n" (String.concat " " e.programs);
  if e.depends <> [] then Printf.printf "needs: %s\n" (String.concat " " e.depends);
  match installed name with
  | Some (v, how) ->
    Printf.printf "installed: %s (%s)\n" v how;
    Option.iter (fun m -> Option.iter (fun d ->
        Printf.printf "documentation: %s/%s/%s\n" root name d) m.doc) (manifest name)
  | None -> print_endline "not installed"

let usage () =
  prerr_endline "usage: pkg list [-i] | search WORD | info NAME | install [-s] NAME... | remove NAME... | update | upgrade";
  exit 2

let () =
  let each f names = if names = [] then usage () else List.iter f names in
  try
    match List.tl (Array.to_list Sys.argv) with
    | [ "list" ] -> list ()
    | [ "list"; "-i" ] -> list_installed ()
    | [ "info"; name ] -> info name
    | "install" :: "-s" :: names -> each (install ~source:true) names
    | "install" :: names -> each (install ~source:false) names
    | "remove" :: names -> each remove names
    | [ "update" ] -> update ()
    | [ "upgrade" ] -> upgrade ()
    | [ "search"; word ] -> search word
    | _ -> usage ()
  with
  | Fail m | Sys_error m -> prerr_endline ("pkg: " ^ m); exit 1
  | Json.Error m -> prerr_endline ("pkg: package.json: " ^ m); exit 1
