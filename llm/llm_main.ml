(* llm: ask a language model from the command line, through llmd
   (doc/decisions/llm.md):

     llm QUESTION...                  the default profile's answer
     llm -p PROFILE QUESTION...       another profile's (see llm -l)
     llm -s SYSTEM QUESTION...        with a system prompt
     llm -v QUESTION...               the model and the tokens too
     llm -l                           the profiles in /disk/llm.env
     llm                              the question from the input *)

let usage () =
  prerr_endline "usage: llm [-p PROFILE] [-s SYSTEM] [-v] QUESTION... | llm -l";
  exit 2

let () =
  let profile = ref "" and system = ref "" and verbose = ref false
  and list = ref false and words = ref [] in
  let rec args = function
    | "-p" :: p :: rest -> profile := p; args rest
    | "-s" :: s :: rest -> system := s; args rest
    | "-v" :: rest -> verbose := true; args rest
    | "-l" :: rest -> list := true; args rest
    | w :: _ when String.length w > 1 && w.[0] = '-' && !words = [] -> usage ()
    | w :: rest -> words := w :: !words; args rest
    | [] -> () in
  args (List.tl (Array.to_list Sys.argv));
  match
    let l = Llm.connect () in
    if !list then
      List.iteri (fun i (name, api, model) ->
          Printf.printf "%s%s\t%s\t%s\n" name (if i = 0 then " (default)" else "") api model)
        (Llm.call l Llm.Profiles)
    else begin
      let q = match List.rev !words with
        | [] -> In_channel.input_all stdin
        | ws -> String.concat " " ws in
      let a = Llm.call l (Llm.Chat { Llm.chat with profile = !profile; system = !system;
                                                   messages = [ Llm.user q ] }) in
      let t = Llm.text a in
      print_string t;
      if t <> "" && t.[String.length t - 1] <> '\n' then print_newline ();
      (match a.stop with
       | Llm.Max_tokens -> prerr_endline "llm: (cut: the answer reached max_tokens)"
       | Refusal -> prerr_endline "llm: (the model declined)"
       | _ -> ());
      if !verbose then
        Printf.eprintf "llm: %s, %d tokens in, %d out\n" a.model a.input_tokens a.output_tokens
    end
  with
  | () -> ()
  | exception Ipc.Remote_error (_, m) -> prerr_endline ("llm: " ^ m); exit 1
  | exception Mynos.Error _ -> prerr_endline "llm: no llm service (llmd)"; exit 1
