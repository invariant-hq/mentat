(* The one test helper binary on PATH under its plain name [mentat_cram], the
   mentat analog of dune's [dune_cmd]. Every subcommand is pure and trivially
   portable: normalization ([censor]) delegates to {!Mentat_test_censor} so cram
   goldens and TUI frames share one marker vocabulary; the rest replace the
   [sed]/[grep -o]/[tr]/[stat] idioms the landed crams reach for. The one
   deliberately effectful subcommand is [lock], which holds the store's own
   run-fence primitive so a held-contention scenario needs no inline python
   fcntl fixture; the surrounding spawn/signal/reap choreography still stays as
   bash in the .t. *)

exception Cram_error of int * string

let fail ?(code = 1) fmt =
  Printf.ksprintf (fun s -> raise (Cram_error (code, s))) fmt

let read_stdin () = In_channel.input_all In_channel.stdin

let read_source = function
  | None -> read_stdin ()
  | Some path -> (
      try In_channel.with_open_bin path In_channel.input_all
      with Sys_error msg -> fail "%s" msg)

(* censor. *)

let cmd_censor args =
  let times = List.mem "--times" args in
  let extra = if times then Mentat_test_censor.times else [] in
  print_string (Mentat_test_censor.apply ~extra (read_stdin ()))

(* json. *)

type step = Key of string | Index of int | Iter

(* .diff[0].path / .headers.authorization / .input[] / .type *)
let parse_json_path p =
  let n = String.length p in
  let steps = ref [] and buf = Buffer.create 16 and i = ref 0 in
  let flush () =
    if Buffer.length buf > 0 then (
      steps := Key (Buffer.contents buf) :: !steps;
      Buffer.clear buf)
  in
  while !i < n do
    match p.[!i] with
    | '.' ->
        flush ();
        incr i
    | '[' ->
        flush ();
        let j =
          try String.index_from p !i ']'
          with Not_found -> fail "malformed json path: unclosed '[' in %S" p
        in
        let inner = String.sub p (!i + 1) (j - !i - 1) in
        (if inner = "" then steps := Iter :: !steps
         else
           match int_of_string_opt inner with
           | Some k -> steps := Index k :: !steps
           | None -> fail "malformed json path: %S is not an index" inner);
        i := j + 1
    | c ->
        Buffer.add_char buf c;
        incr i
  done;
  flush ();
  List.rev !steps

let json_step step (v : Jsont.Json.t) =
  match (step, v) with
  | Key k, Jsont.Object (members, _) -> (
      match Jsont.Json.find_mem k members with
      | Some (_, value) -> [ value ]
      | None -> fail "no member %S" k)
  | Key k, _ -> fail "member %S: value is not an object" k
  | Index k, Jsont.Array (l, _) -> (
      match List.nth_opt l k with
      | Some x -> [ x ]
      | None -> fail "index %d out of range" k)
  | Index k, _ -> fail "index %d: value is not an array" k
  | Iter, Jsont.Array (l, _) -> l
  | Iter, _ -> fail "[]: value is not an array"

(* A terminal string prints raw (unquoted) so `json .model` yields [gpt-5.6-sol];
   every other value prints as minified JSON. *)
let json_print (v : Jsont.Json.t) =
  match v with
  | Jsont.String (s, _) ->
      print_string s;
      print_newline ()
  | v -> (
      match Jsont_bytesrw.encode_string Jsont.json v with
      | Ok s ->
          print_string s;
          print_newline ()
      | Error msg -> fail "re-encode failed: %s" msg)

let cmd_json args =
  let path, file =
    match args with
    | [ path ] -> (path, None)
    | [ path; file ] -> (path, Some file)
    | _ -> fail ~code:2 "usage: mentat_cram json PATH [file]"
  in
  let root =
    match Jsont_bytesrw.decode_string Jsont.json (read_source file) with
    | Ok j -> j
    | Error msg -> fail "invalid JSON: %s" msg
  in
  let steps = parse_json_path path in
  let values =
    List.fold_left
      (fun acc s -> List.concat_map (json_step s) acc)
      [ root ] steps
  in
  List.iter json_print values

(* subst. *)

let split_pat_repl_file = function
  | pat :: repl :: rest ->
      let file =
        match rest with
        | [] -> None
        | [ f ] -> Some f
        | _ -> fail ~code:2 "too many arguments"
      in
      (pat, repl, file)
  | _ -> fail ~code:2 "usage: PATTERN REPLACEMENT [file]"

let cmd_subst args =
  let pat, repl, file = split_pat_repl_file args in
  let re = Re.compile (Re.Pcre.re pat) in
  print_string (Re.replace ~all:true re (read_source file) ~f:(fun _ -> repl))

(* wait-file / wait-line. *)

let take_timeout default args =
  let rec loop acc t = function
    | "--timeout" :: v :: rest -> (
        match float_of_string_opt v with
        | Some f -> loop acc f rest
        | None -> fail ~code:2 "--timeout expects seconds")
    | x :: rest -> loop (x :: acc) t rest
    | [] -> (List.rev acc, t)
  in
  loop [] default args

let poll ~timeout ~step ~ready =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if ready () then true
    else if Unix.gettimeofday () >= deadline then false
    else (
      ignore (Unix.select [] [] [] step);
      loop ())
  in
  loop ()

let file_nonempty path =
  try (Unix.stat path).Unix.st_size > 0 with Unix.Unix_error _ -> false

let cmd_wait_file args =
  let pos, timeout = take_timeout 30. args in
  let path =
    match pos with
    | [ p ] -> p
    | _ -> fail ~code:2 "usage: mentat_cram wait-file PATH [--timeout S]"
  in
  if not (poll ~timeout ~step:0.05 ~ready:(fun () -> file_nonempty path)) then
    fail "timed out after %gs waiting for %s" timeout path

