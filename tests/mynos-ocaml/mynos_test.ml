(* The Mynos OCaml library on MyNOS: processes, semaphores, sleeping, and
   an OCaml client of the memrofs service (C), over IPC. *)

let check what ok =
  Printf.printf "mynos-ocaml: %-34s %s\n%!" what (if ok then "ok" else "FAIL");
  ok

(* file service protocol (mynos-lib/include/mynos_fs.h): an 84-byte
   struct fs_req { int type, client, fd, arg1, arg2; char name[64]; }
   and an 8-byte struct fs_reply { int status, value; } *)
let request typ fill =
  let b = Bytes.make 84 '\000' in
  Bytes.set_int32_le b 0 (Int32.of_int typ);
  Bytes.set_int32_le b 4 (Int32.of_int (Mynos.getpid ()));
  fill b; Bytes.to_string b
let int32_at s i = Int32.to_int (String.get_int32_le s i)

let memrofs_call port req =
  let ch = Mynos.connect port in
  Mynos.send ch req;
  let reply = Mynos.recv ~timeout:2.0 ch in
  ch, reply

let read_file name =
  let port = Mynos.lookup "memrofs" in
  (* OPEN *)
  let ch, r = memrofs_call port (request 0 (fun b ->
    Bytes.blit_string name 0 b 20 (String.length name))) in
  Mynos.free_channel ch;
  let status = int32_at r 0 and fd = int32_at r 4 in
  if status <> 0 then failwith (Printf.sprintf "open: status %d" status);
  (* READ: a reply { status; n }, then the data *)
  let ch, r = memrofs_call port (request 2 (fun b ->
    Bytes.set_int32_le b 8 (Int32.of_int fd);
    Bytes.set_int32_le b 12 100l)) in
  let status = int32_at r 0 and rd = int32_at r 4 in
  if status <> 0 then failwith (Printf.sprintf "read: status %d" status);
  let data = Mynos.recv ~timeout:2.0 ch in
  Mynos.free_channel ch;
  String.sub data 0 rd

