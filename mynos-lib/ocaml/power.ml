(* Turning the machine off: see power.mli. *)

type _ request =
  | Shutdown : unit request
  | Reboot : unit request

module Protocol = struct
  let id = "power/1"
  let summary = "The machine's power (init): turn it off, or restart it."
  let requests = Ipc.[
      request 0 "shutdown" "End the graphical session, then turn the machine off."
        Wire.unit Wire.unit;
      request 1 "reboot" "End the graphical session, then restart the machine."
        Wire.unit Wire.unit ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    Wire.write w Wire.int (match r with Shutdown -> 0 | Reboot -> 1)

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Shutdown
    | 1 -> Request Reboot
    | n -> raise (Wire.Error (Printf.sprintf "power: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Shutdown -> Wire.unit
    | Reboot -> Wire.unit
end

module I = Ipc.Make (Protocol)

let call r = I.call (I.connect "power") r
let shutdown () = call Shutdown
let reboot () = call Reboot

type handler = I.handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
let serve h = I.serve "power" h
