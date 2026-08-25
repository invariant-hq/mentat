(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Git worktree loader for review input — the executable-side review
    projection.

    The effect boundary between the pure review owner ({!Mentat_review}) and a
    git worktree: it resolves a base revision, reads base blobs and worktree
    files, computes a {!Mentat_review.Feature.t} for the changes, scans CR
    occurrences, and fingerprints the reviewable state so a caller can cheaply
    detect change. Nothing here mutates the repository or its index.

    The git subprocess and worktree reads are the two injected effects — a
    {!type-run} and a {!type-read}, each fallible with a display-safe reason.
    The composition edge builds them over the workspace capability's sealed
    [Mentat_workspace_io.Command.run] and [Mentat_workspace_io.File.load], so
    every git spawn crosses the one sealed process boundary; {!make} lets a test
    inject its own effect closures. The workspace meta directories ([.git],
    [.mentat], [_build], [_opam]) are dropped from the reviewed feature.

    The pure output parsing and fingerprint composition are {!Parse}, which
    takes no closures and is exercised directly. *)

(** {1:errors Errors} *)

module Error : sig
  (** Loader errors. *)

  (** The class of a loader {!type-t}. Every case carries a rendered {!message}.
  *)
  type kind =
    | Not_a_repository  (** The workspace was not inside a git worktree. *)
    | Bad_revision of string  (** The revision spec named no commit. *)
    | Git_failed of string
        (** A git subprocess failed; the string is its reason. *)
    | Raced
        (** The worktree kept changing during a load; retried and still
            unstable. *)
    | Io of string
        (** A worktree file could not be read; the string is the cause. *)

  type t
  (** The type for loader errors. *)

  val kind : t -> kind
  (** [kind error] is [error]'s class. *)

  val message : t -> string
  (** [message error] is a human-readable description of [error]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf error] formats [error]'s message. *)
end

(** {1:parse Pure parsing}

    The closure-free output parsing and fingerprint composition, separated so it
    is unit-testable without a git subprocess. *)
module Parse : sig
  val meta_path : Lpath.Rel.t -> bool
  (** [meta_path rel] is [true] iff [rel] lies under a workspace meta directory
      ([.git], [.mentat], [_build], [_opam]) and is therefore never review
      content. *)

  val nul_fields : string -> string list
  (** [nul_fields output] splits [output] on NUL, dropping empty fields — the
      shape of git's [-z] output. *)

  val name_status : string list -> ((string * Lpath.Rel.t) list, string) result
  (** [name_status fields] pairs the NUL fields of [diff --name-status -z] into
      [(status, path)] records. Renames are disabled upstream so every record is
      one status and one path; an unpaired trailing field or an unparseable path
      is an [Error]. *)

  val untracked_paths : string list -> (Lpath.Rel.t list, string) result
  (** [untracked_paths fields] parses the NUL fields of [ls-files --others -z]
      into paths, dropping {!meta_path} entries. An unparseable path is an
      [Error]. *)

  val numstat : string list -> ((int * int * Lpath.Rel.t) list, string) result
  (** [numstat fields] parses the NUL fields of [diff --numstat -z] into
      [(additions, deletions, path)] triples. A binary file's ["-"] counts read
      as [0]; renames are disabled upstream so no record carries the rename
      form's empty leading path. An unparseable count or path is an [Error].
      Meta paths are {e not} filtered here — {!stats} drops them. *)

  val count_lines : string -> int
  (** [count_lines text] is the line count of [text] under git's rule — every
      line counts as an addition and a final line without a trailing newline
      still counts — so it is the additions an untracked file contributes to
      {!stats}. Empty text is [0]. *)

  val fingerprint_key : diff:string -> untracked_token:string -> string
  (** [fingerprint_key ~diff ~untracked_token] is the opaque equality token for
      a reviewable state: a keyed digest over the raw tracked diff and the
      untracked-set token. *)

  val cat_file_batch :
    string -> count:int -> (string option list, string) result
  (** [cat_file_batch output ~count] parses the raw stdout of
      [git cat-file --batch] into [count] per-request results in request order.
      A present object is [Some contents]; an object git reported [missing] is
      [None]. Errors when a header is malformed or the output ends before
      [count] records are read. This is how {!load} reads every base blob of a
      changeset in one subprocess instead of one [cat-file] spawn per file. *)
end

(** {1:loaders Loaders} *)

type run = ?stdin:string -> string list -> (string, string) result
(** A git runner. It receives an optional stdin payload and the full argv
    (including [git]) and returns the subprocess stdout on success or a
    display-safe reason on failure. [stdin], when present, is fed to the
    subprocess's standard input: {!load} passes the object list of a
    [git cat-file --batch] that way. *)

type read = Lpath.Rel.t -> (string, string) result
(** A worktree file reader. It returns a workspace-relative file's contents or a
    display-safe reason on failure. *)

type write =
  Lpath.Rel.t -> before:string -> after:string -> (unit, string) result
(** A worktree file writer. It replaces a workspace-relative file's [before]
    contents with [after] under a stale-safe native write, returning a
    display-safe reason on failure. It is exercised only by {!apply_edit}; the
    read-only loaders never call it. *)

type t
(** The type for git worktree loaders. A loader holds only its effect closures;
    it owns no processes or file descriptors. *)

val make : run:run -> read:read -> write:write -> t
(** [make ~run ~read ~write] is a loader over caller-owned effect closures.
    Production callers construct it at the composition edge, which wires the
    closures through the workspace capability's sealed process, file, and
    native-write boundaries; [make] is the lower-level seam for tests and
    alternative runners. *)

val is_repository : t -> (unit, Error.t) result
(** [is_repository t] confirms the worktree is inside a git repository. Errors
    with {!Error.Not_a_repository} otherwise. *)

val resolve_base : t -> string -> (string, Error.t) result
(** [resolve_base t spec] resolves revision [spec] to a full immutable commit
    hash — not a symbolic ref, so a {!fingerprint} and the {!load} it guards
    always name the same state. Errors with {!Error.Bad_revision} when [spec]
    names no commit. *)

type comparison = {
  sha : string;  (** The merge base, as a full commit hash. *)
  reference : string;
      (** The reference the merge base was computed against: [base] itself, or
          [base@{upstream}] when the upstream resolved and was strictly
          ahead. *)
  upstream_warning : string option;
      (** A caller-surfaceable warning when [base@{upstream}] resolved but
          could not be compared with [base], so the comparison fell back to a
          possibly stale [base]; [None] when the upstream was used, was not
          ahead, or was not configured at all. *)
}
(** The result of {!merge_base}: the merge base and which reference it was
    computed against. *)

val merge_base : t -> base:string -> (comparison, Error.t) result
(** [merge_base t ~base] is the merge base of revision [base] and [HEAD].
    When [base]'s upstream ([base@{upstream}]) resolves and is strictly ahead
    of [base], the upstream is preferred: a review against a stale local base
    branch then compares against what the remote will see, not the stale local
    tip. An upstream that is not configured falls back to [base] silently; one
    that resolves but cannot be compared (a shallow history, say) falls back
    with [upstream_warning] set. Errors with {!Error.Bad_revision} when [base]
    names no commit, and {!Error.Git_failed} when the two histories share no
    merge base. *)

val diff_text : t -> base_sha:string -> (string, Error.t) result
(** [diff_text t ~base_sha] is the raw unified diff from commit [base_sha] to
    the worktree — committed and uncommitted tracked changes together, as
    [git diff] renders them. The output format is pinned — path quoting
    disabled and the [a/]/[b/] prefixes forced — so the bytes do not vary with
    user git configuration. Untracked files are not part of the text.
    [base_sha] must be a resolved commit hash (see {!resolve_base} and
    {!merge_base}). *)

val commit_diff : t -> commit:string -> (string, Error.t) result
(** [commit_diff t ~commit] is the raw unified diff of revision [commit] alone:
    its first parent against it, in the same pinned output format as
    {!diff_text}. Errors with {!Error.Bad_revision} when [commit] names no
    commit, and — with a message naming the commit — when it resolves to a
    root commit, whose lone diff has no base. *)

val fingerprint : t -> base:string -> (string, Error.t) result
(** [fingerprint t ~base] is the current fingerprint of the reviewable state
    from [base] to the worktree: the tracked diff plus untracked paths and
    content identities. [base] must be a resolved commit hash (see
    {!resolve_base}). *)

val stats : t -> base:string -> (Textdiff.stats, Error.t) result
(** [stats t ~base] is the lightweight worktree change summary from commit
    [base] to the worktree: the changed-file count with summed line additions
    and deletions. Tracked counts come from one [git diff --numstat] spawn;
    every untracked file adds one file and its {!Parse.count_lines} as
    additions. Meta directories ([.git], [.mentat], [_build], [_opam]) are
    excluded on both sides. Unlike {!load} it reads no base blob, builds no
    hunk, and scans no CR — it is the ambient status glance's source, not a
    review input. [base] must be a resolved commit hash (see {!resolve_base}).
*)

val load : t -> base:string -> (Mentat_review.Live.load, Error.t) result
(** [load t ~base] loads the worktree changes against commit [base] as a
    {!Mentat_review.Live.load}: the feature holds tracked edits plus untracked
    files as additions with the tip label ["WORKTREE"], the CR occurrences are
    scanned from the worktree texts of non-deleted changed files, and the
    fingerprint tokens the reviewable state.

    The snapshot is guarded by fingerprints taken before and after reading
    content, with a small bounded retry; a worktree that keeps changing errors
    with {!Error.Raced}. *)

val load_if_changed :
  t ->
  base:string ->
  known:string option ->
  ([ `Unchanged | `Loaded of Mentat_review.Live.load ], Error.t) result
(** [load_if_changed t ~base ~known] is [`Unchanged] when the current
    fingerprint equals [known], and a fresh [`Loaded] otherwise — the operation
    a {!Mentat_review.Live} [Load] action maps to. *)

(** {1:apply Applying CR mutations} *)

type apply_error =
  | Content_changed
      (** The CR the edit names is gone from its recorded content: the commented
          comment was itself edited or removed since it was scanned. This is the
          one loud staleness case — it is judged against the commented CR, not
          the whole worktree, so a surface can report "the comment changed"
          precisely and never on an unrelated edit. *)
  | Apply_failed of string  (** Any other failure, display-safe. *)

val apply_edit :
  t ->
  base:string ->
  Mentat_review.Cr.Edit.t ->
  (Mentat_review.Live.load, apply_error) result
(** [apply_edit t ~base edit] applies a wire-safe {!Mentat_review.Cr.Edit.t} to
    its worktree file and reloads the snapshot.

    Staleness is judged against the commented content, not the whole worktree.
    The target file is read fresh; for a {!Mentat_review.Cr.Edit.Replace} or
    {!Mentat_review.Cr.Edit.Remove} the edit's {!Mentat_review.Cr.Ref.t} is
    re-resolved against a fresh scan of that file, so an unrelated change
    elsewhere in the worktree never blocks the edit — the ref simply anchors
    into the current file. A ref that no longer names a live occurrence is
    {!Content_changed}: the commented CR itself moved or was removed. A file
    with no conventional comment syntax, an out-of-range insertion line, a stale
    write, or any other failure is {!Apply_failed}. The caller keeps its
    previous review either way. *)