let () =
  let ok = ref true in
  let ( &&& ) r b = r := !r && b in
  let pid = Mynos.getpid () in
  ok &&& check "getpid" (pid > 0);
  let st = Mynos.stats () in
  Printf.printf "mynos-ocaml: %d processes, %d threads, %d free pages\n"
    st.processes st.threads st.free_pages;
  ok &&& check "stats" (st.processes > 0 && st.free_pages > 0);
  let s = Mynos.sem_create 1 in
  ok &&& check "semaphore try_p on 1" (Mynos.sem_try_p s);
  ok &&& check "semaphore try_p on 0" (not (Mynos.sem_try_p s));
  Mynos.sem_v s; Mynos.sem_p s; Mynos.sem_free s;
  ok &&& check "semaphore v/p/free" true;
  Mynos.sleep 0.1;
  ok &&& check "sleep" true;
  (* port I/O from OCaml: the CMOS clock's seconds (BCD) and its status
     register A, whose low bits are the rate divider set by the BIOS *)
  Mynos.outb 0x70 0x00;
  let sec = Mynos.inb 0x71 in
  Mynos.outb 0x70 0x0A;
  let rega = Mynos.inb 0x71 in
  ok &&& check "port I/O (CMOS clock)"
    (sec lsr 4 < 6 && sec land 0xF < 10 && rega land 0x0F <> 0);
  (match Mynos.lookup "nosuchservice" with
   | _ -> ok &&& check "lookup of a missing service fails" false
   | exception Mynos.Error (_, _) ->
       ok &&& check "lookup of a missing service fails" true);
  (match read_file "AUTOEXEC.BAT" with
   | text ->
       print_string text;
       ok &&& check "read a file through memrofs" true
   | exception e ->
       print_endline (Printexc.to_string e);
       ok &&& check "read a file through memrofs" false);
  (* typed IPC: the wire format *)
  let round c x = Wire.of_string c (Wire.to_string c x) = x in
  let malformed c s = match Wire.of_string c s with
    | _ -> false | exception Wire.Error _ -> true in
  ok &&& check "wire: ints round trip"
    (List.for_all (round Wire.int)
       [ 0; 1; -1; 63; -64; 64; 300; -300; max_int; min_int; 123456789 ]);
  ok &&& check "wire: small ints take one byte"
    (String.length (Wire.to_string Wire.int 63) = 1
     && String.length (Wire.to_string Wire.int (-64)) = 1
     && Wire.to_string Wire.int (-1) = "\001");
  ok &&& check "wire: strings, floats, lists, options, results"
    (round Wire.string "" && round Wire.string (String.make 5000 'x')
     && round Wire.float 3.25 && round Wire.float (-0.0)
     && round Wire.(list (pair int string)) [ (1, "a"); (-2, "") ]
     && round Wire.(array bool) [| true; false |]
     && round Wire.(option (triple int unit string)) (Some (7, (), "z"))
     && round Wire.(result int string) (Error "e")
     && round Wire.(result int string) (Ok 4));
  let tree = Wire.fix (fun tree ->
      Wire.(variant [
          case 0 int (fun n -> `Leaf n) (function `Leaf n -> Some n | _ -> None);
          case 1 (pair tree tree) (fun (a, b) -> `Node (a, b))
            (function `Node (a, b) -> Some (a, b) | _ -> None) ])) in
  ok &&& check "wire: a recursive variant"
    (round tree (`Node (`Leaf 1, `Node (`Leaf (-2), `Leaf 3))));
  ok &&& check "wire: malformed messages are refused"
    (malformed Wire.int "" && malformed Wire.int "\128"
     && malformed Wire.string "\010abc"         (* 5 bytes announced *)
     && malformed Wire.(list int) "\254\255\255\255\007"
     && malformed Wire.bool "\002" && malformed Wire.int "\001\001"
     && malformed Wire.(result int string) "\004");
  ok &&& check "wire: an int too large for 31 bits is refused"
    (Sys.int_size > 31
     || malformed Wire.int "\128\128\128\128\128\001");
  (* typed IPC: every request of the block protocol, through the encoding
     and a handler, and its reply back *)
  let disk = Bytes.make (4 * 512) 'd' in
  let h = { Block.handle = fun (type a) _ (r : a Block.request) : a ->
      match r with
      | Block.Info -> 4
      | Block.Read (lba, n) ->
        if lba < 0 || n < 1 || lba + n > 4 then invalid_arg "out of range";
        Bytes.sub_string disk (lba * 512) (n * 512)
      | Block.Write (lba, s) -> Bytes.blit_string s 0 disk (lba * 512)
                                  (String.length s) } in
  let via r = Block.read_reply (Block.answer h (Block.request_message r)) r in
  ok &&& check "ipc: block requests round trip"
    (via Block.Info = 4
     && (via (Block.Write (1, String.make 512 'w')); true)
     && via (Block.Read (1, 1)) = String.make 512 'w'
     && String.length (via (Block.Read (0, 4))) = 2048);
  ok &&& check "ipc: an exception in the service is the client's error"
    (match via (Block.Read (3, 2)) with
     | _ -> false
     | exception Ipc.Remote_error (_, "out of range") -> true);
  ok &&& check "ipc: bad requests get an error reply"
    (List.for_all (fun msg ->
         match Block.read_reply (Block.answer h msg) Block.Info with
         | _ -> false | exception Ipc.Remote_error _ -> true)
        [ ""; "\014block/2\000";                  (* another version *)
          "\014block/1\018";                       (* request 9 *)
          "\014block/1\002\002";                  (* Read without count *)
          Block.request_message Block.Info ^ "x" ]);
  (* descriptions (mynos-wsd.2): shapes, a service's answer to "describe",
     and values written and read from JSON by shape *)
  ok &&& check "wire: shapes"
    (Wire.(shape (pair (field "a" int) (list (option string))))
     = Wire.(Tuple [ Named ("a", Int); List (Option String) ])
     && (match Wire.shape tree with
         | Wire.Rec ("t", Wire.Variant [ (0, "0", Wire.Int);
                                         (1, "1", Wire.Tuple [ Var "t"; Var "t" ]) ]) -> true
         | _ -> false));
  ok &&& check "ipc: a service describes its protocol"
    (match Wire.of_string (Wire.result Ipc.description_codec Wire.string)
             (Block.answer h (Wire.to_string Wire.string "describe")) with
     | Ok d -> d.Ipc.protocol = "block/1" && d.requests = Block.Protocol.requests
               && List.map (fun (r : Ipc.request_doc) -> r.name) d.requests
                  = [ "info"; "read"; "write" ]
     | Error _ -> false);
  let via_json shape json =
    let w = Wire.writer () in
    Tools.write_json shape w (Json.of_string json);
    Json.to_string (Tools.read_json shape (Wire.reader (Wire.contents w))) in
  ok &&& check "tools: values from JSON and back"
    (via_json Wire.(shape (pair (field "lba" int) (field "count" int))) {|{"count":2,"lba":7}|}
     = {|{"lba":7,"count":2}|}
     && via_json (Wire.shape tree) {|{"1":[{"0":1},{"1":[{"0":-2},{"0":3}]}]}|}
        = {|{"1":[{"0":1},{"1":[{"0":-2},{"0":3}]}]}|}
     && via_json Wire.(shape (list (option string))) {|["a",null]|} = {|["a",null]|}
     && via_json Wire.(shape (result int string)) {|{"error":"e"}|} = {|{"error":"e"}|});
  (* a service served by a second domain of this process, called from the
     first: each end of a channel has its own id (mynos-9e1; the ends were
     told apart by pid, and the call hung) *)
  let pid_seen = ref 0 in
  let h2 = { Block.handle = fun (type a) (c : Ipc.caller) (r : a Block.request) : a ->
      pid_seen := c.Ipc.pid; h.Block.handle c r } in
  ignore (Domain.spawn (fun () -> Block.serve "selftest-block" h2));
  let rec client n =
    match Block.connect ~service:"selftest-block" () with
    | b -> Some b
    | exception Mynos.Error _ when n > 0 -> Mynos.sleep 0.05; client (n - 1)
    | exception Mynos.Error _ -> None in
  ok &&& check "ipc: between two domains of a process"
    (match client 40 with
     | None -> false
     | Some b ->
       Block.sectors b = 4
       && Block.read b 1 1 = String.make 512 'w'
       && !pid_seen = pid);
  (* the caller of a request (doc/decisions/identity-and-permissions.md),
     given to the handler *)
  let who = { Block.handle = fun (type a) (c : Ipc.caller) (r : a Block.request) : a ->
      match r with
      | Block.Info -> c.Ipc.pid * 2 + (if c.io then 1 else 0)
      | _ -> invalid_arg "only Info" } in
  ok &&& check "ipc: the handler gets the caller"
    (Block.read_reply (Block.answer ~caller:{ Ipc.pid = 42; io = true } who
                         (Block.request_message Block.Info)) Block.Info = 85);
  (* the event recorder: an IPC exchange with the registry, recorded *)
  Tracer.start ();
  (try ignore (Mynos.lookup "tracedservice") with Mynos.Error _ -> ());
  let r = Tracer.stop_and_get () in
  let sends = Array.to_list r.Tracer.events
              |> List.filter (fun e -> e.Tracer.kind = Tracer.Send) in
  ok &&& check "trace: a request to the registry is recorded"
    (List.exists (fun e -> Tracer.describe r e = "registry LOOKUP \"tracedservice\"") sends);
  ok &&& check "trace: and its reply, as a call"
    (List.exists (fun c -> c.Tracer.request = "registry LOOKUP \"tracedservice\""
                           && c.reply <> "" && c.finish >= c.start)
       (Tracer.calls r));
  ok &&& check "trace: process names" (Tracer.name r 0 = "kernel(0)");
  (* JSON and HTTP's parsing (mynos-dhp) *)
  let j = {|{"a": [1, 2.5, -3e2, true, null], "s": "x\"\u00e8\ud83d\ude00\n", "o": {}}|} in
  ok &&& check "json: parse and print"
    (match Json.of_string j with
     | v ->
       Json.(member "a" v |> index 2 |> to_int) = -300
       && Json.(member "s" v |> to_string_value) = "x\"\xc3\xa8\xf0\x9f\x98\x80\n"
       && Json.(to_string (member "a" v)) = "[1,2.5,-300,true,null]"
       && Json.of_string (Json.to_string v) = v
     | exception Json.Error m -> print_endline m; false);
  ok &&& check "json: malformed text is refused"
    (List.for_all (fun t -> match Json.of_string t with
         | _ -> false | exception Json.Error _ -> true)
        [ ""; "{"; "[1,]"; "{\"a\" 1}"; "tru"; "\"abc"; "1 2"; "[01x]" ]);
  ok &&& check "http: URLs"
    (Http.parse_url "https://example.com/a?b" = (true, "example.com", 443, "/a?b")
     && Http.parse_url "http://10.0.2.2:8080" = (false, "10.0.2.2", 8080, "/")
     && (match Http.parse_url "ftp://x" with _ -> false | exception Http.Error _ -> true));
  ok &&& check "http: a chunked answer"
    (let r = Http.parse_response
         "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: b\r\n\r\n\
          5\r\nhello\r\n7;x=1\r\n, world\r\n0\r\n\r\n" in
     r.Http.status = 200 && r.body = "hello, world" && Http.header "x-a" r = Some "b");
  print_endline (if !ok then "mynos-ocaml: all checks passed"
                 else "mynos-ocaml: SOME CHECKS FAILED")
