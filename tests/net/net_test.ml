(* Network test (mynos-4f6): init.byte starts netd (lwIP and the NE2000
   driver) and talks to it through module Net (typed IPC). tools/run-tests.sh
   runs QEMU with an NE2000 on its user network, a TCP server on the host
   (port 47001: it answers with the line it got, in capitals), a client
   on the host that connects to port 80 here, forwarded from 47080, and
   HTTPS servers (mynos-dhp, tls/): 47443 with a certificate from the test
   authority, which netd trusts (cacert.pem on this RAM disk), 47444 from
   another authority, 47445 for another name. *)

let check what ok =
  Printf.printf "net: %-40s %s\n%!" what (if ok then "ok" else "FAIL");
  ok

module NI = Ipc.Make (Net.Protocol)

let error = function Ipc.Remote_error (_, m) -> m | e -> Printexc.to_string e

let rec recv_all n s acc =
  match Net.call n (Net.Recv (s, 4096)) with
  | "" -> acc
  | data -> recv_all n s (acc ^ data)

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in
  ignore (Mynos.spawn ~io:true "netd" [| "netd" |]);
  let n = Net.connect () in
  let c = Net.call n Net.Config in
  Printf.printf "net: %s address %s netmask %s gateway %s dns %s\n%!"
    c.Net.mac c.address c.netmask c.gateway c.dns;
  ok &&& check "an address from DHCP" (c.address = "10.0.2.15" && c.gateway = "10.0.2.2");
  ok &&& check "ping the gateway"
    (match Net.call n (Net.Ping ("10.0.2.2", 2000)) with
     | ms -> Printf.printf "net: round trip %d ms\n" ms; true
     | exception e -> print_endline (error e); false);
  ok &&& check "a ping nobody answers times out"
    (match Net.call n (Net.Ping ("10.0.2.99", 300)) with
     | _ -> false
     | exception Ipc.Remote_error (_, "timeout") -> true);
  (* out: a connection to the host *)
  ok &&& check "TCP to the host and back"
    (match Net.call n (Net.Connect ("10.0.2.2", 47001)) with
     | s ->
       ignore (Net.call n (Net.Send (s, "hello from mynos\n")));
       let answer = recv_all n s "" in
       Net.call n (Net.Close s);
       print_string ("net: the host says: " ^ answer);
       answer = "HELLO FROM MYNOS\n"
     | exception e -> print_endline (error e); false);
  ok &&& check "Recv with a timeout"
    (match Net.call n (Net.Connect ("10.0.2.2", 47001)) with
     | s ->
       Net.call n (Net.Set_timeout (s, 300));
       (* the host's server waits for a whole line: nothing comes *)
       let r = (match Net.call n (Net.Recv (s, 100)) with
           | _ -> false
           | exception Ipc.Remote_error (_, "timeout") -> true) in
       Net.call n (Net.Close s);
       r
     | exception e -> print_endline (error e); false);
  ok &&& check "a refused connection is an error"
    (match Net.call n (Net.Connect ("10.0.2.2", 47002)) with
     | _ -> false
     | exception Ipc.Remote_error (_, m) -> print_endline ("net: " ^ m); true);
  (* in: the host connects to us *)
  ok &&& check "a server: the host connects to port 80"
    (match Net.call n (Net.Listen 80) with
     | l ->
       let s, peer, port = Net.call n (Net.Accept l) in
       Printf.printf "net: connection from %s:%d\n%!" peer port;
       let request = Net.call n (Net.Recv (s, 4096)) in
       let body = "hello from a server in MyNOS\n" in
       ignore (Net.call n (Net.Send (s, "HTTP/1.0 200 OK\r\nContent-Length: "
                                         ^ string_of_int (String.length body)
                                         ^ "\r\n\r\n" ^ body)));
       Net.call n (Net.Close s);
       Net.call n (Net.Close l);
       String.length request > 0
     | exception e -> print_endline (error e); false);
  (* TLS *)
  ok &&& check "HTTPS: a POST, a chunked answer"
    (match Http.post ~net:n ~body:"hello tls" "https://10.0.2.2:47443/echo" with
     | r ->
       Printf.printf "net: %d %s, %S\n%!" r.Http.status r.reason r.body;
       r.status = 200 && r.body = "POST /echo HELLO TLS"
     | exception e -> print_endline ("net: " ^ (match e with Http.Error m -> m | e -> error e)); false);
  let refused_tls port what =
    match Net.call n (Net.Connect_tls ("10.0.2.2", port)) with
    | s -> Net.call n (Net.Close s); false
    | exception Ipc.Remote_error (_, m) ->
      Printf.printf "net: %s\n%!" m;
      String.length m > 5 && String.sub m 0 5 = "TLS: "
      && (let rec has i = i + String.length what <= String.length m
                          && (String.sub m i (String.length what) = what || has (i + 1)) in
          has 0) in
  ok &&& check "TLS: an unknown authority is refused" (refused_tls 47444 "trusted CA");
  ok &&& check "TLS: a certificate for another name is refused" (refused_tls 47445 "CN");
  (* UDP *)
  ok &&& check "UDP to the host and back"
    (match Net.call n (Net.Udp_bind 0) with
     | u ->
       Net.call n (Net.Set_timeout (u, 3000));
       ignore (Net.call n (Net.Send_to (u, "10.0.2.2", 47053, "hello udp")));
       let a, p, d = Net.call n (Net.Recv_from (u, 100)) in
       Printf.printf "net: %s:%d says %S\n%!" a p d;
       Net.call n (Net.Close u);
       a = "10.0.2.2" && p = 47053 && d = "HELLO UDP"
     | exception e -> print_endline (error e); false);
  (* BSD sockets from a C program (libmynos, mynos-t9l) *)
  ok &&& check "C sockets: TCP, UDP, a server (tests/net/sockets.c)"
    (match Mynos.spawn "sockets" [| "sockets" |] with
     | pid -> Mynos.wait pid = Mynos.Exited 0
     | exception e -> print_endline (error e); false);
  ok &&& check "OCaml's Unix sockets (the same library)"
    (match Mynos.spawn "ocamlrun" [| "ocamlrun"; "net_child.byte"; "unix" |] with
     | pid -> Mynos.wait pid = Mynos.Exited 0
     | exception e -> print_endline (error e); false);
  (* sockets belong to their process (doc/decisions/identity-and-permissions.md) *)
  let child args =
    match Mynos.spawn "ocamlrun" (Array.append [| "ocamlrun"; "net_child.byte" |] args) with
    | pid -> Mynos.wait pid
    | exception e -> print_endline (error e); Mynos.Exited 99 in
  ok &&& check "another process cannot close our socket"
    (let u = Net.call n (Net.Udp_bind 0) in
     let r = child [| "close"; string_of_int u |] in
     Net.call n (Net.Close u);
     r = Mynos.Exited 0);
  ok &&& check "the sockets of a process that ended are closed"
    (child [| "listen"; "8082" |] = Mynos.Exited 0
     && (Mynos.sleep 1.5;
         match Net.call n (Net.Listen 8082) with
         | l -> Net.call n (Net.Close l); true
         | exception e -> print_endline ("net: " ^ error e); false));
  (* a malformed message: an error reply, and the service goes on *)
  let raw msg =
    let ch = Mynos.connect (Mynos.lookup "net") in
    Mynos.send ch msg;
    let r = Mynos.recv ch in
    Mynos.free_channel ch;
    r in
  let refused m = match NI.read_reply (raw m) Net.Config with
    | _ -> false | exception Ipc.Remote_error _ -> true in
  ok &&& check "malformed requests get an error"
    (List.for_all refused [ "\255"; "\010net/2\000"; "\010net/1\040";
                            "\010net/1\002\200" ]);
  ok &&& check "and netd goes on" ((Net.call n Net.Config).address = c.address);
  (* language models (doc/decisions/llm.md): llmd with three profiles on
     the host's fake provider (tools/net-peer.py llm 47090), one per API
     and one with a wrong key *)
  ignore (Mynos.spawn "ocamlrun" [| "ocamlrun"; "llmd.byte"; "/llm-test.env" |]);
  let l = Llm.connect () in
  ok &&& check "llm: the profiles, the default first"
    (match Llm.call l Llm.Profiles with
     | ps -> ps = [ ("claude", "anthropic", "fake-claude"); ("local", "openai", "fake-local");
                    ("bad_key", "anthropic", "fake-claude") ]
     | exception e -> print_endline (error e); false);
  let asks profile =
    match Llm.ask ~profile ~system:"be brief" l "hello" with
    | a -> a = "echo: hello (system: be brief)"
    | exception e -> print_endline ("net: " ^ error e); false in
  ok &&& check "llm: a question (Claude's API)" (asks "");
  ok &&& check "llm: a question (Chat Completions)" (asks "local");
  (* a tool loop: the model calls the tool, gets its result, answers *)
  let tool_loop profile =
    let tool = { Llm.name = "shout"; description = "Says a text in capitals";
                 schema = {|{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}|} } in
    let c = { Llm.chat with profile; tools = [ tool ]; messages = [ Llm.user "quiet" ] } in
    match Llm.call l (Llm.Chat c) with
    | { Llm.stop = Tool_use; content; _ } as a1 ->
      let results = List.filter_map (function
          | Llm.Tool_call { id; name = "shout"; input } ->
            let text = Json.(member "text" (of_string input) |> to_string_value) in
            Some (Llm.Tool_result { id; content = String.uppercase_ascii text; error = false })
          | _ -> None) content in
      let c = { c with messages = c.messages @ [ { Llm.role = Assistant; content };
                                                 { role = User; content = results } ] } in
      (match Llm.call l (Llm.Chat c) with
       | a2 -> a2.stop = End && Llm.text a2 = "tool said: QUIET"
               && a1.input_tokens > 0 && a1.model <> ""
       | exception e -> print_endline ("net: " ^ error e); false)
    | _ -> print_endline "net: no tool call"; false
    | exception e -> print_endline ("net: " ^ error e); false in
  ok &&& check "llm: a tool loop (Claude's API)" (tool_loop "claude");
  ok &&& check "llm: a tool loop (Chat Completions)" (tool_loop "local");
  ok &&& check "llm: a provider's error is the call's"
    (match Llm.ask ~profile:"bad_key" l "hello" with
     | _ -> false
     | exception Ipc.Remote_error (_, m) -> print_endline ("net: " ^ m);
       m = "bad_key: 401 authentication_error: invalid x-api-key");
  ok &&& check "llm: an unknown profile"
    (match Llm.ask ~profile:"nope" l "hello" with
     | _ -> false | exception Ipc.Remote_error _ -> true);
  (* protocols that describe themselves (mynos-wsd.2): netd (C) and llmd
     (OCaml) answer "describe"; their requests, called from JSON *)
  let structure (rs : Ipc.request_doc list) =
    List.map (fun (r : Ipc.request_doc) -> (r.case, r.name, r.args, r.reply, r.safe)) rs in
  ok &&& check "describe: netd's protocol is net.ml's"
    (match Ipc.describe "net" with
     | d -> d.Ipc.protocol = "net/1"
            && structure d.requests = structure Net.Protocol.requests
     | exception e -> print_endline (error e); false);
  ok &&& check "describe: llmd's"
    (match Ipc.describe "llm" with
     | d -> d.Ipc.protocol = "llm/1" && d.requests = Llm.Protocol.requests
     | exception e -> print_endline (error e); false);
  let tools = (try Tools.of_service "net" @ Tools.of_service "llm"
               with e -> print_endline (error e); []) in
  let tool_call name input =
    match Tools.call (Tools.find tools name) input with
    | out -> print_endline ("net: " ^ name ^ " " ^ input ^ " -> " ^ out); Ok out
    | exception (Ipc.Remote_error (_, m) | Failure m) -> Error m
    | exception e -> Error (error e) in
  ok &&& check "tools: 16 requests of 2 services, as tools"
    (List.length tools = 16
     && (Tools.find tools "net_ping").tool.Llm.schema
        = {|{"type":"object","properties":{"address":{"type":"string"},"timeout_ms":{"type":"integer"}},"required":["address","timeout_ms"]}|});
  ok &&& check "tools: net_config from JSON"
    (match tool_call "net_config" "{}" with
     | Ok out -> Json.(member "address" (of_string out) |> to_string_value) = "10.0.2.15"
     | Error m -> print_endline m; false);
  ok &&& check "tools: net_ping"
    (match tool_call "net_ping" {|{"address": "10.0.2.2", "timeout_ms": 2000}|} with
     | Ok out -> int_of_string_opt out <> None | Error m -> print_endline m; false);
  ok &&& check "tools: a service's error"
    (tool_call "net_close" {|{"socket": 9999}|} = Error "not a socket"
     || (print_endline "net: close 9999"; false));
  ok &&& check "tools: arguments that do not fit"
    (match tool_call "net_ping" {|{"address": 5, "timeout_ms": 1}|} with
     | Error m -> String.starts_with ~prefix:"expected" m | Ok _ -> false);
  ok &&& check "tools: llm_chat from JSON (lists, variants, records)"
    (match tool_call "llm_chat"
             {|{"profile": "local", "system": "", "max_tokens": 0, "tools": [],
                "messages": [{"assistant": false, "content": [{"text": "hi"}]}]}|} with
     | Ok out ->
       let j = Json.of_string out in
       Json.(member "stop" j) = Json.String "end"
       && Json.(member "content" j |> index 0 |> member "text" |> to_string_value) = "echo: hi"
     | Error m -> print_endline m; false);
  (* ask in sh (mynos-wsd.1): the fake model proposes the request itself as
     the command; it runs only when the answer read is "y" (from a file
     here, a key on the console). Its output, "asked-ok", is not in the
     command shown, so tools/run-tests.sh can tell that it ran. *)
  let ask profile answer_file =
    let request = "X=ok; echo asked-$X" in
    match Mynos.spawn ~env:[| "MYNOS_STDIN=" ^ answer_file; "PATH=/" |] "ocamlrun"
            [| "ocamlrun"; "sh.byte"; "-c"; "ask -p " ^ profile ^ " '" ^ request ^ "'" |] with
    | pid -> Mynos.wait pid
    | exception e -> print_endline (error e); Mynos.Exited 99 in
  ok &&& check "ask: a command proposed and run (Claude's API)"
    (ask "claude" "/ask-yes.txt" = Mynos.Exited 0);
  ok &&& check "ask: and with Chat Completions" (ask "local" "/ask-yes.txt" = Mynos.Exited 0);
  ok &&& check "ask: not run without a yes" (ask "claude" "/ask-no.txt" = Mynos.Exited 1);
  (* the agent (mynos-wsd.3): the fake model calls its first tool,
     run_command, with the task as the command, then reports the result.
     The commands write "agent-ran" and "agent-local", which the tasks do
     not contain: tools/run-tests.sh looks for them. *)
  ignore (Mynos.spawn "ocamlrun" [| "ocamlrun"; "tmpfs.byte" |]);
  Mynos.sleep 0.5;
  let agent args answers =
    match Mynos.spawn ~env:[| "MYNOS_STDIN=" ^ answers; "PATH=/" |] "ocamlrun"
            (Array.append [| "ocamlrun"; "agent.byte" |] args) with
    | pid -> Mynos.wait pid
    | exception e -> print_endline (error e); Mynos.Exited 99 in
  ok &&& check "agent: a command confirmed, run, reported"
    (agent [| "-p"; "claude"; "X=ran; echo agent-$X" |] "/ask-yes.txt" = Mynos.Exited 0);
  ok &&& check "agent: with -y, Chat Completions"
    (agent [| "-y"; "-p"; "local"; "Y=local; echo agent-$Y" |] "/ask-no.txt" = Mynos.Exited 0);
  ok &&& check "agent: the recorder saw it call llmd, and llmd netd"
    (match Tracer.load "/tmp/agent.trc" with
     | r ->
       let calls = Tracer.calls r in
       List.exists (fun c -> String.starts_with ~prefix:"llm/1 Chat \"local\"" c.Tracer.request) calls
       && List.exists (fun c -> String.starts_with ~prefix:"net/1 Connect" c.Tracer.request) calls
     | exception e -> print_endline (error e); false);
  ok &&& check "agent: a command refused is not run"
    (agent [| "-p"; "claude"; "echo agent-$NOT_RUN" |] "/ask-no.txt" = Mynos.Exited 0);
  print_endline (if !ok then "net: all checks passed" else "net: FAIL")
