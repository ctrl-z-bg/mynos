(* Buffered I/O, Scheme ports.  *)

(* MyNOS: ports are OCaml's channels (or a string, for input), not Unix
   file descriptors: the channels do the buffering, and MyNOS's programs
   have no descriptors of their own for the console. *)

open Ocs_error

type port = {
  mutable p_in : in_channel option;
  mutable p_out : out_channel option;
  p_str : string;                     (* a string input port's text *)
  mutable p_spos : int;
  mutable p_ugc : char option;
  mutable p_input : bool;
  mutable p_output : bool;
  p_close : bool
}

type port_flag =
    Pf_input
  | Pf_output
  | Pf_close

let mkport ?inp ?out ?(str = "") cl =
  { p_in = inp; p_out = out; p_str = str; p_spos = 0; p_ugc = None;
    p_input = inp <> None || (inp = None && out = None);
    p_output = out <> None; p_close = cl }

let is_input p = p.p_input
let is_output p = p.p_output

let getc p =
  match p.p_ugc with
    Some _ as c -> p.p_ugc <- None; c
  | None ->
      if not p.p_input then raise (Error "not a valid input port");
      match p.p_in with
	Some ic ->
	  (* what was written first: a prompt *)
	  flush stdout;
	  (try Some (input_char ic) with End_of_file -> None)
      | None ->
	  if p.p_spos < String.length p.p_str then begin
	    let c = p.p_str.[p.p_spos] in
	      p.p_spos <- p.p_spos + 1; Some c
	  end else None

let flush p =
  match p.p_out with
    Some oc -> (try Stdlib.flush oc with Sys_error m -> raise (Error ("write error: " ^ m)))
  | None -> ()

let close p =
  if p.p_input || p.p_output then
    begin
      flush p;
      p.p_input <- false;
      p.p_output <- false;
      if p.p_close then begin
	(match p.p_in with Some ic -> close_in_noerr ic | None -> ());
	(match p.p_out with Some oc -> close_out_noerr oc | None -> ())
      end;
      p.p_in <- None; p.p_out <- None
    end

let ungetc p c =
  p.p_ugc <- Some c

let char_ready p =
  p.p_ugc <> None || (p.p_in = None && p.p_spos < String.length p.p_str)
  || (p.p_input && p.p_in <> None)

let putc p c =
  match p.p_out with
    Some oc when p.p_output -> output_char oc c
  | _ -> raise (Error "not a valid output port")

let puts p s =
  match p.p_out with
    Some oc when p.p_output -> output_string oc s
  | _ -> raise (Error "not a valid output port")

let input_port ch = mkport ~inp:ch false
let output_port ch = mkport ~out:ch false

let open_input_port name =
  try
    let p = mkport ~inp:(open_in_bin name) true in
      Gc.finalise close p; p
  with
    Sys_error m -> raise (Error ("unable to open '" ^ name ^ "' for input: " ^ m))

let open_output_port name =
  try
    let p = mkport ~out:(open_out_bin name) true in
      Gc.finalise close p; p
  with
    Sys_error m -> raise (Error ("unable to open '" ^ name ^ "' for output: " ^ m))

let string_input_port s = mkport ~str:s false
