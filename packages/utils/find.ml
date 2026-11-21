(* find [DIR...] [-name PATTERN] [-iname PATTERN] [-type f|d]
   [-maxdepth N]: the files and directories under DIR (.), those that
   match: PATTERN is a shell pattern, with * ? [...], on the name, in quotes
   so that sh does not expand it. *)

open Util

let main () =
  Util.name := "find";
  let u = "[DIR...] [-name PATTERN] [-iname PATTERN] [-type f|d] [-maxdepth N]" in
  let rec go dirs tests = function
    | ("-name" | "-iname" as t) :: p :: rest -> go dirs ((t, p) :: tests) rest
    | ("-type" | "-maxdepth" as t) :: v :: rest -> go dirs ((t, v) :: tests) rest
    | a :: _ when String.length a > 0 && a.[0] = '-' -> usage u
    | d :: rest -> go (d :: dirs) tests rest
    | [] -> List.rev dirs, tests in
  let dirs, tests = go [] [] (!Util.args) in
  let dirs = if dirs = [] then [ "." ] else dirs in
  let maxdepth = match List.assoc_opt "-maxdepth" tests with
    | Some v -> (match int_of_string_opt v with Some n -> n | None -> usage u)
    | None -> max_int in
  let ok path =
    List.for_all (fun (t, v) ->
        let base = Filename.basename path in
        match t with
        | "-name" -> glob v base
        | "-iname" -> glob (String.lowercase_ascii v) (String.lowercase_ascii base)
        | "-type" -> (match v with
            | "d" -> is_dir path
            | "f" -> not (is_dir path)
            | _ -> usage u)
        | _ -> true) tests in
  let rec walk path depth =
    if ok path then print_endline path;
    if depth < maxdepth && is_dir path then
      List.iter (fun c ->
          walk (if path = "/" then "/" ^ c else Filename.concat path c) (depth + 1))
        (children path) in
  List.iter (fun d ->
      if Sys.file_exists d then walk d 0 else warn "%s: no such file or directory" d) dirs;
  finish ()
