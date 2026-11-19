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
    } in
    Tmachine.set_size t.trm (80, 25);
    at_exit (fun () -> release t);
    write t;
    t

  let image t i = Tmachine.image t.trm i; write t
  let cursor t c = Tmachine.cursor t.trm c; write t
  let refresh t = Tmachine.refresh t.trm; write t
  let size t = Tmachine.size t.trm

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
        Unescape.input t.flt t.ibuf 0 n;
        event t
end
