(* minotaur: a text adventure inside MyNOS. You are a message: sh made
   you to read a file from the disk, and you must come back with it. On
   the way, the services, the registry, the disk and its interrupt, and
   at the centre of the labyrinth the Minotaur, who keeps the kernel's
   ports.

     minotaur          (help, inside, lists the words it knows)

   An original story, written for MyNOS; each room is a part of the
   system as the manual describes it. *)

type room =
  | Workshop | Gate | Hall | Registry | Archive | Machine | Bell | Library | Garden | Sandbox
  | Gallery | Harbour

type item =
  | Request | Reply | Slip | Block_request | Sector | Contents | Leaflet

type state = {
  mutable room : room;
  mutable carrying : item list;
  mutable here : (room * item list) list;
  mutable score : int;
  mutable moves : int;
  mutable seen : room list;
  mutable disk_spinning : int;          (* turns until the interrupt; -1 idle *)
  mutable done_ : bool;
  mutable awarded : string list;
}

let name = function
  | Workshop -> "sh's workshop" | Gate -> "The gate of the kernel" | Hall -> "The hall of ports"
  | Registry -> "The registry's office" | Archive -> "fatfs's archive"
  | Machine -> "ata's machine room" | Bell -> "The bell tower of interrupts"
  | Library -> "memrofs's library" | Garden -> "init's garden" | Sandbox -> "tmpfs's sandbox"
  | Gallery -> "displayd's gallery" | Harbour -> "netd's harbour"

let item_name = function
  | Request -> "request" | Reply -> "reply channel" | Slip -> "port slip"
  | Block_request -> "block request" | Sector -> "sector" | Contents -> "file contents"
  | Leaflet -> "leaflet"

let item_words = function
  | Request -> [ "request"; "message" ] | Reply -> [ "reply"; "channel" ]
  | Slip -> [ "slip"; "port"; "ticket" ] | Block_request -> [ "block" ]
  | Sector -> [ "sector"; "bytes" ] | Contents -> [ "contents"; "file"; "scroll"; "notes" ]
  | Leaflet -> [ "leaflet"; "paper" ]

let describe_item = function
  | Request -> "A request, written in the typed words of the fs/1 protocol: \"read /disk/notes.txt, from byte 0, up to 512 bytes\". It is what you are."
  | Reply -> "A reply channel: the end of a channel that leads back to sh, who waits on the other end. Without it, an answer would have nowhere to go."
  | Slip -> "A slip from the registry: \"fatfs: port 7\". With it, a message knows which door to knock at."
  | Block_request -> "fatfs's own request, for the disk driver: \"sector 2048, one sector\". fatfs knows files; the disk knows only sectors."
  | Sector -> "512 bytes, warm from the disk. To you they mean nothing; to fatfs they are part of a file."
  | Contents -> "The contents of /disk/notes.txt, as fatfs cut them out of the sector:\n  Things to try in MyNOS\n  - gui, and the Tour\n  - trace ls /disk"
  | Leaflet -> "A leaflet, printed in the gallery: \"MyNOS: My! Not another Operating System. 2002, and again 2026.\""

let exits st = function
  | Workshop -> [ "east", Gate ]
  | Gate -> [ "west", Workshop; "east", Hall ]
  | Hall -> [ "west", Gate; "north", Registry; "east", Archive; "south", Machine; "down", Bell;
              "northwest", Library; "northeast", Garden; "southwest", Sandbox;
              "southeast", Gallery; "up", Harbour ]
  | Registry -> [ "south", Hall ]
  | Archive -> [ "west", Hall ]
  | Machine -> [ "north", Hall ]
  | Bell -> [ "up", Hall ]
  | Library -> [ "southeast", Hall ]
  | Garden -> [ "southwest", Hall ]
  | Sandbox -> [ "northeast", Hall ]
  | Gallery -> [ "northwest", Hall ]
  | Harbour -> ignore st; [ "down", Hall ]

