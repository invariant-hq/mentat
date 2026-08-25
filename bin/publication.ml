(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = struct
  type t = { context : string; reason : string }

  let make ~context reason = { context; reason }

  let message e =
    if String.equal e.context "" then e.reason
    else Printf.sprintf "%s: %s" e.context e.reason

  let pp ppf e = Format.pp_print_string ppf (message e)
end

module Diff = struct
  (* Per new-side file: the hunks as inclusive new-side intervals, in diff
     order, and the text of every commentable line. Context and added lines
     together cover a hunk's whole new-side interval, so each interval is
     contiguous and the intervals are disjoint. *)
  module File = struct
    type t = { hunks : (int * int) list; lines : (int * string) list }
  end

  type t = (string * File.t) list

  exception Malformed of Error.t

  let fail ~line_number reason =
    raise
      (Malformed
         (Error.make
            ~context:(Printf.sprintf "diff line %d" line_number)
            reason))

  (* "@@ -a[,b] +c[,d] @@[ section]"; counts default to 1. Yields the old
     count, the new-side start, and the new count. *)
  let hunk_header ~line_number line =
    let n = String.length line in
    let pos = ref 0 in
    let expect prefix =
      let m = String.length prefix in
      if !pos + m <= n && String.equal (String.sub line !pos m) prefix then
        pos := !pos + m
      else fail ~line_number "malformed hunk header"
    in
    let integer () =
      let start = !pos in
      while !pos < n && line.[!pos] >= '0' && line.[!pos] <= '9' do
        incr pos
      done;
      match int_of_string_opt (String.sub line start (!pos - start)) with
      | Some value -> value
      | None -> fail ~line_number "malformed hunk header"
    in
    let count () =
      if !pos < n && Char.equal line.[!pos] ',' then (
        incr pos;
        integer ())
      else 1
    in
    expect "@@ -";
    let _old_start = integer () in
    let old_count = count () in
    expect " +";
    let new_start = integer () in
    let new_count = count () in
    expect " @@";
    if !pos < n && not (Char.equal line.[!pos] ' ') then
      fail ~line_number "malformed hunk header";
    (old_count, new_start, new_count)

  let of_unified text =
    let lines =
      match List.rev (String.split_on_char '\n' text) with
      | "" :: rest -> List.rev rest
      | all -> List.rev all
    in
    let files = ref [] in
    let in_file = ref false in
    let path = ref None in
    let hunks = ref [] in
    let texts = ref [] in
    (* An open hunk: old and new lines left to consume, the next new-side
       line, and the hunk's first new-side line. *)
    let hunk = ref None in
    let flush_file () =
      (match !path with
      | Some p ->
          files :=
            (p, { File.hunks = List.rev !hunks; lines = List.rev !texts })
            :: !files
      | None -> ());
      path := None;
      hunks := [];
      texts := []
    in
    let read ~line_number line =
      match !hunk with
      | Some (old_left, new_left, cursor, start) ->
          let record text =
            if Option.is_some !path then texts := (cursor, text) :: !texts
          in
          let rest () = String.sub line 1 (String.length line - 1) in
          let step ~old_used ~new_used =
            let old_left = old_left - old_used
            and new_left = new_left - new_used in
            if old_left < 0 || new_left < 0 then
              fail ~line_number "hunk lines exceed the header's counts";
            let cursor = cursor + new_used in
            if old_left = 0 && new_left = 0 then (
              if cursor > start then hunks := (start, cursor - 1) :: !hunks;
              hunk := None)
            else hunk := Some (old_left, new_left, cursor, start)
          in
          if String.equal line "" then (
            record "";
            step ~old_used:1 ~new_used:1)
          else (
            match line.[0] with
            | ' ' ->
                record (rest ());
                step ~old_used:1 ~new_used:1
            | '+' ->
                record (rest ());
                step ~old_used:0 ~new_used:1
            | '-' -> step ~old_used:1 ~new_used:0
            | '\\' -> ()
            | _ ->
                fail ~line_number
                  "expected a context, +, -, or \\ line in the hunk")
      | None ->
          if String.starts_with ~prefix:"diff --git " line then (
            flush_file ();
            in_file := true)
          else if String.starts_with ~prefix:"@@" line then (
            if not !in_file then
              fail ~line_number "hunk before any file header";
            let old_count, new_start, new_count =
              hunk_header ~line_number line
            in
            if old_count > 0 || new_count > 0 then
              hunk := Some (old_count, new_count, new_start, new_start))
          else if String.starts_with ~prefix:"+++ " line then (
            if not !in_file then
              fail ~line_number "file body before any file header";
            let target = String.sub line 4 (String.length line - 4) in
            (* Git suffixes a literal tab to a target name containing a
               space. *)
            let target =
              let n = String.length target in
              if n > 0 && Char.equal target.[n - 1] '\t' then
                String.sub target 0 (n - 1)
              else target
            in
            if String.starts_with ~prefix:"b/" target then
              path := Some (String.sub target 2 (String.length target - 2))
            else path := None)
          else if not !in_file then
            fail ~line_number "expected a diff file header"
    in
    try
      List.iteri (fun index line -> read ~line_number:(index + 1) line) lines;
      (match !hunk with
      | Some _ ->
          fail ~line_number:(List.length lines) "diff ends inside a hunk"
      | None -> ());
      flush_file ();
      Ok (List.rev !files)
    with Malformed e -> Error e

  let file t ~path = List.assoc_opt path t

  let line_text t ~path ~line =
    match file t ~path with
    | None -> None
    | Some file -> List.assoc_opt line file.File.lines

  let commentable_lines t ~path =
    match file t ~path with
    | None -> []
    | Some file -> List.sort Int.compare (List.map fst file.File.lines)

  (* The hunk interval holding [line]; [Some] for every commentable line. *)
  let hunk_interval t ~path ~line =
    match file t ~path with
    | None -> None
    | Some file ->
        List.find_opt (fun (s, e) -> s <= line && line <= e) file.File.hunks
end

module Anchored = struct
  type t = {
    finding : Review_finding.t;
    fingerprint : Review_finding.Fingerprint.t;
    matched_line : int;
    end_line : int option;
  }
end

module Unanchored = struct
  type t = { finding : Review_finding.t; permalink : string }
end

module Policy = struct
  type badge = Red | Yellow | Green
  type t = { block_on : Review_finding.Severity.t list }

  let default =
    { block_on = [ Review_finding.Severity.P0; Review_finding.Severity.P1 ] }

  let blocks t severity =
    List.exists
      (fun s -> Review_finding.Severity.compare s severity = 0)
      t.block_on

  let badge t findings =
    if
      List.exists
        (fun (f : Review_finding.t) -> blocks t f.Review_finding.severity)
        findings
    then Red
    else if not (List.is_empty findings) then Yellow
    else Green
end

module Marker = struct
  let valid_origin origin =
    String.length origin > 0
    && String.for_all
         (fun c ->
           (c >= 'a' && c <= 'z')
           || (c >= '0' && c <= '9')
           || Char.equal c '-' || Char.equal c ':')
         origin

  let check_origin origin =
    if not (valid_origin origin) then
      invalid_arg (Printf.sprintf "invalid marker origin %S" origin)

  let summary ~origin =
    check_origin origin;
    Printf.sprintf "<!-- mentat-review origin=%s -->" origin

  let finding ~origin fingerprint =
    check_origin origin;
    Printf.sprintf "<!-- mentat-finding:%s origin=%s -->"
      (Review_finding.Fingerprint.to_hex fingerprint)
      origin
end

module Posted = struct
  type t = { fingerprints : string list; summary_id : int option }

  let finding_opener = "<!-- mentat-finding:"
  let summary_opener = "<!-- mentat-review"
  let closer = "-->"
  let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

  (* A marker tail starting at [i]: a space, then only origin-token bytes
     (and further spaces) up to the closer. Both the bare grammar ([" -->"])
     and the origin-bearing grammar ([" origin=... -->"]) satisfy it; a
     missing closer or a foreign byte is not a marker. [Some j] is the
     position just past the closer. *)
  let marker_tail body i =
    let n = String.length body in
    let tail_char c =
      (c >= 'a' && c <= 'z')
      || (c >= '0' && c <= '9')
      || Char.equal c '-' || Char.equal c ':' || Char.equal c '='
      || Char.equal c ' '
    in
    if i >= n || not (Char.equal body.[i] ' ') then None
    else
      let m = String.length closer in
      let rec find j =
        if j + m > n then None
        else if String.equal (String.sub body j m) closer then Some (j + m)
        else if tail_char body.[j] then find (j + 1)
        else None
      in
      find (i + 1)

  (* Occurrences of the finding-marker grammar: the opener, sixteen lowercase
     hexadecimal characters, and a marker tail. Anything else — wrong length,
     wrong case, a missing closer — is not a marker. *)
  let body_fingerprints body =
    let n = String.length body in
    let opener = String.length finding_opener in
    let rec scan acc i =
      if i + opener + 16 > n then List.rev acc
      else if not (String.equal (String.sub body i opener) finding_opener)
      then scan acc (i + 1)
      else
        let hex = String.sub body (i + opener) 16 in
        match
          if String.for_all is_hex hex then marker_tail body (i + opener + 16)
          else None
        with
        | Some next -> scan (hex :: acc) next
        | None -> scan acc (i + 1)
    in
    scan [] 0

  (* Whether [body] carries a summary marker, in the bare or origin-bearing
     grammar. *)
  let has_summary_marker body =
    let n = String.length body in
    let opener = String.length summary_opener in
    let rec scan i =
      if i + opener > n then false
      else if
        String.equal (String.sub body i opener) summary_opener
        && Option.is_some (marker_tail body (i + opener))
      then true
      else scan (i + 1)
    in
    scan 0

  let ( let* ) = Result.bind
  let error ~context reason = Error (Error.make ~context reason)

  let comment ~index json =
    let context = Printf.sprintf "posted[%d]" index in
    match json with
    | Jsont.Object (mems, _) ->
        let* id =
          match Jsont.Json.find_mem "id" mems with
          | Some (_, Jsont.Number (v, _))
            when Float.is_integer v
                 && Float.compare v 1.0 >= 0
                 && Float.equal (float_of_int (int_of_float v)) v ->
              Ok (int_of_float v)
          | Some _ ->
              error ~context:(context ^ ".id") "must be a positive integer"
          | None -> error ~context {|missing member "id"|}
        in
        let* body =
          match Jsont.Json.find_mem "body" mems with
          | Some (_, Jsont.String (s, _)) -> Ok s
          | Some _ -> error ~context:(context ^ ".body") "must be a string"
          | None -> error ~context {|missing member "body"|}
        in
        Ok (id, body)
    | _ -> error ~context "must be an object"

  let decode bytes =
    match Jsont_bytesrw.decode_string Jsont.json bytes with
    | Error reason -> error ~context:"posted" reason
    | Ok (Jsont.Array (elements, _)) ->
        let* _, entries =
          List.fold_left
            (fun acc element ->
              let* index, entries = acc in
              let* entry = comment ~index element in
              Ok (index + 1, entry :: entries))
            (Ok (0, []))
            elements
        in
        let entries = List.rev entries in
        let fingerprints =
          List.concat_map (fun (_, body) -> body_fingerprints body) entries
        in
        let summary_id =
          List.find_map
            (fun (id, body) ->
              if has_summary_marker body then Some id else None)
            entries
        in
        Ok { fingerprints; summary_id }
    | Ok _ -> error ~context:"posted" "must be a JSON array"

  let mem t fingerprint =
    List.mem (Review_finding.Fingerprint.to_hex fingerprint) t.fingerprints

  let summary_id t = t.summary_id
end

module Request = struct
  type t = {
    label : string option;
    method_ : [ `POST | `PATCH ];
    path : string;
    body : Jsont.json;
  }
end

(* Model-authored text reaches a rendered comment only through [neutral], so
   no rendering of it can open or close an HTML comment and forge a marker. *)
let neutral s = Review_finding.Body.text (Review_finding.Body.of_model_text s)

let backtick_run s =
  let longest = ref 0 and current = ref 0 in
  String.iter
    (fun c ->
      if Char.equal c '`' then (
        incr current;
        if !current > !longest then longest := !current)
      else current := 0)
    s;
  !longest

(* An inline code span whose delimiter outruns every backtick run in [s], so
   [s] renders literally and cannot ping a mention. *)
let code_span s =
  let s = String.map (fun c -> if Char.equal c '\n' then ' ' else c) s in
  let ticks = String.make (backtick_run s + 1) '`' in
  let pad =
    if
      String.equal s ""
      || Char.equal s.[0] '`'
      || Char.equal s.[String.length s - 1] '`'
    then " "
    else ""
  in
  ticks ^ pad ^ s ^ pad ^ ticks

(* A fenced block whose fence outruns every backtick run in [body], so the
   body renders literally and cannot ping a mention. *)
let fenced body =
  let fence = String.make (max 3 (backtick_run body + 1)) '`' in
  String.concat "\n" [ fence; body; fence ]

(* In a GFM table a pipe ends the cell even inside a code span — the escaped
   form renders as the pipe — and a newline ends the row. *)
let table_cell s =
  let buffer = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if Char.equal c '|' then Buffer.add_string buffer "\\|"
      else if Char.equal c '\n' then Buffer.add_char buffer ' '
      else Buffer.add_char buffer c)
    s;
  Buffer.contents buffer

(* In link text an unescaped bracket ends the link, and a trailing backslash
   would escape its closing bracket. *)
let link_text s =
  let buffer = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      (match c with
      | '[' | ']' | '\\' -> Buffer.add_char buffer '\\'
      | _ -> ());
      Buffer.add_char buffer c)
    s;
  Buffer.contents buffer

