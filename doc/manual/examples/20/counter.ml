(* Gui's example, with a field, a list and a scroll box *)
type state = { n : int; name : string; picked : int; log : string list }

let colours = [ "red"; "green"; "blue"; "cyan"; "magenta"; "yellow" ]

let () =
  Gui.run ~title:"Widgets" 360 300 { n = 0; name = ""; picked = 0; log = [] }
    (fun ui st ->
       Gui.label ui 16 16 (Printf.sprintf "Clicked %d times" st.n);
       let clicked = Gui.button ui 16 40 120 "Click me" in
       Gui.label ui 16 82 "Name:";
       let name = Gui.text_field ui 1 64 78 200 st.name in
       let picked = ref st.picked in
       List.iteri (fun i c ->
           if Gui.list_item ui 16 (112 + 20 * i) 120 ~selected:(i = st.picked) c
           then picked := i) colours;
       Gui.scroll ui 2 160 112 184 120 (fun y0 ->
           List.iteri (fun i l -> Gui.label ~colour:Gui.muted ui 166 (y0 + 4 + 18 * i) l)
             st.log;
           8 + 18 * List.length st.log);
       let log =
         if clicked then Printf.sprintf "click %d (%s)" (st.n + 1) name :: st.log
         else st.log in
       { n = (if clicked then st.n + 1 else st.n); name; picked = !picked; log })
