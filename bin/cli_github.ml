(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
open Mentat_connector

let docs = Cli_common.s_run
let ( let* ) = Result.bind

(* A generous cap for the caller-supplied files: a merge-base diff on a large
   pull request runs to megabytes, never to gigabytes, and the posted listing
   is bounded by the pull request's own comment count. *)
let input_cap = 64 * 1024 * 1024

(* The pull-request coordinate, parsed strictly from OWNER/REPO#N: both names
   non-empty, the repository name free of further slashes, the number a
   positive decimal. Anything else is a usage error — this command is workflow
   plumbing, and a sloppy coordinate means the workflow is wrong. *)
let parse_pr raw =
  let malformed () =
    Error
      (Exit_status.usage
         (Printf.sprintf "invalid --pr value %s: expected OWNER/REPO#N" raw))
  in
  match String.index_opt raw '#' with
  | None -> malformed ()
  | Some hash -> (
      let owner_repo = String.sub raw 0 hash in
      let number_part =
        String.sub raw (hash + 1) (String.length raw - hash - 1)
      in
      match String.index_opt owner_repo '/' with
      | None -> malformed ()
      | Some slash -> (
          let owner = String.sub owner_repo 0 slash in
          let repo =
            String.sub owner_repo (slash + 1)
              (String.length owner_repo - slash - 1)
          in
          let digits =
            String.length number_part > 0
            && String.for_all (fun c -> c >= '0' && c <= '9') number_part
          in
          if
            String.length owner = 0
            || String.length repo = 0
            || String.contains repo '/'
            || not digits
          then malformed ()
          else
            match int_of_string_opt number_part with
            | Some number when number > 0 -> Ok (owner_repo, number)
            | Some _ | None -> malformed ()))

(* The head commit must be a full object name — the workflow passes the event's
   head SHA verbatim, and permalinks built from an abbreviation would not pin
   the reviewed tree. *)
let parse_head raw =
  let hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') in
  if
    (String.length raw = 40 || String.length raw = 64)
    && String.for_all hex raw
  then Ok raw
  else
    Error
      (Exit_status.usage
         (Printf.sprintf
            "invalid --at value %s: expected a full lowercase commit SHA" raw))

let require flag = function
  | Some value -> Ok value
  | None -> Error (Exit_status.usage (Printf.sprintf "%s is required" flag))

(* The marker origin token: the same grammar [Publication.Marker] enforces,
   checked here so a bad flag value is a usage error, not a crash. *)
let parse_origin raw =
  let valid =
    String.length raw > 0
    && String.for_all
         (fun c ->
           (c >= 'a' && c <= 'z')
           || (c >= '0' && c <= '9')
           || Char.equal c '-' || Char.equal c ':')
         raw
  in
  if valid then Ok raw
  else
    Error
      (Exit_status.usage
         (Printf.sprintf
            "invalid --origin value %s: expected lowercase letters, digits, \
             '-', or ':'"
            raw))

(* An unreadable or missing input file is an environment condition (exit 1),
   like any other IO failure; only the flag grammar itself is usage. *)
let read_file ~flag path =
  match Fs.read_capped ~max_bytes:input_cap path with
  | Ok (Some bytes) -> Ok bytes
  | Ok None ->
      Error
        (Exit_status.runtime (Printf.sprintf "%s: no such file: %s" flag path))
  | Error message ->
      Error (Exit_status.runtime (Printf.sprintf "%s: %s" flag message))

(* Standard input rides the same cap discipline as the file inputs. *)
let read_stdin_capped () =
  let chunk_size = 65536 in
  let chunk = Bytes.create chunk_size in
  let buffer = Buffer.create chunk_size in
  let rec loop () =
    let read = In_channel.input In_channel.stdin chunk 0 chunk_size in
    if read = 0 then Ok (Buffer.contents buffer)
    else if Buffer.length buffer + read > input_cap then
      Error
        (Exit_status.runtime
           (Printf.sprintf "standard input exceeds %d bytes" input_cap))
    else (
      Buffer.add_subbytes buffer chunk 0 read;
      loop ())
  in
  loop ()

let method_string = function `POST -> "POST" | `PATCH -> "PATCH"

let request_json (request : Publication.Request.t) =
  Output.Json.obj
    [
      ("label", Output.Json.string_or_null request.Publication.Request.label);
      ( "method",
        Output.Json.string
          (method_string request.Publication.Request.method_) );
      ("path", Output.Json.string request.Publication.Request.path);
      ("body", request.Publication.Request.body);
    ]

let review pr at diff posted base_label origin =
  (let* pr_raw = require "--pr" pr in
   let* at_raw = require "--at" at in
   let* diff_path = require "--diff" diff in
   let* posted_path = require "--posted" posted in
   let* owner_repo, number = parse_pr pr_raw in
   let* head = parse_head at_raw in
   let* origin = parse_origin origin in
   let* diff_bytes = read_file ~flag:"--diff" diff_path in
   let* posted_bytes = read_file ~flag:"--posted" posted_path in
   let* stdin_bytes = read_stdin_capped () in
   let* document =
     Result.map_error
       (fun e -> Exit_status.runtime (Review_finding.Error.message e))
       (Review_finding.Document.decode stdin_bytes)
   in
   let* diff =
     Result.map_error
       (fun e -> Exit_status.runtime (Publication.Error.message e))
       (Publication.Diff.of_unified diff_bytes)
   in
   let* posted =
     Result.map_error
       (fun e -> Exit_status.runtime (Publication.Error.message e))
       (Publication.Posted.decode posted_bytes)
   in
   let policy = Publication.Policy.default in
   let publication =
     Publication.of_findings ~diff ~policy ~posted ~origin ~owner_repo ~number
       ~head ~base_label document
   in
   let { Publication.threads; summary } = Publication.requests publication in
   let envelope =
     Output.Json.envelope ~type_:"github.review"
       [
         ("review", Output.Json.list (List.map request_json threads));
         ("summary", request_json summary);
         ( "threads_safe",
           Output.Json.bool (Publication.threads_safe publication) );
       ]
   in
   Output.stdout_printf "%s\n" (Output.Json.to_string envelope);
   Ok Exit_status.Success)
  |> Exit_status.of_result

let pr_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "pr" ] ~docv:"OWNER/REPO#N"
        ~doc:"The pull request the findings belong to. Required.")

