(** Turning the machine off, or restarting it: a request to init, which
    serves "power/1" as the service [power] (init/init.ml). Any process may
    ask: MyNOS has one user. The power is init's, which has the [io]
    privilege; the [shutdown] command asks it.

    Before it acts, init ends the graphical session (the text console is
    back), then turns the machine off through ACPI (QEMU, Bochs) or
    restarts it through the keyboard controller. File services write
    through: nothing waits to be written. *)

type _ request =
  | Shutdown : unit request
  | Reboot : unit request

module Protocol : Ipc.PROTOCOL with type 'a request = 'a request

val shutdown : unit -> unit
val reboot : unit -> unit
(** They return once init has the request; the machine stops soon after. *)

type handler = { handle : 'a. Ipc.caller -> 'a request -> 'a }
val serve : handler -> 'b
(** Register as [power] and answer (init). *)