let description st = function
  | Workshop ->
    "A workshop full of half-typed lines. sh sits at its bench, its cursor blinking after \"cat /disk/notes.txt\". It made you a moment ago, and it is waiting: a shell waits for its programs, and you are, in a way, its program now. A door leads east, to the kernel."
  | Gate ->
    "A narrow gate, the only way out of a process: every message to another passes here. Across it lies the Minotaur, the guardian of the kernel's ports, horned, patient, older than anything else in the system. The workshop is west; the hall of ports, east."
  | Hall ->
    "The hall of ports, at the centre of the labyrinth: a round hall with doors on every side, each with a number. Messages hurry past you, each knowing its door. North is the registry's office (its number, every message knows); east, a door whose number you "
    ^ (if List.mem Slip st.carrying then "now know: 7, fatfs's archive"
       else "do not know") ^
    ". South, a heavy door marked \"I/O: drivers only\"; down, stairs to a bell tower; the other doors lead to a library, a garden, a sandbox, a gallery, and up to a harbour. The gate is west."
  | Registry ->
    "An office of drawers, each with a name: console, fs/1, display, net, llm... The registry sits behind the counter. It does nothing but this: names to ports, for whoever asks. The hall is south."
  | Archive ->
    "fatfs's archive: shelves of directories, a FAT on the wall like a map of a city of clusters. fatfs, a careful OCaml program, reads requests at a lectern. The hall is west."
  | Machine ->
    "ata's machine room: a spinning platter the size of a carousel, a head on an arm, the smell of 2003. ata, the disk driver, keeps the I/O ports 0x1F0 to 0x1F7 in its pocket. The hall is north."
  | Bell ->
    "A tower with one great bell, IRQ 14, which rings when the disk has finished. Ropes go down to every driver's room. Stairs lead up."
  | Library ->
    "memrofs's library: the RAM disk, every book loaded at boot and bound for good. A sign: \"read-only\". The books are the system's programs: sh.byte, init.byte, ocamlrun, the font. The hall is southeast."
  | Garden ->
    "init's garden. init tends the services as a gardener tends roses: when one dies, init plants it again, five times a minute at most. A gravestone reads \"fatfs, killed in lesson 6, back the same second\". The hall is southwest."
  | Sandbox ->
    "tmpfs's sandbox: whatever is built here is gone when the power goes. Someone has made /tmp/agent.trc out of sand. The hall is northeast."
  | Gallery ->
    "displayd's gallery: windows hang on the walls, each a picture drawn by its own program into memory it shares with displayd. In one, a tree bends in the wind; in another, a glider gun shoots. A leaflet stand is by the door. The hall is northwest."
  | Harbour ->
    "netd's harbour: packets come and go to the wide world, TLS seals on the precious ones. The sea is rough today, and your request is for the disk, not the web. Stairs lead down to the hall."

let say s = print_endline s

(* a paragraph, wrapped at 78 *)
let para s =
  List.iter (fun line ->
      if String.starts_with ~prefix:"  " line then say line else
      let words = String.split_on_char ' ' line in
      let cur = Buffer.create 80 in
      List.iter (fun w ->
          if Buffer.length cur > 0 && Buffer.length cur + 1 + String.length w > 78 then begin
            say (Buffer.contents cur); Buffer.clear cur end;
          if Buffer.length cur > 0 then Buffer.add_char cur ' ';
          Buffer.add_string cur w) words;
      say (Buffer.contents cur)) (String.split_on_char '\n' s)

let items_here st = Option.value (List.assoc_opt st.room st.here) ~default:[]
let set_here st l = st.here <- (st.room, l) :: List.remove_assoc st.room st.here

let award st key points =
  if not (List.mem key st.awarded) then begin
    st.awarded <- key :: st.awarded; st.score <- st.score + points
  end

let look st =
  say ("\027[1m" ^ name st.room ^ "\027[0m");
  para (description st st.room);
  List.iter (fun i -> say ("There is a " ^ item_name i ^ " here.")) (items_here st)

let find_item words l =
  List.find_opt (fun i -> List.exists (fun w -> List.mem w (item_words i)) words) l

