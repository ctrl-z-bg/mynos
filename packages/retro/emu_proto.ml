(* emu/1 (emu_proto.mli; doc/decisions/retro-emulators.md, section 5). *)

type space = Cpu | Ram | Vram | Rom
type kind = Exec | Read | Write
type breakpoint = { id : int; kind : kind; addr : int; len : int }
type stop = Running | Paused of int | Hit of int * int * int

type info = {
  machine : string; rom : string; loaded : string; frame : int; fps : float;
  paused : bool; key_names : string;
}

type _ request =
  | Info : info request
  | Regs : (string * int) list request
  | Peek : space * int * int -> int list request
  | Disasm : int * int -> string request
  | Screen_text : string request
  | Screenshot : string request
  | Pause : stop request
  | Resume : unit request
  | Step : int -> stop request
  | Frames : int -> stop request
  | Break : kind * int * int -> int request
  | Unbreak : int -> unit request
  | Breaks : breakpoint list request
  | Wait : float -> stop request
  | Keys : string -> unit request
  | Poke : space * int * int list -> unit request
  | Load : string -> string request
  | Save_state : string -> unit request
  | Load_state : string -> unit request
  | Reset : unit request

(* ---- codecs: names as text, for the Services window and the agent ---- *)

let space_c =
  Wire.conv
    (function Cpu -> "cpu" | Ram -> "ram" | Vram -> "vram" | Rom -> "rom")
    (function "cpu" -> Cpu | "ram" -> Ram | "vram" -> Vram | "rom" -> Rom
            | s -> raise (Wire.Error ("emu: no space " ^ s ^ " (cpu, ram, vram, rom)")))
    Wire.string

let kind_c =
  Wire.conv
    (function Exec -> "exec" | Read -> "read" | Write -> "write")
    (function "exec" -> Exec | "read" -> Read | "write" -> Write
            | s -> raise (Wire.Error ("emu: no kind " ^ s ^ " (exec, read, write)")))
    Wire.string

let breakpoint_c =
  Wire.conv
    (fun b -> (b.id, b.kind), (b.addr, b.len))
    (fun ((id, kind), (addr, len)) -> { id; kind; addr; len })
    Wire.(pair (pair (field "id" int) (field "kind" kind_c))
            (pair (field "addr" int) (field "len" int)))

let stop_c =
  Wire.(variant [
      case ~name:"running" 0 unit (fun () -> Running) (function Running -> Some () | _ -> None);
      case ~name:"paused" 1 (field "pc" int) (fun pc -> Paused pc)
        (function Paused pc -> Some pc | _ -> None);
      case ~name:"hit" 2 (triple (field "id" int) (field "pc" int) (field "addr" int))
        (fun (id, pc, a) -> Hit (id, pc, a)) (function Hit (i, p, a) -> Some (i, p, a) | _ -> None) ])

let info_c =
  Wire.conv
    (fun i -> (i.machine, i.rom, i.loaded), (i.frame, i.fps, i.paused), i.key_names)
    (fun ((machine, rom, loaded), (frame, fps, paused), key_names) ->
       { machine; rom; loaded; frame; fps; paused; key_names })
    Wire.(triple (triple (field "machine" string) (field "rom" string) (field "loaded" string))
            (triple (field "frame" int) (field "fps" float) (field "paused" bool))
            (field "key_names" string))

let addr_f = Wire.(field "addr" int)
let peek_args = Wire.(triple (field "space" space_c) addr_f (field "len" int))
let disasm_args = Wire.(pair addr_f (field "n" int))
let break_args = Wire.(triple (field "kind" kind_c) addr_f (field "len" int))
let poke_args = Wire.(triple (field "space" space_c) addr_f (field "bytes" (list int)))
let file_f = Wire.(field "file" string)

