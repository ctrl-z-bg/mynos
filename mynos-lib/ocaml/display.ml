(* The display over typed IPC: see display.mli. The service is displayd
   (services/display/displayd.c), which follows the case numbers below. *)

type event =
  | Key of string
  | Mouse of { x : int; y : int; buttons : int }
  | Close
  | Tick
  | Focus of bool
  | Wheel of int
  | Key_up of string
  | Resize of int * int

type _ request =
  | Info : (int * int) request
  | Create : string * int * int -> int request
  | Attach : int -> unit request
  | Damage : int * int * int * int * int -> unit request
  | Next_event : int * int -> event request
  | Destroy : int -> unit request
  | Set_title : int * string -> unit request
  | Start : unit request
  | Wait_session : unit request
  | Stop : unit request
  | Move : int * int * int -> unit request
  | Resize_to : int * int * int -> unit request
  | Resizable : int * int * int -> unit request
  | Start_at : int * int -> unit request
  | Sizes : (int * int) list request

let window_f = Wire.(field "window" int)
let size_codec = Wire.(pair (field "width" int) (field "height" int))
let create_args = Wire.(triple (field "title" string) (field "width" int) (field "height" int))
let damage_args = Wire.(pair (triple window_f (field "x" int) (field "y" int)) size_codec)
let event_args = Wire.(pair window_f (field "timeout_ms" int))
let title_args = Wire.(pair window_f (field "title" string))
let move_args = Wire.(triple window_f (field "x" int) (field "y" int))
let resize_args = Wire.(triple window_f (field "width" int) (field "height" int))
let resizable_args = Wire.(triple window_f (field "min_width" int) (field "min_height" int))

let event_codec =
  Wire.(variant [
      case ~name:"key" 0 string (fun s -> Key s) (function Key s -> Some s | _ -> None);
      case ~name:"mouse" 1 (triple (field "x" int) (field "y" int) (field "buttons" int))
        (fun (x, y, buttons) -> Mouse { x; y; buttons })
        (function Mouse { x; y; buttons } -> Some (x, y, buttons) | _ -> None);
      case ~name:"close" 2 unit (fun () -> Close) (function Close -> Some () | _ -> None);
      case ~name:"tick" 3 unit (fun () -> Tick) (function Tick -> Some () | _ -> None);
      case ~name:"focus" 4 bool (fun b -> Focus b) (function Focus b -> Some b | _ -> None);
      case ~name:"wheel" 5 int (fun n -> Wheel n) (function Wheel n -> Some n | _ -> None);
      case ~name:"key_up" 6 string (fun s -> Key_up s) (function Key_up s -> Some s | _ -> None);
      case ~name:"resize" 7 size_codec (fun (w, h) -> Resize (w, h))
        (function Resize (w, h) -> Some (w, h) | _ -> None) ])

