(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type error =
  | Malformed_base64
  | Missing_attachment of Mentat_digest.Content_ref.t
  | Store of Mentat_diagnostic.t
  | Rebuild of string

(* The user-facing diagnostic for a media error. The provider path prefixes a
   [Rebuild] with its own context at the call site; the other arms are shared. *)
let message = function
  | Malformed_base64 -> "an attached image payload is not valid base64"
  | Missing_attachment reference ->
      Format.asprintf "referenced attachment %a has no stored blob"
        Mentat_digest.Content_ref.pp reference
  | Store d -> Mentat_diagnostic.to_string d
  | Rebuild detail -> detail

let ( let* ) = Result.bind

let map_result f xs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | x :: rest -> (
        match f x with
        | Ok y -> loop (y :: acc) rest
        | Error _ as error -> error)
  in
  loop [] xs

(* Externalize: [`Base64] -> [`Ref], validating existing [`Ref]s. *)

let externalize_block ~put_attachment ~attachment block =
  match block with
  | Mentat_llm.Content.Text _ | Mentat_llm.Content.Media { source = `Uri _; _ }
    ->
      Ok block
  | Mentat_llm.Content.Media { media_type; source = `Base64 data } -> (
      match Base64.decode data with
      | Error (`Msg _) -> Error Malformed_base64
      | Ok bytes -> (
          match put_attachment bytes with
          | Error e -> Error (Store e)
          | Ok reference ->
              Ok (Mentat_llm.Content.media ~media_type (`Ref reference))))
  | Mentat_llm.Content.Media { source = `Ref reference; _ } -> (
      match attachment reference with
      | Error e -> Error (Store e)
      | Ok (Some _) -> Ok block
      | Ok None -> Error (Missing_attachment reference))

let externalize ~put_attachment ~attachment content =
  map_result (externalize_block ~put_attachment ~attachment) content

(* Resolve: [`Ref] -> [`Base64], loading blob bytes. Only user-message media is
   carried, so only [Mentat_llm.Message.User] is rewritten; a request with no reference is
   returned as-is to avoid reconstructing it. *)

let resolve_block ~attachment block =
  match block with
  | Mentat_llm.Content.Media { media_type; source = `Ref reference } -> (
      match attachment reference with
      | Error e -> Error (Store e)
      | Ok None -> Error (Missing_attachment reference)
      | Ok (Some bytes) ->
          Ok
            (Mentat_llm.Content.media ~media_type
               (`Base64 (Base64.encode_string bytes))))
  | Mentat_llm.Content.Media { source = `Uri _ | `Base64 _; _ }
  | Mentat_llm.Content.Text _ ->
      Ok block

let content_has_ref content =
  List.exists
    (function
      | Mentat_llm.Content.Media { source = `Ref _; _ } -> true | _ -> false)
    content

let message_has_ref = function
  | Mentat_llm.Message.User content -> content_has_ref content
  | Mentat_llm.Message.Tool_result result ->
      content_has_ref (Mentat_llm.Tool.Result.content result)
  | Mentat_llm.Message.System _ | Mentat_llm.Message.Developer _
  | Mentat_llm.Message.Assistant _ ->
      false

let resolve_message ~attachment message =
  match message with
  | Mentat_llm.Message.User content ->
      let* content = map_result (resolve_block ~attachment) content in
      Ok (Mentat_llm.Message.user content)
  | Mentat_llm.Message.Tool_result result ->
      let* content =
        map_result
          (resolve_block ~attachment)
          (Mentat_llm.Tool.Result.content result)
      in
      Ok
        (Mentat_llm.Message.tool_result
           (Mentat_llm.Tool.Result.with_content result content))
  | Mentat_llm.Message.System _ | Mentat_llm.Message.Developer _
  | Mentat_llm.Message.Assistant _ ->
      Ok message

let resolve_request ~attachment request =
  let transcript_messages =
    Mentat_llm.Transcript.messages (Mentat_llm.Request.transcript request)
  in
  if not (List.exists message_has_ref transcript_messages) then Ok request
  else
    let* messages =
      map_result (resolve_message ~attachment) transcript_messages
    in
    match Mentat_llm.Transcript.of_list messages with
    | Error e -> Error (Rebuild (Mentat_llm.Transcript.Error.message e))
    | Ok transcript -> (
        match
          Mentat_llm.Request.make
            ~model:(Mentat_llm.Request.model request)
            ~prelude:(Mentat_llm.Request.prelude request)
            ~tools:(Mentat_llm.Request.tools request)
            ~options:(Mentat_llm.Request.options request)
            ?cache_key:(Mentat_llm.Request.cache_key request)
            transcript
        with
        | Ok request -> Ok request
        | Error e -> Error (Rebuild (Mentat_llm.Request.Error.message e)))
