(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Model = Mentat_llm.Model
module Content = Mentat_llm.Content
module Message = Mentat_llm.Message
module Tool = Mentat_llm.Tool
module Request = Mentat_llm.Request
module Transcript = Mentat_llm.Transcript
module Catalog = Mentat_provider.Catalog
module Pmodel = Mentat_provider.Model
module Media_support = Mentat_provider.Media_support

let model_has_vision ~catalog llm_model =
  let selector =
    Mentat_llm.Provider.id (Model.provider llm_model) ^ "/" ^ Model.id llm_model
  in
  match Catalog.resolve catalog selector with
  | Ok model -> Pmodel.has_input_modality Pmodel.Modality.image model
  | Error _ -> true

let content_has_media content =
  List.exists
    (function Content.Media _ -> true | Content.Text _ -> false)
    content

let strip_media ~placeholder content =
  List.map
    (function
      | Content.Media _ -> Content.text placeholder
      | Content.Text _ as text -> text)
    content

let apply ~catalog request =
  let model = Request.model request in
  let api = Model.api model in
  let vision = model_has_vision ~catalog model in
  let keep_user_media =
    vision && Media_support.encodable api Media_support.User_content
  in
  let keep_tool_result_media =
    vision && Media_support.encodable api Media_support.Tool_result
  in
  let messages = Transcript.messages (Request.transcript request) in
  let needs_strip =
    List.exists
      (function
        | Message.User content ->
            (not keep_user_media) && content_has_media content
        | Message.Tool_result result ->
            (not keep_tool_result_media)
            && content_has_media (Tool.Result.content result)
        | _ -> false)
      messages
  in
  if not needs_strip then request
  else
    let placeholder ~channel =
      if not vision then "[image omitted — the current model has no vision]"
      else
        Printf.sprintf "[image omitted — %s cannot carry image media in %s]"
          (Model.Api.id api) channel
    in
    let strip_message = function
      | Message.User content when not keep_user_media ->
          Message.user
            (strip_media
               ~placeholder:(placeholder ~channel:"a user message")
               content)
      | Message.Tool_result result when not keep_tool_result_media ->
          Message.tool_result
            (Tool.Result.with_content result
               (strip_media
                  ~placeholder:(placeholder ~channel:"a tool result")
                  (Tool.Result.content result)))
      | message -> message
    in
    match Transcript.of_list (List.map strip_message messages) with
    | Error _ -> request
    | Ok transcript -> (
        match
          Request.make ~model ~prelude:(Request.prelude request)
            ~tools:(Request.tools request) ~options:(Request.options request)
            ?cache_key:(Request.cache_key request)
            transcript
        with
        | Ok stripped -> stripped
        | Error _ -> request)
