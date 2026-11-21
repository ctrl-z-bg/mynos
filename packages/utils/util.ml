(* Util: what the commands of the package utils share: their options,
   their input (files, or the standard input), their errors. *)

let name = ref "utils"            (* the command's, set by it first *)
let args : string list ref = ref []   (* its arguments, set by utils.ml *)
let status = ref 0

(* a problem with one file: said, and the command goes on (exit 1, or
   the status the command asks for) *)
let warn fmt =
  Printf.ksprintf (fun s -> prerr_endline (!name ^ ": " ^ s); status := max !status 1) fmt

let die ?(code = 2) fmt =
  Printf.ksprintf (fun s -> prerr_endline (!name ^ ": " ^ s); exit code) fmt

let usage text = die "usage: %s %s" !name text

(* the arguments: options first ("-n 5", "-n5", "-c", "-ci", "--" ends
   them), then the operands. [flags] take no value, [valued] one. *)
let parse ?(flags = "") ?(valued = "") ~usage:u command =
  name := command;
  let set = Hashtbl.create 8 in
  let rec go = function
    | "--" :: rest -> rest
    | a :: rest when String.length a > 1 && a.[0] = '-' && a <> "-" ->
      (* a number alone, as head -5 *)
      if String.for_all (fun c -> c >= '0' && c <= '9') (String.sub a 1 (String.length a - 1))
         && String.contains valued 'n' then begin
        Hashtbl.replace set 'n' (String.sub a 1 (String.length a - 1)); go rest
      end else
        let rec letters i rest =
          if i >= String.length a then go rest
          else
            let c = a.[i] in
            if String.contains valued c then
              if i + 1 < String.length a then begin
                Hashtbl.replace set c (String.sub a (i + 1) (String.length a - i - 1)); go rest
              end else (match rest with
                  | v :: rest -> Hashtbl.replace set c v; go rest
                  | [] -> usage u)
            else if String.contains flags c then begin
              Hashtbl.replace set c ""; letters (i + 1) rest
            end else usage u in
        letters 1 rest
    | rest -> rest in
  let operands = go !args in
  set, operands

let flag set c = Hashtbl.mem set c
let value set c = Hashtbl.find_opt set c

let int_value set c default =
  match value set c with
  | None -> default
  | Some v -> match int_of_string_opt v with
    | Some n -> n
    | None -> die "-%c: not a number: %s" c v

(* [f label channel] for each file ("-", or none at all: the standard
   input); a file that cannot be read is said, and skipped *)
let each_input files f =
  match files with
  | [] -> f "-" stdin
  | _ -> List.iter (fun file ->
      if file = "-" then f "-" stdin
      else if Sys.file_exists file && Sys.is_directory file then warn "%s: a directory" file
      else match open_in_bin file with
        | ic -> Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> f file ic)
        | exception Sys_error m -> warn "%s" m) files

let lines ic =
  let rec go acc = match input_line ic with
    | l -> go (l :: acc)
    | exception End_of_file -> List.rev acc in
  go []

let is_dir p = try Sys.is_directory p with Sys_error _ -> false

(* the entries of a directory, sorted; [] if it cannot be read *)
let children dir =
  match Sys.readdir dir with
  | a -> Array.sort compare a; Array.to_list a
  | exception Sys_error m -> warn "%s" m; []

let size path =
  try In_channel.with_open_bin path (fun ic -> Int64.to_int (In_channel.length ic))
  with Sys_error _ -> 0

(* 1.5K, 12M: as du -h and ls -h write them *)
let human n =
  if n < 1024 then string_of_int n
  else
    let rec go x = function
      | u :: rest when x >= 1024. && rest <> [] -> go (x /. 1024.) rest
      | u :: _ -> if x < 10. then Printf.sprintf "%.1f%s" x u else Printf.sprintf "%.0f%s" x u
      | [] -> assert false in
    go (float n /. 1024.) [ "K"; "M"; "G" ]

(* a shell pattern: * any characters, ? one, [abc] one of them *)
let glob pattern s =
  let n = String.length pattern and m = String.length s in
  let rec go i j =
    if i = n then j = m
    else match pattern.[i] with
      | '*' -> go (i + 1) j || (j < m && go i (j + 1))
      | '?' -> j < m && go (i + 1) (j + 1)
      | '[' when String.index_from_opt pattern i ']' <> None ->
        let close = String.index_from pattern (i + 1) ']' in
        let set = String.sub pattern (i + 1) (close - i - 1) in
        let neg = set <> "" && (set.[0] = '!' || set.[0] = '^') in
        let set = if neg then String.sub set 1 (String.length set - 1) else set in
        let rec mem k =
          k < String.length set
          && ((k + 2 < String.length set && set.[k + 1] = '-'
               && s.[j] >= set.[k] && s.[j] <= set.[k + 2])
              || set.[k] = s.[j] || mem (k + 1)) in
        j < m && (mem 0 <> neg) && go (close + 1) (j + 1)
      | c -> j < m && s.[j] = c && go (i + 1) (j + 1) in
  go 0 0

let finish () = exit !status