let go st dir =
  let dir = match dir with
    | "n" -> "north" | "s" -> "south" | "e" -> "east" | "w" -> "west" | "u" -> "up" | "d" -> "down"
    | "ne" -> "northeast" | "nw" -> "northwest" | "se" -> "southeast" | "sw" -> "southwest" | d -> d in
  match List.assoc_opt dir (exits st st.room) with
  | None -> say "There is no way that way."
  | Some dest ->
    let blocked =
      match st.room, dest with
      | Gate, Hall when not (List.mem Request st.carrying) ->
        Some "The Minotaur lowers his horns. \"A message with nothing to say is no message. Go back to sh for your request.\""
      | Gate, Hall when not (List.mem Reply st.carrying) ->
        Some "The Minotaur sniffs you. \"You carry no reply channel. Whatever you find, how would it get back? I let no message through that cannot be answered, when its sender waits.\""
      | Hall, Archive when not (List.mem Slip st.carrying) ->
        Some "You stand before the door, but which door? There are hundreds, and the numbers mean nothing to you. Someone must tell you fatfs's port."
      | Hall, Machine when not (List.mem Block_request st.carrying) ->
        Some "The door reads \"I/O: drivers only\". A message from sh has no business with the disk itself: only fatfs speaks to ata."
      | _ -> None in
    match blocked with
    | Some m -> para m
    | None ->
      st.room <- dest;
      if not (List.mem dest st.seen) then begin
        st.seen <- dest :: st.seen;
        if List.length st.seen = 12 then begin
          award st "tour" 10; say "(You have seen every room of the labyrinth.)" end
      end;
      if dest = Gate then
        para (if List.mem Contents st.carrying then
                "The Minotaur sees the file contents, and the reply channel. \"Back to sh. Go on.\" He moves aside."
              else "The Minotaur watches you, unblinking.");
      look st

let take st words =
  match find_item words (items_here st) with
  | Some Leaflet -> set_here st (List.filter (( <> ) Leaflet) (items_here st));
    st.carrying <- Leaflet :: st.carrying; say "Taken."
  | Some i -> set_here st (List.filter (( <> ) i) (items_here st)); st.carrying <- i :: st.carrying; say "Taken."
  | None ->
    if st.room = Gallery && List.mem "leaflet" words && not (List.mem Leaflet st.carrying) then begin
      st.carrying <- Leaflet :: st.carrying; say "You take a leaflet from the stand."
    end else if st.room = Library && List.exists (fun w -> w = "book" || w = "books") words then
      para "memrofs shakes its head, kindly. \"Read them here. Nothing leaves, nothing changes: that is what read-only means.\""
    else say "You see no such thing here."

let drop st words =
  match find_item words st.carrying with
  | Some i ->
    st.carrying <- List.filter (( <> ) i) st.carrying;
    set_here st (i :: items_here st);
    say "Dropped.";
    if st.room = Sandbox then para "The sand closes over it. (It will be gone at shutdown; for now, you can still take it.)"
  | None -> say "You do not carry that."

let examine st words =
  match find_item words (st.carrying @ items_here st) with
  | Some i -> para (describe_item i)
  | None ->
    let has w = List.mem w words in
    if has "minotaur" && (st.room = Gate) then
      para "His horns are the shape of the MyNOS logo: you have seen them on the desktop, bottom right. He knows nothing of files, nor of windows. He knows ports, channels, and who may send to whom; he copies each message from one process to another, and that is all he does. It is enough."
    else if (has "sh" || has "shell") && st.room = Workshop then
      para "sh: an OCaml program of a few hundred lines that believes, a little, that it is bash."
    else if has "registry" && st.room = Registry then para "The registry: process 2, the first service after the kernel. Its port is the one number everyone is born knowing."
    else if has "fatfs" && st.room = Archive then para "fatfs reads FAT16 and FAT32, its eight hundred lines of OCaml ready for long names."
    else if has "ata" && st.room = Machine then para "ata, a driver in OCaml: it is a process like any other, except that the kernel gave it I/O ports."
    else if has "bell" && st.room = Bell then para "IRQ 14. When it rings, the kernel wakes whoever waits on it: ata."
    else if has "init" && st.room = Garden then para "init, process 1, reads /init.rc and keeps its promises."
    else if (has "books" || has "book") && st.room = Library then para "Bytecode, mostly: the system's OCaml programs, which ocamlrun reads like scores."
    else if has "windows" && st.room = Gallery then para "Each window is a Gfx buffer shared with displayd; a program draws, then says which part changed."
    else say "You see nothing special."

