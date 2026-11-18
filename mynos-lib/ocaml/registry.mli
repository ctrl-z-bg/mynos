(** registry/1, the protocol of the name registry (services/registry, in
    C; mynos-lib/include/mynos_registry.h). Programs use it through
    {!Mynos.register}, {!Mynos.lookup} and {!Mynos.registered} (libmynos);
    this module describes it, and speaks it typed. *)

type _ request =
  | Register : string -> int request      (** a name: a new port, the caller's *)
  | Lookup : string -> int request        (** the port of a name *)
  | List : (string * int * int) list request   (** names, ports, owners *)

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

val call : 'a request -> 'a
(** @raise Ipc.Remote_error ("not_found", "exists"...) *)
