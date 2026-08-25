(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Review_git], the executable-side review projection over
   {!Mentat_review}'s pure codecs. The loader is
   pure: it takes injected [run]/[read]/[write] closures, so every test scripts a
   fake git subprocess and worktree and drives the whole load without a
   capability. The sealed process/file/edit path the composition edge wires those
   closures through is exercised by the review crams, not here.

   The module lives in [bin/] and is not library-linkable, so its source is
   copied into this test executable by the [copy_files] rule in [dune]. *)

open Windtrap
module Rel = Lpath.Rel

let rel = Rel.of_string_exn

let git_parse_pure () =
  equal (list string) ~msg:"nul_fields drops empties" [ "a"; "b" ]
    (Review_git.Parse.nul_fields "a\000b\000");
  is_true ~msg:".git is meta" (Review_git.Parse.meta_path (rel ".git/config"));
  is_true ~msg:".mentat is meta" (Review_git.Parse.meta_path (rel ".mentat/x"));
  is_true ~msg:"_build is meta" (Review_git.Parse.meta_path (rel "_build/x"));
  is_true ~msg:"lib is not meta"
    (not (Review_git.Parse.meta_path (rel "lib/a.ml")));
  (match Review_git.Parse.name_status [ "M"; "lib/a.ml"; "A"; "lib/b.ml" ] with
  | Ok [ ("M", a); ("A", b) ] ->
      is_true ~msg:"name-status pairs"
        (Rel.equal (rel "lib/a.ml") a && Rel.equal (rel "lib/b.ml") b)
  | Ok _ -> fail "unexpected name-status pairing"
  | Error message -> failf "name-status: %s" message);
  (match Review_git.Parse.name_status [ "M"; "lib/a.ml"; "A" ] with
  | Error _ -> ()
  | Ok _ -> fail "an unpaired trailing field must be an error");
  (match
     Review_git.Parse.untracked_paths [ "lib/c.ml"; ".git/hook"; "_build/x" ]
   with
  | Ok [ path ] ->
      is_true ~msg:"untracked drops meta" (Rel.equal (rel "lib/c.ml") path)
  | Ok _ -> fail "meta untracked paths must be dropped"
  | Error message -> failf "untracked: %s" message);
  (match
     Review_git.Parse.numstat [ "3\t1\tlib/a.ml"; "-\t-\tbin/logo.png" ]
   with
  | Ok [ (add_a, del_a, a); (add_b, del_b, b) ] ->
      is_true ~msg:"numstat counts and paths"
        (add_a = 3 && del_a = 1
        && Rel.equal (rel "lib/a.ml") a
        && add_b = 0 && del_b = 0
        && Rel.equal (rel "bin/logo.png") b)
  | Ok _ -> fail "unexpected numstat parse"
  | Error message -> failf "numstat: %s" message);
  (match Review_git.Parse.numstat [ "1\tlib/a.ml" ] with
  | Error _ -> ()
  | Ok _ -> fail "a record without two tabs must be an error");
  equal int ~msg:"count_lines of empty is zero" 0
    (Review_git.Parse.count_lines "");
  equal int ~msg:"count_lines counts newline-terminated lines" 2
    (Review_git.Parse.count_lines "a\nb\n");
  equal int ~msg:"count_lines counts a final unterminated line" 2
    (Review_git.Parse.count_lines "a\nb");
  let key = Review_git.Parse.fingerprint_key ~diff:"D" ~untracked_token:"U" in
  equal string ~msg:"fingerprint is deterministic" key
    (Review_git.Parse.fingerprint_key ~diff:"D" ~untracked_token:"U");
  is_true ~msg:"a changed diff moves the fingerprint"
    (not
       (String.equal key
          (Review_git.Parse.fingerprint_key ~diff:"D2" ~untracked_token:"U")))

let str_contains sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  n = 0 || go 0