let file_has_line re path =
  try
    In_channel.with_open_text path (fun ic ->
        let rec loop () =
          match In_channel.input_line ic with
          | None -> false
          | Some line -> if Re.execp re line then true else loop ()
        in
        loop ())
  with Sys_error _ -> false

let cmd_wait_line args =
  let pos, timeout = take_timeout 30. args in
  let pat, path =
    match pos with
    | [ p; f ] -> (p, f)
    | _ ->
        fail ~code:2 "usage: mentat_cram wait-line PATTERN FILE [--timeout S]"
  in
  let re = Re.compile (Re.Pcre.re pat) in
  if not (poll ~timeout ~step:0.05 ~ready:(fun () -> file_has_line re path))
  then fail "timed out after %gs waiting for /%s/ in %s" timeout pat path

(* count-ctl. *)

let default_ctl c =
  let x = Char.code c in
  (x < 0x20 && x <> 9 && x <> 10 && x <> 13) || x = 0x7f

let cmd_count_ctl args =
  let pos, _ = take_timeout 0. args in
  let member =
    let rec find = function
      | "--bytes" :: v :: _ ->
          let set = Hashtbl.create 16 in
          String.split_on_char ',' v
          |> List.iter (fun s ->
              match int_of_string_opt (String.trim s) with
              | Some b -> Hashtbl.replace set (Char.chr (b land 0xff)) ()
              | None ->
                  fail ~code:2 "--bytes expects a comma list of byte values");
          fun c -> Hashtbl.mem set c
      | _ :: rest -> find rest
      | [] -> default_ctl
    in
    find args
  in
  ignore pos;
  let s = read_stdin () in
  let n = ref 0 in
  String.iter (fun c -> if member c then incr n) s;
  Printf.printf "%d\n" !n

(* stat. *)

let cmd_stat args =
  let kind, path =
    match args with
    | [ k; p ] -> (k, p)
    | _ -> fail ~code:2 "usage: mentat_cram stat KIND PATH"
  in
  let st =
    try Unix.lstat path
    with Unix.Unix_error (e, _, _) ->
      fail "%s: %s" path (Unix.error_message e)
  in
  let out =
    match kind with
    | "perms" -> Printf.sprintf "%o" (st.Unix.st_perm land 0o7777)
    | "size" -> string_of_int st.Unix.st_size
    | "kind" -> (
        match st.Unix.st_kind with
        | Unix.S_REG -> "file"
        | Unix.S_DIR -> "directory"
        | Unix.S_LNK -> "symlink"
        | Unix.S_CHR -> "character-special"
        | Unix.S_BLK -> "block-special"
        | Unix.S_FIFO -> "fifo"
        | Unix.S_SOCK -> "socket")
    | k -> fail ~code:2 "unknown stat kind %S; expected perms, kind, or size" k
  in
  print_endline out

(* hmac-sha256. Sign a webhook delivery body the way GitHub does — the
   lowercase hex HMAC-SHA256 over the file's exact bytes — so a cram mints
   X-Hub-Signature-256 headers against a charter's minted secret without an
   ambient openssl. The key is taken as an argument: crams read it with
   $(cat secrets/webhook), whose trailing-newline strip matches the
   listener's trim of the stored secret. *)
let cmd_hmac_sha256 args =
  let key, file =
    match args with
    | [ key ] -> (key, None)
    | [ key; file ] -> (key, Some file)
    | _ -> fail ~code:2 "usage: mentat_cram hmac-sha256 KEY [FILE]"
  in
  print_endline
    (Digestif.SHA256.to_hex
       (Digestif.SHA256.hmac_string ~key (read_source file)))

(* lock. Hold an exclusive POSIX record lock ([lockf F_LOCK]) — the same fence
   the store's run lock takes — on a file until a signal terminates the process,
   printing "ready" once the lock is held. A held-fence contention scenario runs
   the helper in the background, waits for readiness, drives the contending
   command, then kills it — all in bash. *)
let cmd_lock args =
  let path =
    match args with
    | [ path ] -> path
    | _ -> fail ~code:2 "usage: mentat_cram lock PATH"
  in
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
  let rec acquire () =
    try Unix.lockf fd Unix.F_LOCK 0
    with Unix.Unix_error (Unix.EINTR, _, _) -> acquire ()
  in
  acquire ();
  print_string "ready\n";
  flush stdout;
  let rec park () =
    (try ignore (Unix.select [] [] [] (-1.))
     with Unix.Unix_error (Unix.EINTR, _, _) -> ());
    park ()
  in
  park ()

(* dispatch. *)

let usage () =
  prerr_endline
    "usage: mentat_cram \
     <censor|json|subst|wait-file|wait-line|count-ctl|stat|hmac-sha256|lock> \
     ...";
  exit 2

let () =
  match Array.to_list Sys.argv with
  | _ :: cmd :: args -> (
      try
        match cmd with
        | "censor" -> cmd_censor args
        | "json" -> cmd_json args
        | "subst" -> cmd_subst args
        | "wait-file" -> cmd_wait_file args
        | "wait-line" -> cmd_wait_line args
        | "count-ctl" -> cmd_count_ctl args
        | "stat" -> cmd_stat args
        | "hmac-sha256" -> cmd_hmac_sha256 args
        | "lock" -> cmd_lock args
        | other ->
            Printf.eprintf "mentat_cram: unknown subcommand %S\n" other;
            exit 2
      with Cram_error (code, msg) ->
        Printf.eprintf "mentat_cram %s: %s\n" cmd msg;
        exit code)
  | _ -> usage ()
