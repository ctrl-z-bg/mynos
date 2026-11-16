(** Commands of the MyNOS shell.

    The shell is the OCaml toplevel: you type OCaml phrases, ended by [;;].
    This module is opened when the shell starts, so its functions are
    commands; the whole MyNOS API is in module {!Mynos}. *)

val help : unit -> unit
(** Print a short guide. *)

val ls : ?dir:string -> unit -> unit
(** List the files of a directory, with their sizes: the current one by
    default. [/] is the RAM disk; [/tmp] is writable, in memory; [/disk] is
    the FAT disk, whose files stay. *)

val cd : string -> unit
(** Change the current directory (programs started later start there). *)

val pwd : unit -> unit
(** Print the current directory. *)

val cat : string -> unit
(** Print a file. *)

val write : string -> string -> unit
(** [write file text] makes [file] contain [text] (under [/tmp] or
    [/disk]). *)

val rm : string -> unit
(** Remove a file (under [/tmp] or [/disk]). *)

val run : string -> string list -> Mynos.status
(** [run prog args] starts the program in file [prog] with arguments
    [args] and waits for its end. A name without a directory is looked for
    in the current directory, then at the root of the RAM disk. A bytecode program ([.byte]) runs on
    [ocamlrun]; anything else must be an ELF program. *)

val compile : ?output:string -> string -> Mynos.status
(** [compile "/disk/prog.ml"] compiles a program into [/disk/prog.byte]
    (or [output]) with ocamlc, inside MyNOS; it may use module {!Mynos}. *)

val free : unit -> unit
(** Print the free memory. *)
