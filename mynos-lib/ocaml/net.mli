(** The network, over typed IPC with the network service [net] (netd:
    lwIP and the NE2000 driver, services/net). Protocol ["net/1"].

    {[
      let n = Net.connect ();;
      Net.call n Net.Config;;                  (* the address, by DHCP *)
      Net.call n (Net.Ping ("10.0.2.2", 1000));;   (* round trip, in ms *)
      let s = Net.call n (Net.Connect ("10.0.2.2", 8000));;
      let t = Net.call n (Net.Connect_tls ("example.com", 443));;
      Net.call n (Net.Send (s, "hello"));;
      Net.call n (Net.Recv (s, 4096));;
    ]}

    Addresses are dotted IPv4 strings. Sockets are numbers, and belong to
    the process that made them (a connection from [Accept], to the process
    that accepted it): another one gets ["not your socket"]. netd closes the
    sockets of a process that ended within a second, so a restarted server
    can listen on its port again. [Recv], [Accept] and [Recv_from] wait. *)

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
  | Set_timeout : int * int -> unit request
      (** [(socket, ms)]: a [Recv] or [Accept] on it that waits longer
          fails with ["timeout"]; 0: wait forever (the default) *)
  | Connect_tls : string * int -> int request
      (** [(host, port)]: a TCP socket with TLS over it (1.2 or 1.3).
          [host] is a name (resolved by DNS) or an address. The server's
          certificate must be valid for [host] and come from an authority
          netd trusts: Mozilla's list ([/cacert.pem] on the RAM disk) and
          the user's ([/disk/ca.pem], if any). [Send] and [Recv] then carry
          the clear bytes. *)
  | Udp_bind : int -> int request
      (** a UDP port (0: any): a UDP socket. Up to 32 datagrams wait to be
          read; later ones are dropped. *)
  | Send_to : int * string * int * string -> int request
      (** [(socket, address, port, data)]: one datagram (up to 8192
          bytes); its size *)
  | Recv_from : int * int -> (string * int * string) request
      (** [(socket, max)]: the next datagram, waiting for one
          ({!Set_timeout} applies): [(address, port, data)], [data] cut to
          [max] bytes *)
  | Poll : (int * int) list * int -> int list request
      (** [([(socket, events); ...], timeout_ms)]: wait until a socket is
          ready for its events (1 data, the end or a connection to accept;
          2 a [Send] would not wait), or [timeout_ms] (0: at once;
          negative: no limit): each socket's flags, its events that are
          ready and 4 the peer closed, 8 the connection failed, 16 not a
          socket of ours. *)

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type t

val connect : ?service:string -> unit -> t
(** The network service (["net"]), waiting up to 5 s for it to start. *)

val call : t -> 'a request -> 'a
(** Raises {!Ipc.Remote_error} when the request fails. *)

val config_codec : config Wire.t
