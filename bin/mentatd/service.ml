(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

module Platform = struct
  type t = Macos | Linux

  (* The markers the sandbox's backend resolver trusts, in the same order:
     a procfs kernel identity for Linux first, then the Seatbelt shim every
     macOS ships. *)
  let detect () =
    if Sys.file_exists "/proc/sys/kernel/ostype" then Some Linux
    else if Sys.file_exists "/usr/bin/sandbox-exec" then Some Macos
    else None

  let to_string = function Macos -> "macOS" | Linux -> "Linux"
end

module Unit_file = struct
  let label = "dev.invarianthq.mentatd"
  let systemd_unit = "mentatd.service"

  (* The ownership marker: rendered into every unit, tested before any replace
     or remove. Matching on the marker rather than full bytes lets a newer
     install replace an older render while still refusing a hand-written
     file. *)
  let marker = "Written by `mentatd install`"
  let ours bytes = String.includes ~affix:marker bytes

  let path platform ~home ~xdg_config_home =
    match (platform : Platform.t) with
    | Platform.Macos ->
        Filename.concat home
          (Filename.concat "Library/LaunchAgents" (label ^ ".plist"))
    | Platform.Linux ->
        let config =
          match xdg_config_home with
          | Some dir when not (Filename.is_relative dir) -> dir
          | Some _ | None -> Filename.concat home ".config"
        in
        Filename.concat config (Filename.concat "systemd/user" systemd_unit)

  let has_control s =
    String.exists (fun c -> Char.code c < 0x20 || Char.code c = 0x7f) s

  let carriable ~what path =
    if has_control path then
      Error
        (Printf.sprintf
           "%s %s contains a control character, which no service unit can \
            carry"
           what (String.escaped path))
    else Ok ()

  let xml_escape s =
    let b = Buffer.create (String.length s) in
    String.iter
      (function
        | '&' -> Buffer.add_string b "&amp;"
        | '<' -> Buffer.add_string b "&lt;"
        | '>' -> Buffer.add_string b "&gt;"
        | c -> Buffer.add_char b c)
      s;
    Buffer.contents b

  (* systemd expands [%] specifiers in every directive, so it is doubled;
     quoting rules for double quotes and backslashes differ between
     directives, so paths carrying them are refused rather than guessed at —
     as is ['$'], which systemd substitutes from the service environment
     even inside double quotes (only [$$] survives literally), silently
     rewriting the value. *)
  let systemd_path ~what path =
    let* () = carriable ~what path in
    if String.exists (fun c -> c = '"' || c = '\\' || c = '$') path then
      Error
        (Printf.sprintf
           "%s %s contains a quote, backslash, or dollar sign, which this \
            unit render does not escape for systemd"
           what path)
    else begin
      let b = Buffer.create (String.length path) in
      String.iter
        (function
          | '%' -> Buffer.add_string b "%%" | c -> Buffer.add_char b c)
        path;
      Ok (Buffer.contents b)
    end

  (* Every argv token walks the same refusals the paths do: the tokens are
     [--flag=value] lines the install verb itself forms, but the value half
     is owner input. *)
  let launchd ~exec ~args ~log =
    let* () = carriable ~what:"the executable path" exec in
    let* () =
      List.fold_left
        (fun acc token ->
          let* () = acc in
          carriable ~what:"the argument" token)
        (Ok ()) args
    in
    let* () = carriable ~what:"the log path" log in
    let log = xml_escape log in
    let arguments =
      String.concat "\n"
        (List.map
           (fun token -> Printf.sprintf "    <string>%s</string>" (xml_escape token))
           (exec :: args))
    in
    Ok
      (Printf.sprintf
         {|<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by `mentatd install`; `mentatd uninstall` removes it, and the
     next install overwrites it. AbandonProcessGroup is load-bearing: the
     daemon's run children detach into their own sessions and must outlive
     it, so stopping or restarting this job may signal only the daemon
     itself — it adopts the survivors when it next boots. Without the key,
     launchd would take mid-turn runs down with the job. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>%s</string>
  <key>ProgramArguments</key>
  <array>
%s
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>AbandonProcessGroup</key>
  <true/>
  <key>StandardOutPath</key>
  <string>%s</string>
  <key>StandardErrorPath</key>
  <string>%s</string>
</dict>
</plist>
|}
         label arguments log log)

  let systemd ~exec ~args ~log =
    let* exec = systemd_path ~what:"the executable path" exec in
    let* args =
      List.fold_left
        (fun acc token ->
          let* args = acc in
          let* token = systemd_path ~what:"the argument" token in
          Ok (token :: args))
        (Ok []) args
      |> Result.map List.rev
    in
    let* log = systemd_path ~what:"the log path" log in
    let exec_start =
      String.concat " "
        (List.map (Printf.sprintf {|"%s"|}) (exec :: args))
    in
    Ok
      (Printf.sprintf
         {|# Written by `mentatd install`; `mentatd uninstall` removes it, and the
# next install overwrites it. KillMode=process is load-bearing: the daemon's
# run children detach into their own sessions and must outlive it, so
# stopping or restarting this unit may signal only the daemon itself — it
# adopts the survivors when it next boots. The default control-group kill
# would take mid-turn runs down with the unit. The restart pacing is
# load-bearing too: a daemon spawned outside the service holds the per-user
# claim and this unit's daemon then exits nonzero, so the manager must retry
# until the claim frees — the default burst limit would park the unit failed
# after five fast exits instead.

[Unit]
Description=mentat daemon
StartLimitIntervalSec=0

[Service]
ExecStart=%s
KillMode=process
Restart=on-failure
RestartSec=10
StandardOutput=append:%s
StandardError=append:%s

[Install]
WantedBy=default.target
|}
         exec_start log log)

  let render platform ~exec ~args ~log =
    match (platform : Platform.t) with
    | Platform.Macos -> launchd ~exec ~args ~log
    | Platform.Linux -> systemd ~exec ~args ~log

  type standing = Fresh | Unchanged | Replaceable | Foreign

  let standing ~existing ~rendered =
    match existing with
    | None -> Fresh
    | Some bytes when String.equal bytes rendered -> Unchanged
    | Some bytes when ours bytes -> Replaceable
    | Some _ -> Foreign
end

(* ---- Host resolution ---- *)

let home () =
  match Sys.getenv_opt "HOME" with
  | Some home when not (Filename.is_relative home) -> Ok home
  | Some _ | None ->
      Error
        "HOME is unset or not absolute; the service unit directory cannot be \
         resolved"

(* The unit pins the path of the binary that ran the install; a relative
   invocation is anchored to the working directory so the pinned path is
   absolute. A moved or renamed binary leaves the pin dangling — the remedy
   is re-running [mentatd install] from the new binary, which replaces the
   unit. *)
let executable () =
  let exe = Sys.executable_name in
  if Filename.is_relative exe then Filename.concat (Sys.getcwd ()) exe else exe

(* The service-managed daemon's log, as [User_dirs.daemon_dir] documents
   its contents: the service manager appends the daemon's standard output
   and error there. *)
let log_path dirs = Filename.concat (User_dirs.daemon_dir dirs) "daemon.log"

let prepared platform ~args =
  let* dirs = User_dirs.resolve ~getenv:Sys.getenv_opt in
  let* home = home () in
  let path =
    Unit_file.path platform ~home
      ~xdg_config_home:(Sys.getenv_opt "XDG_CONFIG_HOME")
  in
  let log = log_path dirs in
  let* rendered =
    Unit_file.render platform ~exec:(executable ()) ~args ~log
  in
  Ok (dirs, path, log, rendered)

(* ---- Service-manager processes ---- *)

(* One manager command, run to completion with stdio inherited so its own
   diagnostics stay visible; [quiet] silences a probe whose failure is an
   answer, not an error. [Unix.create_process] resolves the program on PATH
   and reports a missing one only as the child's exit 127, which the callers'
   loud failures surface with the full command line. *)
let run_tool ~quiet argv =
  let args = Array.of_list argv in
  match
    let null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close null with Unix.Unix_error _ -> ())
      (fun () ->
        let out = if quiet then null else Unix.stdout in
        let err = if quiet then null else Unix.stderr in
        let pid = Unix.create_process args.(0) args null out err in
        let rec wait () =
          match Unix.waitpid [] pid with
          | _, Unix.WEXITED code -> code
          | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> 128
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
        in
        wait ())
  with
  | code -> Ok code
  | exception Unix.Unix_error (e, _, _) ->
      Error
        (Printf.sprintf "could not run `%s`: %s" (String.concat " " argv)
           (Unix.error_message e))

