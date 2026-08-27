(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The resident-service surface: [mentatd install] and [mentatd uninstall].

    [install] writes one user-level service unit — a launchd agent on macOS, a
    systemd user unit on Linux — that keeps [mentatd] resident: started at
    login, restarted on failure, its standard output and error appended to the
    daemon log the spawned-daemon path already writes. [uninstall] unloads and
    removes that unit and nothing else — the daemon's discovery file, store,
    and logs are never touched.

    Every unit this module renders pins the setting that lets the daemon's run
    children outlive it — [KillMode=process] on systemd,
    [AbandonProcessGroup] on launchd. The children detach into their own
    sessions and must survive a stop, restart, or crash of the daemon so the
    daemon can adopt them when it next boots; a unit without the pin would let
    the service manager kill mid-turn runs on every restart. The pin is part of
    the rendered bytes, so replacing the unit re-asserts it.

    Both verbs refuse a file at the unit path that does not carry this module's
    ownership marker: a hand-written unit is named, never overwritten and never
    removed. *)

(** The two service managers this surface speaks to. *)
module Platform : sig
  type t =
    | Macos  (** launchd, via a user agent under [~/Library/LaunchAgents]. *)
    | Linux
        (** A systemd user manager, via a unit under
            [$XDG_CONFIG_HOME/systemd/user] (default
            [~/.config/systemd/user]). *)

  val detect : unit -> t option
  (** [detect ()] is the running host's platform, or [None] when neither
      service manager can be present — the caller refuses loudly rather than
      guessing. Linux is recognized by its procfs kernel identity, macOS by
      the Seatbelt shim every installation ships. *)

  val to_string : t -> string
  (** [to_string t] is the platform's display name. *)
end

(** The unit file: identity, location, rendering, and the standing of whatever
    already occupies its path. Everything here is pure, so both renderings are
    testable byte-for-byte on any host. *)
module Unit_file : sig
  val label : string
  (** [label] is the launchd job label, ["dev.invarianthq.mentatd"] — reverse
      DNS of the project's domain. The plist basename is [label ^ ".plist"];
      the systemd unit is named {!systemd_unit} instead, following each
      manager's own convention. *)

  val systemd_unit : string
  (** [systemd_unit] is ["mentatd.service"], the systemd unit name and
      basename. *)

  val path :
    Platform.t -> home:string -> xdg_config_home:string option -> string
  (** [path platform ~home ~xdg_config_home] is the absolute unit path:
      [home/Library/LaunchAgents/<label>.plist] on macOS,
      [<config>/systemd/user/mentatd.service] on Linux where [config] is an
      absolute [xdg_config_home] and [home/.config] otherwise (a relative
      override is ignored, as the XDG rules demand). *)

  val render :
    Platform.t ->
    exec:string ->
    args:string list ->
    log:string ->
    (string, string) result
  (** [render platform ~exec ~args ~log] is the unit's exact bytes: run
      [exec] with exactly [args] (the daemon's foreground serve, plus any
      baked-in serve flags in [--flag=value] form), start at login, restart
      on failure — paced and unlimited under systemd, whose default burst
      limit would otherwise park the unit failed while a spawned daemon
      holds the per-user claim — append both output streams to [log], and
      pin the child-survival setting. [Error message] when a path or
      argument cannot be carried by the unit syntax: any control character,
      and — under systemd, whose quoting and variable expansion the render
      refuses to guess at — a double quote, backslash, or dollar sign. XML
      metacharacters in a launchd value and [%] under systemd are
      escaped. *)

  val ours : string -> bool
  (** [ours bytes] is whether [bytes] carries the ownership marker every
      rendered unit embeds — the test both verbs apply before replacing or
      removing an existing file. *)

  (** What occupies the unit path before an install. *)
  type standing =
    | Fresh  (** Nothing there; write and load. *)
    | Unchanged  (** Byte-identical to the render; nothing to write. *)
    | Replaceable  (** Ours, but out of date; replace and restart. *)
    | Foreign  (** Not recognizably ours; refuse, naming the path. *)

  val standing : existing:string option -> rendered:string -> standing
  (** [standing ~existing ~rendered] classifies the current occupant of the
      unit path against the bytes an install would write. *)
end

val install :
  print:bool ->
  ingress_port:int option ->
  github_base_url:string option ->
  charter_git_base:string option ->
  web:bool ->
  web_port:int option ->
  Exit_status.t
(** [install ~print ~ingress_port ~github_base_url ~charter_git_base ~web
    ~web_port] resolves the unit for this host and, when [print] is false,
    writes it (0644, atomically) and hands it to the service manager:
    [launchctl bootout]/[bootstrap] into the user's [gui] domain on macOS,
    [systemctl --user daemon-reload]/[enable]/[restart] on Linux.
    [ingress_port], [github_base_url], [charter_git_base], and the web
    pair ([web] bakes [--web], [web_port] bakes [--web-port]) are baked
    into the unit's exec line as the daemon's own serve flags, so the
    resident daemon starts with them at every boot — a service-managed
    daemon's browser frontend and charters dashboard exist only this way,
    since only one daemon claims a store;
    re-running install with different flags renders different bytes and
    replaces the unit. An unchanged, already-loaded unit is a
    success-shaped no-op; a changed one restarts the service on the new
    bytes. A manager call that fails is a loud error naming the exact
    command to run manually — the written unit is left in place, never
    silently half-installed. A foreign file at the unit path, an
    unsupported platform, and an unresolvable home are all loud refusals.

    With [print] the rendered unit goes to standard output and nothing on the
    system is touched — no directory is created, no file written, no manager
    spoken to. *)

val uninstall : unit -> Exit_status.t
(** [uninstall ()] unloads the service from the manager and removes the unit
    file. An absent unit is a clean success with a note (idempotent
    uninstall); a foreign file at the unit path is a loud refusal. The
    daemon's own state — store, discovery file, logs — is never touched, and
    run children keep running: the unit's child-survival pin means unloading
    the service stops only the daemon itself. *)
