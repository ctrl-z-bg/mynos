(* A small typed service, for the tests: "greeter/1", one request. An
   agent starts it in the background (sh's &): ps, and the System window,
   show it with its name. Also an example of a whole service:

     greeter          serve, forever
     greeter NAME     ask the service: its greeting for NAME *)

type _ request = Hello : string -> string request

module Protocol = struct
  let id = "greeter/1"
  let summary = "Greets: an example service."
  let requests = Ipc.[
      request ~safe:true 0 "hello" "A greeting for someone." Wire.string Wire.string ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed
  let write_request (type a) w (r : a request) =
    match r with Hello name -> Wire.write w Wire.int 0; Wire.write w Wire.string name
  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request (Hello (Wire.read r Wire.string))
    | n -> raise (Wire.Error (Printf.sprintf "greeter: unknown request %d" n))
  let reply : type a. a request -> a Wire.t = function Hello _ -> Wire.string
end

module I = Ipc.Make (Protocol)

let () =
  match Sys.argv with
  | [| _; name |] -> print_endline (I.call (I.connect "greeter") (Hello name))
  | _ ->
    I.serve "greeter" { I.handle = fun (type a) _ (r : a request) : a ->
        match r with Hello name -> "Hello, " ^ name ^ ", from MyNOS!" }
