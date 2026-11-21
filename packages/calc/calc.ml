(* calc: a calculator of exact numbers, on OCaml's Num library.

     calc                  read expressions, one a line (quit, or Ctrl-D, ends)
     calc EXPRESSION...    compute them, one an argument

   Integers have no limit (2^200, 50!), fractions stay fractions
   (1/3 + 1/6 = 1/2), and a result that is not an integer is also shown
   in decimals. sqrt, the trigonometric functions, ln, exp and pi give
   approximations (floating point), marked with ~. Names keep values
   (x = 2^10), and _ is the last result. help lists the rest. *)

open Num

type value = Exact of num | Approx of float

exception Error of string
let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

let digits = ref 20          (* the decimals shown *)
let vars : (string, value) Hashtbl.t = Hashtbl.create 16

(* {1 Numbers} *)

let float_of = function Exact n -> float_of_num n | Approx f -> f
let is_int = function Exact n -> is_integer_num n | Approx _ -> false
let int_of v name =
  match v with
  | Exact n when is_integer_num n -> n
  | _ -> error "%s: not an integer" name
let small v name =
  let n = int_of v name in
  if abs_num n >/ Int 1_000_000 then error "%s: too large" name;
  int_of_num n

let arith op fop a b =
  match a, b with
  | Exact x, Exact y -> Exact (op x y)
  | _ -> Approx (fop (float_of a) (float_of b))

let div a b =
  match a, b with
  | _, Exact y when sign_num y = 0 -> error "division by zero"
  | Exact x, Exact y -> Exact (div_num x y)
  | _ -> Approx (float_of a /. float_of b)

let modulo a b =
  match a, b with
  | Exact x, Exact y when is_integer_num x && is_integer_num y ->
    if sign_num y = 0 then error "division by zero" else Exact (mod_num x y)
  | _ -> Approx (Float.rem (float_of a) (float_of b))

let power a b =
  match a, b with
  | Exact x, Exact y when is_integer_num y ->
    if abs_num y >/ Int 100_000 then error "^: the exponent is too large";
    if sign_num x = 0 && sign_num y < 0 then error "division by zero";
    Exact (power_num x y)
  | _ -> Approx (Float.pow (float_of a) (float_of b))

let rec factorial n acc = if n <= 1 then acc else factorial (n - 1) (mult_num acc (Int n))

let gcd a b =
  let rec go a b = if sign_num b = 0 then a else go b (mod_num a b) in
  go (abs_num a) (abs_num b)

(* the prime factors, by trial division: for the numbers of a calculator.
   After 100000 divisions it gives up: the last factor is then [n]'s
   rest, maybe not prime ([false]) *)
let factors n =
  if n </ Int 2 then error "factor: a number from 2"
  else
    let rec go n d acc steps =
      if mult_num d d >/ n then List.rev (if n >/ Int 1 then n :: acc else acc), true
      else if steps > 100_000 then List.rev (n :: acc), false
      else if sign_num (mod_num n d) = 0 then go (quo_num n d) d (d :: acc) (steps + 1)
      else go n (if d =/ Int 2 then Int 3 else add_num d (Int 2)) acc (steps + 1) in
    go n (Int 2) [] 0

(* {1 Expressions} *)

type token = Num of num | Dec of string | Name of string | Op of char | End

let tokens s =
  let n = String.length s in
  let rec go i acc =
    if i >= n then List.rev (End :: acc)
    else match s.[i] with
      | ' ' | '\t' -> go (i + 1) acc
      | '0' .. '9' | '.' ->
        let j = ref i in
        while !j < n && (match s.[!j] with '0' .. '9' | '.' | '_' -> true | _ -> false) do incr j done;
        let t = String.concat "" (String.split_on_char '_' (String.sub s i (!j - i))) in
        if t = "." then error "a lone ."
        else if String.contains t '.' then go !j (Dec t :: acc)
        else go !j (Num (num_of_string t) :: acc)
      | 'a' .. 'z' | 'A' .. 'Z' | '_' ->
        let j = ref i in
        while !j < n && (match s.[!j] with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) do incr j done;
        go !j (Name (String.sub s i (!j - i)) :: acc)
      | '*' when i + 1 < n && s.[i + 1] = '*' -> go (i + 2) (Op '^' :: acc)
      | ('+' | '-' | '*' | '/' | '%' | '^' | '(' | ')' | '!' | ',' | '=') as c -> go (i + 1) (Op c :: acc)
      | c -> error "what is %c?" c in
  go 0 []

(* a decimal written with a point: exact (0.1 is 1/10) *)
let decimal t =
  match String.split_on_char '.' t with
  | [ a; b ] when not (String.contains b '.') ->
    let a = if a = "" then "0" else a in
    Exact (div_num (num_of_string (a ^ b)) (power_num (Int 10) (Int (String.length b))))
  | _ -> error "%s: not a number" t

