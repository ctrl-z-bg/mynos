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
  | Udp_bind : int -> int request
  | Send_to : int * string * int * string -> int request
  | Recv_from : int * int -> (string * int * string) request

let config_codec =
  Wire.(conv
          (fun c -> (c.mac, c.address, (c.netmask, c.gateway, c.dns)))
          (fun (mac, address, (netmask, gateway, dns)) ->
             { mac; address; netmask; gateway; dns })
          (triple (field "mac" string) (field "address" string)
             (triple (field "netmask" string) (field "gateway" string)
                (field "dns" string))))

(* the requests' arguments, for the description (write_request writes
   them one after the other, as these tuples) *)
let socket = Wire.(field "socket" int)
let address = Wire.(field "address" string)
let port = Wire.(field "port" int)

module Protocol = struct
  let id = "net/1"
  let summary =
    "The network (TCP/IP over the NE2000 card; netd, in C): addresses, DNS, \
     TCP connections (also with TLS) and listening sockets, UDP. Sockets \
     are numbers and belong to the process that made them."
  let requests = Ipc.[
      request ~safe:true 0 "config" "The network's configuration (by DHCP)."
        Wire.unit config_codec;
      request ~safe:true 1 "ping"
        "Ping an address (IPv4, dotted): the round trip time in ms."
        Wire.(pair address (field "timeout_ms" int)) Wire.int;
      request ~safe:true 2 "resolve" "A host name's IPv4 address (DNS)."
        Wire.(field "name" string) Wire.string;
      request 3 "connect" "A TCP connection to an address and port: its socket."
        Wire.(pair address port) Wire.int;
      request 4 "listen" "Listen on a TCP port: a listening socket."
        port Wire.int;
      request 5 "accept"
        "Wait for a connection on a listening socket: its socket, and the \
         peer's address and port."
        socket Wire.(triple socket address port);
      request 6 "send" "Send all of these bytes on a socket: their number."
        Wire.(pair socket (field "data" string)) Wire.int;
      request 7 "recv"
        "Receive at most max bytes (up to 16384) from a socket; empty at the \
         end. Waits."
        Wire.(pair socket (field "max" int)) Wire.string;
      request 8 "close" "Close a socket." socket Wire.unit;
      request 9 "set_timeout"
        "A recv or accept on this socket that waits longer than ms fails \
         with \"timeout\" (0: wait forever)."
        Wire.(pair socket (field "ms" int)) Wire.unit;
      request 10 "connect_tls"
        "A TCP connection with TLS to a host (a name, or an address) and \
         port, the server's certificate checked: its socket. send and recv \
         then carry the clear bytes."
        Wire.(pair (field "host" string) port) Wire.int;
      request 11 "udp_bind" "A UDP socket on a port (0: any)." port Wire.int;
      request 12 "send_to" "Send one UDP datagram: its size."
        Wire.(Wire.conv (fun (s, a, p, d) -> ((s, a), (p, d)))
                (fun ((s, a), (p, d)) -> (s, a, p, d))
                (pair (pair socket address) (pair port (field "data" string))))
        Wire.int;
      request 13 "recv_from"
        "Receive one UDP datagram (at most max bytes): the sender's address \
         and port, and the data. Waits."
        Wire.(pair socket (field "max" int))
        Wire.(triple address port (field "data" string)) ]
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
    | Udp_bind p -> case 11; int p
    | Send_to (s, a, p, d) -> case 12; int s; str a; int p; str d
    | Recv_from (s, n) -> case 13; int s; int n

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
    | 11 -> Request (Udp_bind (int ()))
    | 12 ->
      let s = int () in let a = str () in let p = int () in
      Request (Send_to (s, a, p, str ()))
    | 13 -> let s = int () in Request (Recv_from (s, int ()))
    | n -> raise (Wire.Error (Printf.sprintf "net: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Config -> config_codec
    | Ping _ -> Wire.int
    | Connect _ -> Wire.int
    | Connect_tls _ -> Wire.int
    | Udp_bind _ -> Wire.int
    | Send_to _ -> Wire.int
    | Recv_from _ -> Wire.(triple string int string)
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
