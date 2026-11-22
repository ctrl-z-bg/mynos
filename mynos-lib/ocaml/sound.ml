(* Sound over typed IPC: see sound.mli. The service is soundd
   (services/sound/soundd.c), which follows the case numbers below. *)

type _ request =
  | Info : (int * int) request
  | Open : int request
  | Write : int * string -> unit request
  | Close : int -> unit request
  | Stop : int -> unit request
  | Tone : int * int -> unit request
  | Volume : int -> int request

let stream_f = Wire.(field "stream" int)
let info_codec = Wire.(pair (field "rate" int) (field "channels" int))
let write_args = Wire.(pair stream_f (field "samples" string))
let tone_args = Wire.(pair (field "hz" int) (field "ms" int))
let level_f = Wire.(field "level" int)

module Protocol = struct
  let id = "sound/1"
  let summary =
    "Sound (soundd, in C): streams of samples mixed and played by a Sound Blaster 16, \
     tones, the volume."
  let requests = Ipc.[
      request ~safe:true 0 "info"
        "The output: samples a second, and channels (16-bit signed samples, little-endian)."
        Wire.unit info_codec;
      request 1 "open" "A stream of samples, mixed with the others: its number."
        Wire.unit Wire.int;
      request 2 "write"
        "Samples for a stream: stereo pairs of 16-bit signed little-endian samples at the \
         output's rate. Waits while the stream holds more than a second."
        write_args Wire.unit;
      request 3 "close" "The stream ends when what it holds has played. Waits until then."
        stream_f Wire.unit;
      request 4 "stop" "The stream ends at once." stream_f Wire.unit;
      request 5 "tone" "A tone (a square wave), mixed with the rest." tone_args Wire.unit;
      request 6 "volume" "The volume, 0 to 100 (-1: unchanged): the one in use."
        level_f Wire.int ]
  type 'a r = 'a request
  type 'a request = 'a r
  type packed = Request : 'a request -> packed

  let write_request (type a) w (r : a request) =
    let case n = Wire.write w Wire.int n in
    match r with
    | Info -> case 0
    | Open -> case 1
    | Write (s, d) -> case 2; Wire.write w write_args (s, d)
    | Close s -> case 3; Wire.write w stream_f s
    | Stop s -> case 4; Wire.write w stream_f s
    | Tone (hz, ms) -> case 5; Wire.write w tone_args (hz, ms)
    | Volume v -> case 6; Wire.write w level_f v

  let read_request r =
    match Wire.read r Wire.int with
    | 0 -> Request Info
    | 1 -> Request Open
    | 2 -> let s, d = Wire.read r write_args in Request (Write (s, d))
    | 3 -> Request (Close (Wire.read r stream_f))
    | 4 -> Request (Stop (Wire.read r stream_f))
    | 5 -> let hz, ms = Wire.read r tone_args in Request (Tone (hz, ms))
    | 6 -> Request (Volume (Wire.read r level_f))
    | n -> raise (Wire.Error (Printf.sprintf "sound: unknown request %d" n))

  let reply : type a. a request -> a Wire.t = function
    | Info -> info_codec
    | Open -> Wire.int
    | Write _ -> Wire.unit
    | Close _ -> Wire.unit
    | Stop _ -> Wire.unit
    | Tone _ -> Wire.unit
    | Volume _ -> Wire.int
end

module I = Ipc.Make (Protocol)

type t = I.client

let connect () = I.connect "sound"
let call = I.call
let rate = 22050

let get = function Some s -> s | None -> connect ()

let tone ?sound hz ms = call (get sound) (Tone (hz, ms))
let volume ?sound level = call (get sound) (Volume level)

type stream = { sound : t; id : int }

let open_stream ?sound () = let s = get sound in { sound = s; id = call s Open }
let write st data = call st.sound (Write (st.id, data))
let close st = call st.sound (Close st.id)
let stop st = call st.sound (Stop st.id)

(* {1 WAV} *)

type wav = { channels : int; wav_rate : int; bits : int; data : string }

let u16 s i = Char.code s.[i] lor (Char.code s.[i + 1] lsl 8)
let u32 s i = u16 s i lor (u16 s (i + 2) lsl 16)

(* RIFF, WAVE, then chunks: "fmt " and "data" are needed *)
let read_wav s =
  let n = String.length s in
  if n < 12 || String.sub s 0 4 <> "RIFF" || String.sub s 8 4 <> "WAVE" then
    failwith "not a WAV file";
  let rec chunks i fmt =
    if i + 8 > n then failwith "a WAV file without data"
    else
      let id = String.sub s i 4 and len = u32 s (i + 4) in
      let len = min len (n - i - 8) in
      match id with
      | "fmt " ->
        if len < 16 then failwith "a WAV file with a short format";
        chunks (i + 8 + len + (len land 1)) (Some (i + 8))
      | "data" ->
        (match fmt with
         | None -> failwith "a WAV file without a format before its data"
         | Some f ->
           let format = u16 s f and channels = u16 s (f + 2)
           and wav_rate = u32 s (f + 4) and bits = u16 s (f + 14) in
           if format <> 1 then failwith "not PCM (compressed WAV files are not read)";
           if channels < 1 || channels > 2 then failwith "WAV: 1 or 2 channels only";
           if bits <> 8 && bits <> 16 then failwith "WAV: 8 or 16 bits only";
           if wav_rate < 1000 || wav_rate > 192000 then failwith "WAV: a strange rate";
           { channels; wav_rate; bits; data = String.sub s (i + 8) len })
      | _ -> chunks (i + 8 + len + (len land 1)) fmt in
  chunks 12 None

(* positions in floats: on MyNOS's i386 an int has 31 bits, and a frame
   number times a rate passes them within a minute of music *)
let in_frames w = String.length w.data / (w.channels * w.bits / 8)
let frames w = int_of_float (float (in_frames w) *. float rate /. float w.wav_rate)

(* a sample of the file: frame [f], channel [c], as 16-bit *)
let sample w f c =
  let c = if c < w.channels then c else 0 in
  if w.bits = 8 then (Char.code w.data.[f * w.channels + c] - 128) lsl 8
  else
    let i = 2 * (f * w.channels + c) in
    let v = u16 w.data i in
    if v >= 0x8000 then v - 0x10000 else v

(* output frames by linear interpolation between the file's *)
let convert w first count =
  let total = in_frames w in
  let count = max 0 (min count (frames w - first)) in
  let b = Bytes.create (4 * count) in
  let ratio = float w.wav_rate /. float rate in
  for k = 0 to count - 1 do
    (* the position in the file: a frame, and 1/65536 of one *)
    let pos = float (first + k) *. ratio in
    let f = min (total - 1) (int_of_float pos) in
    let frac = int_of_float ((pos -. float f) *. 65536.) in
    let g = if f + 1 < total then f + 1 else f in
    for c = 0 to 1 do
      let a = sample w f c and z = sample w g c in
      let v = a + (z - a) * frac / 65536 in
      Bytes.set_uint16_le b (4 * k + 2 * c) (v land 0xFFFF)
    done
  done;
  Bytes.to_string b

let play_file ?sound path =
  let w = read_wav (In_channel.with_open_bin path In_channel.input_all) in
  let st = open_stream ?sound () in
  let total = frames w in
  let rec go first =
    if first < total then begin
      write st (convert w first rate);
      go (first + rate)
    end in
  (try go 0 with e -> (try stop st with _ -> ()); raise e);
  close st