let talk st words =
  let has w = List.mem w words in
  if has "minotaur" && st.room = Gate then
    para "\"I do not know what a file is,\" says the Minotaur. \"Nor a window, nor a network. Those are the services' business, out there in their own rooms. I keep the ports, I copy the messages, I wake whoever waits. A microkernel, they call me. Small, they say. I say: enough.\""
  else if (has "sh" || has "shell") && st.room = Workshop then
    para (if List.mem Contents st.carrying then "\"You have it? Give it to me,\" says sh."
          else "\"Bring me /disk/notes.txt,\" says sh. \"Take the request and the reply channel; ask the registry where fatfs lives.\"")
  else if has "registry" && st.room = Registry then
    para "\"Ask me for a name,\" says the registry. \"Ask about fatfs, for instance.\""
  else if has "fatfs" && st.room = Archive then
    para "\"Give me your request,\" says fatfs. \"Files are my business.\""
  else if has "ata" && st.room = Machine then
    para "\"Sectors,\" says ata. \"Give me a block request; and then we wait for the bell.\""
  else if has "init" && st.room = Garden then
    para "\"Everyone dies here,\" says init cheerfully. \"Then I start them again. Except me.\""
  else say "No one answers."

let ask st words =
  let has w = List.mem w words in
  if st.room = Registry && (has "fatfs" || has "fs" || has "fs/1" || has "disk" || has "files") then begin
    if List.mem Slip st.carrying then para "\"I told you: port 7,\" says the registry."
    else begin
      para "The registry opens a drawer. \"fatfs: port 7.\" It hands you a slip. (Lookup: one message there, one back.)";
      st.carrying <- Slip :: st.carrying; award st "slip" 10
    end
  end
  else if st.room = Gate && has "minotaur" then talk st words
  else talk st words

let rec give st words =
  match find_item words st.carrying with
  | None -> say "You do not carry that."
  | Some i ->
    match st.room, i with
    | Archive, Request ->
      if List.mem Contents st.carrying then say "fatfs has already answered you."
      else if List.mem Sector st.carrying then begin
        para "fatfs takes the sector, finds the file's bytes in it, and hands you the file contents. \"Your answer. Take it back to sh.\"";
        st.carrying <- Contents :: List.filter (fun x -> x <> Sector) st.carrying;
        award st "contents" 20
      end else begin
        para "fatfs reads your request. \"/disk/notes.txt: cluster 5, sector 2048. I do not have it in memory.\" It writes a block request and hands it to you. \"Take this to ata, south of the hall. I would go, but I have other requests; and a message is what carries a request.\"";
        if not (List.mem Block_request st.carrying) then st.carrying <- Block_request :: st.carrying;
        award st "block" 10
      end
    | Archive, Sector ->
      give st [ "request" ]
    | Machine, Block_request ->
      para "ata takes the block request, writes the sector's number to port 0x1F3 and its neighbours, and sends the command. The platter spins up. \"Now we wait for the bell,\" says ata, \"IRQ 14. While we wait, the CPU does other work: nobody spins in a microkernel.\"";
      st.carrying <- List.filter (( <> ) Block_request) st.carrying;
      st.disk_spinning <- 2
    | Workshop, Contents ->
      para "sh takes the file contents and prints them:\n\n  Things to try in MyNOS\n  - gui, and the Tour\n  - trace ls /disk\n\nThe cursor blinks again after a fresh prompt. Your work is done: a message, sent, answered, and gone, as messages go. Somewhere in the hall the Minotaur copies the next one.";
      st.carrying <- List.filter (( <> ) Contents) st.carrying;
      award st "home" 40; st.done_ <- true
    | Gate, _ -> para "\"I take nothing,\" says the Minotaur. \"I copy.\""
    | _ -> say "No one here wants it."

