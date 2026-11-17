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

(** {2 Descriptions}

    A protocol describes itself (doc/decisions/llm.md): its requests, with
    their arguments and reply as {!Wire.shape}s. Every service made with
    {!Make} answers a request of protocol ["describe"] with its
    description, so a program can learn a service's protocol at run time,
    and call it without its OCaml types ({!Tools}: from JSON, for language
    models). *)

type request_doc = {
  case : int;              (** its number on the wire *)
  name : string;           (** ["read"] *)
  doc : string;            (** what it does, for people and models *)
  args : Wire.shape;       (** written after the number: a {!Wire.Tuple} of
                               {!Wire.Named} values, or [Unit] *)
  reply : Wire.shape;
  safe : bool;             (** it only reads: it changes nothing *)
}

val request :
  ?safe:bool -> int -> string -> string -> 'a Wire.t -> 'b Wire.t -> request_doc
(** [request case name doc args reply] ([safe]: false). *)

type description = {
  protocol : string;       (** ["block/1"] *)
  summary : string;
  requests : request_doc list;
}

val description_codec : description Wire.t

val describe : ?timeout:float -> string -> description
(** The description of the service registered under this name. Raises
    {!Mynos.Error} if there is none or it does not answer within
    [timeout] seconds (1), {!Remote_error} if it does not describe
    itself. Only typed services should be asked. *)

module type PROTOCOL = sig
  val id : string
  (** Name and version, such as ["block/1"]: a service refuses requests
      of another id. *)

  val summary : string
  (** What the service does, in a sentence or two. *)

  val requests : request_doc list
  (** Its requests: their numbers must be [write_request]'s. *)

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
