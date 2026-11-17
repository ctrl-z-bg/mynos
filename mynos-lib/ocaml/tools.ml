(* Typed services as a language model's tools: see tools.mli. *)

open Wire

let fail fmt = Printf.ksprintf failwith fmt

(* the components of a tuple, nested tuples without a name flattened: a
   record written as pair (triple a b c) (pair d e) has five fields *)
let rec components = function
  | Tuple l -> List.concat_map (function
      | Named (n, s) -> [ (Some n, s) ]
      | s -> components s) l
  | Named (n, s) -> [ (Some n, s) ]
  | Unit -> []
  | s -> [ (None, s) ]

type kind = Obj of (string * shape) list | Arr of shape list | Single of shape

let kind s =
  match s with
  | Tuple _ | Named _ ->
    let cs = components s in
    if cs <> [] && List.for_all (fun (n, _) -> n <> None) cs then
      Obj (List.map (fun (n, s) -> (Option.get n, s)) cs)
    else (match cs with
        | [ (_, s) ] -> Single s
        | _ -> Arr (List.map snd cs))
  | s -> Single s

let obj l = Json.Object l
let str s = Json.String s

let rec schema_in env s : Json.t =
  match s with
  | Unit -> obj [ "type", str "null" ]
  | Bool -> obj [ "type", str "boolean" ]
  | Int -> obj [ "type", str "integer" ]
  | Float -> obj [ "type", str "number" ]
  | String -> obj [ "type", str "string" ]
  | Option x -> obj [ "anyOf", Array [ schema_in env x; obj [ "type", str "null" ] ] ]
  | List x -> obj [ "type", str "array"; "items", schema_in env x ]
  | Tuple _ | Named _ ->
    (match kind s with
     | Obj fields ->
       obj [ "type", str "object";
             "properties", Object (List.map (fun (n, s) -> (n, schema_in env s)) fields);
             "required", Array (List.map (fun (n, _) -> str n) fields) ]
     | Arr l -> obj [ "type", str "array";
                      "minItems", Number (Float.of_int (List.length l));
                      "maxItems", Number (Float.of_int (List.length l)) ]
     | Single x -> schema_in env x)
  | Variant cases ->
    obj [ "anyOf", Array (List.map (fun (_, name, s) ->
        if s = Unit then obj [ "type", str "string"; "enum", Array [ str name ] ]
        else obj [ "type", str "object";
                   "properties", Object [ name, schema_in env s ];
                   "required", Array [ str name ] ]) cases) ]
  | Rec (n, x) -> if List.mem n env then obj [] else schema_in (n :: env) x
  | Var _ -> obj []                     (* a recursive occurrence: any *)

let schema s = schema_in [] s

let args_schema s =
  match kind s with
  | Obj _ -> schema s
  | Single Unit -> obj [ "type", str "object"; "properties", Object [] ]
  | _ -> obj [ "type", str "object"; "properties", Object [ "value", schema s ];
               "required", Array [ str "value" ] ]

let member k = function
  | Json.Object l -> Option.value (List.assoc_opt k l) ~default:Json.Null
  | _ -> Json.Null

let describe_json j =
  let s = Json.to_string j in
  if String.length s > 60 then String.sub s 0 60 ^ "..." else s

let rec write_in env s w (j : Json.t) =
  match s, j with
  | Unit, _ -> ()
  | Bool, Bool b -> write w bool b
  | Int, Number f when Float.is_integer f -> write w int (int_of_float f)
  | Int, String v when int_of_string_opt v <> None -> write w int (int_of_string v)
  | Float, Number f -> write w float f
  | String, String v -> write w string v
  | Option _, Null -> write w bool false
  | Option x, _ -> write w bool true; write_in env x w j
  | List x, Array l -> write w int (List.length l); List.iter (write_in env x w) l
  | (Tuple _ | Named _), _ ->
    (match kind s, j with
     | Obj fields, Object _ ->
       List.iter (fun (n, s) -> write_in env s w (member n j)) fields
     | Arr l, Array js when List.length l = List.length js ->
       List.iter2 (fun s j -> write_in env s w j) l js
     | Single x, _ -> write_in env x w j
     | _ -> fail "expected %s, not %s" (Json.to_string (schema_in [] s)) (describe_json j))
  | Variant cases, (String name | Object [ (name, _) ]) ->
    (match List.find_opt (fun (_, n, _) -> n = name) cases with
     | Some (case, _, x) ->
       write w int case;
       write_in env x w (match j with Object [ (_, v) ] -> v | _ -> Null)
     | None -> fail "no case %S (there are: %s)" name
                 (String.concat ", " (List.map (fun (_, n, _) -> n) cases)))
  | Rec (n, x), _ -> write_in ((n, x) :: env) x w j
  | Var n, _ ->
    (match List.assoc_opt n env with
     | Some x -> write_in env x w j
     | None -> fail "unknown type %s" n)
  | _ -> fail "expected %s, not %s" (Json.to_string (schema_in [] s)) (describe_json j)

let write_json s w j = write_in [] s w j

let rec read_in env s r : Json.t =
  match s with
  | Unit -> Null
  | Bool -> Bool (read r bool)
  | Int -> Number (Float.of_int (read r int))
  | Float -> Number (read r float)
  | String -> String (read r string)
  | Option x -> if read r bool then read_in env x r else Null
  | List x -> let n = read r int in Array (List.init n (fun _ -> read_in env x r))
  | Tuple _ | Named _ ->
    (match kind s with
     | Obj fields -> Object (List.map (fun (n, s) -> (n, read_in env s r)) fields)
     | Arr l -> Array (List.map (fun s -> read_in env s r) l)
     | Single x -> read_in env x r)
  | Variant cases ->
    let n = read r int in
    (match List.find_opt (fun (c, _, _) -> c = n) cases with
     | Some (_, name, Unit) -> String name
     | Some (_, name, x) -> Object [ name, read_in env x r ]
     | None -> raise (Wire.Error (Printf.sprintf "unknown case %d" n)))
  | Rec (n, x) -> read_in ((n, x) :: env) x r
  | Var n ->
    (match List.assoc_opt n env with
     | Some x -> read_in env x r
     | None -> raise (Wire.Error ("unknown type " ^ n)))

let read_json s r = read_in [] s r

type t = {
  service : string;
  protocol : string;
  request : Ipc.request_doc;
  tool : Llm.tool;
}

(* tool names: letters, digits, _ and -, at most 64 *)
let tool_name service request =
  let s = String.map (fun c ->
      match c with 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' -> c | _ -> '_')
      (service ^ "_" ^ request) in
  if String.length s > 64 then String.sub s 0 64 else s

let of_description service (d : Ipc.description) =
  List.map (fun (r : Ipc.request_doc) ->
      { service; protocol = d.protocol; request = r;
        tool = { Llm.name = tool_name service r.name;
                 description = Printf.sprintf "%s (Service %s, protocol %s: %s)%s"
                     r.doc service d.protocol d.summary
                     (if r.safe then "" else " It changes things.");
                 schema = Json.to_string (args_schema r.args) } })
    d.requests

let of_service service = of_description service (Ipc.describe service)

let find ts name = List.find (fun t -> t.tool.Llm.name = name) ts

let call t input =
  let args = if String.trim input = "" then Json.Object []
    else try Json.of_string input with Json.Error m -> fail "the input is not JSON: %s" m in
  let args = match kind t.request.args with
    | Obj _ | Single Unit -> args
    | _ -> member "value" args in
  let w = Wire.writer () in
  write w string t.protocol;
  write w int t.request.case;
  write_json t.request.args w args;
  let ch = Mynos.connect (Mynos.lookup t.service) in
  let answer =
    Fun.protect ~finally:(fun () -> try Mynos.free_channel ch with Mynos.Error _ -> ())
      (fun () -> Mynos.send ch (Wire.contents w); Mynos.recv ch) in
  let r = Wire.reader answer in
  match read r int with
  | 0 ->
    let v = read_json t.request.reply r in
    if not (Wire.at_end r) then raise (Ipc.Protocol_error (t.service ^ ": bytes left over"));
    Json.to_string v
  | 1 -> raise (Ipc.Remote_error (t.service, read r string))
  | n -> raise (Ipc.Protocol_error (Printf.sprintf "%s: reply case %d" t.service n))