(* Emit the [git cat-file --batch] reply for the [base:path] object list fed on
   [stdin], looking each up in [blobs]. Content is framed exactly as git frames
   it — [<oid> blob <size>\n<content>\n] — and an unknown object is reported
   [missing], so the loader's batch parser is exercised end to end. *)
let cat_file_batch_reply ~blobs stdin =
  let oid = String.make 40 '0' in
  let names =
    List.filter (fun s -> String.length s > 0) (String.split_on_char '\n' stdin)
  in
  let buffer = Buffer.create 256 in
  List.iter
    (fun name ->
      match List.assoc_opt name blobs with
      | Some content ->
          Buffer.add_string buffer
            (Printf.sprintf "%s blob %d\n%s\n" oid (String.length content)
               content)
      | None -> Buffer.add_string buffer (name ^ " missing\n"))
    names;
  Ok (Buffer.contents buffer)

(* A scripted git worktree: [base] modifies [lib/a.ml] and adds the untracked
   [lib/new.ml]. The fake [run] answers exact argv — base blobs come through one
   [cat-file --batch] whose object list arrives on [stdin] — and the fake [read]
   answers worktree texts, so the whole load runs without a subprocess. *)
let scripted_loader () =
  let blobs = [ ("deadbeef:lib/a.ml", "let a = 1\n") ] in
  let responses =
    [
      ([ "git"; "rev-parse"; "--show-toplevel" ], Ok "/repo\n");
      ( [ "git"; "rev-parse"; "--verify"; "--quiet"; "trunk^{commit}" ],
        Ok "deadbeef\n" );
      ( [
          "git";
          "-c";
          "core.quotePath=false";
          "diff";
          "--no-color";
          "--no-ext-diff";
          "--src-prefix=a/";
          "--dst-prefix=b/";
          "deadbeef";
        ],
        Ok "DIFF" );
      ( [ "git"; "ls-files"; "--others"; "--exclude-standard"; "-z" ],
        Ok "lib/new.ml\000" );
      ( [
          "git";
          "diff";
          "--name-status";
          "--no-renames";
          "--no-ext-diff";
          "-z";
          "deadbeef";
        ],
        Ok "M\000lib/a.ml\000" );
      ( [
          "git";
          "diff";
          "--numstat";
          "--no-renames";
          "--no-ext-diff";
          "-z";
          "deadbeef";
        ],
        Ok "1\t1\tlib/a.ml\000" );
    ]
  in
  let texts = [ ("lib/a.ml", "let a = 2\n"); ("lib/new.ml", "let n = 0\n") ] in
  let run ?(stdin = "") argv =
    match argv with
    | [ "git"; "cat-file"; "--batch" ] -> cat_file_batch_reply ~blobs stdin
    | _ -> (
        match List.assoc_opt argv responses with
        | Some result -> result
        | None -> Error ("unscripted git: " ^ String.concat " " argv))
  in
  let read rel =
    match List.assoc_opt (Rel.to_string rel) texts with
    | Some text -> Ok text
    | None -> Error ("no such file: " ^ Rel.to_string rel)
  in
  let write _ ~before:_ ~after:_ = Ok () in
  Review_git.make ~run ~read ~write

let git_resolve_base () =
  let loader = scripted_loader () in
  (match Review_git.resolve_base loader "trunk" with
  | Ok hash -> equal string ~msg:"resolved base hash" "deadbeef" hash
  | Error error -> failf "resolve_base: %a" Review_git.Error.pp error);
  match Review_git.resolve_base loader "no-such-ref" with
  | Ok _ -> fail "an unknown revision must fail"
  | Error error -> (
      match Review_git.Error.kind error with
      | Review_git.Error.Bad_revision _ -> ()
      | _ -> failf "expected Bad_revision, got %a" Review_git.Error.pp error)

(* A loader scripting only the merge-base flow: base resolution, upstream
   resolution, the rev-list comparison, and merge-base itself. *)
let merge_base_loader ~upstream ~rev_list ~merge_base_ref () =
  let run ?stdin:_ argv =
    match argv with
    | [ "git"; "rev-parse"; "--verify"; "--quiet"; "trunk^{commit}" ] ->
        Ok "deadbeef\n"
    | [ "git"; "rev-parse"; "--verify"; "--quiet"; "trunk@{upstream}^{commit}" ]
      ->
        upstream
    | [ "git"; "rev-list"; "--count"; "trunk..trunk@{upstream}" ] -> rev_list
    | [ "git"; "merge-base"; reference; "HEAD" ]
      when String.equal reference merge_base_ref ->
        Ok "cafebabe\n"
    | _ -> Error ("unscripted git: " ^ String.concat " " argv)
  in
  let read rel = Error ("no such file: " ^ Rel.to_string rel) in
  let write _ ~before:_ ~after:_ = Ok () in
  Review_git.make ~run ~read ~write

let git_merge_base_names_its_reference () =
  let comparison loader =
    match Review_git.merge_base loader ~base:"trunk" with
    | Ok comparison -> comparison
    | Error error -> failf "merge_base: %a" Review_git.Error.pp error
  in
  let no_upstream =
    comparison
      (merge_base_loader ~upstream:(Error "fatal: no upstream")
         ~rev_list:(Error "unreached") ~merge_base_ref:"trunk" ())
  in
  equal string ~msg:"no upstream compares against the base" "trunk"
    no_upstream.Review_git.reference;
  equal string ~msg:"the merge base hash is trimmed" "cafebabe"
    no_upstream.Review_git.sha;
  is_true ~msg:"no upstream warns nothing"
    (Option.is_none no_upstream.Review_git.upstream_warning);
  let ahead =
    comparison
      (merge_base_loader ~upstream:(Ok "beefbeef\n") ~rev_list:(Ok "2\n")
         ~merge_base_ref:"trunk@{upstream}" ())
  in
  equal string ~msg:"an ahead upstream is preferred" "trunk@{upstream}"
    ahead.Review_git.reference;
  is_true ~msg:"a used upstream warns nothing"
    (Option.is_none ahead.Review_git.upstream_warning);
  let not_ahead =
    comparison
      (merge_base_loader ~upstream:(Ok "beefbeef\n") ~rev_list:(Ok "0\n")
         ~merge_base_ref:"trunk" ())
  in
  equal string ~msg:"an even upstream falls back to the base" "trunk"
    not_ahead.Review_git.reference;
  is_true ~msg:"an even upstream warns nothing"
    (Option.is_none not_ahead.Review_git.upstream_warning);
  let incomparable =
    comparison
      (merge_base_loader ~upstream:(Ok "beefbeef\n")
         ~rev_list:(Error "fatal: shallow history") ~merge_base_ref:"trunk" ())
  in
  equal string ~msg:"an incomparable upstream falls back to the base" "trunk"
    incomparable.Review_git.reference;
  match incomparable.Review_git.upstream_warning with
  | Some warning ->
      is_true ~msg:"the warning names the upstream"
        (let sub = "trunk@{upstream}" in
         let n = String.length sub and m = String.length warning in
         let rec go i =
           i + n <= m && (String.equal (String.sub warning i n) sub || go (i + 1))
         in
         go 0)
  | None -> fail "an incomparable upstream must warn"

let git_load_builds_the_feature () =
  let loader = scripted_loader () in
  match Review_git.load loader ~base:"deadbeef" with
  | Error error -> failf "load: %a" Review_git.Error.pp error
  | Ok loaded ->
      let feature = loaded.Mentat_review.Live.feature in
      equal string ~msg:"feature base is the resolved hash" "deadbeef"
        (Mentat_review.Feature.base feature);
      let files = Mentat_review.Feature.files feature in
      equal (list string) ~msg:"tracked and untracked files, path-sorted"
        [ "lib/a.ml"; "lib/new.ml" ]
        (List.map
           (fun file -> Rel.to_string (Mentat_review.Feature.File.path file))
           files);
      let status_of path =
        match Mentat_review.Feature.find_file feature ~path:(rel path) with
        | Some file -> Mentat_review.Feature.File.status file
        | None -> failf "missing file %s" path
      in
      is_true ~msg:"lib/a.ml is Modified"
        (match status_of "lib/a.ml" with
        | Mentat_review.Feature.File.Modified -> true
        | _ -> false);
      is_true ~msg:"lib/new.ml is Added"
        (match status_of "lib/new.ml" with
        | Mentat_review.Feature.File.Added -> true
        | _ -> false)

(* The lightweight glance summary over the same scripted worktree: numstat gives
   the tracked +1 −1 on lib/a.ml, and the one untracked lib/new.ml adds one file
   and its single line as additions — never a base-blob read or a CR scan. *)
let git_stats_summarizes_the_worktree () =
  let loader = scripted_loader () in
  match Review_git.stats loader ~base:"deadbeef" with
  | Error error -> failf "stats: %a" Review_git.Error.pp error
  | Ok stats ->
      equal int ~msg:"tracked + untracked file count" 2 stats.Textdiff.files;
      equal int ~msg:"tracked + untracked additions" 2 stats.Textdiff.additions;
      equal int ~msg:"tracked deletions, untracked none" 1
        stats.Textdiff.deletions

let git_load_batches_base_blobs () =
  (* A three-file changeset reads every base blob through one
     [git cat-file --batch], never a per-file [cat-file blob] spawn. This is the
     fix for the O(files) git spawns that held a large review at "computing…":
     the load was one subprocess per modified file. *)
  let blobs =
    [
      ("deadbeef:lib/a.ml", "let a = 1\n");
      ("deadbeef:lib/b.ml", "let b = 1\n");
      ("deadbeef:lib/c.ml", "let c = 1\n");
    ]
  in
  let texts =
    [
      ("lib/a.ml", "let a = 2\n");
      ("lib/b.ml", "let b = 2\n");
      ("lib/c.ml", "let c = 2\n");
    ]
  in
  let calls = ref [] in
  let run ?(stdin = "") argv =
    calls := argv :: !calls;
    match argv with
    | [
     "git";
     "-c";
     "core.quotePath=false";
     "diff";
     "--no-color";
     "--no-ext-diff";
     "--src-prefix=a/";
     "--dst-prefix=b/";
     "deadbeef";
    ] ->
        Ok "DIFF"
    | [ "git"; "ls-files"; "--others"; "--exclude-standard"; "-z" ] -> Ok ""
    | [
     "git";
     "diff";
     "--name-status";
     "--no-renames";
     "--no-ext-diff";
     "-z";
     "deadbeef";
    ] ->
        Ok "M\000lib/a.ml\000M\000lib/b.ml\000M\000lib/c.ml\000"
    | [ "git"; "cat-file"; "--batch" ] -> cat_file_batch_reply ~blobs stdin
    | _ -> Error ("unscripted git: " ^ String.concat " " argv)
  in
  let read rel =
    match List.assoc_opt (Rel.to_string rel) texts with
    | Some text -> Ok text
    | None -> Error ("no such file: " ^ Rel.to_string rel)
  in
  let write _ ~before:_ ~after:_ = Ok () in
  let loader = Review_git.make ~run ~read ~write in
  match Review_git.load loader ~base:"deadbeef" with
  | Error error -> failf "load: %a" Review_git.Error.pp error
  | Ok loaded ->
      equal int ~msg:"all three files load" 3
        (List.length
           (Mentat_review.Feature.files loaded.Mentat_review.Live.feature));
      let is_per_file_blob = function
        | "git" :: "cat-file" :: "blob" :: _ -> true
        | _ -> false
      in
      let is_batch = function
        | [ "git"; "cat-file"; "--batch" ] -> true
        | _ -> false
      in
      is_true ~msg:"no per-file cat-file blob spawn"
        (not (List.exists is_per_file_blob !calls));
      equal int ~msg:"exactly one cat-file --batch spawn" 1
        (List.length (List.filter is_batch !calls))

let git_cat_file_batch_parse () =
  let present content =
    Printf.sprintf "%s blob %d\n%s\n" (String.make 40 'a')
      (String.length content) content
  in
  let output =
    present "let a = 1\n" ^ "deadbeef:gone missing\n" ^ present "multi\nline\n"
  in
  (match Review_git.Parse.cat_file_batch output ~count:3 with
  | Ok [ Some a; None; Some c ] ->
      equal string ~msg:"present blob content" "let a = 1\n" a;
      equal string ~msg:"content newlines are preserved by the size framing"
        "multi\nline\n" c
  | Ok _ -> fail "expected present, missing, present"
  | Error message -> failf "batch parse: %s" message);
  (* A body shorter than its declared size is an error, never a silent slice. *)
  match Review_git.Parse.cat_file_batch "aaa blob 99\nshort\n" ~count:1 with
  | Error _ -> ()
  | Ok _ -> fail "a truncated object must be an error"

(* A single-file (lib/a.ml, Modified) worktree whose text is mutable, so the
   reload after a write observes the new text. Base blobs come through one
   [cat-file --batch]; [writes] records every written text in reverse order. *)
let mutation_loader ~worktree =
  let blobs = [ ("deadbeef:lib/a.ml", "let a = 1\n") ] in
  let writes = ref [] in
  let run ?(stdin = "") argv =
    match argv with
    | [
     "git";
     "-c";
     "core.quotePath=false";
     "diff";
     "--no-color";
     "--no-ext-diff";
     "--src-prefix=a/";
     "--dst-prefix=b/";
     "deadbeef";
    ] ->
        Ok "DIFF"
    | [ "git"; "ls-files"; "--others"; "--exclude-standard"; "-z" ] -> Ok ""
    | [
     "git";
     "diff";
     "--name-status";
     "--no-renames";
     "--no-ext-diff";
     "-z";
     "deadbeef";
    ] ->
        Ok "M\000lib/a.ml\000"
    | [ "git"; "cat-file"; "--batch" ] -> cat_file_batch_reply ~blobs stdin
    | _ -> Error ("unscripted git: " ^ String.concat " " argv)
  in
  let read rel =
    if String.equal (Rel.to_string rel) "lib/a.ml" then Ok !worktree
    else Error ("no such file: " ^ Rel.to_string rel)
  in
  let write rel ~before:_ ~after =
    if String.equal (Rel.to_string rel) "lib/a.ml" then (
      writes := after :: !writes;
      worktree := after;
      Ok ())
    else Error ("no write: " ^ Rel.to_string rel)
  in
  (Review_git.make ~run ~read ~write, writes)

let make_cr body =
  match Mentat_review.Cr.make ~body () with
  | Ok cr -> cr
  | Error error -> failf "cr make: %a" Mentat_review.Cr.Error.pp error

(* The occurrence ref a frontend would hold for the CR in [text] whose body
   contains [needle] — minted the same way {!Mentat_review.Cr.views} mints one. *)
let ref_for text needle =
  let views =
    Mentat_review.Cr.views
      (Mentat_review.Cr.scan_file ~path:(rel "lib/a.ml") ~text)
  in
  match
    List.find_opt
      (fun v -> str_contains needle v.Mentat_review.Cr.View.body)
      views
  with
  | Some v -> v.Mentat_review.Cr.View.ref
  | None -> failf "no CR occurrence matching %S" needle

let git_apply_edit_replaces_against_fresh_scan () =
  (* A Replace whose commented CR is unchanged lands: the ref re-resolves against
     a fresh scan of the file and the new body is written. *)
  let worktree = ref "let a = 2\n(* CR reviewer: fix this *)\n" in
  let loader, writes = mutation_loader ~worktree in
  let edit =
    Mentat_review.Cr.Edit.Replace
      { ref = ref_for !worktree "fix this"; cr = make_cr "fix this now" }
  in
  match Review_git.apply_edit loader ~base:"deadbeef" edit with
  | Error Review_git.Content_changed -> fail "the commented CR was unchanged"
  | Error (Review_git.Apply_failed message) -> failf "apply failed: %s" message
  | Ok _ -> (
      match !writes with
      | after :: _ ->
          is_true ~msg:"the new CR body is written"
            (str_contains "fix this now" after)
      | [] -> fail "the write closure was never called")

let git_apply_edit_stales_only_on_changed_comment () =
  (* Staleness is judged against the commented comment: when that comment itself
     changed on disk, the ref no longer resolves and the action fails loud with
     [Content_changed], writing nothing. *)
  let worktree = ref "let a = 2\n(* CR reviewer: fix this *)\n" in
  let loader, writes = mutation_loader ~worktree in
  let ref_ = ref_for !worktree "fix this" in
  worktree := "let a = 2\n(* CR reviewer: something else entirely *)\n";
  let edit =
    Mentat_review.Cr.Edit.Replace { ref = ref_; cr = make_cr "fix this now" }
  in
  match Review_git.apply_edit loader ~base:"deadbeef" edit with
  | Error Review_git.Content_changed ->
      is_true ~msg:"nothing is written when the comment changed" (!writes = [])
  | Ok _ -> fail "a changed comment must fail loud"
  | Error (Review_git.Apply_failed message) ->
      failf "expected Content_changed: %s" message

let git_apply_edit_sequential_actions_succeed () =
  (* Writing one CR must not stale the next action. Two Replaces land in a row
     over a worktree that changes between them — first by the write itself, then
     by an unrelated line — because each is judged against its own commented
     comment, not the whole worktree. This is the reported "re-query the rev"
     defect: the second edit used to stale on the first edit's fingerprint. *)
  let worktree =
    ref "let a = 2\n(* CR reviewer: one *)\n(* CR reviewer: two *)\n"
  in
  let loader, writes = mutation_loader ~worktree in
  let first =
    Mentat_review.Cr.Edit.Replace
      { ref = ref_for !worktree "one"; cr = make_cr "one resolved" }
  in
  (match Review_git.apply_edit loader ~base:"deadbeef" first with
  | Ok _ -> ()
  | Error Review_git.Content_changed -> fail "the first edit staled"
  | Error (Review_git.Apply_failed message) ->
      failf "first edit failed: %s" message);
  (* An unrelated worktree change lands between the two actions. *)
  worktree := !worktree ^ "let unrelated = 0\n";
  let second =
    Mentat_review.Cr.Edit.Replace
      { ref = ref_for !worktree "two"; cr = make_cr "two resolved" }
  in
  (match Review_git.apply_edit loader ~base:"deadbeef" second with
  | Ok _ -> ()
  | Error Review_git.Content_changed ->
      fail "the second edit staled after the first write"
  | Error (Review_git.Apply_failed message) ->
      failf "second edit failed: %s" message);
  equal int ~msg:"both edits wrote" 2 (List.length !writes)

let git_not_a_repository () =
  let loader =
    Review_git.make
      ~run:(fun ?stdin:_ _ -> Error "not a git repository")
      ~read:(fun _ -> Error "no read")
      ~write:(fun _ ~before:_ ~after:_ -> Error "no write")
  in
  match Review_git.is_repository loader with
  | Ok () -> fail "a non-repository must fail"
  | Error error -> (
      match Review_git.Error.kind error with
      | Review_git.Error.Not_a_repository -> ()
      | _ -> failf "expected Not_a_repository, got %a" Review_git.Error.pp error
      )

(* Suite. *)

let () =
  run "mentat.review_git"
    [
      test "git parsing splits, filters, and fingerprints" git_parse_pure;
      test "git cat-file --batch parsing" git_cat_file_batch_parse;
      test "git resolve_base returns the commit hash" git_resolve_base;
      test "git merge_base names the reference it compared"
        git_merge_base_names_its_reference;
      test "git load builds the reviewable feature" git_load_builds_the_feature;
      test "git stats summarizes the worktree" git_stats_summarizes_the_worktree;
      test "git load reads base blobs in one cat-file --batch"
        git_load_batches_base_blobs;
      test "git apply_edit replaces against a fresh scan"
        git_apply_edit_replaces_against_fresh_scan;
      test "git apply_edit stales only on a changed comment"
        git_apply_edit_stales_only_on_changed_comment;
      test "git apply_edit lands successive CR edits"
        git_apply_edit_sequential_actions_succeed;
      test "git is_repository fails outside a worktree" git_not_a_repository;
    ]
