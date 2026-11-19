(* netask: a question to a model that may use the network's safe
   requests (config, ping, resolve) as tools.  netask QUESTION *)

let tool_result tools = function
  | Llm.Tool_call { id; name; input } ->
    let content, error =
      match Tools.call (Tools.find tools name) input with
      | json -> (json, false)
      | exception Not_found -> ("no tool " ^ name, true)
      | exception (Ipc.Remote_error (_, m) | Failure m) -> (m, true) in
    Printf.printf "  [%s %s -> %s]\n%!" name input content;
    Some (Llm.Tool_result { id; content; error })
  | _ -> None

let () =
  let question = String.concat " " (List.tl (Array.to_list Sys.argv)) in
  let l = Llm.connect () in
  (* only what changes nothing: the requests marked safe *)
  let tools = List.filter (fun t -> t.Tools.request.Ipc.safe) (Tools.of_service "net") in
  let chat = { Llm.chat with
               system = "You answer questions about this machine's network.";
               tools = List.map (fun t -> t.Tools.tool) tools } in
  let rec turn n messages =
    let a = Llm.call l (Llm.Chat { chat with messages }) in
    let messages = messages @ [ { Llm.role = Assistant; content = a.content } ] in
    match a.stop with
    | Llm.Tool_use when n < 10 ->
      let results = List.filter_map (tool_result tools) a.content in
      turn (n + 1) (messages @ [ { Llm.role = User; content = results } ])
    | Llm.End | Llm.Tool_use -> print_endline (Llm.text a)
    | Llm.Max_tokens -> print_endline (Llm.text a ^ " [cut]")
    | Llm.Refusal -> print_endline "(the model declined)"
    | Llm.Other s -> Printf.printf "(stopped: %s)\n" s in
  match turn 1 [ Llm.user question ] with
  | () -> ()
  | exception Ipc.Remote_error (_, m) -> prerr_endline ("netask: " ^ m); exit 1
