(* The tour's lessons (gui/tour.ml, gui/system.ml): a text file, lessons
   separated by lines "---". Each starts with "key: value" lines, then a
   blank line and its text:

     title: A file from the RAM disk
     command: cat /init.rc
     show: sh, memrofsd, registry
     note: fs/1 Open | sh asks memrofs to open the file...
     note: fs/1 Read | Each read is a request and a reply...

     In MyNOS a file is not something the kernel knows...

   [command] is recorded (trace) and replayed in the System window, which
   shows only the processes of [show] (by program name) and, at each step
   whose description contains a note's pattern, the note's words. *)

type t = {
  title : string;
  command : string;
  show : string list;
  notes : (string * string) list;           (* pattern, words *)
  text : string;
}

let trim = String.trim

let parse_one block =
  let lines = String.split_on_char '\n' block in
  let rec header acc = function
    | l :: rest when trim l = "" -> (List.rev acc, rest)
    | l :: rest ->
      (match String.index_opt l ':' with
       | Some i -> header ((trim (String.sub l 0 i),
                            trim (String.sub l (i + 1) (String.length l - i - 1))) :: acc) rest
       | None -> header acc rest)
    | [] -> (List.rev acc, []) in
  let fields, body = header [] lines in
  let get k = try List.assoc k fields with Not_found -> "" in
  let notes = List.filter_map (fun (k, v) ->
      if k <> "note" then None
      else match String.index_opt v '|' with
        | Some i -> Some (trim (String.sub v 0 i), trim (String.sub v (i + 1) (String.length v - i - 1)))
        | None -> None) fields in
  (* the text: paragraphs, separated by blank lines, each joined in one line *)
  let paras = ref [] and cur = Buffer.create 256 in
  let flush () = if Buffer.length cur > 0 then (paras := Buffer.contents cur :: !paras; Buffer.clear cur) in
  List.iter (fun l ->
      if trim l = "" then flush ()
      else (if Buffer.length cur > 0 then Buffer.add_char cur ' '; Buffer.add_string cur (trim l)))
    body;
  flush ();
  if get "title" = "" then None
  else Some { title = get "title"; command = get "command";
              show = List.filter (( <> ) "") (List.map trim (String.split_on_char ',' (get "show")));
              notes; text = String.concat "\n" (List.rev !paras) }

let parse s =
  let blocks = ref [] and cur = Buffer.create 1024 in
  List.iter (fun l ->
      if trim l = "---" then (blocks := Buffer.contents cur :: !blocks; Buffer.clear cur)
      else (Buffer.add_string cur l; Buffer.add_char cur '\n'))
    (String.split_on_char '\n' s);
  blocks := Buffer.contents cur :: !blocks;
  List.filter_map parse_one (List.rev !blocks)

let load path =
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> parse s
  | exception Sys_error _ -> []

let to_string t =
  String.concat "\n"
    ([ "title: " ^ t.title; "command: " ^ t.command; "show: " ^ String.concat ", " t.show ]
     @ List.map (fun (p, w) -> "note: " ^ p ^ " | " ^ w) t.notes
     @ [ ""; String.concat "\n\n" (String.split_on_char '\n' t.text); "" ])

(* the words for a step, by its description: the first note that matches *)
let note_for t description =
  let contains s sub =
    let n = String.length sub and m = String.length s in
    let rec at i = i + n <= m && (String.sub s i n = sub || at (i + 1)) in
    n > 0 && at 0 in
  List.find_map (fun (p, w) -> if contains description p then Some w else None) t.notes
