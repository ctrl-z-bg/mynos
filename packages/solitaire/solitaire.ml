(* solitaire: Klondike patience. Build the four foundations up by suit,
   from the ace to the king; on the seven columns, cards go down in
   alternate colours, and only a king fills an empty column. Drag cards
   with the mouse, or click one: it goes where it can (a foundation
   first). Click the stock to turn a card. U undoes, N deals again, Q
   quits; Auto sends to the foundations whatever can go. *)

type card = { rank : int; suit : int; mutable up : bool }   (* rank 1-13, suit 0-3 *)

let red c = c.suit = 1 || c.suit = 2
(* the suits, drawn: the screen's font has the diamond only *)
let suit_bits = [|
  [| "....#...."; "...###..."; "..#####.."; ".#######."; "#########"; "#########";
     ".##.#.##."; "....#...."; "...###..." |];                                      (* spades *)
  [| ".##...##."; "####.####"; "#########"; "#########"; ".#######."; "..#####..";
     "...###..."; "....#...."; "........." |];                                      (* hearts *)
  [| "....#...."; "...###..."; "..#####.."; ".#######."; "#########"; ".#######.";
     "..#####.."; "...###..."; "....#...." |];                                      (* diamonds *)
  [| "...###..."; "...###..."; ".#.###.#."; "#########"; "#########"; ".#..#..#.";
     "....#...."; "...###..."; "........." |];                                      (* clubs *)
|]

let draw_suit gx x y scale suit colour =
  Array.iteri (fun r row ->
      String.iteri (fun c ch ->
          if ch = '#' then Gfx.fill gx (x + c * scale) (y + r * scale) scale scale colour) row)
    suit_bits.(suit)
let ranks = [| ""; "A"; "2"; "3"; "4"; "5"; "6"; "7"; "8"; "9"; "10"; "J"; "Q"; "K" |]

let cw = 64 and ch = 88 and gap = 12
let width = 7 * cw + 8 * gap and height = 566
let top = 44
let col_x i = gap + i * (cw + gap)
let row2 = top + ch + 20                    (* the columns' top *)
let fan_down = 8 and fan_up = 22

type place = Stock | Waste | Found of int | Col of int

type game = {
  mutable stock : card list;                (* the top first *)
  mutable waste : card list;
  found : card list array;
  cols : card list array;                   (* the top (last dealt) first *)
  mutable undo : (card list * card list * card list array * card list array * (card * bool) list) list;
  mutable moves : int;
}

let deal () =
  let deck = Array.init 52 (fun i -> { rank = i mod 13 + 1; suit = i / 13; up = false }) in
  for i = 51 downto 1 do
    let j = Random.int (i + 1) in let t = deck.(i) in deck.(i) <- deck.(j); deck.(j) <- t
  done;
  let deck = ref (Array.to_list deck) in
  let take () = match !deck with c :: rest -> deck := rest; c | [] -> assert false in
  let cols = Array.init 7 (fun i ->
      let cs = List.init (i + 1) (fun _ -> take ()) in
      (List.hd cs).up <- true; cs) in
  { stock = !deck; waste = []; found = Array.make 4 []; cols; undo = []; moves = 0 }

let all_cards g =
  g.stock @ g.waste @ List.concat (Array.to_list g.found) @ List.concat (Array.to_list g.cols)

let save g =
  g.undo <- (g.stock, g.waste, Array.copy g.found, Array.copy g.cols,
             List.map (fun c -> (c, c.up)) (all_cards g)) :: g.undo

let undo g =
  match g.undo with
  | (s, w, f, c, ups) :: rest ->
    g.stock <- s; g.waste <- w;
    Array.blit f 0 g.found 0 4; Array.blit c 0 g.cols 0 7;
    List.iter (fun (card, up) -> card.up <- up) ups;
    g.undo <- rest
  | [] -> ()

let won g = Array.for_all (fun f -> List.length f = 13) g.found

(* {1 Moves} *)

let can_found g cards i =
  match cards with
  | [ c ] -> (match g.found.(i) with
      | [] -> c.rank = 1
      | t :: _ -> t.suit = c.suit && c.rank = t.rank + 1)
  | _ -> false

(* [cards]: the bottom one last *)
let can_col g cards i =
  match List.rev cards with
  | [] -> false
  | bottom :: _ ->
    match g.cols.(i) with
    | [] -> bottom.rank = 13
    | t :: _ -> t.up && red t <> red bottom && bottom.rank = t.rank - 1

(* the cards taken from a place: [n] from the top of a column *)
let take g from n =
  match from with
  | Waste -> let c = List.hd g.waste in g.waste <- List.tl g.waste; [ c ]
  | Found i -> let c = List.hd g.found.(i) in g.found.(i) <- List.tl g.found.(i); [ c ]
  | Col i ->
    let cs = List.filteri (fun k _ -> k < n) g.cols.(i) in
    g.cols.(i) <- List.filteri (fun k _ -> k >= n) g.cols.(i);
    (match g.cols.(i) with t :: _ -> t.up <- true | [] -> ());
    cs
  | Stock -> []

let put g cards dest =
  match dest with
  | Found i -> g.found.(i) <- cards @ g.found.(i)
  | Col i -> g.cols.(i) <- cards @ g.cols.(i)
  | _ -> ()

(* the cards a place would give: n from the top *)
let peek g from n =
  match from with
  | Waste -> (match g.waste with c :: _ -> [ c ] | [] -> [])
  | Found i -> (match g.found.(i) with c :: _ -> [ c ] | [] -> [])
  | Col i -> List.filteri (fun k _ -> k < n) g.cols.(i)
  | Stock -> []

let legal g cards dest =
  match dest with
  | Found i -> can_found g cards i
  | Col i -> can_col g cards i
  | _ -> false

let move g from n dest =
  let cards = peek g from n in
  if cards <> [] && from <> dest && legal g cards dest then begin
    save g; put g (take g from n) dest; g.moves <- g.moves + 1; true
  end else false

let turn_stock g =
  save g;
  match g.stock with
  | c :: rest -> c.up <- true; g.stock <- rest; g.waste <- c :: g.waste
  | [] ->
    g.stock <- List.rev_map (fun c -> c.up <- false; c) g.waste; g.waste <- []

(* a click on cards: they go to a foundation, else to a column *)
let smart g from n =
  let dests = (if n = 1 then List.init 4 (fun i -> Found i) else [])
              @ List.init 7 (fun i -> Col i) in
  List.exists (fun d -> move g from n d) dests

let auto g =
  let rec go () =
    let froms = Waste :: List.init 7 (fun i -> Col i) in
    if List.exists (fun f -> List.exists (fun i -> move g f 1 (Found i)) [ 0; 1; 2; 3 ]) froms
    then go () in
  go ()

(* {1 The table} *)

let card_y g i k =
  (* the k-th card from the bottom of column i *)
  let cs = List.rev g.cols.(i) in
  let y = ref row2 in
  List.iteri (fun j c -> if j < k then y := !y + (if c.up then fan_up else fan_down)) cs;
  !y

(* the place under the pointer, and how many cards it gives *)
let hit g x y =
  let inside cx cy = x >= cx && x < cx + cw && y >= cy && y < cy + ch in
  if inside (col_x 0) top then Some (Stock, 0)
  else if inside (col_x 1) top then Some (Waste, 1)
  else match List.find_opt (fun i -> inside (col_x (3 + i)) top) [ 0; 1; 2; 3 ] with
    | Some i -> Some (Found i, 1)
    | None ->
      match List.find_opt (fun i -> x >= col_x i && x < col_x i + cw) (List.init 7 Fun.id) with
      | None -> None
      | Some i ->
        let n = List.length g.cols.(i) in
        if n = 0 then (if y >= row2 && y < row2 + ch then Some (Col i, 0) else None)
        else
          (* the top card covers the most; the others, their strip *)
          let rec find k =
            if k < 0 then None
            else
              let cy = card_y g i k in
              let bottom = if k = n - 1 then cy + ch else card_y g i (k + 1) in
              if y >= cy && y < bottom then
                (let c = List.nth (List.rev g.cols.(i)) k in
                 if c.up then Some (Col i, n - k) else None)
              else find (k - 1) in
          find (n - 1)

let draw_back gx x y =
  Gfx.fill gx x y cw ch 0x1A4F8B;
  Gfx.rect gx x y cw ch 0x0D2E55;
  Gfx.rect gx (x + 4) (y + 4) (cw - 8) (ch - 8) 0x5C8FC7;
  for k = 0 to 5 do
    Gfx.line gx (x + 6) (y + 10 + k * 12) (x + cw - 7) (y + 16 + k * 12) 0x3C73B0
  done

let draw_card gx x y c =
  if not c.up then draw_back gx x y
  else begin
    Gfx.fill gx x y cw ch 0xFFFFFF;
    Gfx.rect gx x y cw ch 0x90A4AE;
    let col = if red c then 0xC62828 else 0x212121 in
    let r = ranks.(c.rank) in
    ignore (Gfx.text ~bold:true gx (x + 4) (y + 3) r col);
    draw_suit gx (x + 6 + Gfx.char_w * String.length r) (y + 7) 1 c.suit col;
    draw_suit gx (x + cw / 2 - 9) (y + ch / 2 - 7) 2 c.suit col;
    draw_suit gx (x + cw - 14) (y + ch - 14) 1 c.suit col;
    ignore (Gfx.text ~bold:true gx (x + cw - 16 - Gfx.char_w * String.length r) (y + ch - 19) r col)
  end

let slot gx x y label =
  Gfx.rect gx x y cw ch 0x5E8C6A;
  if label <> "" then ignore (Gfx.text gx (x + cw / 2 - 4) (y + ch / 2 - 8) label 0x5E8C6A)

type drag = { from : place; n : int; cards : card list; dx : int; dy : int }

type state = { mutable g : game; mutable drag : drag option; mutable down : bool }

let draw ui st =
  let gx = ui.Gui.g and g = st.g in
  Gfx.fill gx 0 0 width height 0x2E6B3F;
  let dragged c = match st.drag with Some d -> List.memq c d.cards | None -> false in
  (match g.stock with [] -> slot gx (col_x 0) top "" | _ -> draw_back gx (col_x 0) top);
  (match List.filter (fun c -> not (dragged c)) g.waste with
   | c :: _ -> draw_card gx (col_x 1) top c
   | [] -> slot gx (col_x 1) top "");
  Array.iteri (fun i f ->
      match List.filter (fun c -> not (dragged c)) f with
      | c :: _ -> draw_card gx (col_x (3 + i)) top c
      | [] -> slot gx (col_x (3 + i)) top "A") g.found;
  Array.iteri (fun i cs ->
      if cs = [] then slot gx (col_x i) row2 "K";
      List.iteri (fun k c ->
          if not (dragged c) then draw_card gx (col_x i) (card_y g i k) c) (List.rev cs)) g.cols;
  (match st.drag with
   | Some d ->
     List.iteri (fun k c -> draw_card gx (ui.Gui.mx - d.dx) (ui.Gui.my - d.dy + k * fan_up) c)
       (List.rev d.cards)
   | None -> ());
  if won g then begin
    Gfx.fill gx (width / 2 - 150) 300 300 70 0x1B3A26;
    ignore (Gfx.text ~bold:true gx (width / 2 - 64) 316 "All home! Well done." 0xFFFFFF);
    ignore (Gfx.text gx (width / 2 - 56) 340 "N deals again" 0xA5D6A7)
  end

let () =
  Random.self_init ();
  Gui.run ~title:"Solitaire" width height { g = deal (); drag = None; down = false } (fun ui st ->
      let pressed = ui.Gui.buttons land 1 <> 0 in
      (* pressed on cards: they follow the pointer *)
      if pressed && not st.down then begin
        st.down <- true;
        let (px, py) = ui.Gui.press in
        match hit st.g px py with
        | Some ((Waste | Found _ | Col _) as from, n) when n > 0 ->
          let cards = peek st.g from n in
          if cards <> [] then begin
            let cx = match from with
              | Waste -> col_x 1 | Found i -> col_x (3 + i) | Col i -> col_x i | Stock -> 0 in
            let cy = match from with
              | Col i -> card_y st.g i (List.length st.g.cols.(i) - n) | _ -> top in
            st.drag <- Some { from; n; cards; dx = px - cx; dy = py - cy }
          end
        | _ -> ()
      end;
      if ui.Gui.clicked then begin
        st.down <- false;
        let (px, py) = ui.Gui.press in
        let still = abs (ui.Gui.mx - px) < 4 && abs (ui.Gui.my - py) < 4 in
        (match st.drag with
         | Some d when still -> ignore (smart st.g d.from d.n)
         | Some d ->
           (* dropped: on the place whose card or slot is under the pointer *)
           let x = ui.Gui.mx - d.dx + cw / 2 and y = ui.Gui.my - d.dy + 10 in
           let dest =
             if y < top + ch && y >= top - 20 then
               List.find_opt (fun i -> abs (x - (col_x (3 + i) + cw / 2)) < cw) [ 0; 1; 2; 3 ]
               |> Option.map (fun i -> Found i)
             else
               List.find_opt (fun i -> abs (x - (col_x i + cw / 2)) < (cw + gap) / 2) (List.init 7 Fun.id)
               |> Option.map (fun i -> Col i) in
           Option.iter (fun dest -> ignore (move st.g d.from d.n dest)) dest
         | None ->
           (match hit st.g px py with
            | Some (Stock, _) when still -> turn_stock st.g
            | _ -> ()));
        st.drag <- None
      end;
      List.iter (function
          | "q" | "Q" -> raise Gui.Quit
          | "u" | "U" -> undo st.g
          | "n" | "N" -> st.g <- deal ()
          | "a" | "A" -> auto st.g
          | " " -> turn_stock st.g
          | _ -> ()) ui.Gui.keys;
      draw ui st;
      (* the bar, over the table *)
      Gfx.fill ui.Gui.g 0 0 width (top - 8) 0x245633;
      if Gui.button ui (col_x 3) 5 66 "Undo" then undo st.g;
      if Gui.button ui (col_x 4) 5 66 "Auto" then auto st.g;
      if Gui.button ui (col_x 5) 5 66 "New" then st.g <- deal ();
      ignore (Gfx.text ui.Gui.g (col_x 0) 10 (Printf.sprintf "Moves %d" st.g.moves) 0xD7EAD9);
      st)
