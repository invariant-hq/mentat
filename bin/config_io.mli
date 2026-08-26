(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Configuration file discovery and IO. File location, reads, atomic writes,
    and [.gitignore] maintenance are executable-private; the pure
    [mentat.config] core only parses and plans.

    The three file layers: the user file at [config_home/config.json], and the
    workspace files [<root>/.mentat/config.json] (shared) and
    [<root>/.mentat/config.local.json] (project-local, gitignored). Reading
    resolves them — with the pre-decided trust outcome — into a
    {!Mentat_config.Resolved.t}; writing plans an edit with the pure core and
    performs the atomic replace it describes. *)

type layer =
  | User
  | Project
  | Project_local  (** A writable config file layer. *)

val resolve :
  dirs:User_dirs.t ->
  root:Lpath.Abs.t ->
  trusted:bool ->
  getenv:(string -> string option) ->
  overrides:Mentat_config.t list ->
  (Mentat_config.Resolved.t, string) result
(** [resolve ~dirs ~root ~trusted ~getenv ~overrides] reads every layer and
    resolves the effective configuration. Workspace files contribute only when
    [trusted]. [Error message] on a fatal cross-field invariant or an unreadable
    user file. *)

val layer_path : dirs:User_dirs.t -> root:Lpath.Abs.t -> layer -> string
(** [layer_path ~dirs ~root layer] is the absolute file path of [layer]. *)

val layer_of_path :
  dirs:User_dirs.t -> root:Lpath.Abs.t -> string -> layer option
(** [layer_of_path ~dirs ~root path] is the layer whose file is [path], if any.
    Paths are compared as files, so a relative spelling or a symlinked home
    still classifies; a path that does not resolve, or names no layer file, is
    [None]. *)

val read : path:string -> (string option, string) result
(** [read ~path] is the byte-capped contents of [path]: [Ok None] if the file is
    absent (so [config validate] on a missing file is "ok", not a parse error),
    [Ok (Some bytes)] if present, [Error] if unreadable or over the cap. *)

val init :
  dirs:User_dirs.t -> root:Lpath.Abs.t -> layer -> (string, string) result
(** [init ~dirs ~root layer] creates [layer]'s file if absent — an empty [{}]
    written atomically through the parent chain (so it is really created even
    when [.mentat/] did not exist) — and, for {!Project_local}, adds the file to
    [<root>/.mentat/.gitignore]. Returns the file path; a pre-existing file is
    left untouched. *)

val read_layer :
  dirs:User_dirs.t ->
  root:Lpath.Abs.t ->
  layer ->
  (Mentat_config.t, string) result
(** [read_layer ~dirs ~root layer] is [layer]'s parsed configuration, or the
    empty configuration if the file is absent. [Error message] on a malformed
    file. *)

val ensure_gitignored : root:Lpath.Abs.t -> string -> (unit, string) result
(** [ensure_gitignored ~root name] appends [name] to
    [<root>/.mentat/.gitignore] unless already listed — the one convention for
    keeping executable-owned entries under [.mentat] out of the project's
    status. *)

val plan_write :
  dirs:User_dirs.t ->
  root:Lpath.Abs.t ->
  layer ->
  f:(Mentat_config.t -> (Mentat_config.t, Mentat_config.Error.t) result) ->
  (bool, string) result
(** [plan_write ~dirs ~root layer ~f] applies [f] to [layer]'s supported fields,
    preserving unknown members, and performs the atomic replace the plan
    describes (creating parent directories, and for {!Project_local} adding the
    file to [<root>/.mentat/.gitignore]). [Ok true] iff bytes were written;
    [Ok false] if the edit changed nothing. *)