let succeeds argv =
  match run_tool ~quiet:true argv with Ok 0 -> true | Ok _ | Error _ -> false

(* A manager call whose failure fails the verb: loud, with the exact command
   named so the owner can run it by hand once the manager is reachable. *)
let require argv ~standing_at =
  let line = String.concat " " argv in
  match run_tool ~quiet:false argv with
  | Ok 0 -> Ok ()
  | Ok code ->
      Error
        (Printf.sprintf "`%s` failed (exit %d); %s — run the command manually"
           line code standing_at)
  | Error message ->
      Error (Printf.sprintf "%s; %s — run the command manually" message
               standing_at)

(* ---- install ---- *)

let written ~standing ~path =
  match (standing : Unit_file.standing) with
  | Unit_file.Fresh -> Printf.sprintf "installed %s" path
  | Unit_file.Unchanged -> Printf.sprintf "already installed: %s (unchanged)" path
  | Unit_file.Replaceable -> Printf.sprintf "replaced %s" path
  | Unit_file.Foreign -> assert false

let loaded_line ~log =
  Printf.sprintf "loaded %s; mentatd runs at login (log: %s)" Unit_file.label
    log

let restarted_line ~log =
  Printf.sprintf "restarted %s on the new unit (log: %s)" Unit_file.label log

