(** Typed IPC: services whose requests and replies are OCaml types
    (doc/decisions/typed-ipc.md).

    A protocol is a GADT of requests, indexed by the type of their reply:

    {[
      type _ request =
        | Info  : int request
        | Read  : int * int -> string request
    ]}

    [Ipc.Make (P)] gives clients a [call] whose result has the type of the
    request, and services a [serve] loop that hands each request, with
    its {!caller}, to a function of type ['a. caller -> 'a P.request -> 'a]. Messages are encoded with
    {!Wire}: a request is the protocol's [id] then the request; a reply is
    [Ok value] or [Error message] (case 0 or 1). One connection per call. *)

exception Remote_error of string * string
(** [(service, message)]: the service could not do the request (it raised
    an exception, or did not understand the message). *)

exception Protocol_error of string
(** The service's reply was malformed. *)

type caller = { pid : int; io : bool }
(** Who sent a request: its pid (pids are not reused, so it names one
    process) and whether it has the [io] privilege
    (doc/decisions/identity-and-permissions.md). *)

val nobody : caller
(** A caller for tests: pid -1, no privilege. *)

module type PROTOCOL = sig
  val id : string
  (** Name and version, such as ["block/1"]: a service refuses requests
      of another id. *)

  type 'a request
  type packed = Request : 'a request -> packed

  val write_request : Wire.writer -> 'a request -> unit
  val read_request : Wire.reader -> packed
  (** Raises {!Wire.Error} on a malformed request. *)

  val reply : 'a request -> 'a Wire.t
  (** The codec of the reply to each request. *)
end

module Make (P : PROTOCOL) : sig
  (** {2 Clients} *)

  type client

  val connect : string -> client
  (** The service registered under this name (raises {!Mynos.Error} if
      there is none). *)

  val service : client -> string

  val call : client -> 'a P.request -> 'a
  (** Raises {!Remote_error}, {!Protocol_error}, or {!Mynos.Error}. *)

  (** {2 Services} *)

  type handler = { handle : 'a. caller -> 'a P.request -> 'a }
  (** [handle caller request]. An exception raised by [handle] is the
      reply: the client raises {!Remote_error} with its message. *)

  val serve : string -> handler -> 'b
  (** Register the service under this name and answer requests, one at a
      time, forever. *)

  val serve_port : int -> handler -> 'b

  (** {2 Messages (for tests)} *)

  val request_message : 'a P.request -> string
  val answer : ?caller:caller -> handler -> string -> string
  (** The reply to a request message, as [serve] sends it ([caller]:
      {!nobody} by default). *)

  val read_reply : string -> 'a P.request -> 'a
  (** As [call] reads it; [Remote_error]'s service name is [""]. *)
end