let at_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "at" ] ~docv:"SHA"
        ~doc:
          "The full head commit SHA the findings were produced at. Required.")

let diff_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "diff" ] ~docv:"FILE"
        ~doc:
          "The unified merge-base diff the review ran over, byte for byte. \
           Required.")

let posted_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "posted" ] ~docv:"FILE"
        ~doc:
          "A JSON array of the comments this publisher already posted on the \
           pull request, each an object with $(b,id) and $(b,body) members, \
           pre-filtered by the caller to its own posting identity. Required.")

let base_label_opt =
  Arg.(
    value
    & opt string "the merge base"
    & info [ "base-label" ] ~docv:"REF"
        ~doc:
          "What the head was reviewed against, named in the summary comment. \
           Display only.")

let origin_opt =
  Arg.(
    value
    & opt string "ci"
    & info [ "origin" ] ~docv:"TOKEN"
        ~doc:
          "The origin token stamped into the emitted comment markers, so \
           coexisting publishers can tell their comments apart. Lowercase \
           letters, digits, $(b,-), and $(b,:) only.")

let review_cmd =
  let doc = "Render a findings document into GitHub review requests." in
  let man =
    [
      `S Manpage.s_description;
      `P
        "Reads a review run's findings document on standard input, anchors \
         each finding against the supplied unified diff, reconciles with the \
         comments already posted, and prints one JSON envelope on standard \
         output holding the GitHub API requests that would publish the \
         result. The command is always dry: it performs no network IO, so it \
         has no retry policy and no partial-failure state — the caller sends \
         the requests.";
      `P
        "The envelope carries $(b,review) (the thread requests, one per \
         blocking finding that anchors to the diff and is not already \
         posted), $(b,summary) (the single sticky summary request), and \
         $(b,threads_safe) (false when blocking findings exist but no thread \
         is posted this run and no blocking fingerprint is already on the \
         pull request — the signature of a diff that does not match the \
         head). When $(b,threads_safe) is false no thread requests are \
         emitted; the flag names why the list is empty. Each request is an \
         object with $(b,label), $(b,method), $(b,path), and $(b,body) \
         members.";
    ]
  in
  Cmd.v
    (Cmd.info "review" ~doc ~docs ~man ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const review $ pr_opt $ at_opt $ diff_opt $ posted_opt
         $ base_label_opt $ origin_opt))

let cmd =
  let doc = "Publish agent results to GitHub." in
  Cmd.group
    (Cmd.info "github" ~doc ~docs ~exits:Cli_common.exits)
    [ review_cmd ]
