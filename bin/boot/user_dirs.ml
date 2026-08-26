(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { config_home : string; data_home : string; state_home : string }

let is_absolute path = String.length path > 0 && Char.equal path.[0] '/'

(* One rung of the ladder: an absolute override wins; a set-but-relative override
   is a hard error; otherwise [xdg]/mentat, else [$HOME]/[fallback]. *)
let resolve_home ~getenv ~override ~xdg ~fallback =
  match getenv override with
  | Some value when String.length value > 0 ->
      if is_absolute value then Ok value
      else
        Error (Printf.sprintf "%s must be an absolute path: %s" override value)
  | Some _ | None -> (
      match getenv xdg with
      | Some base when is_absolute base -> Ok (Filename.concat base "mentat")
      | Some _ | None -> (
          match getenv "HOME" with
          | Some home when is_absolute home ->
              Ok (Filename.concat home fallback)
          | Some _ | None ->
              Error
                (Printf.sprintf "cannot resolve %s: $HOME is unset or relative"
                   override)))

let resolve ~getenv =
  let ( let* ) = Result.bind in
  let* config_home =
    resolve_home ~getenv ~override:"MENTAT_CONFIG_HOME" ~xdg:"XDG_CONFIG_HOME"
      ~fallback:".config/mentat"
  in
  let* data_home =
    resolve_home ~getenv ~override:"MENTAT_DATA_HOME" ~xdg:"XDG_DATA_HOME"
      ~fallback:".local/share/mentat"
  in
  let* state_home =
    resolve_home ~getenv ~override:"MENTAT_STATE_HOME" ~xdg:"XDG_STATE_HOME"
      ~fallback:".local/state/mentat"
  in
  Ok { config_home; data_home; state_home }

let config_home t = t.config_home
let data_home t = t.data_home
let state_home t = t.state_home
let config_file t = Filename.concat t.config_home "config.json"
let auth_file t = Filename.concat t.config_home "auth.json"
let trust_file t = Filename.concat t.config_home "trust.json"
let daemon_dir t = Filename.concat t.data_home "daemon"
let charters_dir t = Filename.concat t.config_home "charters"
let charter_dir t name = Filename.concat (charters_dir t) name

let charter_state_dir t name =
  Filename.concat (Filename.concat t.state_home "charters") name

(* The socket lives under literal [/tmp], not the daemon dir, so a deep checkout
   or a relocated home cannot overflow [sun_path] (~104 bytes). It is per-user
   and per-store: the key digests the data home, so a [MENTAT_DATA_HOME]
   override isolates daemons.

   It lives here rather than with the daemon because two callers need it and
   they cannot see each other. The daemon binds it; the sandbox has to deny it,
   since [/tmp] is granted writable and the socket answers any local peer
   without a token — a confined command that could reach it would be driving
   Mentat rather than being confined by it. *)
let daemon_socket_dir t =
  let key =
    Mentat_digest.key ~length:12 ~domain:"mentat.daemon-socket.v1"
      [ t.data_home ]
  in
  Printf.sprintf "/tmp/mentat-%d-%s" (Unix.getuid ()) key

(* A session id is admitted verbatim as the path leaf only when it is short and
   filename-plain; anything else is keyed. Both forms are pure functions of the
   id, and both keep the socket path inside the [sun_path] budget. *)
let child_socket_dir t ~session =
  let plain c =
    (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || Char.equal c '-' || Char.equal c '_' || Char.equal c '.'
  in
  let leaf =
    if
      String.length session > 0
      && String.length session <= 40
      && String.for_all plain session
      && not (Char.equal session.[0] '.')
    then session
    else
      Mentat_digest.key ~length:16 ~domain:"mentat.child-socket.v1" [ session ]
  in
  Filename.concat (Filename.concat (daemon_socket_dir t) "s") leaf