let funcs : (string * (value list -> value)) list =
  let one name f = name, (function [ x ] -> f x | _ -> error "%s takes one value" name) in
  let two name f = name, (function [ x; y ] -> f x y | _ -> error "%s takes two values" name) in
  let approx name f = one name (fun x -> Approx (f (float_of x))) in
  [ one "sqrt" (fun x ->
        match x with
        | Exact n when sign_num n >= 0 && is_integer_num n ->
          (* exact when it is a square *)
          let f = Float.sqrt (float_of_num n) in
          let r = num_of_string (Printf.sprintf "%.0f" f) in
          if mult_num r r =/ n then Exact r else Approx f
        | _ -> if float_of x < 0. then error "sqrt of a negative number" else Approx (Float.sqrt (float_of x)));
    approx "sin" sin; approx "cos" cos; approx "tan" tan;
    approx "asin" asin; approx "acos" acos; approx "atan" atan;
    approx "ln" log; approx "log" log10; approx "exp" exp;
    one "abs" (function Exact n -> Exact (abs_num n) | Approx f -> Approx (Float.abs f));
    one "floor" (function Exact n -> Exact (floor_num n) | Approx f -> Exact (num_of_string (Printf.sprintf "%.0f" (Float.floor f))));
    one "ceil" (function Exact n -> Exact (ceiling_num n) | Approx f -> Exact (num_of_string (Printf.sprintf "%.0f" (Float.ceil f))));
    one "round" (function Exact n -> Exact (round_num n) | Approx f -> Exact (num_of_string (Printf.sprintf "%.0f" (Float.round f))));
    one "num" (function Exact (Ratio r) -> Exact (Big_int (Ratio.numerator_ratio r)) | Exact n -> Exact n | Approx _ -> error "num: an exact number");
    one "den" (function Exact (Ratio r) -> Exact (Big_int (Ratio.denominator_ratio r)) | Exact _ -> Exact (Int 1) | Approx _ -> error "den: an exact number");
    two "gcd" (fun a b -> Exact (gcd (int_of a "gcd") (int_of b "gcd")));
    two "lcm" (fun a b ->
        let a = int_of a "lcm" and b = int_of b "lcm" in
        if sign_num a = 0 || sign_num b = 0 then Exact (Int 0)
        else Exact (abs_num (quo_num (mult_num a b) (gcd a b))));
    two "C" (fun n k ->
        let n = small n "C" and k = small k "C" in
        if k < 0 || k > n then Exact (Int 0)
        else Exact (div_num (factorial n (Int 1)) (mult_num (factorial k (Int 1)) (factorial (n - k) (Int 1)))));
    one "fib" (fun n ->
        let n = small n "fib" in
        let rec go a b i = if i = 0 then a else go b (add_num a b) (i - 1) in
        Exact (go (Int 0) (Int 1) n));
    one "isprime" (fun n ->
        let n = int_of n "isprime" in
        match factors n with
        | _ when n </ Int 2 -> Exact (Int 0)
        | [ p ], true when p =/ n -> Exact (Int 1)
        | _, true -> Exact (Int 0)
        | [ _ ], false -> error "isprime: too large to tell by division"
        | _ -> Exact (Int 0));
  ]

(* by precedence: a sum of products, a product of unary terms, a unary
   minus over a power, a power of factorials, a factorial of an atom
   (a number, a name, a call, an expression in brackets). ^ groups from
   the right, and binds tighter than a minus before it: -3^2 is -9. *)
let parse toks =
  let toks = ref toks in
  let peek () = List.hd !toks in
  let next () = toks := List.tl !toks in
  let expect c = if peek () = Op c then next () else error "%c expected" c in
  let rec sum () =
    let v = ref (product ()) in
    let rec loop () = match peek () with
      | Op '+' -> next (); v := arith add_num ( +. ) !v (product ()); loop ()
      | Op '-' -> next (); v := arith sub_num ( -. ) !v (product ()); loop ()
      | _ -> () in
    loop (); !v
  and product () =
    let v = ref (unary ()) in
    let rec loop () = match peek () with
      | Op '*' -> next (); v := arith mult_num ( *. ) !v (unary ()); loop ()
      | Op '/' -> next (); v := div !v (unary ()); loop ()
      | Op '%' -> next (); v := modulo !v (unary ()); loop ()
      | _ -> () in
    loop (); !v
  and unary () = match peek () with
    | Op '-' -> next (); arith sub_num ( -. ) (Exact (Int 0)) (unary ())
    | Op '+' -> next (); unary ()
    | _ -> pow ()
  and pow () =
    let b = postfix () in
    match peek () with
    | Op '^' -> next (); power b (unary ())
    | _ -> b
  and postfix () =
    let v = ref (atom ()) in
    while peek () = Op '!' do
      next ();
      v := Exact (factorial (small !v "!") (Int 1))
    done;
    !v
  and atom () = match peek () with
    | Num n -> next (); Exact n
    | Dec t -> next (); decimal t
    | Op '(' -> next (); let v = sum () in expect ')'; v
    | Name "pi" -> next (); Approx Float.pi
    | Name "e" -> next (); Approx (exp 1.)
    | Name f when List.mem_assoc f funcs && (match List.nth_opt !toks 1 with Some (Op '(') -> true | _ -> false) ->
      next (); next ();
      let args = ref [ sum () ] in
      while peek () = Op ',' do next (); args := sum () :: !args done;
      expect ')';
      (List.assoc f funcs) (List.rev !args)
    | Name x -> next ();
      (match Hashtbl.find_opt vars x with
       | Some v -> v
       | None -> error "%s has no value" x)
    | Op c -> error "%c out of place" c
    | End -> error "the expression is cut short" in
  let v = sum () in
  if peek () <> End then error "something after the expression";
  v

