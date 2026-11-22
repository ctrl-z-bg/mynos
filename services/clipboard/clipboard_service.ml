(* clipboard: the clipboard of MyNOS, a service (registered as
   "clipboard", protocol clipboard/1, module Clipboard): the text copied
   last, kept for any program to paste. init starts it at boot; it holds
   up to 1 MB, in memory, until the machine stops. *)

let text = ref ""

let () =
  Clipboard.serve "clipboard"
    { Clipboard.handle = fun (type a) _ (r : a Clipboard.request) : a ->
          match r with
          | Clipboard.Get -> !text
          | Clipboard.Set s ->
            if String.length s > 1048576 then failwith "more than 1 MB";
            text := s }
