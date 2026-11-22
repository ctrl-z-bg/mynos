(* Building a file with the ocamlc inside MyNOS (/ocamlc.byte, on the RAM
   disk): the libraries chosen as the agent chooses them (Agent's
   ocamlc_libraries: mynos.cma, and unix, threads, str... when the code
   names them), its program beside it (NAME.byte), the compiler's messages
   read back, its errors made marks for the text. *)

type error = {
  line : int;            (* from 1 *)
  first : int;           (* bytes in the line; first = last: the whole line *)
  last : int;
  text : string;         (* "Error: ..." or "Warning ...", whole *)
  is_error : bool;
}

let target file = Filename.remove_extension file ^ ".byte"

(* the compiler, as a process: its messages into [out] *)
let spawn file out =
  let code = try In_channel.with_open_bin file In_channel.input_all with Sys_error _ -> "" in
  let dir = Filename.dirname file in
  let env = Array.of_list (
      List.filter (fun kv ->
          not (List.exists (fun p -> String.starts_with ~prefix:(p ^ "=") kv)
                 [ "OCAMLLIB"; "MYNOS_STDOUT"; "MYNOS_STDERR"; "MYNOS_STDIN"; "MYNOS_CONSOLE" ]))
        (Array.to_list (Mynos.environment ()))
      @ [ "OCAMLLIB=/"; "MYNOS_STDOUT=" ^ out; "MYNOS_STDERR=" ^ out ]) in
  Out_channel.with_open_bin out (fun _ -> ());
  let argv = [ "ocamlrun"; "/ocamlc.byte"; "-use-prims"; "/primitives" ]
             @ Agent.ocamlc_libraries code
             @ [ "-I"; dir; "-o"; target file; file ] in
  Mynos.spawn ~env "ocamlrun" (Array.of_list argv)

(* ocamlc's messages: a header (File "f", line L, characters A-B:, or
   lines L1-L2), the code shown, then the error or warning, until the
   next header *)
let parse file messages =
  let lines = String.split_on_char '\n' messages in
  let header l =
    try
      Scanf.sscanf l "File %S, line %d, characters %d-%d:" (fun f n a b -> Some (f, n, a, b))
    with _ ->
      try Scanf.sscanf l "File %S, lines %d-%d, characters %d-%d:" (fun f n _ a _ -> Some (f, n, a, a))
      with _ ->
        try Scanf.sscanf l "File %S, line %d" (fun f n -> Some (f, n, 0, 0))
        with _ -> None in
  let same f = f = file || Filename.basename f = Filename.basename file in
  let rec go acc cur = function
    | [] -> List.rev (match cur with Some e -> e :: acc | None -> acc)
    | l :: rest ->
      match header l with
      | Some (f, n, a, b) ->
        let acc = match cur with Some e -> e :: acc | None -> acc in
        go acc (if same f then Some { line = n; first = a; last = b; text = ""; is_error = false }
                else None) rest
      | None ->
        (match cur with
         | Some e ->
           (* the code shown ("3 | let x"), and "^^^" under it, are skipped *)
           let t = String.trim l in
           let code = (try let i = String.index l '|' in
                         String.for_all (fun c -> c = ' ' || (c >= '0' && c <= '9'))
                           (String.sub l 0 i) && i > 0 with Not_found -> false)
                      || (t <> "" && String.for_all (fun c -> c = '^' || c = ' ' || c = '.') t) in
           if code || t = "" then go acc cur rest
           else
             let text = if e.text = "" then t else e.text ^ " " ^ t in
             let is_error = e.is_error || String.starts_with ~prefix:"Error" t in
             go acc (Some { e with text; is_error }) rest
         | None -> go acc None rest) in
  go [] None lines

let marks errors =
  List.map (fun e -> { Textarea.mline = e.line; first = e.first; last = e.last; message = e.text })
    errors

(* compile and wait: the messages, and the errors in [file] *)
let run file =
  let out = Printf.sprintf "/tmp/studio-build-%d.txt" (Mynos.getpid ()) in
  let pid = spawn file out in
  ignore (Mynos.wait pid);
  let messages = try In_channel.with_open_bin out In_channel.input_all with Sys_error _ -> "" in
  (String.trim messages, parse file messages)