(* {1 Showing a value} *)

(* n with !digits decimals, the trailing zeros dropped; and whether
   that is n exactly *)
let decimals n =
  let s = approx_num_fix !digits n in
  let s = if s <> "" && s.[0] = '+' then String.sub s 1 (String.length s - 1) else s in
  let s =
    if String.contains s '.' then begin
      let i = ref (String.length s - 1) in
      while s.[!i] = '0' do decr i done;
      if s.[!i] = '.' then decr i;
      String.sub s 0 (!i + 1)
    end else s in
  let places = match String.index_opt s '.' with Some i -> String.length s - i - 1 | None -> 0 in
  let back = div_num (num_of_string (String.concat "" (String.split_on_char '.' s)))
      (power_num (Int 10) (Int places)) in
  s, back =/ n

let show = function
  | Exact n when is_integer_num n -> string_of_num n
  | Exact n ->
    let d, exact = decimals n in
    Printf.sprintf "%s %s %s" (string_of_num n) (if exact then "=" else "~") d
  | Approx f ->
    if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "~%.0f" f
    else Printf.sprintf "~%.15g" f

let help () = "\
numbers:    123  1_000_000  0.25 (exact: 1/4)  2^200  50!  1/3 + 1/6
operators:  + - * / %  ^ (or **)  ! (factorial)  ( )
functions:  sqrt abs floor ceil round num den gcd(a,b) lcm(a,b) C(n,k)
            fib(n) isprime(n) factor(n); sin cos tan asin acos atan ln log exp
constants:  pi e (approximations, marked ~)
names:      x = 2^10 keeps a value; _ is the last result
commands:   digits N (decimals shown, now " ^ string_of_int !digits ^ "), vars, help, quit"

(* a line: a command, an assignment or an expression *)
let line s =
  let s = String.trim s in
  match String.split_on_char ' ' s with
  | [ "" ] -> None
  | [ "help" ] | [ "?" ] -> Some (help ())
  | [ "digits"; n ] ->
    (match int_of_string_opt n with
     | Some n when n >= 0 && n <= 1000 -> digits := n; Some (Printf.sprintf "%d decimals" n)
     | _ -> error "digits: a number from 0 to 1000")
  | [ "vars" ] ->
    Some (String.concat "\n" (Hashtbl.fold (fun k v acc -> (k ^ " = " ^ show v) :: acc) vars []
                              |> List.sort compare))
  | _ ->
    match tokens s with
    | Name "factor" :: Op '(' :: rest ->
      let v = parse (Op '(' :: rest) in
      let fs, all = factors (int_of v "factor") in
      Some (String.concat " * " (List.map string_of_num fs)
            ^ (if all then "" else "  (the last one not divided further: too large)"))
    | Name x :: Op '=' :: rest when not (List.mem_assoc x funcs) && x <> "pi" && x <> "e" ->
      let v = parse rest in
      Hashtbl.replace vars x v; Hashtbl.replace vars "_" v;
      Some (x ^ " = " ^ show v)
    | toks ->
      let v = parse toks in
      Hashtbl.replace vars "_" v;
      Some (show v)

let eval s =
  match line s with
  | r -> r
  | exception Error m -> Some ("error: " ^ m)
  | exception Failure m -> Some ("error: " ^ m)
  | exception Division_by_zero -> Some "error: division by zero"
  | exception Stack_overflow -> Some "error: too deep"
  | exception e -> Some ("error: " ^ Printexc.to_string e)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [] ->
    let interactive = Sys.getenv_opt "MYNOS_STDIN" = None in
    if interactive then print_endline "calc: exact numbers. help lists what it knows, quit ends.";
    let rec loop () =
      if interactive then (print_string "> "; flush stdout);
      match input_line stdin with
      | "quit" | "exit" -> ()
      | l -> Option.iter print_endline (eval l); loop ()
      | exception End_of_file -> if interactive then print_newline () in
    loop ()
  | exprs ->
    let failed = ref false in
    List.iter (fun e ->
        match eval e with
        | Some r -> if String.starts_with ~prefix:"error: " r then failed := true; print_endline r
        | None -> ()) exprs;
    if !failed then exit 1
