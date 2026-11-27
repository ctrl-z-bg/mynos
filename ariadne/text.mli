(** A page as text: the {!Dom} read as blocks, what M0's window and
    [ariadne --dump] show. Layout (M3) replaces it in the window; the dump
    keeps it. *)

type kind =
  | Heading of int        (** h1..h6 *)
  | Paragraph
  | Item of int           (** a list's item, at this depth (1: not nested) *)
  | Pre                   (** preformatted, as written *)
  | Rule                  (** hr *)

type block = { kind : kind; text : string }
(** [text]: spaces collapsed (except in [Pre]); a [br] is a ['\n'] *)

type page = {
  title : string;
  blocks : block list;
  links : string list;    (** the [href]s of the links, as written, in order, once each *)
}

val of_dom : Dom.node -> page

val to_text : page -> string
(** The dump: the title, then a line per block ([#] for headings, [-] for
    items, four spaces before preformatted lines, [----] for rules). *)

val collapse : string -> string
(** Runs of white space as one space, none at either end. *)
