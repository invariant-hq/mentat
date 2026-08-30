(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Client = Mentat_client
module Session = Mentat_session
module Composition = Mentat_boot.Composition

let log_src = Logs.Src.create "mentat.auto-title" ~doc:"Session auto-titling"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* The env gate defaults on; a falsey value opts out so an unattended run avoids
   the extra provider request the title costs. *)
let enabled t =
  match
    Option.map String.lowercase_ascii (Composition.getenv t "MENTAT_AUTO_TITLE")
  with
  | Some ("0" | "false" | "no" | "off") -> false
  | Some _ | None -> true

let system_prompt =
  "You are a title generator. You output ONLY a thread title, nothing else.\n\n\
   Generate a brief title that helps the user find this conversation later. \
   Your output must be a single line of at most 50 characters, with no \
   explanation and no surrounding quotes.\n\n\
   Rules:\n\
   - Use the same language as the user's message.\n\
   - The title must read naturally and be grammatically correct.\n\
   - Focus on the main topic or question the user needs to retrieve.\n\
   - Keep technical terms, numbers, filenames, and error codes exact.\n\
   - Never name tools (no \"read tool\", \"bash tool\", \"edit tool\").\n\
   - Never assume a tech stack that was not mentioned.\n\
   - Never refuse or complain about the input; always produce a meaningful \
   title, even for a short or conversational message.\n\
   - Do not include the words \"summarizing\" or \"generating\"."

(* Some models inline a reasoning block as <think>…</think> in the message body.
   Drop the first such span so the title comes from the real answer. *)
let strip_think s =
  match
    (String.find_first ~sub:"<think>" s, String.find_first ~sub:"</think>" s)
  with
  | Some i, Some j when j >= i ->
      let tail = j + String.length "</think>" in
      String.sub s 0 i ^ String.sub s tail (String.length s - tail)
  | _ -> s

(* The first non-blank line, matching the single-line contract the prompt asks
   for and guarding against a model that adds a preamble. *)
let first_line s =
  String.split_on_char '\n' s
  |> List.map String.trim
  |> List.find_opt (fun line -> not (String.equal line ""))

let unquote s =
  let n = String.length s in
  if
    n >= 2
    &&
    let c = s.[0] in
    (c = '"' || c = '\'' || c = '`') && s.[n - 1] = c
  then String.trim (String.sub s 1 (n - 2))
  else s

(* A byte clamp that never splits a UTF-8 codepoint, since the 50-character
   contract is a request the model may exceed. *)
let clamp max s =
  if String.length s <= max then s
  else
    let rec back i =
      if i > 0 && Char.code s.[i] land 0xC0 = 0x80 then back (i - 1) else i
    in
    String.trim (String.sub s 0 (back max)) ^ "…"

let sanitize raw =
  match first_line (strip_think raw) with
  | None -> None
  | Some line -> (
      match String.trim (unquote line) with
      | "" -> None
      | title -> Some (clamp 80 title))

(* The caller renames before the turn is submitted, so this session is not yet
   driven by this process. A [Busy] here means another process transiently holds
   the session's run-lock; a short bounded backoff absorbs that. *)
let rename_with_retry t ~client ~session ~title =
  let clock = Eio.Stdenv.clock (Composition.stdenv t) in
  let rec attempt n delay =
    match Client.rename client ~session ~title with
    | Ok () -> Ok ()
    | Error (Mentat_protocol.Error.Busy _) when n > 0 ->
        Eio.Time.sleep clock delay;
        attempt (n - 1) (Float.min 0.5 (delay *. 1.5))
    | Error _ as error -> error
  in
  attempt 8 0.1

(* The title generation gates the turn's submission, so the cap is worst-case
   added latency on a user's very first prompt: keep it tight, and let a slow or
   stalled small-model call yield no title rather than hold the turn hostage. *)
let generation_timeout_s = 3.0

let generate t ~prompt =
  let clock = Eio.Stdenv.clock (Composition.stdenv t) in
  match
    Eio.Time.with_timeout clock generation_timeout_s (fun () ->
        Ok
          (Composition.small_model_completion t ~system:system_prompt
             ~user:prompt))
  with
  | Ok result -> result
  | Error `Timeout -> Error "title generation timed out"

let run t ~client ~session ~prompt =
  if not (enabled t) then ()
  else
    match generate t ~prompt with
    | Error message ->
        Log.info (fun log -> log "auto-title skipped: %s" message)
    | Ok text -> (
        match sanitize text with
        | None ->
            Log.info (fun log -> log "auto-title produced no usable title")
        | Some title -> (
            match rename_with_retry t ~client ~session ~title with
            | Ok () ->
                Log.info (fun log ->
                    log "auto-titled session %s: %S"
                      (Session.Id.to_string session)
                      title)
            | Error error ->
                Log.info (fun log ->
                    log "auto-title rename failed: %s"
                      (Mentat_diagnostic.to_string
                         (Mentat_protocol.Error.diagnostic error)))))
