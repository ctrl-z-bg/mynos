(** Commands of the MyNOS shell.

    The shell is the OCaml toplevel: you type OCaml phrases, ended by [;;].
    This module is opened when the shell starts, so its functions are
    commands; the whole MyNOS API is in module {!Mynos}. *)

val help : unit -> unit
(** Print a short guide. *)

val ls : ?dir:string -> unit -> unit
(** List the files of a directory ([/], the RAM disk, by default; [/tmp] is
    the writable one), with their sizes. *)

val cat : string -> unit
(** Print a file. *)

val write : string -> string -> unit
(** [write file text] makes [file] contain [text] (only under [/tmp]). *)

val rm : string -> unit
(** Remove a file (only under [/tmp]). *)

val run : string -> string list -> Mynos.status
(** [run prog args] starts the program in file [prog] with arguments
    [args] and waits for its end. A bytecode program ([.byte]) runs on
    [ocamlrun]; anything else must be an ELF program. *)

val free : unit -> unit
(** Print the free memory. *)
