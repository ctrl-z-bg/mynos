(** The network, over typed IPC with the network service [net] (netd:
    lwIP and the NE2000 driver, services/net). Protocol ["net/1"].

    {[
      let n = Net.connect ();;
      Net.call n Net.Config;;                  (* the address, by DHCP *)
      Net.call n (Net.Ping ("10.0.2.2", 1000));;   (* round trip, in ms *)
      let s = Net.call n (Net.Connect ("10.0.2.2", 8000));;
      Net.call n (Net.Send (s, "hello"));;
      Net.call n (Net.Recv (s, 4096));;
    ]}

    Addresses are dotted IPv4 strings. Sockets are numbers: any process may
    use any socket (there is no owner yet). [Recv] and [Accept] wait. *)

type config = {
  mac : string;        (** ["52:54:00:12:34:56"] *)
  address : string;
  netmask : string;
  gateway : string;
  dns : string;
}

type _ request =
  | Config : config request
  | Ping : string * int -> int request
      (** [(address, timeout_ms)]: the round trip time in ms *)
  | Resolve : string -> string request
      (** a host name: its address (DNS) *)
  | Connect : string * int -> int request
      (** [(address, port)]: a TCP socket *)
  | Listen : int -> int request
      (** a TCP port: a listening socket *)
  | Accept : int -> (int * string * int) request
      (** a listening socket: a connection's socket, and the peer's address
          and port *)
  | Send : int * string -> int request
      (** all of the bytes; their number *)
  | Recv : int * int -> string request
      (** at most this many bytes (up to 16384); [""] at the end *)
  | Close : int -> unit request

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type t

val connect : ?service:string -> unit -> t
(** The network service (["net"]), waiting up to 5 s for it to start. *)

val call : t -> 'a request -> 'a
(** Raises {!Ipc.Remote_error} when the request fails. *)

val config_codec : config Wire.t
