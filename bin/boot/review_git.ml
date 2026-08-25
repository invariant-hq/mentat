(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The git worktree loader for review input — the effect boundary between the
   pure review owner and a git worktree. It resolves a base revision, reads base
   blobs and worktree files, computes a {!Mentat_review.Feature.t} for the
   changes, scans CR occurrences, and fingerprints the reviewable state so a
   caller can cheaply detect change. Nothing here mutates the repository.

   The git subprocess and worktree reads are injected as [run] and [read]
   closures. [read] classifies what it finds — regular-file text, a symbolic
   link's target (never followed), or an over-bound refusal — and otherwise
   fails with a display-safe reason, like [run]. The composition edge
   constructs them over the workspace capability's sealed
   [Mentat_workspace_io.Command.run] and [Mentat_workspace_io.File]
   observations, so every spawn crosses the one sealed process boundary; the
   pure parsing in {!Parse} takes no closures and is exercised directly. *)

module Error = struct
  type kind =
    | Not_a_repository
    | Bad_revision of string
    | Git_failed of string
    | Raced
    | Io of string

  type t = { kind : kind; message : string }

  let make kind message = { kind; message }
  let kind t = t.kind
  let message t = t.message
  let pp ppf t = Format.pp_print_string ppf t.message
end

let git_failed message = Error (Error.make (Error.Git_failed message) message)

(* Pure parsing. *)

