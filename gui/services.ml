(* The service explorer (doc/decisions/gui.md, phase 2). Every typed
   service describes its protocol (Ipc.describe): this window lists the
   services, their requests, and makes a form for a request from its
   arguments' shape. "Call" sends it as JSON (module Tools) and shows the
   reply. Nothing here knows any protocol in advance. *)

(* the typed services to ask: every name in the registry (registry/1),
   but the terminal windows' consoles ("term<pid>"), one per window *)
let candidates () =
  (try Mynos.registered () with Mynos.Error _ -> [])
  |> List.map (fun (name, _, _) -> name)
  |> List.filter (fun n -> not (String.starts_with ~prefix:"term" n))
  |> List.sort_uniq compare

type state = {
  mutable services : (string * Ipc.description * Tools.t list) list;
  mutable service : int;
  mutable request : int;
  mutable values : (string * string) list;    (* a field's text *)
  mutable result : (bool * string) option;    (* ok, text *)
}

(* the fields of a request's form: (name, JSON type) from its schema *)
let fields (t : Tools.t) =
  match Json.of_string t.Tools.tool.Llm.schema with
  | j ->
    (match Json.member "properties" j with
     | Json.Object props ->
       List.map (fun (n, s) ->
           (n, match s with
             | Json.Object _ -> (match Json.member "type" s with
                 | Json.String ty -> ty
                 | _ -> "json")
             | _ -> "json")) props
     | _ -> [])
  | exception Json.Error _ -> []

let to_json ty text =
  match ty with
  | "integer" -> (match int_of_string_opt (String.trim text) with
      | Some n -> Json.Number (float n)
      | None -> failwith (Printf.sprintf "%S is not a number" text))
  | "string" -> Json.String text
  | "boolean" -> Json.Bool (String.trim text = "true")
  | _ -> (try Json.of_string text with Json.Error m -> failwith m)

(* a reply's JSON, wrapped to the panel's width *)
let wrap width s =
  let per = max 1 (width / Gfx.char_w) in
  let rec go acc s =
    if String.length s <= per then List.rev (s :: acc)
    else go (String.sub s 0 per :: acc) (String.sub s per (String.length s - per)) in
  List.concat_map (go []) (String.split_on_char '\n' s)

let () =
  let st = { services = []; service = 0; request = 0; values = []; result = None } in
  st.services <- List.filter_map (fun name ->
      match Ipc.describe ~timeout:1.0 name with
      | d -> Some (name, d, Tools.of_description name d)
      | exception _ -> None) (candidates ());
  Gui.run ~title:"Services" 760 520 st (fun ui st ->
      let g = ui.Gui.g in
      (* the services *)
      Gfx.fill g 0 0 170 520 0xE6EBF0;
      Gui.label ~bold:true ui 12 10 "Services";
      List.iteri (fun i (name, _, _) ->
          if Gui.list_item ui 4 (34 + i * 24) 162 ~selected:(i = st.service) name then begin
            st.service <- i; st.request <- 0; st.values <- []; st.result <- None
          end) st.services;
      Gui.label ~colour:Gui.muted ui 12 480 "described by";
      Gui.label ~colour:Gui.muted ui 12 496 "themselves";
      match List.nth_opt st.services st.service with
      | None -> Gui.label ui 190 20 "No typed service answered."; st
      | Some (name, d, tools) ->
        (* the requests *)
        Gui.label ~bold:true ui 182 10 d.Ipc.protocol;
        Gui.scroll ~colour:Gui.background ui 1 176 30 178 450 (fun top ->
            List.iteri (fun i (t : Tools.t) ->
                let label = t.request.Ipc.name ^ (if t.request.safe then "" else " *") in
                if Gui.list_item ui 178 (top + i * 22) 160 ~selected:(i = st.request) label
                then begin
                  st.request <- i; st.values <- []; st.result <- None
                end) tools;
            22 * List.length tools);
        Gui.label ~colour:Gui.muted ui 182 496 "* changes things";
        (* the request's form *)
        let x = 362 and w = 386 in
        Gfx.fill g (x - 6) 0 1 520 0xD5DBE1;
        (match List.nth_opt tools st.request with
         | None -> ()
         | Some t ->
           Gui.label ~bold:true ui x 10 (name ^ " \xc2\xb7 " ^ t.request.Ipc.name);
           let y = 32 + Gui.paragraph ~colour:Gui.muted ui x 32 w t.request.doc + 8 in
           let fs = fields t in
           let y = List.fold_left (fun y (i, (fname, ty)) ->
               Gui.label ui x y (Printf.sprintf "%s (%s)" fname ty);
               let v = Option.value (List.assoc_opt fname st.values) ~default:"" in
               let v' = Gui.text_field ui i x (y + 18) w v in
               if v' <> v then st.values <- (fname, v') :: List.remove_assoc fname st.values;
               y + 48) y (List.mapi (fun i f -> (i, f)) fs) in
           if fs = [] then Gui.label ~colour:Gui.muted ui x y "(no arguments)";
           let y = y + (if fs = [] then 24 else 4) in
           if Gui.button ui x y 120 "Call" then begin
             st.result <-
               (match
                  let args = Json.Object (List.map (fun (fname, ty) ->
                      (fname, to_json ty (Option.value (List.assoc_opt fname st.values)
                                            ~default:""))) fs) in
                  Tools.call t (Json.to_string args)
                with
                | reply -> Some (true, reply)
                | exception Ipc.Remote_error (_, m) -> Some (false, m)
                | exception Failure m -> Some (false, m)
                | exception e -> Some (false, Printexc.to_string e))
           end;
           (match st.result with
            | None -> ()
            | Some (ok, text) ->
              let y = y + 40 in
              Gui.label ~bold:true ~colour:(if ok then 0x2E7D32 else 0xC62828) ui x y
                (if ok then "Reply" else "Error");
              let lines = wrap (w - 16 - 10) text in
              Gui.scroll ui 2 x (y + 20) w (max 40 (520 - y - 30)) (fun top ->
                  List.iteri (fun i l ->
                      ignore (Gui.text ui (x + 8) (top + 6 + i * 18) l Gui.foreground)) lines;
                  12 + 18 * List.length lines)));
        st)