let activate_macos ~standing ~path ~log =
  let domain = Printf.sprintf "gui/%d" (Unix.getuid ()) in
  let target = domain ^ "/" ^ Unit_file.label in
  let standing_at = Printf.sprintf "the unit is written at %s" path in
  let loaded = succeeds [ "launchctl"; "print"; target ] in
  match ((standing : Unit_file.standing), loaded) with
  | Unit_file.Unchanged, true ->
      Ok [ Printf.sprintf "already installed and loaded: %s" path ]
  | (Unit_file.Fresh | Unit_file.Unchanged), false ->
      let* () =
        require [ "launchctl"; "bootstrap"; domain; path ] ~standing_at
      in
      Ok [ written ~standing ~path; loaded_line ~log ]
  | (Unit_file.Fresh | Unit_file.Replaceable), true ->
      let* () = require [ "launchctl"; "bootout"; target ] ~standing_at in
      let* () =
        require [ "launchctl"; "bootstrap"; domain; path ] ~standing_at
      in
      Ok [ written ~standing ~path; restarted_line ~log ]
  | Unit_file.Replaceable, false ->
      let* () =
        require [ "launchctl"; "bootstrap"; domain; path ] ~standing_at
      in
      Ok [ written ~standing ~path; loaded_line ~log ]
  | Unit_file.Foreign, _ -> assert false

let activate_linux ~standing ~path ~log =
  let standing_at = Printf.sprintf "the unit is written at %s" path in
  let* () =
    require [ "systemctl"; "--user"; "daemon-reload" ] ~standing_at
  in
  match (standing : Unit_file.standing) with
  | Unit_file.Fresh | Unit_file.Unchanged ->
      let* () =
        require
          [ "systemctl"; "--user"; "enable"; "--now"; Unit_file.systemd_unit ]
          ~standing_at
      in
      Ok [ written ~standing ~path; loaded_line ~log ]
  | Unit_file.Replaceable ->
      let* () =
        require
          [ "systemctl"; "--user"; "enable"; Unit_file.systemd_unit ]
          ~standing_at
      in
      let* () =
        require
          [ "systemctl"; "--user"; "restart"; Unit_file.systemd_unit ]
          ~standing_at
      in
      Ok [ written ~standing ~path; restarted_line ~log ]
  | Unit_file.Foreign -> assert false

let install_unit platform ~args =
  let* dirs, path, log, rendered = prepared platform ~args in
  let* existing = Fs.read_capped ~max_bytes:Fs.default_max_bytes path in
  let standing = Unit_file.standing ~existing ~rendered in
  match standing with
  | Unit_file.Foreign ->
      Error
        (Printf.sprintf
           "refusing to overwrite %s: it is not a unit `mentatd install` \
            wrote; move it aside first"
           path)
  | Unit_file.Fresh | Unit_file.Unchanged | Unit_file.Replaceable -> (
      (* The manager appends the daemon's stdio under the daemon home, so the
         directory must exist before the first service start. *)
      Daemon.ensure_daemon_dir dirs;
      let* () =
        match standing with
        | Unit_file.Unchanged -> Ok ()
        | _ -> Fs.atomic_write ~perms:0o644 path rendered
      in
      match (platform : Platform.t) with
      | Platform.Macos -> activate_macos ~standing ~path ~log
      | Platform.Linux -> activate_linux ~standing ~path ~log)