(* Percent-encode a repository path for a URL, keeping [/] separators. *)
let url_path s =
  let unreserved c =
    (c >= 'A' && c <= 'Z')
    || (c >= 'a' && c <= 'z')
    || (c >= '0' && c <= '9')
    || Char.equal c '-' || Char.equal c '.' || Char.equal c '_'
    || Char.equal c '~' || Char.equal c '/'
  in
  let buffer = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if unreserved c then Buffer.add_char buffer c
      else Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents buffer

let severity_emoji = function
  | Review_finding.Severity.P0 -> "🔴"
  | Review_finding.Severity.P1 -> "🟠"
  | Review_finding.Severity.P2 -> "🟡"
  | Review_finding.Severity.P3 -> "⚪"

let permalink ~owner_repo ~head (f : Review_finding.t) =
  let range =
    match f.Review_finding.end_line with
    | Some e when e > f.Review_finding.line ->
        Printf.sprintf "#L%d-L%d" f.Review_finding.line e
    | _ -> Printf.sprintf "#L%d" f.Review_finding.line
  in
  Printf.sprintf "https://github.com/%s/blob/%s/%s%s" owner_repo head
    (url_path f.Review_finding.path)
    range

(* A finding anchors iff its trimmed anchor equals the trimmed text of a
   commentable line of its claimed path: the quote is the primary key, and the
   claimed line only disambiguates. A unique match anchors there even when the
   claimed line is wrong; among several matches the occurrence nearest the
   claimed line wins, and an exact tie is honestly unanchored. A quote found
   nowhere in the diff never anchors — the hallucination check. *)