module Protocol = struct
  let id = "emu/1"
  let summary =
    "An emulated machine (a ZX Spectrum, a Game Boy...): its registers, memory and \
     screen read; paused, stepped, run for frames; breakpoints and watchpoints; keys \
     pressed; tapes, snapshots and cartridges loaded; its state saved."
  let requests = Ipc.[
      request ~safe:true 0 "info"
        "The machine, its ROM, what was loaded, the frame, frames a second, paused or \
         not, the names of its keys." Wire.unit info_c;
      request ~safe:true 1 "regs" "The CPU's registers, by name." Wire.unit
        Wire.(list (pair (field "name" string) (field "value" int)));
      request ~safe:true 2 "peek"
        "len bytes (up to 4096) from addr: space cpu (as the CPU sees it), ram, vram \
         (a video chip's own), rom." peek_args Wire.(list int);
      request ~safe:true 3 "disasm" "n instructions from addr, a line each: address, \
                                     bytes, text." disasm_args Wire.string;
      request ~safe:true 4 "screen_text"
        "The screen as text, a line a row; ? where a cell is not a character." Wire.unit
        Wire.string;
      request ~safe:true 5 "screenshot"
        "The screen as a PNG in /tmp, named after the service and the frame: its path."
        Wire.unit Wire.string;
      request 6 "pause" "Pause the machine: where it stopped." Wire.unit stop_c;
      request 7 "resume" "Let it run." Wire.unit Wire.unit;
      request 8 "step" "Run n instructions (pausing it first): where it stopped."
        Wire.(field "n" int) stop_c;
      request 9 "frames"
        "Run n frames as fast as it can (pausing it first), then pause: where it stopped \
         (hit: a breakpoint stopped it)." Wire.(field "n" int) stop_c;
      request 10 "break"
        "A breakpoint (kind exec: an instruction at addr about to run) or a watchpoint \
         (read, write: len bytes from addr): its id." break_args Wire.int;
      request 11 "unbreak" "Remove a breakpoint." Wire.(field "id" int) Wire.unit;
      request 12 "breaks" "The breakpoints." Wire.unit (Wire.list breakpoint_c);
      request 13 "wait"
        "Wait at most seconds until a breakpoint is hit or the machine pauses: where \
         it stopped (running: the time ran out)." Wire.(field "seconds" float) stop_c;
      request 14 "keys"
        "Press the machine's keys: groups separated by spaces, a group names joined \
         by +, held 2 frames (or :n frames: CS+0:5), let go for a frame between. On a \
         Spectrum \"P 2 SS+K 2 ENTER\" types PRINT 2+2. Returns once typed; an error \
         if paused."
        Wire.(field "keys" string) Wire.unit;
      request 15 "poke" "Write bytes from addr (space cpu, ram, vram; not rom)."
        poke_args Wire.unit;
      request 16 "load" "Load a file (a tape, a snapshot, a cartridge): what it was."
        file_f Wire.string;
      request 17 "save_state" "Save the machine's state to a file (the machine's own \
                               format: a Spectrum's .z80 or .sna)." file_f Wire.unit;
      request 18 "load_state" "Restore a state saved." file_f Wire.unit;
      request 19 "reset" "Reset the machine." Wire.unit Wire.unit ]

  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    let case n = Wire.write w Wire.int n in
    match r with
    | Info -> case 0
    | Regs -> case 1
    | Peek (s, a, n) -> case 2; Wire.write w peek_args (s, a, n)
    | Disasm (a, n) -> case 3; Wire.write w disasm_args (a, n)
    | Screen_text -> case 4
    | Screenshot -> case 5
    | Pause -> case 6
    | Resume -> case 7
    | Step n -> case 8; Wire.write w Wire.int n
    | Frames n -> case 9; Wire.write w Wire.int n
    | Break (k, a, n) -> case 10; Wire.write w break_args (k, a, n)
    | Unbreak id -> case 11; Wire.write w Wire.int id
    | Breaks -> case 12
    | Wait s -> case 13; Wire.write w Wire.float s
    | Keys k -> case 14; Wire.write w Wire.string k
    | Poke (s, a, b) -> case 15; Wire.write w poke_args (s, a, b)
    | Load f -> case 16; Wire.write w file_f f
    | Save_state f -> case 17; Wire.write w file_f f
    | Load_state f -> case 18; Wire.write w file_f f
    | Reset -> case 19

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Info
    | 1 -> Request Regs
    | 2 -> let s, a, n = Wire.read r peek_args in Request (Peek (s, a, n))
    | 3 -> let a, n = Wire.read r disasm_args in Request (Disasm (a, n))
    | 4 -> Request Screen_text
    | 5 -> Request Screenshot
    | 6 -> Request Pause
    | 7 -> Request Resume
    | 8 -> Request (Step (Wire.read r Wire.int))
    | 9 -> Request (Frames (Wire.read r Wire.int))
    | 10 -> let k, a, n = Wire.read r break_args in Request (Break (k, a, n))
    | 11 -> Request (Unbreak (Wire.read r Wire.int))
    | 12 -> Request Breaks
    | 13 -> Request (Wait (Wire.read r Wire.float))
    | 14 -> Request (Keys (Wire.read r Wire.string))
    | 15 -> let s, a, b = Wire.read r poke_args in Request (Poke (s, a, b))
    | 16 -> Request (Load (Wire.read r file_f))
    | 17 -> Request (Save_state (Wire.read r file_f))
    | 18 -> Request (Load_state (Wire.read r file_f))
    | 19 -> Request Reset
    | n -> raise (Wire.Error (Printf.sprintf "emu: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Info -> info_c
    | Regs -> Wire.(list (pair string int))
    | Peek _ -> Wire.(list int)
    | Disasm _ -> Wire.string
    | Screen_text -> Wire.string
    | Screenshot -> Wire.string
    | Pause -> stop_c
    | Resume -> Wire.unit
    | Step _ -> stop_c
    | Frames _ -> stop_c
    | Break _ -> Wire.int
    | Unbreak _ -> Wire.unit
    | Breaks -> Wire.list breakpoint_c
    | Wait _ -> stop_c
    | Keys _ -> Wire.unit
    | Poke _ -> Wire.unit
    | Load _ -> Wire.string
    | Save_state _ -> Wire.unit
    | Load_state _ -> Wire.unit
    | Reset -> Wire.unit
end

module I = Ipc.Make (Protocol)

let find prefix =
  let n = String.length prefix in
  let digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s in
  List.filter_map (fun (name, _, _) ->
      if String.length name > n && String.sub name 0 n = prefix
         && digits (String.sub name n (String.length name - n))
      then Some name else None)
    (Mynos.registered ())
