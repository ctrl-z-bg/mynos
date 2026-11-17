(** Typed services as a language model's tools (doc/decisions/llm.md).

    A typed service describes its protocol ({!Ipc.describe}): its requests,
    and their arguments and replies as {!Wire.shape}s. From that alone,
    this module makes each request a tool ({!Llm.tool}, with a JSON Schema
    of its arguments), and calls it with JSON: the arguments are written
    as the protocol's bytes, the reply read back as JSON. No code of the
    service's own is needed.

    {[
      let ts = Tools.of_service "net";;
      List.map (fun t -> t.Tools.tool.Llm.name) ts;;   (* "net_config"... *)
      Tools.call (Tools.find ts "net_resolve") {|{"name": "example.com"}|};;
    ]}

    Values in JSON:
    - unit: [null]; bool, int, float, string: JSON's (strings are bytes:
      binary data does not suit JSON);
    - option: [null] or the value; lists and arrays: arrays;
    - tuples of named components ({!Wire.field}): objects; other tuples:
      arrays;
    - variants: the case's name (a string) when it carries nothing, else
      [{"name": value}]. *)

val schema : Wire.shape -> Json.t
(** The JSON Schema of a value of this shape. *)

val args_schema : Wire.shape -> Json.t
(** The JSON Schema of a request's arguments: always an object (a tool's
    input must be one); arguments that are not named components are under
    ["value"]. *)

val write_json : Wire.shape -> Wire.writer -> Json.t -> unit
(** A value from JSON, as the protocol's bytes. Raises [Failure] if the
    JSON does not fit the shape. *)

val read_json : Wire.shape -> Wire.reader -> Json.t
(** A value of the protocol, as JSON. Raises {!Wire.Error}. *)

type t = {
  service : string;             (** its name in the registry *)
  protocol : string;
  request : Ipc.request_doc;
  tool : Llm.tool;              (** named [SERVICE_REQUEST] *)
}

val of_description : string -> Ipc.description -> t list
val of_service : string -> t list
(** The tools of the service registered under this name (it is asked
    for its description: see {!Ipc.describe}). *)

val find : t list -> string -> t
(** The tool of that name. @raise Not_found *)

val call : t -> string -> string
(** [call tool input]: [input] is the arguments as a JSON object (the
    model's tool call); the reply as JSON. Raises {!Ipc.Remote_error} when
    the service refuses (its message), [Failure] for arguments that do not
    fit. *)
