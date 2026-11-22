(* A service of one's own: the source of a typed service called NAME, to
   start from. Run as service, it registers NAME; the Services window
   shows it, with a form for each request; NAME WORDS... asks it. *)

let service name =
  let cap = String.capitalize_ascii name in
  Printf.sprintf {|(* %s: a service of MyNOS, made in Studio. It registers "%s" and
   serves "%s/1": typed requests, which describe themselves (the Services
   window shows them, with a form for each; the agent can use them).

     %s           serve (Studio's "Run as service")
     %s hello WHO   ask it, from a Terminal *)

(* {1 The protocol: one constructor a request, its reply's type} *)

type _ request =
  | Hello : string -> string request          (* a greeting for someone *)
  | Count : int request                       (* how many greetings so far *)

module Protocol = struct
  let id = "%s/1"
  let summary = "%s: a service made in MyNOS Studio."
  let requests = Ipc.[
      request ~safe:true 0 "hello" "A greeting for someone." Wire.string Wire.string;
      request ~safe:true 1 "count" "How many greetings so far." Wire.unit Wire.int ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    match r with
    | Hello who -> Wire.write w Wire.int 0; Wire.write w Wire.string who
    | Count -> Wire.write w Wire.int 1
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request (Hello (Wire.read r Wire.string))
    | 1 -> Request Count
    | n -> raise (Wire.Error (Printf.sprintf "%s: unknown request %%d" n))
  let reply : type a. a request -> a Wire.t = function
    | Hello _ -> Wire.string
    | Count -> Wire.int
end

module I = Ipc.Make (Protocol)

(* {1 The service: its state, and the answer to each request} *)

let greetings = ref 0

let handle : type a. a request -> a = function
  | Hello who -> incr greetings; Printf.sprintf "Hello, %%s, from %s!" who
  | Count -> !greetings

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ "hello"; who ] -> print_endline (I.call (I.connect "%s") (Hello who))
  | [ "count" ] -> print_endline (string_of_int (I.call (I.connect "%s") Count))
  | _ ->
    print_endline "%s: serving %s/1";
    I.serve "%s" { I.handle = fun (type a) _ (r : a request) : a -> handle r }
|} name name name name name name cap name name name name name name name
