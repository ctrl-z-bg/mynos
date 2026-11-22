(* Completion from the running system. After "Gui." or "List.", the
   module's interface as the compiler inside MyNOS knows it (its .cmi:
   "include M" compiled with -i, in a domain of its own, once): its
   values, types, exceptions, modules. After "Sound." or "Display.", also
   the requests of the service whose protocol has that name ("sound/1" is
   module Sound's), as the service itself describes them (Ipc.describe):
   constructors, typed arguments, replies, documentation; asked of the
   registry and of the services again every 10 seconds. A module of
   MyNOS's services whose service is not running says so. *)

type item = {
  constructor : string;      (* "Tone", "button": what is inserted *)
  signature : string;        (* "(hz : int, ms : int) -> unit" *)
  doc : string;
  safe : bool;
  request : bool;            (* a request of a running service *)
}

(* a protocol's module: "sound/1" -> "Sound" *)
let module_of protocol =
  match String.index_opt protocol '/' with
  | Some i -> String.capitalize_ascii (String.sub protocol 0 i)
  | None -> String.capitalize_ascii protocol

(* the modules of the system's protocols: their service, when it runs *)
let known = [ "Display", "display"; "Sound", "sound"; "Net", "net"; "Block", "ata0";
              "Fs", "fatfs"; "Console", "console"; "Registry", "registry"; "Llm", "llm";
              "Power", "power" ]

let rec shape (s : Wire.shape) =
  match s with
  | Wire.Unit -> "unit" | Wire.Bool -> "bool" | Wire.Int -> "int" | Wire.Float -> "float"
  | Wire.String -> "string"
  | Wire.Option s -> shape s ^ " option"
  | Wire.List s -> shape s ^ " list"
  | Wire.Tuple l -> "(" ^ String.concat ", " (List.map shape l) ^ ")"
  | Wire.Named (n, s) -> n ^ " : " ^ shape s
  | Wire.Variant cases -> String.concat " | " (List.map (fun (_, n, _) -> n) cases)
  | Wire.Rec (n, _) | Wire.Var n -> n

let items (d : Ipc.description) =
  List.map (fun (r : Ipc.request_doc) ->
      { constructor = String.capitalize_ascii r.name;
        signature = (match r.args with Wire.Unit -> "" | a -> shape a ^ " -> ") ^ shape r.reply;
        doc = r.doc; safe = r.safe; request = true }) d.requests

(* module -> (service, its items) *)
let table : (string, string * item list) Hashtbl.t = Hashtbl.create 16
let checked = ref (-100.)

let refresh () =
  if Mynos.uptime () -. !checked > 10. then begin
    checked := Mynos.uptime ();
    Hashtbl.reset table;
    let names = try List.map (fun (n, _, _) -> n) (Mynos.registered ()) with _ -> [] in
    List.iter (fun n ->
        (* a terminal's console and Studio's own run console are not modules *)
        if not (String.starts_with ~prefix:"term" n) then
          match Ipc.describe ~timeout:0.3 n with
          | d ->
            let m = module_of d.Ipc.protocol in
            if not (Hashtbl.mem table m) || List.assoc_opt m known = Some n then
              Hashtbl.replace table m (n, items d)
          | exception _ -> ()) names
  end

(* {1 Interfaces} *)

let collapse s =
  String.concat " " (List.filter (( <> ) "") (String.split_on_char ' '
    (String.map (function '\n' | '\t' -> ' ' | c -> c) s)))

(* ocamlc -i's text: items, each from a line at column 0 that starts with
   a keyword (a record's closing brace is at column 0 too) *)
let parse_interface text =
  let starts l = List.exists (fun k -> String.starts_with ~prefix:(k ^ " ") l)
      [ "val"; "external"; "type"; "exception"; "module"; "class" ] in
  let blocks = List.fold_left (fun acc l ->
      if starts l then [ l ] :: acc
      else match acc with b :: rest -> (l :: b) :: rest | [] -> acc) []
      (String.split_on_char '\n' text) in
  (* a variant type's constructors: after "= " or "| ", capitalized, not a
     path ("= Gui.picked =" is the type it re-exports) *)
  let constructors whole tname =
    let n = String.length whole in
    let rec scan i acc =
      if i + 2 >= n then List.rev acc
      else if (whole.[i] = '=' || whole.[i] = '|') && whole.[i + 1] = ' '
              && whole.[i + 2] >= 'A' && whole.[i + 2] <= 'Z' then begin
        let j = ref (i + 2) in
        while !j < n && (match whole.[!j] with 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' | '\'' -> true | _ -> false)
        do incr j done;
        let c = String.sub whole (i + 2) (!j - i - 2) in
        if !j < n && whole.[!j] = '.' then scan !j acc
        else scan !j ({ constructor = c; signature = "a " ^ tname; doc = whole; safe = false;
                        request = false } :: acc)
      end else scan (i + 1) acc in
    if String.contains whole '{' then [] else scan 0 [] in
  List.concat_map (fun b ->
      let whole = collapse (String.concat "\n" (List.rev b)) in
      let item = match String.index_opt whole ' ' with
      | None -> None
      | Some sp ->
        let kw = String.sub whole 0 sp and rest = String.sub whole (sp + 1) (String.length whole - sp - 1) in
        let rest = if String.starts_with ~prefix:"rec " rest then String.sub rest 4 (String.length rest - 4) else rest in
        (* the name: the first word (not an operator, nor a type's parameters) *)
        let words = String.split_on_char ' ' rest in
        let words = List.filter (fun w -> w <> "" && w.[0] <> '\'' && w.[0] <> '(' && w.[0] <> '+' && w.[0] <> '-') words in
        match words with
        | [] -> None
        | name :: _ ->
          let name = match String.index_opt name ':' with Some c -> String.sub name 0 c | None -> name in
          let after_colon () = match String.index_opt rest ':' with
            | Some c -> String.trim (String.sub rest (c + 1) (String.length rest - c - 1))
            | None -> "" in
          let signature = match kw with
            | "val" | "external" -> after_colon ()
            | "exception" -> "exception" ^ (match String.index_opt rest ' ' with
                | Some c -> String.sub rest c (String.length rest - c) | None -> "")
            | k -> k in
          if name = "" || not (List.mem name.[0] (List.init 26 (fun i -> Char.chr (97 + i)) @ List.init 26 (fun i -> Char.chr (65 + i)) @ [ '_' ]))
          then None
          else Some { constructor = name; signature; doc = whole; safe = false; request = false } in
      match item with
      | Some ({ signature = "type"; _ } as it) -> it :: constructors whole it.constructor
      | Some it -> [ it ]
      | None -> [])
    (List.rev blocks)

type interface = Reading | Ready of item list | Absent

let interfaces : (string, interface) Hashtbl.t = Hashtbl.create 16
let ilock = Mutex.create ()

(* how many interfaces have been read: a list made before the last one
   was read is asked for again *)
let read_count = Atomic.make 0

(* the interface of [m], read once (in the background): Reading meanwhile *)
let interface ~dir m =
  Mutex.protect ilock (fun () ->
      match Hashtbl.find_opt interfaces m with
      | Some i -> i
      | None ->
        Hashtbl.replace interfaces m Reading;
        ignore (Domain.spawn (fun () ->
            let r = match Build.interface ~dir m with
              | Ok text -> Ready (parse_interface text)
              | Error _ | exception _ -> Absent in
            Mutex.protect ilock (fun () -> Hashtbl.replace interfaces m r);
            Atomic.incr read_count));
        Reading)

type answer =
  | Items of string * item list       (* where they come from, the items that match *)
  | Not_running of string             (* a module of the system's: its service is not there *)
  | Reading of string                 (* the module's interface, being read *)
  | Nothing

(* "Gui.bu", "Sound.to": what completes it; [dir] the file's (its own
   modules' .cmi) *)
let for_word ?(dir = "/disk") word =
  match String.rindex_opt word '.' with
  | None -> Nothing
  | Some i ->
    let m = String.sub word 0 i and prefix = String.sub word (i + 1) (String.length word - i - 1) in
    let m = match String.rindex_opt m '.' with Some j -> String.sub m (j + 1) (String.length m - j - 1) | None -> m in
    if m = "" || not (m.[0] >= 'A' && m.[0] <= 'Z') then Nothing
    else begin
      refresh ();
      let p = String.lowercase_ascii prefix in
      let matching = List.filter (fun it ->
          String.starts_with ~prefix:p (String.lowercase_ascii it.constructor)) in
      let service = Hashtbl.find_opt table m in
      match interface ~dir m, service with
      | Reading, None -> Reading m
      | Reading, Some (service, its) -> Items ("the running service " ^ service ^ " (reading " ^ m ^ "...)", matching its)
      | Ready lib, Some (service, its) ->
        (* a constructor that is a request too: once, as the request *)
        let lib = List.filter (fun (it : item) ->
            not (List.exists (fun (r : item) -> r.constructor = it.constructor) its)) lib in
        Items (m ^ "'s interface, and the running service " ^ service, matching (lib @ its))
      | Ready lib, None ->
        let note = match List.assoc_opt m known with
          | Some service -> " (" ^ service ^ ": not running)" | None -> "" in
        Items (m ^ "'s interface" ^ note, matching lib)
      | Absent, Some (service, its) -> Items ("the running service " ^ service, matching its)
      | Absent, None ->
        match List.assoc_opt m known with
        | Some service -> Not_running service
        | None -> Nothing
    end
