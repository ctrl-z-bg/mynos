let sector = 512
let max_count = 32

type t = { port : int; size : int }

let request typ lba count =
  let b = Bytes.create 12 in
  Bytes.set_int32_le b 0 (Int32.of_int typ);
  Bytes.set_int32_le b 4 (Int32.of_int lba);
  Bytes.set_int32_le b 8 (Int32.of_int count);
  Bytes.to_string b

let status_text = function
  | 1 -> "invalid request"
  | 2 -> "I/O error"
  | n -> "status " ^ string_of_int n

(* one exchange: the reply's value; [data] is sent after the request,
   [k] runs on the channel before it is freed (to receive data) *)
let call port ?data typ lba count k =
  let ch = Mynos.connect port in
  Fun.protect ~finally:(fun () -> try Mynos.free_channel ch with _ -> ())
    (fun () ->
       Mynos.send ch (request typ lba count);
       Option.iter (Mynos.send ch) data;
       let r = Mynos.recv ch in
       let status = Int32.to_int (String.get_int32_le r 0)
       and value = Int32.to_int (String.get_int32_le r 4) in
       if status <> 0 then failwith ("Block: " ^ status_text status);
       k ch value)

let connect ?(service = "ata0") () =
  let port = Mynos.lookup service in
  { port; size = call port 0 0 0 (fun _ v -> v) }

let sectors d = d.size

let read d lba count =
  let buf = Buffer.create (count * sector) in
  let rec go lba count =
    if count > 0 then begin
      let n = min count max_count in
      Buffer.add_string buf (call d.port 1 lba n (fun ch _ -> Mynos.recv ch));
      go (lba + n) (count - n)
    end in
  go lba count;
  Buffer.contents buf

let write d lba bytes =
  if String.length bytes mod sector <> 0 then
    invalid_arg "Block.write: not a whole number of sectors";
  let rec go lba off =
    if off < String.length bytes then begin
      let n = min ((String.length bytes - off) / sector) max_count in
      let data = String.sub bytes off (n * sector) in
      call d.port ~data 2 lba n (fun _ _ -> ());
      go (lba + n) (off + n * sector)
    end in
  go lba 0