module Parse = struct
  (* Workspace meta directories are never review content even when the
     repository does not gitignore them; the same set the watchers ignore. A
     tracked file under a meta directory is still dropped from the feature. *)
  let meta_path rel =
    List.exists
      (fun component ->
        List.mem component Mentat_workspace.observation_prune_names)
      (String.split_on_char '/' (Lpath.Rel.to_string rel))

  (* The review feature's own reserved scratch namespace: [run review]
     materializes its target diff to a root-level
     [.mentat-review-<session>.patch], and a parked or killed run keeps one
     behind. Like the meta directories, the review's own scratch is never
     review content — without this, the next review would ingest a kept
     patch as a new file, and two concurrent reviews in one workspace would
     cross-contaminate. *)
  let reserved_scratch rel =
    let name = Lpath.Rel.to_string rel in
    (not (String.contains name '/'))
    && String.starts_with ~prefix:".mentat-review-" name
    && String.ends_with ~suffix:".patch" name

  let nul_fields output =
    List.filter
      (fun field -> String.length field > 0)
      (String.split_on_char '\000' output)

  let rel_of ~context path =
    match Lpath.Rel.of_string path with
    | Ok rel -> Ok rel
    | Error error ->
        Error
          (Printf.sprintf "unexpected path %S in git %s output: %s" path context
             (Lpath.Error.message error))

  (* Changed paths from [--name-status -z]: NUL-separated
     [status, path, status, path, ...] records. Renames are disabled so every
     record has exactly one path. *)
  let name_status fields =
    let rec pair = function
      | [] -> Ok []
      | status :: path :: rest -> (
          match pair rest with
          | Error _ as error -> error
          | Ok tail -> (
              match rel_of ~context:"name-status" path with
              | Error message -> Error message
              | Ok rel -> Ok ((status, rel) :: tail)))
      | [ field ] ->
          Error
            (Printf.sprintf "unpaired field %S in git name-status output" field)
    in
    pair fields

  (* Untracked paths from [ls-files --others -z], meta directories and the
     review's reserved scratch dropped. *)
  let untracked_paths fields =
    let rec collect = function
      | [] -> Ok []
      | path :: rest -> (
          match collect rest with
          | Error _ as error -> error
          | Ok tail -> (
              match rel_of ~context:"ls-files" path with
              | Error message -> Error message
              | Ok rel -> Ok (rel :: tail)))
    in
    match collect fields with
    | Error _ as error -> error
    | Ok paths ->
        Ok
          (List.filter
             (fun rel -> not (meta_path rel || reserved_scratch rel))
             paths)

  (* Line-addition count for an untracked file's worktree text — the additions
     it contributes to the worktree summary, matching git's rule: every line is
     an addition, and a final line without a trailing newline still counts. *)
  let count_lines text =
    if String.length text = 0 then 0
    else
      let newlines =
        String.fold_left
          (fun n c -> if Char.equal c '\n' then n + 1 else n)
          0 text
      in
      if Char.equal text.[String.length text - 1] '\n' then newlines
      else newlines + 1

  (* One untracked file rendered as the new-file unified diff [git diff] would
     emit for it once tracked, minus the index line: header, mode line,
     [/dev/null] sources, and a single hunk adding every line. Path quoting
     stays off to match the pinned tracked-diff output; a name containing a
     space takes git's literal-tab suffix on the [+++] line. A file with a NUL
     byte in its first 8000 bytes renders git's binary stanza and an empty
     file only its headers — neither contributes hunk lines. *)
  let untracked_diff ~path ~contents =
    let path = Lpath.Rel.to_string path in
    let buffer = Buffer.create (String.length contents + 128) in
    Buffer.add_string buffer
      (Printf.sprintf "diff --git a/%s b/%s\n" path path);
    Buffer.add_string buffer "new file mode 100644\n";
    let binary =
      let n = min 8000 (String.length contents) in
      let rec scan i =
        i < n && (Char.equal contents.[i] '\000' || scan (i + 1))
      in
      scan 0
    in
    let count = count_lines contents in
    if binary then
      Buffer.add_string buffer
        (Printf.sprintf "Binary files /dev/null and b/%s differ\n" path)
    else if count > 0 then (
      let target = if String.contains path ' ' then path ^ "\t" else path in
      Buffer.add_string buffer "--- /dev/null\n";
      Buffer.add_string buffer (Printf.sprintf "+++ b/%s\n" target);
      Buffer.add_string buffer
        (if count = 1 then "@@ -0,0 +1 @@\n"
         else Printf.sprintf "@@ -0,0 +1,%d @@\n" count);
      let lines =
        match List.rev (String.split_on_char '\n' contents) with
        | "" :: rest -> List.rev rest
        | all -> List.rev all
      in
      List.iter
        (fun line ->
          Buffer.add_char buffer '+';
          Buffer.add_string buffer line;
          Buffer.add_char buffer '\n')
        lines;
      if not (Char.equal contents.[String.length contents - 1] '\n') then
        Buffer.add_string buffer "\\ No newline at end of file\n");
    Buffer.contents buffer

  (* One untracked symbolic link rendered as the new-file diff git emits for
     a link: mode 120000 and the target path as the single content line,
     never following the link. Git stores a link's target as its blob
     content without a trailing newline, so the no-newline marker always
     follows. *)
  let untracked_link_diff ~path ~target =
    let path = Lpath.Rel.to_string path in
    let name = if String.contains path ' ' then path ^ "\t" else path in
    String.concat ""
      [
        Printf.sprintf "diff --git a/%s b/%s\n" path path;
        "new file mode 120000\n";
        "--- /dev/null\n";
        Printf.sprintf "+++ b/%s\n" name;
        "@@ -0,0 +1 @@\n";
        "+" ^ target ^ "\n";
        "\\ No newline at end of file\n";
      ]

  (* One untracked file whose bytes are unavailable — over the loader's read
     bound — rendered as the binary stanza a NUL-bearing file already takes:
     the file is named in the diff without its contents. *)
  let untracked_binary_diff ~path =
    let path = Lpath.Rel.to_string path in
    Printf.sprintf
      "diff --git a/%s b/%s\nnew file mode 100644\nBinary files /dev/null \
       and b/%s differ\n"
      path path path

  (* Per-file counts from [diff --numstat -z]: NUL-separated
     [<add>\t<del>\t<path>] records. [add]/[del] are ["-"] for a binary file,
     counted as 0. Renames are disabled upstream, so no record carries the
     rename form's empty leading path. *)
  let numstat fields =
    let count field =
      if String.equal field "-" then Some 0 else int_of_string_opt field
    in
    let record field =
      match String.index_opt field '\t' with
      | None -> Error (Printf.sprintf "unparseable numstat record %S" field)
      | Some i -> (
          match String.index_from_opt field (i + 1) '\t' with
          | None -> Error (Printf.sprintf "unparseable numstat record %S" field)
          | Some j -> (
              let add = String.sub field 0 i in
              let del = String.sub field (i + 1) (j - i - 1) in
              let path =
                String.sub field (j + 1) (String.length field - j - 1)
              in
              match (count add, count del) with
              | None, _ | _, None ->
                  Error
                    (Printf.sprintf "unparseable numstat counts in %S" field)
              | Some add, Some del -> (
                  match rel_of ~context:"numstat" path with
                  | Error _ as error -> error
                  | Ok rel -> Ok (add, del, rel))))
    in
    let rec loop = function
      | [] -> Ok []
      | field :: rest -> (
          match record field with
          | Error _ as error -> error
          | Ok parsed -> (
              match loop rest with
              | Error _ as error -> error
              | Ok tail -> Ok (parsed :: tail)))
    in
    loop fields

  let fingerprint_key ~diff ~untracked_token =
    Mentat_digest.key ~length:64
      ~domain:"mentat.workspace_io.git.fingerprint.v1" [ diff; untracked_token ]

  (* Parse the raw stdout of [git cat-file --batch] into [count] per-request
     results in request order. Each present object is a header line
     [<oid> <type> <size>\n], then [size] content bytes, then a newline; a
     missing object is a single [<name> missing\n] line. Content bytes are
     arbitrary, so the size drives the slice rather than a newline scan. A
     missing marker is the last space-separated token being "missing"; a present
     header's last token is the numeric size, so the two never collide even for
     a path with spaces. *)
  let cat_file_batch output ~count =
    let len = String.length output in
    let rec loop pos remaining acc =
      if remaining = 0 then Ok (List.rev acc)
      else if pos >= len then
        Error "git cat-file --batch output ended before all objects were read"
      else
        match String.index_from_opt output pos '\n' with
        | None -> Error "git cat-file --batch header was not newline-terminated"
        | Some nl -> (
            let header = String.sub output pos (nl - pos) in
            let body = nl + 1 in
            match List.rev (String.split_on_char ' ' header) with
            | "missing" :: _ -> loop body (remaining - 1) (None :: acc)
            | size :: _type :: _oid -> (
                match int_of_string_opt size with
                | None ->
                    Error
                      (Printf.sprintf "git cat-file --batch: bad object size %S"
                         size)
                | Some size when body + size > len ->
                    Error
                      "git cat-file --batch: object shorter than its declared \
                       size"
                | Some size ->
                    let content = String.sub output body size in
                    (* Each object's content is newline-terminated by git. *)
                    loop (body + size + 1) (remaining - 1) (Some content :: acc)
                )
            | _ ->
                Error
                  (Printf.sprintf "git cat-file --batch: unparseable header %S"
                     header))
    in
    loop 0 count []
end

(* Repository handles. *)

type run = ?stdin:string -> string list -> (string, string) result

(* The worktree reader never follows a final symlink: the loader must render
   a link as git renders it (its target as content), not duplicate — or
   escape through — whatever the link points at. *)
type file = Text of string | Link of string
type read_error = Too_large | Unreadable of string
type read = Lpath.Rel.t -> (file, read_error) result

type write =
  Lpath.Rel.t -> before:string -> after:string -> (unit, string) result

type t = { run : run; read : read; write : write }

let make ~run ~read ~write = { run; read; write }

let git ?stdin t args =
  Result.map_error
    (fun message -> Error.make (Error.Git_failed message) message)
    (t.run ?stdin ("git" :: args))

let is_repository t =
  match t.run [ "git"; "rev-parse"; "--show-toplevel" ] with
  | Ok output when String.length (String.trim output) > 0 -> Ok ()
  | Ok _ ->
      Error
        (Error.make Error.Not_a_repository "git did not report a worktree root")
  | Error message ->
      Error
        (Error.make Error.Not_a_repository
           ("not inside a git worktree: " ^ message))

(* Quiet resolution: [Some hash] when [spec] names a commit, [None] otherwise. *)
let resolve_opt t spec =
  match
    t.run [ "git"; "rev-parse"; "--verify"; "--quiet"; spec ^ "^{commit}" ]
  with
  | Ok output ->
      let hash = String.trim output in
      if String.length hash > 0 then Some hash else None
  | Error _ -> None

let resolve_base t spec =
  match resolve_opt t spec with
  | Some hash -> Ok hash
  | None ->
      Error
        (Error.make (Error.Bad_revision spec)
           (Printf.sprintf "unknown base revision %s" spec))

(* The unified-diff output is pinned against user git configuration: path
   quoting off and the a/ b/ prefixes forced, so a downstream parser sees the
   same bytes regardless of core.quotePath, diff.mnemonicPrefix, or
   diff.noprefix. *)
let diff_args base =
  [
    "-c";
    "core.quotePath=false";
    "diff";
    "--no-color";
    "--no-ext-diff";
    "--src-prefix=a/";
    "--dst-prefix=b/";
    base;
  ]

type comparison = {
  sha : string;
  reference : string;
  upstream_warning : string option;
}

(* The review base for a branch: the merge base of a reference and HEAD. The
   reference is [base]'s upstream when it resolves and is strictly ahead, so a
   review against a stale local base branch compares against what the remote
   will see. No upstream configured is the ordinary local shape and falls back
   to [base] silently; an upstream that resolves but cannot be compared falls
   back too, with a warning the caller can surface — a stale comparison is
   exactly what the upstream preference exists to prevent. *)
let merge_base t ~base =
  match resolve_base t base with
  | Error e -> Error e
  | Ok _ -> (
      let upstream = base ^ "@{upstream}" in
      let fallback reason =
        ( base,
          Some
            (Printf.sprintf
               "%s resolved but could not be compared with %s (%s); reviewing \
                against %s"
               upstream base reason base) )
      in
      let reference, upstream_warning =
        match resolve_opt t upstream with
        | None -> (base, None)
        | Some _ -> (
            match git t [ "rev-list"; "--count"; base ^ ".." ^ upstream ] with
            | Error error -> fallback (Error.message error)
            | Ok count -> (
                match int_of_string_opt (String.trim count) with
                | Some ahead when ahead > 0 -> (upstream, None)
                | Some _ -> (base, None)
                | None -> fallback "unreadable rev-list count"))
      in
      match git t [ "merge-base"; reference; "HEAD" ] with
      | Error error ->
          let message =
            Printf.sprintf "cannot determine the merge base of %s and HEAD: %s"
              reference (Error.message error)
          in
          Error (Error.make (Error.Git_failed message) message)
      | Ok output ->
          let hash = String.trim output in
          if String.length hash > 0 then
            Ok { sha = hash; reference; upstream_warning }
          else
            git_failed
              (Printf.sprintf "no merge base between %s and HEAD" reference))

(* One commit's own change: its first parent against it. A root commit has no
   parent and therefore no lone diff; that is a revision-class refusal, not a
   git failure. *)
let commit_diff t ~commit =
  match resolve_base t commit with
  | Error _ as error -> error
  | Ok sha -> (
      match resolve_opt t (sha ^ "^") with
      | None ->
          Error
            (Error.make (Error.Bad_revision commit)
               (Printf.sprintf
                  "commit %s is a root commit; it has no parent to diff against"
                  commit))
      | Some parent ->
          git t
            [
              "-c";
              "core.quotePath=false";
              "diff";
              "--no-color";
              "--no-ext-diff";
              "--src-prefix=a/";
              "--dst-prefix=b/";
              parent;
              sha;
            ])

let untracked_paths t =
  match git t [ "ls-files"; "--others"; "--exclude-standard"; "-z" ] with
  | Error _ as error -> error
  | Ok output -> (
      match Parse.untracked_paths (Parse.nul_fields output) with
      | Ok paths -> Ok paths
      | Error message -> git_failed message)

(* A file's review-side text. A symlink reads as its target path — its git
   blob content — so the feature shows the link itself, exactly as a tracked
   link's diff would. *)
let worktree_text t ~path =
  match t.read path with
  | Ok (Text contents) -> Ok contents
  | Ok (Link target) -> Ok target
  | Error Too_large ->
      let message =
        Printf.sprintf "%s is too large to review" (Lpath.Rel.to_string path)
      in
      Error (Error.make (Error.Io message) message)
  | Error (Unreadable message) -> Error (Error.make (Error.Io message) message)

(* Bare [git diff] never shows an untracked file, so each is appended as a
   synthesized new-file diff — a worktree whose only change is a new file
   still yields a non-empty review diff. A symlink renders as git's link
   stanza from its target, never followed; a file over the read bound
   degrades to the binary stanza; any other unreadable file stays loud. *)
let diff_text t ~base_sha =
  match git t (diff_args base_sha) with
  | Error _ as error -> error
  | Ok tracked -> (
      match untracked_paths t with
      | Error _ as error -> error
      | Ok paths ->
          let rec append acc = function
            | [] -> Ok (String.concat "" (tracked :: List.rev acc))
            | path :: rest -> (
                match t.read path with
                | Ok (Text contents) ->
                    append (Parse.untracked_diff ~path ~contents :: acc) rest
                | Ok (Link target) ->
                    append (Parse.untracked_link_diff ~path ~target :: acc) rest
                | Error Too_large ->
                    append (Parse.untracked_binary_diff ~path :: acc) rest
                | Error (Unreadable message) ->
                    Error (Error.make (Error.Io message) message))
          in
          append [] paths)

(* An equality token for the untracked set: paths plus content identities, so
   creating, deleting, or editing an untracked file moves the fingerprint even
   when a writer preserves mtimes. A symlink's identity is its target text
   under a distinguishing prefix, so retargeting the link — or replacing a
   file with a link to identical bytes — moves the fingerprint too. *)
let untracked_token t paths =
  let buffer = Buffer.create 256 in
  List.iter
    (fun rel ->
      Mentat_digest.frame buffer (Lpath.Rel.to_string rel);
      match t.read rel with
      | Ok (Text contents) ->
          Mentat_digest.frame buffer
            (Mentat_digest.Content_ref.to_token
               (Mentat_digest.Content_ref.of_contents contents))
      | Ok (Link target) -> Mentat_digest.frame buffer ("link:" ^ target)
      | Error (Too_large | Unreadable _) ->
          Mentat_digest.frame buffer "absent")
    paths;
  Buffer.contents buffer

let fingerprint t ~base =
  match git t (diff_args base) with
  | Error _ as error -> error
  | Ok output -> (
      match untracked_paths t with
      | Error _ as error -> error
      | Ok untracked ->
          Ok
            (Parse.fingerprint_key ~diff:output
               ~untracked_token:(untracked_token t untracked)))

let changed_paths t ~base =
  match
    git t
      [ "diff"; "--name-status"; "--no-renames"; "--no-ext-diff"; "-z"; base ]
  with
  | Error _ as error -> error
  | Ok output -> (
      match Parse.name_status (Parse.nul_fields output) with
      | Error message -> git_failed message
      | Ok tracked -> (
          let tracked =
            List.filter (fun (_, rel) -> not (Parse.meta_path rel)) tracked
          in
          match untracked_paths t with
          | Error _ as error -> error
          | Ok untracked ->
              Ok (tracked @ List.map (fun rel -> ("A", rel)) untracked)))

(* The lightweight worktree change summary from [base] to the worktree: changed
   files with summed line additions and deletions. Tracked counts come from one
   [diff --numstat] spawn; each untracked file adds one file and its line count
   as additions. Unlike {!load} no base blob is read, no hunk is built, and no
   CR is scanned — this is the ambient glance's cheap source. Meta directories
   are excluded on both sides. *)
let stats t ~base =
  match
    git t [ "diff"; "--numstat"; "--no-renames"; "--no-ext-diff"; "-z"; base ]
  with
  | Error _ as error -> error
  | Ok output -> (
      match Parse.numstat (Parse.nul_fields output) with
      | Error message -> git_failed message
      | Ok records -> (
          let tracked =
            List.filter (fun (_, _, rel) -> not (Parse.meta_path rel)) records
          in
          match untracked_paths t with
          | Error _ as error -> error
          | Ok untracked ->
              let additions =
                List.fold_left (fun acc (add, _, _) -> acc + add) 0 tracked
              in
              let deletions =
                List.fold_left (fun acc (_, del, _) -> acc + del) 0 tracked
              in
              let untracked_additions =
                List.fold_left
                  (fun acc rel ->
                    match t.read rel with
                    | Ok (Text text) -> acc + Parse.count_lines text
                    | Ok (Link target) -> acc + Parse.count_lines target
                    | Error (Too_large | Unreadable _) -> acc)
                  0 untracked
              in
              Ok
                (Textdiff.Stats.v
                   ~files:(List.length tracked + List.length untracked)
                   ~additions:(additions + untracked_additions)
                   ~deletions)))

(* Read every base blob of [paths] in one [git cat-file --batch] spawn rather
   than one [cat-file blob] per file, so a large changeset costs a single git
   process instead of N. Returns each path's base-side text; a path git reports
   missing (renamed away, say) is an error, matching the per-file reader this
   replaces. *)
let base_blobs t ~base paths =
  match paths with
  | [] -> Ok []
  | _ -> (
      let stdin =
        String.concat ""
          (List.map
             (fun path -> base ^ ":" ^ Lpath.Rel.to_string path ^ "\n")
             paths)
      in
      match git ~stdin t [ "cat-file"; "--batch" ] with
      | Error _ as error -> error
      | Ok output -> (
          match Parse.cat_file_batch output ~count:(List.length paths) with
          | Error message -> git_failed message
          | Ok contents ->
              let rec zip paths contents =
                match (paths, contents) with
                | [], [] -> Ok []
                | path :: paths, Some content :: contents -> (
                    match zip paths contents with
                    | Error _ as error -> error
                    | Ok tail -> Ok ((path, content) :: tail))
                | path :: _, None :: _ ->
                    git_failed
                      (Printf.sprintf "base blob missing for %s"
                         (Lpath.Rel.to_string path))
                | _ ->
                    git_failed
                      "git cat-file --batch returned the wrong number of \
                       objects"
              in
              zip paths contents))

(* Assemble one file's (before, after) sides. [before] is the pre-fetched base
   blob — [Some] for a Modified or Deleted file, [None] for an Added one — so no
   git spawns happen here; the after side is the worktree read. *)
let sides t ~before status path =
  match status with
  | "A" -> (
      match worktree_text t ~path with
      | Ok after -> Ok (None, Some after)
      | Error _ as error -> error)
  | "D" -> Ok (before, None)
  | _ -> (
      match worktree_text t ~path with
      | Ok after -> Ok (before, Some after)
      | Error _ as error -> error)

let collect t ~base ~fingerprint:snapshot =
  match changed_paths t ~base with
  | Error _ as error -> error
  | Ok changed -> (
      let sorted =
        List.sort (fun (_, a) (_, b) -> Lpath.Rel.compare a b) changed
      in
      (* Modified and deleted files have a base side; added files do not. Batch
         the base blobs of the former into one cat-file spawn. *)
      let base_paths =
        List.filter_map
          (fun (status, path) ->
            if String.equal status "A" then None else Some path)
          sorted
      in
      match base_blobs t ~base base_paths with
      | Error _ as error -> error
      | Ok blobs -> (
          let table = Hashtbl.create (List.length blobs) in
          List.iter
            (fun (path, content) ->
              Hashtbl.replace table (Lpath.Rel.to_string path) content)
            blobs;
          let before_of path =
            Hashtbl.find_opt table (Lpath.Rel.to_string path)
          in
          let rec build files crs = function
            | [] -> Ok (List.rev files, List.rev crs)
            | (status, path) :: rest -> (
                match sides t ~before:(before_of path) status path with
                | Error _ as error -> error
                | Ok (before, after) -> (
                    (* Git's default diff context: two edits within a couple
                       dozen lines stay separate hunks, matching what a reviewer
                       sees in git. [Feature.File.make]'s own default is wider. *)
                    match
                      Mentat_review.Feature.File.make ~context:3 ~path ~before
                        ~after ()
                    with
                    | Error error ->
                        git_failed
                          (Printf.sprintf "cannot load %s: %s"
                             (Lpath.Rel.to_string path)
                             (Format.asprintf "%a" Mentat_review.Error.pp error))
                    | Ok file ->
                        let file_crs =
                          match after with
                          | Some text -> Mentat_review.Cr.scan_file ~path ~text
                          | None -> []
                        in
                        build (file :: files)
                          (List.rev_append file_crs crs)
                          rest))
          in
          match build [] [] sorted with
          | Error _ as error -> error
          | Ok (files, crs) ->
              let feature =
                Mentat_review.Feature.v ~base ~tip:"WORKTREE" files
              in
              Ok { Mentat_review.Live.feature; crs; fingerprint = snapshot }))

let max_load_attempts = 3

(* The snapshot is guarded by fingerprints taken before and after reading
   content, with a small bounded retry; a worktree that keeps changing during a
   load errors [Raced]. *)
let load t ~base =
  let rec attempt remaining =
    match fingerprint t ~base with
    | Error _ as error -> error
    | Ok snapshot -> (
        let retry error =
          if remaining > 1 then attempt (remaining - 1)
          else
            match (Error.kind error : Error.kind) with
            | Error.Io _ | Error.Raced ->
                Error
                  (Error.make Error.Raced
                     "the worktree kept changing while loading the review")
            | _ -> Error error
        in
        match collect t ~base ~fingerprint:snapshot with
        | Error error -> (
            match Error.kind error with
            | Error.Io _ -> retry error
            | _ -> Error error)
        | Ok load -> (
            match fingerprint t ~base with
            | Error _ as error -> error
            | Ok verify ->
                if String.equal verify snapshot then Ok load
                else retry (Error.make Error.Raced "worktree changed")))
  in
  attempt max_load_attempts

let load_if_changed t ~base ~known =
  match fingerprint t ~base with
  | Error _ as error -> error
  | Ok current -> (
      match known with
      | Some known when String.equal known current -> Ok `Unchanged
      | Some _ | None -> (
          match load t ~base with
          | Ok load -> Ok (`Loaded load)
          | Error _ as error -> error))

type apply_error = Content_changed | Apply_failed of string

(* The worktree-relative file an edit targets: an Add names it directly, a
   Replace or Remove names it through the occurrence ref. *)
let edit_path = function
  | Mentat_review.Cr.Edit.Add { path; _ } -> path
  | Mentat_review.Cr.Edit.Replace { ref; _ } -> ref.Mentat_review.Cr.Ref.path
  | Mentat_review.Cr.Edit.Remove { ref } -> ref.Mentat_review.Cr.Ref.path

(* Apply a wire-safe CR edit to its file and reload. The target file is read
   once and, for a Replace or Remove, the edit's ref is re-resolved against a
   fresh scan of that file — so staleness is judged against the commented CR,
   not the whole worktree: an unrelated edit elsewhere never blocks the action,
   and only a ref that no longer names a live occurrence is [Content_changed].
   Files without a comment syntax, an out-of-range line, a stale write, and any
   other failure are [Apply_failed]. The caller keeps its review either way. *)
let apply_edit t ~base edit =
  let cr_message error = Format.asprintf "%a" Mentat_review.Cr.Error.pp error in
  let rel = edit_path edit in
  match t.read rel with
  | Error Too_large ->
      Error
        (Apply_failed
           (Printf.sprintf "%s is too large to edit" (Lpath.Rel.to_string rel)))
  | Error (Unreadable message) -> Error (Apply_failed message)
  | Ok (Link _) ->
      Error
        (Apply_failed
           (Printf.sprintf "%s is a symbolic link" (Lpath.Rel.to_string rel)))
  | Ok (Text text) -> (
      let resolve ref =
        Mentat_review.Cr.resolve_ref
          (Mentat_review.Cr.scan_file ~path:rel ~text)
          ref
      in
      let op =
        match edit with
        | Mentat_review.Cr.Edit.Add { path; line; cr } ->
            Ok (Mentat_review.Op.Add { path; line; cr })
        | Mentat_review.Cr.Edit.Replace { ref; cr } -> (
            match resolve ref with
            | Some occurrence ->
                Ok (Mentat_review.Op.Replace { occurrence; cr })
            | None -> Error Content_changed)
        | Mentat_review.Cr.Edit.Remove { ref } -> (
            match resolve ref with
            | Some occurrence -> Ok (Mentat_review.Op.Remove { occurrence })
            | None -> Error Content_changed)
      in
      match op with
      | Error _ as error -> error
      | Ok op -> (
          let edited =
            match op with
            | Mentat_review.Op.Add { line; cr; _ } -> (
                match Mentat_review.Cr.Syntax.of_path rel with
                | None ->
                    Error
                      (Printf.sprintf "%s has no conventional comment syntax"
                         (Lpath.Rel.to_string rel))
                | Some syntax ->
                    Result.map_error cr_message
                      (Mentat_review.Cr.add_before_line ~syntax ~text ~line cr))
            | Mentat_review.Op.Replace { occurrence; cr } ->
                Result.map_error cr_message
                  (Mentat_review.Cr.replace ~text occurrence cr)
            | Mentat_review.Op.Remove { occurrence } ->
                Result.map_error cr_message
                  (Mentat_review.Cr.remove ~text occurrence)
          in
          match edited with
          | Error message -> Error (Apply_failed message)
          | Ok edited -> (
              match t.write rel ~before:text ~after:edited with
              | Error message -> Error (Apply_failed message)
              | Ok () -> (
                  match load t ~base with
                  | Ok load -> Ok load
                  | Error error -> Error (Apply_failed (Error.message error)))))
      )
