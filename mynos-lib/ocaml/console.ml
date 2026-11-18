(* console/1, the protocol of the consoles: see console.mli. *)

type _ request =
  | Read : int -> string request
  | Mode : int * int * int -> unit request
  | Keymap : int -> int request
  | Write : string -> unit request
  | Foreground : int -> unit request

let canon = 1 and echo = 2 and nosig = 4
let layout_us = 0 and layout_it = 1

let mode_args = Wire.(triple (field "mode" int) (field "vmin" int) (field "vtime" int))

module Protocol = struct
  let id = "console/1"
  let summary =
    "A console: the keyboard and the screen of programs (consoled, the text \
     console; a terminal window's console). Line editing or keys one by one, \
     echo, Ctrl-C."
  let requests = Ipc.[
      request 0 "read"
        "Up to max bytes of input: a line in line mode, keys in raw mode; \"\" at \
         the end of the input (Ctrl-D, a hang-up) or when VTIME passes."
        Wire.(field "max" int) Wire.string;
      request 1 "mode"
        "The input mode: 1 line editing, 2 echo, 4 Ctrl-C is a key (not an \
         interrupt); vmin and vtime as termios VMIN and VTIME (raw mode)."
        mode_args Wire.unit;
      request 2 "keymap" "The keyboard layout: 0 us, 1 it (-1: unchanged); the one in use."
        Wire.(field "layout" int) Wire.int;
      request 3 "write" "Output, to the screen." Wire.(field "data" string) Wire.unit;
      request 4 "foreground"
        "The program the caller waits for (one of its children; 0: none): Ctrl-C \
         ends it."
        Wire.(field "pid" int) Wire.unit ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    let case n = Wire.write w Wire.int n in
    match r with
    | Read n -> case 0; Wire.write w Wire.int n
    | Mode (m, vmin, vtime) -> case 1; Wire.write w mode_args (m, vmin, vtime)
    | Keymap l -> case 2; Wire.write w Wire.int l
    | Write s -> case 3; Wire.write w Wire.string s
    | Foreground p -> case 4; Wire.write w Wire.int p

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request (Read (Wire.read r Wire.int))
    | 1 -> let m, vmin, vtime = Wire.read r mode_args in Request (Mode (m, vmin, vtime))
    | 2 -> Request (Keymap (Wire.read r Wire.int))
    | 3 -> Request (Write (Wire.read r Wire.string))
    | 4 -> Request (Foreground (Wire.read r Wire.int))
    | n -> raise (Wire.Error (Printf.sprintf "console: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Read _ -> Wire.string
    | Mode _ -> Wire.unit
    | Keymap _ -> Wire.int
    | Write _ -> Wire.unit
    | Foreground _ -> Wire.unit
end

module I = Ipc.Make (Protocol)

type client = I.client
let connect ?(service = "console") () = I.connect service
let call = I.call
let decode = I.decode
let reply = I.reply
let error_reply = I.error_reply
