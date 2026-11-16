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
  print_endline (if !ok then "mynos-ocaml: all checks passed"
                 else "mynos-ocaml: SOME CHECKS FAILED")