let anchor diff (f : Review_finding.t) =
  let path = f.Review_finding.path and claimed = f.Review_finding.line in
  let quote = String.trim f.Review_finding.anchor in
  let matches =
    List.filter
      (fun line ->
        match Diff.line_text diff ~path ~line with
        | Some text -> String.equal quote (String.trim text)
        | None -> false)
      (Diff.commentable_lines diff ~path)
  in
  let matched_line =
    match matches with
    | [] -> None
    | [ line ] -> Some line
    | lines -> (
        let distance line = abs (line - claimed) in
        match
          List.sort (fun a b -> Int.compare (distance a) (distance b)) lines
        with
        | best :: next :: _ when distance best = distance next -> None
        | best :: _ -> Some best
        | [] -> None)
  in
  match matched_line with
  | None -> None
  | Some line ->
      let fingerprint =
        Review_finding.Fingerprint.of_finding ~path
          ~anchor:f.Review_finding.anchor ~title:f.Review_finding.title
      in
      let end_line =
        match
          (f.Review_finding.end_line, Diff.hunk_interval diff ~path ~line)
        with
        | None, _ | _, None -> None
        | Some e, Some (_, hunk_end) ->
            let e = min e hunk_end in
            if e > line then Some e else None
      in
      Some { Anchored.finding = f; fingerprint; matched_line = line; end_line }