let unsupported =
  "no supported service manager: `mentatd install` needs launchd (macOS) or \
   a systemd user manager (Linux)"

(* The exec-line pass-through: the daemon's own serve flags, baked into the
   unit in [--flag=value] form so the resident daemon starts with them at
   every boot. Re-running install with different flags renders different
   bytes, which the standing classifies as replaceable. *)
let exec_args ~ingress_port ~github_base_url ~routine_git_base ~web ~web_port
    =
  (match ingress_port with
  | Some port -> [ Printf.sprintf "--ingress-port=%d" port ]
  | None -> [])
  @ (match github_base_url with
    | Some url -> [ "--github-base-url=" ^ url ]
    | None -> [])
  @ (match routine_git_base with
    | Some base -> [ "--routine-git-base=" ^ base ]
    | None -> [])
  @ (if web then [ "--web" ] else [])
  @
  match web_port with
  | Some port -> [ Printf.sprintf "--web-port=%d" port ]
  | None -> []

let install ~print ~ingress_port ~github_base_url ~routine_git_base ~web
    ~web_port =
  let args =
    exec_args ~ingress_port ~github_base_url ~routine_git_base ~web ~web_port
  in
  match Platform.detect () with
  | None -> Exit_status.runtime unsupported
  | Some platform when print -> (
      match prepared platform ~args with
      | Error message -> Exit_status.runtime message
      | Ok (_, _, _, rendered) ->
          print_string rendered;
          Exit_status.Success)
  | Some platform -> (
      match install_unit platform ~args with
      | Error message -> Exit_status.runtime message
      | Ok lines ->
          List.iter print_endline lines;
          Exit_status.Success)

(* ---- uninstall ---- *)

let remove path =
  match Unix.unlink path with
  | () -> Ok ()
  | exception Unix.Unix_error (e, _, _) ->
      Error
        (Printf.sprintf "could not remove %s: %s" path (Unix.error_message e))

let uninstall_unit platform =
  let* home = home () in
  let path =
    Unit_file.path platform ~home
      ~xdg_config_home:(Sys.getenv_opt "XDG_CONFIG_HOME")
  in
  let* existing = Fs.read_capped ~max_bytes:Fs.default_max_bytes path in
  match existing with
  | None ->
      Ok [ Printf.sprintf "nothing to uninstall: %s does not exist" path ]
  | Some bytes when not (Unit_file.ours bytes) ->
      Error
        (Printf.sprintf
           "refusing to remove %s: it is not a unit `mentatd install` wrote; \
            remove it yourself if it is stale"
           path)
  | Some _ -> (
      let standing_at = Printf.sprintf "the unit remains at %s" path in
      match (platform : Platform.t) with
      | Platform.Macos ->
          let domain = Printf.sprintf "gui/%d" (Unix.getuid ()) in
          let target = domain ^ "/" ^ Unit_file.label in
          let* unloaded =
            if succeeds [ "launchctl"; "print"; target ] then
              let* () =
                require [ "launchctl"; "bootout"; target ] ~standing_at
              in
              Ok [ Printf.sprintf "unloaded %s" Unit_file.label ]
            else Ok []
          in
          let* () = remove path in
          Ok (unloaded @ [ Printf.sprintf "removed %s" path ])
      | Platform.Linux ->
          let* () =
            require
              [
                "systemctl"; "--user"; "disable"; "--now";
                Unit_file.systemd_unit;
              ]
              ~standing_at
          in
          let* () = remove path in
          let* () =
            require
              [ "systemctl"; "--user"; "daemon-reload" ]
              ~standing_at:"the unit file is already removed"
          in
          Ok
            [
              Printf.sprintf "disabled %s" Unit_file.systemd_unit;
              Printf.sprintf "removed %s" path;
            ])

let uninstall () =
  match Platform.detect () with
  | None -> Exit_status.runtime unsupported
  | Some platform -> (
      match uninstall_unit platform with
      | Error message -> Exit_status.runtime message
      | Ok lines ->
          List.iter print_endline lines;
          Exit_status.Success)
