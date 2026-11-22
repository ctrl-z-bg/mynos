(* Completion from the running system: after "Sound." or "Display.", the
   requests of the service whose protocol has that name ("sound/1" is
   module Sound's), as the service itself describes them (Ipc.describe):
   their constructors, typed arguments, replies, documentation. Asked of
   the registry and of the services themselves, again every 10 seconds;
   the modules of MyNOS's services that are not running say so. *)

type item = {
  constructor : string;      (* "Tone" *)
  signature : string;        (* "(hz : int, ms : int) -> unit" *)
  doc : string;
  safe : bool;
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
        doc = r.doc; safe = r.safe }) d.requests

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

type answer =
  | Items of string * item list       (* the service, its requests that match *)
  | Not_running of string             (* a module of the system's: its service is not there *)
  | Nothing

(* "Sound.to": what completes it *)
let for_word word =
  match String.rindex_opt word '.' with
  | None -> Nothing
  | Some i ->
    let m = String.sub word 0 i and prefix = String.sub word (i + 1) (String.length word - i - 1) in
    let m = match String.rindex_opt m '.' with Some j -> String.sub m (j + 1) (String.length m - j - 1) | None -> m in
    if m = "" || not (m.[0] >= 'A' && m.[0] <= 'Z') then Nothing
    else begin
      refresh ();
      match Hashtbl.find_opt table m with
      | Some (service, its) ->
        let p = String.lowercase_ascii prefix in
        Items (service, List.filter (fun it ->
            String.starts_with ~prefix:p (String.lowercase_ascii it.constructor)) its)
      | None ->
        match List.assoc_opt m known with
        | Some service -> Not_running service
        | None -> Nothing
    end