module Protocol = struct
  let id = "display/1"
  let summary =
    "The display (displayd, in C): the graphical session, windows whose \
     pixels are shared with it, their events."
  let requests = Ipc.[
      request ~safe:true 0 "info" "The screen's size, in pixels." Wire.unit size_codec;
      request 1 "create" "A window, of this size (its content): its number. It shows once attached."
        create_args Wire.int;
      request 2 "attach"
        "Give a window its pixels: the same connection then carries a shared message \
         of width x height 32-bit pixels (0xRRGGBB), which stays shared with the display."
        window_f Wire.unit;
      request 3 "damage" "A part of the window's pixels changed: it is shown again."
        damage_args Wire.unit;
      request 4 "next_event"
        "The window's next event: keys (UTF-8, VT100 sequences for the others) and \
         their releases (key_up: the same text), the \
         mouse in the window (buttons: 1 left, 2 right, 4 middle), close, focus, the \
         wheel over it (its notches, positive towards the user: down), resize (the size \
         the user asked for: answer with resize); tick when none \
         came within timeout_ms (0: wait forever; negative: do not wait). Waits."
        event_args event_codec;
      request 5 "destroy" "Close a window." window_f Wire.unit;
      request 6 "set_title" "A window's title." title_args Wire.unit;
      request 7 "start" "Start the graphical session: the screen leaves text mode."
        Wire.unit Wire.unit;
      request 8 "wait_session" "Wait until the graphical session ends. Waits."
        Wire.unit Wire.unit;
      request 9 "stop" "End the graphical session: windows get close, text mode is back."
        Wire.unit Wire.unit;
      request 10 "move" "Move a window (its content's top left corner)." move_args Wire.unit;
      request 11 "resize"
        "A window's new size: the same connection then carries a shared message of its \
         pixels, as attach does, which replaces the old one."
        resize_args Wire.unit;
      request 12 "resizable"
        "Let the user resize a window (a grip, a double click on the title to maximize), \
         down to this size; 0: not resizable."
        resizable_args Wire.unit;
      request 13 "start_at"
        "Start the graphical session with the screen at this size (from 800x600, a width \
         multiple of 8, within the video memory)."
        Wire.(pair (field "width" int) (field "height" int)) Wire.unit;
      request ~safe:true 14 "sizes"
        "The usual screen sizes the video memory holds (start_at takes others too)."
        Wire.unit Wire.(list (pair (field "width" int) (field "height" int))) ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    let case n = Wire.write w Wire.int n in
    match r with
    | Info -> case 0
    | Create (t, x, y) -> case 1; Wire.write w create_args (t, x, y)
    | Attach i -> case 2; Wire.write w window_f i
    | Damage (i, x, y, dw, dh) -> case 3; Wire.write w damage_args ((i, x, y), (dw, dh))
    | Next_event (i, t) -> case 4; Wire.write w event_args (i, t)
    | Destroy i -> case 5; Wire.write w window_f i
    | Set_title (i, t) -> case 6; Wire.write w title_args (i, t)
    | Start -> case 7
    | Wait_session -> case 8
    | Stop -> case 9
    | Move (i, x, y) -> case 10; Wire.write w move_args (i, x, y)
    | Resize_to (i, x, y) -> case 11; Wire.write w resize_args (i, x, y)
    | Resizable (i, x, y) -> case 12; Wire.write w resizable_args (i, x, y)
    | Start_at (x, y) -> case 13; Wire.write w Wire.(pair (field "width" int) (field "height" int)) (x, y)
    | Sizes -> case 14

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Info
    | 1 -> let t, x, y = Wire.read r create_args in Request (Create (t, x, y))
    | 2 -> Request (Attach (Wire.read r window_f))
    | 3 -> let (i, x, y), (dw, dh) = Wire.read r damage_args in Request (Damage (i, x, y, dw, dh))
    | 4 -> let i, t = Wire.read r event_args in Request (Next_event (i, t))
    | 5 -> Request (Destroy (Wire.read r window_f))
    | 6 -> let i, t = Wire.read r title_args in Request (Set_title (i, t))
    | 7 -> Request Start
    | 8 -> Request Wait_session
    | 9 -> Request Stop
    | 10 -> let i, x, y = Wire.read r move_args in Request (Move (i, x, y))
    | 11 -> let i, x, y = Wire.read r resize_args in Request (Resize_to (i, x, y))
    | 12 -> let i, x, y = Wire.read r resizable_args in Request (Resizable (i, x, y))
    | 13 -> let x, y = Wire.read r Wire.(pair (field "width" int) (field "height" int)) in
      Request (Start_at (x, y))
    | 14 -> Request Sizes
    | n -> raise (Wire.Error (Printf.sprintf "display: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Info -> size_codec
    | Create _ -> Wire.int
    | Next_event _ -> event_codec
    | Attach _ -> Wire.unit
    | Damage _ -> Wire.unit
    | Destroy _ -> Wire.unit
    | Set_title _ -> Wire.unit
    | Start -> Wire.unit
    | Wait_session -> Wire.unit
    | Stop -> Wire.unit
    | Move _ -> Wire.unit
    | Resize_to _ -> Wire.unit
    | Resizable _ -> Wire.unit
    | Start_at _ -> Wire.unit
    | Sizes -> Wire.(list (pair (field "width" int) (field "height" int)))
end

module I = Ipc.Make (Protocol)

type t = I.client

let connect () =
  let rec go tries =
    match I.connect "display" with
    | c -> c
    | exception Mynos.Error _ when tries > 0 -> Mynos.sleep 0.1; go (tries - 1) in
  go 50

let call = I.call

type window = { display : t; id : int; pixels : Gfx.t }

let window ?display ?(title = "") w h =
  let d = match display with Some d -> d | None -> connect () in
  let id = call d (Create (title, w, h)) in
  let pixels = Gfx.create w h in
  (* attach: the request, then the pixels, shared, on the same connection *)
  let ch = Mynos.connect (Mynos.lookup "display") in
  let answer =
    Fun.protect ~finally:(fun () -> try Mynos.free_channel ch with Mynos.Error _ -> ())
      (fun () ->
         Mynos.send ch (I.request_message (Attach id));
         Gfx.send_shared ch pixels;
         Mynos.recv ch) in
  I.read_reply answer (Attach id);
  { display = d; id; pixels }

let damage ?(x = 0) ?(y = 0) ?w ?h win =
  let w = Option.value w ~default:win.pixels.Gfx.width
  and h = Option.value h ~default:win.pixels.Gfx.height in
  call win.display (Damage (win.id, x, y, w, h))

let next_event ?(timeout = 0.) win =
  call win.display (Next_event (win.id, int_of_float (timeout *. 1000.)))

let poll win = call win.display (Next_event (win.id, -1))

let set_title win t = call win.display (Set_title (win.id, t))
let move win x y = call win.display (Move (win.id, x, y))

(* new pixels of the new size, shared, on the request's connection: as
   [window]'s attach *)
let resize win w h =
  let pixels = Gfx.create w h in
  let req = Resize_to (win.id, w, h) in
  let ch = Mynos.connect (Mynos.lookup "display") in
  let answer =
    Fun.protect ~finally:(fun () -> try Mynos.free_channel ch with Mynos.Error _ -> ())
      (fun () ->
         Mynos.send ch (I.request_message req);
         Gfx.send_shared ch pixels;
         Mynos.recv ch) in
  I.read_reply answer req;
  { win with pixels }

let set_resizable win w h = call win.display (Resizable (win.id, w, h))
let destroy win = try call win.display (Destroy win.id) with Ipc.Remote_error _ -> ()
