(* ide/1: MyNOS Studio as a service (registered as studio<pid>). Its agent
   pane is MyNOS's agent given this service: the requests below are its
   tools, from this description; sh, a script or the Services window can
   use them too. Files are paths; lines count from 1. *)

type _ request =
  | Files : string request
  | Read : string * int * int -> string request
  | Replace : string * int * int * string -> unit request
  | Open : string -> unit request
  | Save : string -> unit request
  | Build : string -> string request
  | Errors : string -> string request
  | Goto : string * int -> unit request
  | Find : string * string -> string request

let file_f = Wire.(field "file" string)
let read_args = Wire.(triple file_f (field "first" int) (field "last" int))
let replace_args =
  Wire.(pair (triple file_f (field "first" int) (field "last" int)) (field "text" string))
let goto_args = Wire.(pair file_f (field "line" int))
let find_args = Wire.(pair file_f (field "text" string))

module Protocol = struct
  let id = "ide/1"
  let summary =
    "MyNOS Studio: its open files, read and changed by lines, built with ocamlc, \
     their errors."
  let requests = Ipc.[
      request ~safe:true 0 "files"
        "The files open in Studio, one a line (\" *\" after a name: changed, not saved); \
         the first is the one shown." Wire.unit Wire.string;
      request ~safe:true 1 "read"
        "Lines first to last of a file (from 1; last 0: to the end), each after its \
         number and a bar: \"12| let x = 1\". Opened in Studio if it was not."
        read_args Wire.string;
      request 2 "replace"
        "Lines first to last of a file replaced by text (its lines, no numbers); last = \
         first - 1 inserts before first. Shown in Studio, not saved."
        replace_args Wire.unit;
      request ~safe:true 3 "open" "Open a file in Studio (a new one if it does not exist)."
        file_f Wire.unit;
      request 4 "save" "Save a file open in Studio." file_f Wire.unit;
      request ~safe:true 5 "build"
        "Compile a file with ocamlc (its program beside it, .byte): the compiler's \
         messages, \"\" when it compiled cleanly. The errors are marked in Studio."
        file_f Wire.string;
      request ~safe:true 6 "errors" "The last build's errors of a file, one a line."
        file_f Wire.string;
      request ~safe:true 7 "goto" "Show a file at a line." goto_args Wire.unit;
      request ~safe:true 8 "find" "The lines of a file that contain a text: their numbers \
                                   and contents." find_args Wire.string ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    let case n = Wire.write w Wire.int n in
    match r with
    | Files -> case 0
    | Read (f, a, b) -> case 1; Wire.write w read_args (f, a, b)
    | Replace (f, a, b, t) -> case 2; Wire.write w replace_args ((f, a, b), t)
    | Open f -> case 3; Wire.write w file_f f
    | Save f -> case 4; Wire.write w file_f f
    | Build f -> case 5; Wire.write w file_f f
    | Errors f -> case 6; Wire.write w file_f f
    | Goto (f, l) -> case 7; Wire.write w goto_args (f, l)
    | Find (f, t) -> case 8; Wire.write w find_args (f, t)

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Files
    | 1 -> let f, a, b = Wire.read r read_args in Request (Read (f, a, b))
    | 2 -> let (f, a, b), t = Wire.read r replace_args in Request (Replace (f, a, b, t))
    | 3 -> Request (Open (Wire.read r file_f))
    | 4 -> Request (Save (Wire.read r file_f))
    | 5 -> Request (Build (Wire.read r file_f))
    | 6 -> Request (Errors (Wire.read r file_f))
    | 7 -> let f, l = Wire.read r goto_args in Request (Goto (f, l))
    | 8 -> let f, t = Wire.read r find_args in Request (Find (f, t))
    | n -> raise (Wire.Error (Printf.sprintf "ide: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Files -> Wire.string
    | Read _ -> Wire.string
    | Replace _ -> Wire.unit
    | Open _ -> Wire.unit
    | Save _ -> Wire.unit
    | Build _ -> Wire.string
    | Errors _ -> Wire.string
    | Goto _ -> Wire.unit
    | Find _ -> Wire.string
end

module I = Ipc.Make (Protocol)
