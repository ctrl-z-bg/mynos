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
  print_endline (if !ok then "net: all checks passed" else "net: FAIL")