(* Gravest severity first, then path, then line. *)
let order (a : Review_finding.t) (b : Review_finding.t) =
  let c =
    Review_finding.Severity.compare a.Review_finding.severity
      b.Review_finding.severity
  in
  if c <> 0 then c
  else
    let c = String.compare a.Review_finding.path b.Review_finding.path in
    if c <> 0 then c
    else Int.compare a.Review_finding.line b.Review_finding.line

type t = {
  badge : Policy.badge;
  threads : Anchored.t list;
  rows : Unanchored.t list;
  overflow : int;
  blocking : int;
  total : int;
  threads_safe : bool;
  summary_id : int option;
  owner_repo : string;
  number : int;
  head : string;
  base_label : string;
  origin : string;
}

let thread_cap = 20

let of_findings ~diff ~policy ~posted ~origin ~owner_repo ~number ~head
    ~base_label (document : Review_finding.Document.t) =
  let findings = document.Review_finding.Document.findings in
  let threadable, rows =
    List.partition_map
      (fun (f : Review_finding.t) ->
        if Policy.blocks policy f.Review_finding.severity then
          match anchor diff f with
          | Some anchored -> Either.Left anchored
          | None -> Either.Right f
        else Either.Right f)
      findings
  in
  let fresh =
    List.filter
      (fun (a : Anchored.t) ->
        not (Posted.mem posted a.Anchored.fingerprint))
      threadable
  in
  let fresh =
    List.sort
      (fun (a : Anchored.t) (b : Anchored.t) ->
        order a.Anchored.finding b.Anchored.finding)
      fresh
  in
  (* One thread per fingerprint even within one document: a repeated
     (path, anchor, title) keeps only its first occurrence in posting order. *)
  let fresh =
    let seen = Hashtbl.create 7 in
    List.filter
      (fun (a : Anchored.t) ->
        let hex = Review_finding.Fingerprint.to_hex a.Anchored.fingerprint in
        if Hashtbl.mem seen hex then false
        else (
          Hashtbl.add seen hex ();
          true))
      fresh
  in
  let threads = List.take thread_cap fresh in
  let demoted = List.drop thread_cap fresh in
  let rows =
    List.sort order
      (rows @ List.map (fun (a : Anchored.t) -> a.Anchored.finding) demoted)
  in
  let rows =
    List.map
      (fun f ->
        { Unanchored.finding = f; permalink = permalink ~owner_repo ~head f })
      rows
  in
  let blocking_findings =
    List.filter
      (fun (f : Review_finding.t) ->
        Policy.blocks policy f.Review_finding.severity)
      findings
  in
  let threads_safe =
    List.is_empty blocking_findings
    || threads <> []
    || List.exists
         (fun (f : Review_finding.t) ->
           Posted.mem posted
             (Review_finding.Fingerprint.of_finding ~path:f.Review_finding.path
                ~anchor:f.Review_finding.anchor ~title:f.Review_finding.title))
         blocking_findings
  in
  {
    badge = Policy.badge policy findings;
    threads;
    rows;
    overflow = List.length demoted;
    blocking = List.length blocking_findings;
    total = List.length findings;
    threads_safe;
    summary_id = Posted.summary_id posted;
    owner_repo;
    number;
    head;
    base_label;
    origin;
  }

