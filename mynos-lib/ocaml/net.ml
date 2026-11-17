(* The network over typed IPC: see net.mli. The service is in C
   (services/net/netd.c), which follows the case numbers below. *)

type config = {
  mac : string;
  address : string;
  netmask : string;
  gateway : string;
  dns : string;
}

type _ request =
  | Config : config request
  | Ping : string * int -> int request
  | Resolve : string -> string request
  | Connect : string * int -> int request
  | Listen : int -> int request
  | Accept : int -> (int * string * int) request
  | Send : int * string -> int request
  | Recv : int * int -> string request
  | Close : int -> unit request
  | Set_timeout : int * int -> unit request
  | Connect_tls : string * int -> int request

let config_codec =
  Wire.(conv
          (fun c -> (c.mac, c.address, (c.netmask, c.gateway, c.dns)))
          (fun (mac, address, (netmask, gateway, dns)) ->
             { mac; address; netmask; gateway; dns })
          (triple string string (triple string string string)))

module Protocol = struct
  let id = "net/1"
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    let case n = Wire.write w Wire.int n in
    let str = Wire.write w Wire.string and int = Wire.write w Wire.int in
    match r with
    | Config -> case 0
    | Ping (a, t) -> case 1; str a; int t
    | Resolve name -> case 2; str name
    | Connect (a, p) -> case 3; str a; int p
    | Listen p -> case 4; int p
    | Accept s -> case 5; int s
    | Send (s, d) -> case 6; int s; str d
    | Recv (s, n) -> case 7; int s; int n
    | Close s -> case 8; int s
    | Set_timeout (s, ms) -> case 9; int s; int ms
    | Connect_tls (h, p) -> case 10; str h; int p

  let read_request r =
    let str () = Wire.read r Wire.string and int () = Wire.read r Wire.int in
    match int () with
    | 0 -> Request Config
    | 1 -> let a = str () in Request (Ping (a, int ()))
    | 2 -> Request (Resolve (str ()))
    | 3 -> let a = str () in Request (Connect (a, int ()))
    | 4 -> Request (Listen (int ()))
    | 5 -> Request (Accept (int ()))
    | 6 -> let s = int () in Request (Send (s, str ()))
    | 7 -> let s = int () in Request (Recv (s, int ()))
    | 8 -> Request (Close (int ()))
    | 9 -> let s = int () in Request (Set_timeout (s, int ()))
    | 10 -> let h = str () in Request (Connect_tls (h, int ()))
    | n -> raise (Wire.Error (Printf.sprintf "net: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Config -> config_codec
    | Ping _ -> Wire.int
    | Connect _ -> Wire.int
    | Connect_tls _ -> Wire.int
    | Listen _ -> Wire.int
    | Send _ -> Wire.int
    | Resolve _ -> Wire.string
    | Recv _ -> Wire.string
    | Accept _ -> Wire.(triple int string int)
    | Close _ -> Wire.unit
    | Set_timeout _ -> Wire.unit
end

module I = Ipc.Make (Protocol)

type t = I.client

let connect ?(service = "net") () =
  let rec go tries =
    match I.connect service with
    | c -> c
    | exception Mynos.Error _ when tries > 0 -> Mynos.sleep 0.1; go (tries - 1) in
  go 50

let call = I.call
