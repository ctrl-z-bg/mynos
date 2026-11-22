(* clip: the clipboard (the system's: the clipboard service), from the
   command line.

     clip              print it
     clip TEXT...      copy the words
     CMD | clip        copy what CMD wrote (clip -i: the same, from any
                       standard input) *)

open Util

let piped () = Sys.getenv_opt "MYNOS_STDIN" <> None

let main () =
  let set, words = parse ~flags:"i" ~usage:"[-i] [TEXT...]" "clip" in
  if words <> [] then Clipboard.set (String.concat " " words)
  else if flag set 'i' || piped () then Clipboard.set (In_channel.input_all stdin)
  else begin
    let s = Clipboard.get () in
    print_string s;
    if s <> "" && s.[String.length s - 1] <> '\n' then print_newline ()
  end;
  finish ()
