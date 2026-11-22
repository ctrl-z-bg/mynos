(** The clipboard: a service of its own ([clipboard], services/clipboard),
    so that what one program copies another pastes (the text boxes of
    {!Textarea}, {!Gui}'s fields, the [clip] command, the agent).
    Protocol ["clipboard/1"]: text. *)

type _ request =
  | Get : string request              (** the text copied last ([""]: none) *)
  | Set : string -> unit request      (** copy a text *)

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
val serve : string -> handler -> 'b
(** The service's side (services/clipboard). *)

val get : unit -> string
(** What was copied last; [""] without the service. *)

val set : string -> unit
(** Copy (the service keeps up to 1 MB); nothing without the service. *)