(* the disk works while you do other things: at each move *)
let tick st =
  if st.disk_spinning > 0 then begin
    st.disk_spinning <- st.disk_spinning - 1;
    if st.disk_spinning = 0 then begin
      st.disk_spinning <- -1;
      if st.room = Machine || st.room = Bell then begin
        para "BONG. The bell of IRQ 14 rings through the tower. The kernel wakes ata, and ata reads 512 bytes from port 0x1F0, two at a time. \"Your sector,\" it says, and gives it to you.";
        st.carrying <- Sector :: st.carrying; award st "sector" 10
      end else begin
        para "Far away, a bell rings: IRQ 14. ata will have your sector ready.";
        st.here <- (Machine, Sector :: Option.value (List.assoc_opt Machine st.here) ~default:[])
                   :: List.remove_assoc Machine st.here;
        award st "sector" 10
      end
    end
  end

let wait st =
  if st.disk_spinning > 0 then say "The platter spins." else say "Time passes."

let help () =
  para "Directions: north, south, east, west (n s e w), ne nw se sw, up, down. look (l), examine THING (x), take, drop, inventory (i), give THING (to whoever is here), talk to SOMEONE, ask SOMEONE about THING, wait (z), score, help, quit."

let inventory st =
  if st.carrying = [] then say "You carry nothing: an empty message."
  else begin say "You carry:"; List.iter (fun i -> say ("  a " ^ item_name i)) st.carrying end

let score st = Printf.printf "Your score is %d of 100, in %d moves.\n" st.score st.moves

let () =
  let st = { room = Workshop; carrying = []; here = [ (Workshop, [ Request; Reply ]) ];
             score = 0; moves = 0; seen = [ Workshop ]; disk_spinning = -1; done_ = false;
             awarded = [] } in
  say "";
  say "\027[1mMINOTAUR\027[0m: a message in the labyrinth";
  say "A story inside MyNOS. Type help for the words it knows.";
  say "";
  look st;
  let rec loop () =
    if st.done_ then begin say ""; score st; say "Thank you for travelling through MyNOS." end
    else begin
      print_string "\n> "; flush stdout;
      match input_line stdin with
      | exception End_of_file -> say ""
      | line ->
        let words = String.split_on_char ' ' (String.lowercase_ascii (String.trim line))
                    |> List.filter (fun w -> w <> "" && not (List.mem w [ "the"; "a"; "an"; "to"; "at"; "with" ])) in
        st.moves <- st.moves + 1;
        (match words with
         | [] -> st.moves <- st.moves - 1
         | [ ("n" | "s" | "e" | "w" | "u" | "d" | "ne" | "nw" | "se" | "sw" | "north" | "south" | "east"
             | "west" | "up" | "down" | "northeast" | "northwest" | "southeast" | "southwest") as d ] -> go st d
         | ("go" | "walk") :: d :: _ -> go st d
         | [ "l" ] | [ "look" ] -> look st
         | ("x" | "examine" | "read" | "look") :: rest -> examine st rest
         | ("take" | "get" | "pick") :: rest -> take st rest
         | "drop" :: rest -> drop st rest
         | [ "i" ] | [ "inventory" ] -> inventory st
         | "give" :: rest | "show" :: rest -> give st rest
         | ("talk" | "speak") :: rest -> talk st rest
         | "ask" :: rest -> ask st rest
         | [ "z" ] | [ "wait" ] -> wait st
         | [ "score" ] -> score st
         | [ "help" ] | [ "?" ] -> help ()
         | [ "xyzzy" ] | [ "plugh" ] ->
           para "Nothing happens. In a microkernel, a magic word would have to be a service, and none is registered under that name."
         | [ "quit" ] | [ "q" ] -> score st; exit 0
         | "write" :: _ when st.room = Library -> para "The ink will not take. \"Read-only,\" says memrofs, not unkindly."
         | _ -> say "I do not know that word. (help lists those I know.)");
        if words <> [] then tick st;
        loop ()
    end in
  loop ()