let badge t = t.badge
let threads t = t.threads
let summary_rows t = t.rows
let overflow t = t.overflow
let threads_safe t = t.threads_safe
let json_mem name value = Jsont.Json.mem (Jsont.Json.name name) value

let thread_body t (a : Anchored.t) =
  let f = a.Anchored.finding in
  let header =
    Printf.sprintf "**%s** — %s"
      (Review_finding.Severity.to_string f.Review_finding.severity)
      (code_span f.Review_finding.title)
  in
  let body = Review_finding.Body.text f.Review_finding.body in
  let parts =
    if String.equal body "" then [ header ] else [ header; fenced body ]
  in
  String.concat "\n\n"
    (parts @ [ Marker.finding ~origin:t.origin a.Anchored.fingerprint ])

let thread_request t (a : Anchored.t) =
  let position =
    match a.Anchored.end_line with
    | Some e ->
        [
          json_mem "line" (Jsont.Json.int e);
          json_mem "start_line" (Jsont.Json.int a.Anchored.matched_line);
        ]
    | None -> [ json_mem "line" (Jsont.Json.int a.Anchored.matched_line) ]
  in
  {
    Request.label = Some (Review_finding.Fingerprint.to_hex a.Anchored.fingerprint);
    method_ = `POST;
    path = Printf.sprintf "/repos/%s/pulls/%d/comments" t.owner_repo t.number;
    body =
      Jsont.Json.object'
        ([
           json_mem "body" (Jsont.Json.string (thread_body t a));
           json_mem "commit_id" (Jsont.Json.string t.head);
           json_mem "path"
             (Jsont.Json.string a.Anchored.finding.Review_finding.path);
         ]
        @ position);
  }

let count n noun = Printf.sprintf "%d %s%s" n noun (if n = 1 then "" else "s")

let summary_row (u : Unanchored.t) =
  let f = u.Unanchored.finding in
  let location =
    let display =
      match f.Review_finding.end_line with
      | Some e when e > f.Review_finding.line ->
          Printf.sprintf "%s:%d-%d" f.Review_finding.path
            f.Review_finding.line e
      | _ ->
          Printf.sprintf "%s:%d" f.Review_finding.path f.Review_finding.line
    in
    Printf.sprintf "[%s](%s)" (link_text (neutral display))
      u.Unanchored.permalink
  in
  Printf.sprintf "| %s %s | %s | %s |"
    (severity_emoji f.Review_finding.severity)
    (Review_finding.Severity.to_string f.Review_finding.severity)
    (table_cell (code_span f.Review_finding.title))
    (table_cell location)

let summary_body t =
  let head7 = String.sub t.head 0 (min 7 (String.length t.head)) in
  let header =
    match t.badge with
    | Policy.Red ->
        "### 🔴 Mentat review — " ^ count t.blocking "blocking finding"
    | Policy.Yellow -> "### 🟡 Mentat review — no blocking findings"
    | Policy.Green -> "### 🟢 Mentat review — no findings"
  in
  let reviewed =
    Printf.sprintf "Reviewed `%s` against %s · %s · %s posted" head7
      (code_span (neutral t.base_label))
      (count t.total "finding")
      (count (List.length t.threads) "thread")
  in
  let table =
    if List.is_empty t.rows then []
    else
      [
        String.concat "\n"
          ("| Severity | Finding | Location |" :: "| --- | --- | --- |"
          :: List.map summary_row t.rows);
      ]
  in
  let note =
    if t.overflow = 0 then []
    else [ count t.overflow "further finding" ^ " not threaded this run" ]
  in
  let footer = "<sub>mentat · " ^ Marker.summary ~origin:t.origin ^ "</sub>" in
  String.concat "\n\n" ((header :: reviewed :: table) @ note @ [ footer ])

let summary_request t =
  let body =
    Jsont.Json.object' [ json_mem "body" (Jsont.Json.string (summary_body t)) ]
  in
  match t.summary_id with
  | Some id ->
      {
        Request.label = None;
        method_ = `PATCH;
        path = Printf.sprintf "/repos/%s/issues/comments/%d" t.owner_repo id;
        body;
      }
  | None ->
      {
        Request.label = None;
        method_ = `POST;
        path = Printf.sprintf "/repos/%s/issues/%d/comments" t.owner_repo t.number;
        body;
      }

type requests = { threads : Request.t list; summary : Request.t }

let requests t =
  {
    threads = List.map (thread_request t) (threads t);
    summary = summary_request t;
  }
