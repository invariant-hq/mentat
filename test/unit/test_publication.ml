(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Publication], the review publication renderer. The module
   is pure — diff parsing, anchoring, policy partition, and request
   rendering — so everything is exercised on values and string payloads
   directly.

   The module lives in the private [mentat_connector] library under
   [bin/connector/]. *)

open Windtrap
open Mentat_connector
module Severity = Review_finding.Severity

let str_contains sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  n = 0 || go 0

(* Mirror [Document.decode]'s invariants: titles arrive neutralized. *)
let finding ?end_line ?(body = "") ~severity ~path ~line ~anchor ~title () =
  {
    Review_finding.severity;
    path;
    line;
    end_line;
    anchor;
    title = Review_finding.Body.text (Review_finding.Body.of_model_text title);
    body = Review_finding.Body.of_model_text body;
  }

let fingerprint (f : Review_finding.t) =
  Review_finding.Fingerprint.of_finding ~path:f.Review_finding.path
    ~anchor:f.Review_finding.anchor ~title:f.Review_finding.title

let hex f = Review_finding.Fingerprint.to_hex (fingerprint f)

let diff_of s =
  match Publication.Diff.of_unified s with
  | Ok diff -> diff
  | Error e -> failf "diff: %s" (Publication.Error.message e)

let posted_of json =
  match Publication.Posted.decode json with
  | Ok posted -> posted
  | Error e -> failf "posted: %s" (Publication.Error.message e)

let head = "0123456789abcdef0123456789abcdef01234567"

let publish ?policy ?posted ?(findings = []) diff =
  let policy = Option.value policy ~default:Publication.Policy.default in
  let posted = match posted with Some p -> p | None -> posted_of "[]" in
  Publication.of_findings ~diff ~policy ~posted ~origin:"ci"
    ~owner_repo:"acme/widget" ~number:5 ~head ~base_label:"main"
    { Review_finding.Document.summary = "s"; findings }

let thread_hexes p =
  List.map
    (fun (a : Publication.Anchored.t) ->
      Review_finding.Fingerprint.to_hex a.Publication.Anchored.fingerprint)
    (Publication.threads p)

let row_titles p =
  List.map
    (fun (u : Publication.Unanchored.t) ->
      u.Publication.Unanchored.finding.Review_finding.title)
    (Publication.summary_rows p)

let request_body_text (r : Publication.Request.t) =
  match r.Publication.Request.body with
  | Jsont.Object (mems, _) -> (
      match Jsont.Json.find_mem "body" mems with
      | Some (_, Jsont.String (s, _)) -> s
      | _ -> fail "the request has no string body member")
  | _ -> fail "the request body is not an object"

let summary_body_of p =
  request_body_text (Publication.requests p).Publication.summary

let encode_compact json =
  match Jsont_bytesrw.encode_string ~format:Jsont.Minify Jsont.json json with
  | Ok s -> s
  | Error reason -> failf "encode: %s" reason

(* Diff parsing. *)

let multi_file_diff =
  String.concat "\n"
    [
      "diff --git a/lib/a.ml b/lib/a.ml";
      "index 1111111..2222222 100644";
      "--- a/lib/a.ml";
      "+++ b/lib/a.ml";
      "@@ -1,3 +1,4 @@";
      " let a = 1";
      "-let b = 2";
      "+let b = 3";
      "+let c = 4";
      " let d = 5";
      "@@ -10 +11,2 @@";
      " tail context";
      "+added tail";
      "diff --git a/lib/old.ml b/lib/new.ml";
      "similarity index 90%";
      "rename from lib/old.ml";
      "rename to lib/new.ml";
      "index 3333333..4444444 100644";
      "--- a/lib/old.ml";
      "+++ b/lib/new.ml";
      "@@ -1,2 +1,2 @@";
      "-let x = 1";
      "+let x = 2";
      " let y = 3";
      "diff --git a/img.png b/img.png";
      "index 5555555..6666666 100644";
      "Binary files a/img.png and b/img.png differ";
      "diff --git a/gone.ml b/gone.ml";
      "deleted file mode 100644";
      "--- a/gone.ml";
      "+++ /dev/null";
      "@@ -1,2 +0,0 @@";
      "-one";
      "-two";
      "diff --git a/fresh.ml b/fresh.ml";
      "new file mode 100644";
      "--- /dev/null";
      "+++ b/fresh.ml";
      "@@ -0,0 +1,2 @@";
      "+first";
      "+second";
      "";
    ]

let diff_parses_files () =
  let diff = diff_of multi_file_diff in
  equal (list int) ~msg:"commentable lines cover context and additions"
    [ 1; 2; 3; 4; 11; 12 ]
    (Publication.Diff.commentable_lines diff ~path:"lib/a.ml");
  equal (option string) ~msg:"context line text" (Some "let a = 1")
    (Publication.Diff.line_text diff ~path:"lib/a.ml" ~line:1);
  equal (option string) ~msg:"added line text" (Some "let c = 4")
    (Publication.Diff.line_text diff ~path:"lib/a.ml" ~line:3);
  equal (option string) ~msg:"second hunk text" (Some "added tail")
    (Publication.Diff.line_text diff ~path:"lib/a.ml" ~line:12);
  equal (option string) ~msg:"a line between hunks is not commentable" None
    (Publication.Diff.line_text diff ~path:"lib/a.ml" ~line:6);
  equal (list int) ~msg:"a rename registers its new-side path" [ 1; 2 ]
    (Publication.Diff.commentable_lines diff ~path:"lib/new.ml");
  equal (list int) ~msg:"the rename's old path is gone" []
    (Publication.Diff.commentable_lines diff ~path:"lib/old.ml");
  equal (list int) ~msg:"binary files are unanchorable" []
    (Publication.Diff.commentable_lines diff ~path:"img.png");
  equal (list int) ~msg:"deleted files have no new side" []
    (Publication.Diff.commentable_lines diff ~path:"gone.ml");
  equal (list int) ~msg:"new files are fully commentable" [ 1; 2 ]
    (Publication.Diff.commentable_lines diff ~path:"fresh.ml");
  equal (option string) ~msg:"new-file line text" (Some "second")
    (Publication.Diff.line_text diff ~path:"fresh.ml" ~line:2)

let diff_reads_no_newline_markers () =
  let diff =
    diff_of
      (String.concat "\n"
         [
           "diff --git a/tail.txt b/tail.txt";
           "index aaa..bbb 100644";
           "--- a/tail.txt";
           "+++ b/tail.txt";
           "@@ -1 +1 @@";
           "-old line";
           "\\ No newline at end of file";
           "+new line";
           "\\ No newline at end of file";
           "";
         ])
  in
  equal (option string) ~msg:"the replacement line is commentable"
    (Some "new line")
    (Publication.Diff.line_text diff ~path:"tail.txt" ~line:1)

let diff_rejects ~msg ?expect body =
  match Publication.Diff.of_unified body with
  | Ok _ -> failf "%s: the diff parsed" msg
  | Error e -> (
      let message = Publication.Error.message e in
      match expect with
      | None -> ()
      | Some needle ->
          if not (str_contains needle message) then
            failf "%s: message %S does not name %S" msg message needle)

let diff_is_strict () =
  let file body =
    String.concat "\n"
      ([ "diff --git a/f b/f"; "--- a/f"; "+++ b/f" ] @ body)
  in
  diff_rejects ~msg:"truncated hunk header" ~expect:"malformed hunk header"
    (file [ "@@ -1,2 +1,2 @"; " x"; " y" ]);
  diff_rejects ~msg:"junk hunk header" ~expect:"malformed hunk header"
    (file [ "@@ junk @@" ]);
  diff_rejects ~msg:"countless hunk header" ~expect:"malformed hunk header"
    (file [ "@@ - + @@" ]);
  diff_rejects ~msg:"no space after the header" ~expect:"malformed hunk header"
    (file [ "@@ -1 +1 @@x"; " a" ]);
  diff_rejects ~msg:"hunk body past its counts" ~expect:"exceed"
    (file [ "@@ -1 +1,2 @@"; " a"; " b" ]);
  diff_rejects ~msg:"diff ends inside a hunk" ~expect:"inside a hunk"
    (file [ "@@ -2,2 +2,2 @@"; " a" ]);
  diff_rejects ~msg:"garbage inside a hunk" ~expect:"expected a context"
    (file [ "@@ -1,2 +1,2 @@"; " a"; "junk" ]);
  diff_rejects ~msg:"content before any file header" ~expect:"file header"
    (String.concat "\n" [ "hello"; "diff --git a/f b/f" ]);
  diff_rejects ~msg:"hunk before any file header" ~expect:"file header"
    "@@ -1 +1 @@"

(* Real git bytes: a name containing a space gets a literal tab suffix on the
   [---]/[+++] lines. *)
let diff_strips_the_tab_after_a_spaced_path () =
  let diff =
    diff_of
      (String.concat "\n"
         [
           "diff --git a/a b.txt b/a b.txt";
           "index 1111111..2222222 100644";
           "--- a/a b.txt\t";
           "+++ b/a b.txt\t";
           "@@ -1 +1,2 @@";
           " first line";
           "+second line";
           "";
         ])
  in
  equal (list int) ~msg:"the tab-suffixed name registers clean" [ 1; 2 ]
    (Publication.Diff.commentable_lines diff ~path:"a b.txt");
  equal (option string) ~msg:"line text under the clean path"
    (Some "second line")
    (Publication.Diff.line_text diff ~path:"a b.txt" ~line:2)

(* Anchoring. *)

let anchoring_matches_the_quote () =
  let diff = diff_of multi_file_diff in
  let anchored =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:3 ~anchor:"let c = 4"
      ~title:"Anchored" ()
  in
  (* The quote is unique at line 11; the claimed line 10 is not even
     commentable. Anchor-first matching threads it at the matched line. *)
  let wrong_line =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:10 ~end_line:12
      ~anchor:"tail context" ~title:"Wrong line" ()
  in
  let padded =
    finding ~severity:Severity.P1 ~path:"lib/a.ml" ~line:2
      ~anchor:"  let b = 3  " ~title:"Padded" ()
  in
  let substring =
    finding ~severity:Severity.P1 ~path:"lib/a.ml" ~line:2 ~anchor:"b = 3"
      ~title:"Substring" ()
  in
  let hallucinated =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:3 ~anchor:"let z = 9"
      ~title:"Hallucinated" ()
  in
  let foreign_path =
    finding ~severity:Severity.P0 ~path:"lib/q.ml" ~line:1 ~anchor:"let a = 1"
      ~title:"Foreign path" ()
  in
  let mild =
    finding ~severity:Severity.P2 ~path:"lib/a.ml" ~line:1 ~anchor:"let a = 1"
      ~title:"Mild" ()
  in
  let p =
    publish diff
      ~findings:
        [
          anchored; wrong_line; padded; substring; hallucinated; foreign_path;
          mild;
        ]
  in
  equal (list string)
    ~msg:"trimmed-equal quotes thread; the claimed line is no gate"
    [ hex anchored; hex wrong_line; hex padded ]
    (thread_hexes p);
  (match Publication.threads p with
  | [ _; w; _ ] ->
      equal int ~msg:"the thread lands on the matched line" 11
        w.Publication.Anchored.matched_line;
      equal (option int) ~msg:"end_line clamps at the matched line's hunk"
        (Some 12) w.Publication.Anchored.end_line
  | threads -> failf "expected three threads, got %d" (List.length threads));
  equal (list string)
    ~msg:"unmatched and non-blocking findings become summary rows"
    [ "Hallucinated"; "Foreign path"; "Substring"; "Mild" ]
    (row_titles p)

let ambiguous_anchor_uses_the_claimed_line () =
  let diff =
    diff_of
      (String.concat "\n"
         [
           "diff --git a/dup.ml b/dup.ml";
           "--- a/dup.ml";
           "+++ b/dup.ml";
           "@@ -1,3 +1,5 @@";
           " alpha";
           "+done";
           " beta";
           "+done";
           " gamma";
           "";
         ])
  in
  let at line = finding ~severity:Severity.P0 ~path:"dup.ml" ~line ~anchor:"done" ~title:"Dup" () in
  let threads_for f =
    List.map
      (fun (a : Publication.Anchored.t) -> a.Publication.Anchored.matched_line)
      (Publication.threads (publish diff ~findings:[ f ]))
  in
  equal (list int) ~msg:"an exact claimed line wins its occurrence" [ 2 ]
    (threads_for (at 2));
  equal (list int) ~msg:"the nearest occurrence wins a wrong claimed line"
    [ 4 ]
    (threads_for (at 5));
  equal (list int) ~msg:"a distant claimed line still finds the nearest" [ 4 ]
    (threads_for (at 100));
  equal (list int) ~msg:"an equidistant tie is honestly unanchored" []
    (threads_for (at 3))

let end_line_clamps_to_the_hunk () =
  let diff = diff_of multi_file_diff in
  let kept =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:1 ~end_line:3
      ~anchor:"let a = 1" ~title:"Kept" ()
  in
  let clamped =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:2 ~end_line:99
      ~anchor:"let b = 3" ~title:"Clamped" ()
  in
  let collapsed =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:4 ~end_line:11
      ~anchor:"let d = 5" ~title:"Collapsed" ()
  in
  let p = publish diff ~findings:[ kept; clamped; collapsed ] in
  match Publication.threads p with
  | [ a; b; c ] ->
      equal (option int) ~msg:"a range inside the hunk is kept" (Some 3)
        a.Publication.Anchored.end_line;
      equal (option int) ~msg:"a range past the hunk clamps to its end"
        (Some 4) b.Publication.Anchored.end_line;
      equal (option int)
        ~msg:"a clamp does not cross into the next hunk and collapses" None
        c.Publication.Anchored.end_line
  | threads -> failf "expected three threads, got %d" (List.length threads)

(* Policy. *)

let policy_badges_and_blocks () =
  let p0 =
    finding ~severity:Severity.P0 ~path:"a" ~line:1 ~anchor:"x" ~title:"t" ()
  in
  let p2 =
    finding ~severity:Severity.P2 ~path:"a" ~line:1 ~anchor:"x" ~title:"t" ()
  in
  let p3 =
    finding ~severity:Severity.P3 ~path:"a" ~line:1 ~anchor:"x" ~title:"t" ()
  in
  let default = Publication.Policy.default in
  is_true ~msg:"any blocking finding is red"
    (Publication.Policy.badge default [ p0; p2 ] = Publication.Policy.Red);
  is_true ~msg:"only non-blocking findings are yellow"
    (Publication.Policy.badge default [ p2; p3 ] = Publication.Policy.Yellow);
  is_true ~msg:"no findings is green"
    (Publication.Policy.badge default [] = Publication.Policy.Green);
  is_true ~msg:"default blocks P0 and P1"
    (Publication.Policy.blocks default Severity.P0
    && Publication.Policy.blocks default Severity.P1);
  is_false ~msg:"default does not block P2 or P3"
    (Publication.Policy.blocks default Severity.P2
    || Publication.Policy.blocks default Severity.P3);
  let strict = { Publication.Policy.block_on = [ Severity.P2 ] } in
  is_true ~msg:"a custom policy reddens its own severities"
    (Publication.Policy.badge strict [ p2 ] = Publication.Policy.Red);
  is_true ~msg:"a custom policy yellows what it does not block"
    (Publication.Policy.badge strict [ p0 ] = Publication.Policy.Yellow)

(* Convergence. *)

let convergence_skips_posted_fingerprints () =
  let diff = diff_of multi_file_diff in
  let first =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:2 ~anchor:"let b = 3"
      ~title:"First" ()
  in
  let second =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:3 ~anchor:"let c = 4"
      ~title:"Second" ()
  in
  let posted =
    posted_of
      (Printf.sprintf {|[{"id": 11, "body": "**P0** First\n\n%s"}]|}
         (Publication.Marker.finding ~origin:"ci" (fingerprint first)))
  in
  let p = publish diff ~posted ~findings:[ first; second ] in
  equal (list string) ~msg:"only the unposted finding threads" [ hex second ]
    (thread_hexes p);
  equal (list string) ~msg:"a posted finding is not a summary row either" []
    (row_titles p);
  (match Publication.requests p with
  | { Publication.threads = [ thread ]; summary } ->
      is_true ~msg:"the thread posts"
        (thread.Publication.Request.method_ = `POST);
      is_true ~msg:"the summary posts fresh"
        (summary.Publication.Request.method_ = `POST)
  | { Publication.threads; _ } ->
      failf "expected one thread request, got %d" (List.length threads));
  is_true ~msg:"the summary still counts every finding"
    (str_contains "2 findings · 1 thread posted" (summary_body_of p))

let duplicate_findings_post_one_thread () =
  let diff = diff_of multi_file_diff in
  let one =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:2 ~anchor:"let b = 3"
      ~title:"Dup" ~body:"first wording" ()
  in
  let again =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:2 ~anchor:"let b = 3"
      ~title:"Dup" ~body:"second wording" ()
  in
  let p = publish diff ~findings:[ one; again ] in
  equal (list string) ~msg:"one thread per fingerprint" [ hex one ]
    (thread_hexes p);
  equal (list string) ~msg:"the duplicate is not a summary row either" []
    (row_titles p)

let threads_safe_two_way_rule () =
  let diff = diff_of multi_file_diff in
  let blocking_unmatched =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:1 ~anchor:"nowhere"
      ~title:"Blocking" ()
  in
  let blocking_matched =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:3 ~anchor:"let c = 4"
      ~title:"Matched" ()
  in
  let mild =
    finding ~severity:Severity.P2 ~path:"lib/a.ml" ~line:1 ~anchor:"nowhere"
      ~title:"Mild" ()
  in
  is_true ~msg:"no blocking findings is safe"
    (Publication.threads_safe (publish diff ~findings:[ mild ]));
  is_false ~msg:"blocking findings that match nowhere are unsafe"
    (Publication.threads_safe
       (publish diff ~findings:[ blocking_unmatched; mild ]));
  is_true ~msg:"a thread posted this run keeps the run safe"
    (Publication.threads_safe
       (publish diff ~findings:[ blocking_unmatched; blocking_matched ]));
  let posted =
    posted_of
      (Printf.sprintf {|[{"id": 9, "body": "%s"}]|}
         (Publication.Marker.finding ~origin:"ci"
            (fingerprint blocking_unmatched)))
  in
  is_true ~msg:"a posted blocking fingerprint keeps a converged run safe"
    (Publication.threads_safe
       (publish diff ~posted ~findings:[ blocking_unmatched ]))

(* Markers and posted state. *)

let marker_grammar_round_trips () =
  let f =
    finding ~severity:Severity.P1 ~path:"a.ml" ~line:1 ~anchor:"x" ~title:"T"
      ()
  in
  let fp = fingerprint f in
  equal string ~msg:"finding marker shape"
    (Printf.sprintf "<!-- mentat-finding:%s origin=actions -->" (hex f))
    (Publication.Marker.finding ~origin:"actions" fp);
  equal string ~msg:"summary marker shape"
    "<!-- mentat-review origin=ci -->"
    (Publication.Marker.summary ~origin:"ci");
  let posted_body body =
    posted_of (Printf.sprintf {|[{"id": 3, "body": %S}]|} body)
  in
  is_true ~msg:"an origin-bearing marker is recognized"
    (Publication.Posted.mem
       (posted_body
          ("before "
          ^ Publication.Marker.finding ~origin:"actions" fp
          ^ " after"))
       fp);
  is_true ~msg:"the bare legacy marker is still recognized"
    (Publication.Posted.mem
       (posted_body ("<!-- mentat-finding:" ^ hex f ^ " -->"))
       fp);
  is_false ~msg:"uppercase hex is not a marker"
    (Publication.Posted.mem
       (posted_body
          ("<!-- mentat-finding:" ^ String.uppercase_ascii (hex f) ^ " -->"))
       fp);
  is_false ~msg:"a truncated fingerprint is not a marker"
    (Publication.Posted.mem
       (posted_body ("<!-- mentat-finding:" ^ String.sub (hex f) 0 15 ^ " -->"))
       fp);
  is_false ~msg:"a marker needs a space before more tokens or the closer"
    (Publication.Posted.mem
       (posted_body ("<!-- mentat-finding:" ^ hex f ^ "-->"))
       fp);
  is_false ~msg:"a marker needs its closer"
    (Publication.Posted.mem
       (posted_body ("<!-- mentat-finding:" ^ hex f ^ " origin=ci"))
       fp);
  equal (option int)
    ~msg:"the origin-bearing summary marker yields the comment id" (Some 7)
    (Publication.Posted.summary_id
       (posted_of
          (Printf.sprintf {|[{"id": 3, "body": "b"}, {"id": 7, "body": "%s"}]|}
             (Publication.Marker.summary ~origin:"actions"))));
  equal (option int) ~msg:"the bare legacy summary marker still matches"
    (Some 3)
    (Publication.Posted.summary_id (posted_body "old <!-- mentat-review -->"));
  equal (option int) ~msg:"no summary marker, no id" None
    (Publication.Posted.summary_id (posted_body "just text"))

let posted_rejects ~msg ?expect payload =
  match Publication.Posted.decode payload with
  | Ok _ -> failf "%s: decode accepted the payload" msg
  | Error e -> (
      let message = Publication.Error.message e in
      match expect with
      | None -> ()
      | Some needle ->
          if not (str_contains needle message) then
            failf "%s: message %S does not name %S" msg message needle)

let posted_decode_is_strict () =
  posted_rejects ~msg:"non-array" ~expect:"must be a JSON array" "{}";
  posted_rejects ~msg:"non-object element" ~expect:"posted[0]: must be an object"
    "[3]";
  posted_rejects ~msg:"missing id" ~expect:{|posted[0]: missing member "id"|}
    {|[{"body": "b"}]|};
  posted_rejects ~msg:"missing body"
    ~expect:{|posted[0]: missing member "body"|} {|[{"id": 3}]|};
  posted_rejects ~msg:"fractional id" ~expect:"posted[0].id"
    {|[{"id": 3.5, "body": "b"}]|};
  posted_rejects ~msg:"string id" ~expect:"posted[0].id"
    {|[{"id": "3", "body": "b"}]|};
  posted_rejects ~msg:"non-string body" ~expect:"posted[0].body"
    {|[{"id": 3, "body": 4}]|};
  posted_rejects ~msg:"the error names the later comment" ~expect:"posted[1]"
    {|[{"id": 3, "body": "b"}, {"id": 4}]|};
  match
    Publication.Posted.decode
      {|[{"id": 3, "body": "b", "user": {"login": "bot"}}]|}
  with
  | Ok _ -> ()
  | Error e ->
      failf "unknown members must be tolerated: %s"
        (Publication.Error.message e)

(* Summary rendering. *)

let summary_renders_the_worked_example () =
  let diff = diff_of multi_file_diff in
  let threaded =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:2 ~anchor:"let b = 3"
      ~title:"Broken invariant" ~body:"Explanation." ()
  in
  let unanchored =
    finding ~severity:Severity.P1 ~path:"lib/z.ml" ~line:9 ~anchor:"missing"
      ~title:"Missing check" ()
  in
  let mild =
    finding ~severity:Severity.P2 ~path:"lib/a.ml" ~line:1 ~anchor:"let a = 1"
      ~title:"Naming nit" ()
  in
  let p = publish diff ~findings:[ threaded; unanchored; mild ] in
  is_true ~msg:"the badge is red" (Publication.badge p = Publication.Policy.Red);
  let expected =
    String.concat "\n"
      [
        "### 🔴 Mentat review — 2 blocking findings";
        "";
        "Reviewed `0123456` against `main` · 3 findings · 1 thread posted";
        "";
        "| Severity | Finding | Location |";
        "| --- | --- | --- |";
        "| 🟠 P1 | `Missing check` | \
         [lib/z.ml:9](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/lib/z.ml#L9) \
         |";
        "| 🟡 P2 | `Naming nit` | \
         [lib/a.ml:1](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/lib/a.ml#L1) \
         |";
        "";
        "<sub>mentat · <!-- mentat-review origin=ci --></sub>";
      ]
  in
  equal string ~msg:"summary body" expected (summary_body_of p)

let summary_renders_zero_findings () =
  let p = publish (diff_of multi_file_diff) in
  is_true ~msg:"the badge is green"
    (Publication.badge p = Publication.Policy.Green);
  let expected =
    String.concat "\n"
      [
        "### 🟢 Mentat review — no findings";
        "";
        "Reviewed `0123456` against `main` · 0 findings · 0 threads posted";
        "";
        "<sub>mentat · <!-- mentat-review origin=ci --></sub>";
      ]
  in
  equal string ~msg:"summary body" expected (summary_body_of p);
  match Publication.requests p with
  | { Publication.threads = []; summary } ->
      is_true ~msg:"the summary posts fresh"
        (summary.Publication.Request.method_ = `POST);
      equal string ~msg:"summary path" "/repos/acme/widget/issues/5/comments"
        summary.Publication.Request.path
  | { Publication.threads; _ } ->
      failf "expected no thread requests, got %d" (List.length threads)

let summary_patches_when_already_posted () =
  let posted =
    posted_of
      (Printf.sprintf {|[{"id": 77, "body": "old summary %s"}]|}
         (Publication.Marker.summary ~origin:"ci"))
  in
  let p = publish (diff_of multi_file_diff) ~posted in
  match Publication.requests p with
  | { Publication.threads = []; summary } ->
      is_true ~msg:"the summary patches in place"
        (summary.Publication.Request.method_ = `PATCH);
      equal string ~msg:"summary path"
        "/repos/acme/widget/issues/comments/77"
        summary.Publication.Request.path
  | { Publication.threads; _ } ->
      failf "expected no thread requests, got %d" (List.length threads)

let overflow_demotes_beyond_the_cap () =
  let body_lines = List.init 22 (fun i -> Printf.sprintf " line %d" (i + 1)) in
  let diff =
    diff_of
      (String.concat "\n"
         ([
            "diff --git a/big.ml b/big.ml";
            "--- a/big.ml";
            "+++ b/big.ml";
            "@@ -1,22 +1,22 @@";
          ]
         @ body_lines @ [ "" ]))
  in
  let findings =
    List.init 22 (fun i ->
        finding ~severity:Severity.P0 ~path:"big.ml" ~line:(i + 1)
          ~anchor:(Printf.sprintf "line %d" (i + 1))
          ~title:(Printf.sprintf "Finding %02d" (i + 1))
          ())
  in
  let p = publish diff ~findings in
  equal int ~msg:"twenty threads post" 20 (List.length (Publication.threads p));
  equal int ~msg:"two findings demote" 2 (Publication.overflow p);
  equal (list string) ~msg:"the demoted findings are the last in order"
    [ "Finding 21"; "Finding 22" ] (row_titles p);
  equal int ~msg:"twenty thread requests" 20
    (List.length (Publication.requests p).Publication.threads);
  is_true ~msg:"the note counts the demoted"
    (str_contains "2 further findings not threaded this run"
       (summary_body_of p))

(* Requests. *)

let requests_take_the_worked_shapes () =
  let diff = diff_of multi_file_diff in
  let ranged =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:2 ~end_line:3
      ~anchor:"let b = 3" ~title:"Broken invariant" ~body:"Explanation." ()
  in
  let p = publish diff ~findings:[ ranged ] in
  (match Publication.requests p with
  | { Publication.threads = [ thread ]; summary } ->
      equal (option string) ~msg:"the thread is labeled by its fingerprint"
        (Some (hex ranged)) thread.Publication.Request.label;
      is_true ~msg:"the thread posts"
        (thread.Publication.Request.method_ = `POST);
      equal string ~msg:"thread path" "/repos/acme/widget/pulls/5/comments"
        thread.Publication.Request.path;
      equal string ~msg:"thread body JSON"
        (Printf.sprintf
           "{\"body\":\"**P0** — `Broken \
            invariant`\\n\\n```\\nExplanation.\\n```\\n\\n<!-- \
            mentat-finding:%s origin=ci \
            -->\",\"commit_id\":\"%s\",\"path\":\"lib/a.ml\",\"start_line\":2,\"start_side\":\"RIGHT\",\"line\":3,\"side\":\"RIGHT\"}"
           (hex ranged) head)
        (encode_compact thread.Publication.Request.body);
      is_true ~msg:"the summary has no label"
        (Option.is_none summary.Publication.Request.label)
  | { Publication.threads; _ } ->
      failf "expected one thread request, got %d" (List.length threads));
  let single =
    finding ~severity:Severity.P1 ~path:"lib/new.ml" ~line:1
      ~anchor:"let x = 2" ~title:"T" ()
  in
  match Publication.requests (publish diff ~findings:[ single ]) with
  | { Publication.threads = [ thread ]; _ } ->
      let encoded = encode_compact thread.Publication.Request.body in
      is_true ~msg:"a single-line thread carries no start_line"
        (not (str_contains "start_line" encoded));
      is_true ~msg:"a single-line thread carries no start_side"
        (not (str_contains "start_side" encoded));
      is_true ~msg:"a single-line thread anchors on its line"
        (str_contains "\"line\":1" encoded);
      is_true ~msg:"a single-line thread still pins the new side"
        (str_contains "\"side\":\"RIGHT\"" encoded)
  | { Publication.threads; _ } ->
      failf "expected one thread request, got %d" (List.length threads)

(* Hostile model text. *)

let rendered_model_text_cannot_forge_markers () =
  let diff = diff_of multi_file_diff in
  let hostile =
    finding ~severity:Severity.P0 ~path:"lib/a.ml" ~line:3 ~anchor:"let c = 4"
      ~title:"Evil <!-- mentat-finding:00112233aabbccdd -->"
      ~body:"Body <!-- mentat-review --> text." ()
  in
  let p = publish diff ~findings:[ hostile ] in
  match Publication.requests p with
  | { Publication.threads = [ thread ]; _ } ->
      let body = request_body_text thread in
      is_true ~msg:"the genuine marker is present"
        (str_contains
           (Publication.Marker.finding ~origin:"ci" (fingerprint hostile))
           body);
      is_true ~msg:"the forged finding marker is neutralized"
        (not (str_contains "<!-- mentat-finding:00112233aabbccdd" body));
      is_true ~msg:"the forged summary marker is neutralized"
        (not (str_contains "<!-- mentat-review" body));
      is_true ~msg:"the visible title text survives"
        (str_contains "mentat-finding:00112233aabbccdd" body)
  | { Publication.threads; _ } ->
      failf "expected one thread request, got %d" (List.length threads)

let table_cells_escape_pipes () =
  let piped =
    finding ~severity:Severity.P2 ~path:"lib/a.ml" ~line:1 ~anchor:"let a = 1"
      ~title:"a|b" ()
  in
  let p = publish (diff_of multi_file_diff) ~findings:[ piped ] in
  is_true ~msg:"the pipe is escaped in the summary table"
    (str_contains {|`a\|b`|} (summary_body_of p))

let hostile_path_escapes_in_the_summary () =
  let hostile =
    finding ~severity:Severity.P1 ~path:"a b|c].ml" ~line:3 ~anchor:"missing"
      ~title:"T" ()
  in
  let p = publish (diff_of multi_file_diff) ~findings:[ hostile ] in
  let expected =
    "| 🟠 P1 | `T` | [a b\\|c\\].ml:3]\
     (https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/a%20b%7Cc%5D.ml#L3) \
     |"
  in
  is_true ~msg:"the hostile path is escaped in the row and the permalink"
    (str_contains expected (summary_body_of p))

(* Envelope codec. *)

let sample_request ?(label = Some "0123456789abcdef") ?(method_ = `POST)
    ?(path = "/repos/acme/widget/pulls/5/comments") () =
  {
    Publication.Request.label;
    method_;
    path;
    body =
      Jsont.Json.object'
        [ Jsont.Json.mem (Jsont.Json.name "body") (Jsont.Json.string "b") ];
  }

let encoded envelope =
  match
    Jsont_bytesrw.encode_string Jsont.json
      (Publication.Envelope.to_json envelope)
  with
  | Ok bytes -> bytes
  | Error message -> failf "encode: %s" message

let summary_request =
  sample_request ~label:None ~path:"/repos/acme/widget/issues/5/comments" ()

let envelope_round_trips () =
  let envelope =
    {
      Publication.Envelope.threads =
        [
          sample_request ();
          sample_request ~label:None ~method_:`PATCH
            ~path:"/repos/acme/widget/issues/comments/9" ();
        ];
      summary = summary_request;
      threads_safe = true;
    }
  in
  let bytes = encoded envelope in
  is_true ~msg:"the envelope carries its type"
    (str_contains {|"schema_version":1,"type":"github.review"|} bytes);
  match Publication.Envelope.decode bytes with
  | Error e -> failf "decode: %s" (Publication.Error.message e)
  | Ok read ->
      equal int ~msg:"threads survive" 2
        (List.length read.Publication.Envelope.threads);
      is_true ~msg:"threads_safe survives"
        read.Publication.Envelope.threads_safe;
      equal (option string) ~msg:"labels survive" (Some "0123456789abcdef")
        (List.hd read.Publication.Envelope.threads).Publication.Request.label;
      equal string ~msg:"summary path survives"
        "/repos/acme/widget/issues/5/comments"
        read.Publication.Envelope.summary.Publication.Request.path

let envelope_refuses_hostile_paths () =
  let refuses ~msg ?expect path =
    let envelope =
      {
        Publication.Envelope.threads = [ sample_request ~path () ];
        summary = summary_request;
        threads_safe = true;
      }
    in
    match Publication.Envelope.decode (encoded envelope) with
    | Ok _ -> failf "%s: decode accepted path %s" msg path
    | Error e -> (
        let message = Publication.Error.message e in
        match expect with
        | None -> ()
        | Some needle ->
            if not (str_contains needle message) then
              failf "%s: message %S does not name %S" msg message needle)
  in
  refuses ~msg:"dot-segment traversal" ~expect:"envelope.review[0].path"
    "/repos/acme/widget/../../../orgs/evil/x";
  refuses ~msg:"a lone dot segment" "/repos/acme/./widget";
  refuses ~msg:"an empty segment" "/repos//widget";
  refuses ~msg:"a trailing slash" "/repos/acme/widget/";
  refuses ~msg:"a query cut" "/repos/acme/widget/pulls?per_page=1";
  refuses ~msg:"a fragment cut" "/repos/acme/widget#f";
  refuses ~msg:"a control byte" "/repos/acme/widget/\x1b[2Jpulls";
  refuses ~msg:"a relative path" "repos/acme/widget";
  match
    Publication.Request.of_json ~context:"r"
      (Publication.Request.to_json (sample_request ()))
  with
  | Ok read ->
      equal string ~msg:"a conforming path survives"
        "/repos/acme/widget/pulls/5/comments" read.Publication.Request.path
  | Error e -> failf "of_json: %s" (Publication.Error.message e)

(* Suite. *)

(* The poster's outcome line: the emitted wire shape and the folds a reaper
   reads it back with, one custody. *)
let outcome_lines_and_folds () =
  let encode outcome =
    match
      Jsont_bytesrw.encode_string Jsont.json
        (Publication.Outcome.to_json outcome)
    with
    | Ok line -> line
    | Error reason -> failf "outcome failed to encode: %s" reason
  in
  equal string ~msg:"a labeled 2xx line"
    {|{"schema_version":1,"type":"github.publish","label":"aa11","status":201}|}
    (encode { Publication.Outcome.label = Some "aa11"; status = 201; error = None });
  equal string ~msg:"a refused summary line carries its excerpt"
    {|{"schema_version":1,"type":"github.publish","label":null,"status":422,"error":"refused"}|}
    (encode
       { Publication.Outcome.label = None; status = 422; error = Some "refused" });
  let log =
    String.concat "\n"
      [
        encode { Publication.Outcome.label = Some "aa11"; status = 201; error = None };
        encode
          {
            Publication.Outcome.label = Some "bb22";
            status = 422;
            error = Some "refused";
          };
        encode { Publication.Outcome.label = None; status = 200; error = None };
        "not an outcome line";
      ]
  in
  equal int ~msg:"one thread answered 2xx" 1
    (Publication.Outcome.threads_posted log);
  is_true ~msg:"the summary landed" (Publication.Outcome.summary_ok log);
  is_false ~msg:"a refused summary is not ok"
    (Publication.Outcome.summary_ok
       (encode { Publication.Outcome.label = None; status = 502; error = None }));
  equal int ~msg:"an empty log posted nothing" 0
    (Publication.Outcome.threads_posted "")

let marker_predicates () =
  let fp =
    Review_finding.Fingerprint.of_finding ~path:"a.ml" ~anchor:"x" ~title:"t"
  in
  is_true ~msg:"a finding marker marks"
    (Publication.Marker.marks
       ("before " ^ Publication.Marker.finding ~origin:"ci" fp ^ " after"));
  is_true ~msg:"a summary marker marks"
    (Publication.Marker.marks (Publication.Marker.summary ~origin:"charter:x"));
  is_false ~msg:"plain prose does not mark"
    (Publication.Marker.marks "an ordinary comment, <!-- but not ours -->");
  equal string ~msg:"origin folding lowercases and dashes foreign bytes"
    "my-review--v2" (Publication.Marker.origin_of_name "My_Review!.v2");
  equal string ~msg:"a folded name composes into a valid origin"
    "<!-- mentat-review origin=charter:pr-review -->"
    (Publication.Marker.summary
       ~origin:("charter:" ^ Publication.Marker.origin_of_name "PR-Review"))

let () =
  run "mentat.publication"
    [
      test "the diff parser maps commentable lines and their text"
        diff_parses_files;
      test "the diff parser reads no-newline markers"
        diff_reads_no_newline_markers;
      test "the diff parser rejects malformed and truncated hunks"
        diff_is_strict;
      test "the diff parser strips the tab after a spaced path"
        diff_strips_the_tab_after_a_spaced_path;
      test "anchoring matches the quote, claimed line as tiebreak"
        anchoring_matches_the_quote;
      test "an ambiguous anchor disambiguates by the claimed line"
        ambiguous_anchor_uses_the_claimed_line;
      test "end_line clamps to the anchoring hunk" end_line_clamps_to_the_hunk;
      test "policies derive badges and blocking" policy_badges_and_blocks;
      test "convergence posts only unposted fingerprints"
        convergence_skips_posted_fingerprints;
      test "duplicate findings in one document post one thread"
        duplicate_findings_post_one_thread;
      test "threads_safe follows the two-way rule" threads_safe_two_way_rule;
      test "the marker grammar round-trips through posted state"
        marker_grammar_round_trips;
      test "posted decode rejects departures and tolerates extras"
        posted_decode_is_strict;
      test "the summary renders the worked example"
        summary_renders_the_worked_example;
      test "the summary renders zero findings" summary_renders_zero_findings;
      test "the summary patches the posted comment"
        summary_patches_when_already_posted;
      test "the thread cap demotes overflow to summary rows"
        overflow_demotes_beyond_the_cap;
      test "requests take the worked shapes" requests_take_the_worked_shapes;
      test "rendered model text cannot forge markers"
        rendered_model_text_cannot_forge_markers;
      test "table cells escape pipes" table_cells_escape_pipes;
      test "a hostile path escapes in the summary row and permalink"
        hostile_path_escapes_in_the_summary;
      test "the review envelope round-trips through its codec"
        envelope_round_trips;
      test "envelope decode refuses paths that could escape the repository"
        envelope_refuses_hostile_paths;
      test "outcome lines emit and fold with one custody"
        outcome_lines_and_folds;
      test "marker predicates recognize and fold origins" marker_predicates;
    ]
