(* MyNOS backend for Notty (not part of Notty): a full-screen terminal on
   the MyNOS console, in the manner of Notty_unix.Term. The console is put
   in raw mode (Mynos.console_mode) while the terminal is open; output goes
   to stdout, whose VT100 sequences the kernel's screen driver interprets;
   input is read from stdin and decoded by Notty.Unescape.

   Copyright (C) 2026 MyNOS team. GPL v2 or later, as MyNOS. *)

open Notty

module Term = struct
  type t = {
    trm : Tmachine.t;
    buf : Buffer.t;
    flt : Unescape.t;
    ibuf : Bytes.t;
    mutable carry : string;   (* the start of a UTF-8 character cut by a read *)
  }

  let write t =
    Buffer.clear t.buf;
    Tmachine.output t.trm t.buf;
    print_string (Buffer.contents t.buf);
    flush stdout

  let release t =
    if Tmachine.release t.trm then begin
      write t;
      Mynos.console_mode ~canon:true ~echo:true ~isig:true ()
    end

  let create ?(mouse = false) () =
    Mynos.console_mode ~canon:false ~echo:false ~isig:false ();   (* Ctrl-C: a key *)
    let t = {
      trm = Tmachine.create ~mouse ~bpaste:false Cap.ansi;
      buf = Buffer.create 4096;
      flt = Unescape.create ();
      ibuf = Bytes.create 1024;
      carry = "";
    } in
    Tmachine.set_size t.trm (Console.size ());          (* a terminal window's, as it is *)
    at_exit (fun () -> release t);
    write t;
    t

  let image t i = Tmachine.image t.trm i; write t
  let cursor t c = Tmachine.cursor t.trm c; write t
  let refresh t = Tmachine.refresh t.trm; write t
  let size t = Tmachine.size t.trm

  (* how many bytes at the end of s begin a UTF-8 character not complete
     yet *)
  let incomplete_tail s =
    let n = String.length s in
    let rec back k =
      if k > 3 || k > n then 0
      else
        let c = Char.code s.[n - k] in
        if c land 0xC0 = 0x80 then back (k + 1)            (* a continuation *)
        else
          let need = if c land 0xE0 = 0xC0 then 2
            else if c land 0xF0 = 0xE0 then 3
            else if c land 0xF8 = 0xF0 then 4 else 1 in
          if need > k then k else 0 in
    if n = 0 then 0 else back 1

  let rec event t =
    if Tmachine.dead t.trm then `End
    else
      match Unescape.next t.flt with
      (* the console sends Enter as CR, as a raw terminal: Notty expects
         the LF that termios's ICRNL makes of it on Unix *)
      | `Key (`ASCII 'M', [`Ctrl]) -> `Key (`Enter, [])
      | #Unescape.event | `End as r -> r
      | `Await ->
        let n = input stdin t.ibuf 0 (Bytes.length t.ibuf) in
        (* a read may end inside a UTF-8 character (the serial terminal
           sends one byte at a time): its first bytes wait for the rest,
           which Unescape would otherwise take for malformed input *)
        let s = t.carry ^ Bytes.sub_string t.ibuf 0 n in
        let keep = incomplete_tail s in
        let whole = String.length s - keep in
        t.carry <- String.sub s whole keep;
        if n = 0 then Unescape.input t.flt t.ibuf 0 0          (* the end *)
        else if whole > 0 then Unescape.input t.flt (Bytes.of_string s) 0 whole;
        (* (only the start of a character: read on) *)
        event t
end
