(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The wire vocabulary the endpoint table names: the two client-owned flow
   codecs deferred until a transport carried them (compaction_result, the login
   step) minted here, plus the request/response object codecs each endpoint
   carries. Owner codecs are reused whole; a codec is built here only where an
   owner defers one. *)

(* Small foundations. *)

(* A [unit] result crosses as the empty object [{}], a value that round-trips
   and leaves room for a later member without a breaking shape change. *)
let ok_unit : unit Jsont.t =
  Jsont.Object.map ~kind:"ok" () |> Jsont.Object.finish

let uri : Uri.t Jsont.t =
  Jsont.map ~kind:"uri"
    ~dec:(fun s -> Uri.of_string s)
    ~enc:(fun u -> Uri.to_string u)
    Jsont.string

let rel_path : Lpath.Rel.t Jsont.t =
  Jsont.map ~kind:"relative path"
    ~dec:(fun s ->
      match Lpath.Rel.of_string s with
      | Ok path -> path
      | Error error ->
          Jsont.Error.msg Jsont.Meta.none (Lpath.Error.message error))
    ~enc:Lpath.Rel.to_string Jsont.string

let reasoning_effort : Mentat_llm.Request.Options.Reasoning_effort.t Jsont.t =
  Jsont.map ~kind:"reasoning effort"
    ~dec:(fun s ->
      match Mentat_llm.Request.Options.Reasoning_effort.of_string s with
      | Some effort -> effort
      | None ->
          Jsont.Error.msg Jsont.Meta.none
            (Printf.sprintf "unknown reasoning effort %S" s))
    ~enc:Mentat_llm.Request.Options.Reasoning_effort.to_string Jsont.string

let login_method : Mentat_provider.Auth.Login.Id.t Jsont.t =
  Jsont.map ~kind:"login method id"
    ~dec:(fun s ->
      match Mentat_provider.Auth.Login.Id.of_string s with
      | Some id -> id
      | None ->
          Jsont.Error.msg Jsont.Meta.none
            (Printf.sprintf "invalid login method id %S" s))
    ~enc:Mentat_provider.Auth.Login.Id.to_string Jsont.string

(* A rewind [Anchor.t] gains its wire form here: the owner defers a codec until a
   transport carries the rewind flow across processes (anchor.mli), and this is
   that transport. The shape is the anchor's own two accessors — a turn id and
   the boundary edge — reassembled through its constructors. *)
let anchor : Mentat_session.Anchor.t Jsont.t =
  let edge =
    Jsont.enum ~kind:"anchor edge"
      [
        ("before", Mentat_session.Anchor.Before);
        ("after", Mentat_session.Anchor.After);
      ]
  in
  Jsont.Object.map ~kind:"rewind anchor" (fun turn -> function
    | Mentat_session.Anchor.Before -> Mentat_session.Anchor.before_turn turn
    | Mentat_session.Anchor.After -> Mentat_session.Anchor.after_turn turn)
  |> Jsont.Object.mem "turn" Mentat_session.Turn.Id.jsont
       ~enc:Mentat_session.Anchor.turn
  |> Jsont.Object.mem "edge" edge ~enc:Mentat_session.Anchor.edge
  |> Jsont.Object.finish

(* Request records — one per endpoint whose driver field takes more than a bare
   owner value. The [submit], [review apply], and [review compose] endpoints
   carry owner codecs directly and appear in the table rather than here. *)

type session_only = { session : Mentat_session.Id.t }

let session_only : session_only Jsont.t =
  Jsont.Object.map ~kind:"session request" (fun session -> { session })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.session)
  |> Jsont.Object.finish

let empty : unit Jsont.t =
  Jsont.Object.map ~kind:"empty request" () |> Jsont.Object.finish

type model_readiness = { refresh : bool }

let model_readiness : model_readiness Jsont.t =
  Jsont.Object.map ~kind:"model_readiness request" (fun refresh -> { refresh })
  |> Jsont.Object.mem "refresh" Jsont.bool ~dec_absent:false
       ~enc_omit:(fun refresh -> not refresh)
       ~enc:(fun r -> r.refresh)
  |> Jsont.Object.finish

type answer_unattended = {
  au_session : Mentat_session.Id.t;
  au_decision : Mentat_session.Decision.Id.t;
}

let answer_unattended : answer_unattended Jsont.t =
  Jsont.Object.map ~kind:"answer_unattended request"
    (fun au_session au_decision -> { au_session; au_decision })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.au_session)
  |> Jsont.Object.mem "decision" Mentat_session.Decision.Id.jsont ~enc:(fun r ->
      r.au_decision)
  |> Jsont.Object.finish

type fork = {
  fork_session : Mentat_session.Id.t;
  fork_into : Mentat_session.Id.t;
}

let fork : fork Jsont.t =
  Jsont.Object.map ~kind:"fork request" (fun fork_session fork_into ->
      { fork_session; fork_into })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.fork_session)
  |> Jsont.Object.mem "into" Mentat_session.Id.jsont ~enc:(fun r -> r.fork_into)
  |> Jsont.Object.finish

type rewind = {
  rw_session : Mentat_session.Id.t;
  rw_into : Mentat_session.Id.t;
  rw_anchor : Mentat_session.Anchor.t;
}

let rewind : rewind Jsont.t =
  Jsont.Object.map ~kind:"rewind request" (fun rw_session rw_into rw_anchor ->
      { rw_session; rw_into; rw_anchor })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.rw_session)
  |> Jsont.Object.mem "into" Mentat_session.Id.jsont ~enc:(fun r -> r.rw_into)
  |> Jsont.Object.mem "anchor" anchor ~enc:(fun r -> r.rw_anchor)
  |> Jsont.Object.finish

type compact = {
  compact_session : Mentat_session.Id.t;
  compact_turn : Mentat_session.Turn.Id.t;
}

let compact : compact Jsont.t =
  Jsont.Object.map ~kind:"compact request" (fun compact_session compact_turn ->
      { compact_session; compact_turn })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.compact_session)
  |> Jsont.Object.mem "turn" Mentat_session.Turn.Id.jsont ~enc:(fun r ->
      r.compact_turn)
  |> Jsont.Object.finish

type tail = { tail_session : Mentat_session.Id.t; tail_n : int option }

let tail : tail Jsont.t =
  Jsont.Object.map ~kind:"tail request" (fun tail_session tail_n ->
      { tail_session; tail_n })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.tail_session)
  |> Jsont.Object.opt_mem "n" Jsont.int ~enc:(fun r -> r.tail_n)
  |> Jsont.Object.finish

type page = {
  page_session : Mentat_session.Id.t;
  page_n : int option;
  page_before : Mentat_protocol.Position.t option;
}

let page : page Jsont.t =
  Jsont.Object.map ~kind:"page request" (fun page_session page_n page_before ->
      { page_session; page_n; page_before })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.page_session)
  |> Jsont.Object.opt_mem "n" Jsont.int ~enc:(fun r -> r.page_n)
  |> Jsont.Object.mem "before" (Jsont.option Mentat_protocol.Position.jsont)
       ~enc:(fun r -> r.page_before)
  |> Jsont.Object.finish

type change_diff = {
  cd_session : Mentat_session.Id.t;
  cd_change : Mentat_mutation.Change.Id.t;
}

let change_diff : change_diff Jsont.t =
  Jsont.Object.map ~kind:"change_diff request" (fun cd_session cd_change ->
      { cd_session; cd_change })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.cd_session)
  |> Jsont.Object.mem "change" Mentat_mutation.Change.Id.jsont ~enc:(fun r ->
      r.cd_change)
  |> Jsont.Object.finish

type revert = {
  rv_session : Mentat_session.Id.t;
  rv_scope : Mentat_mutation.Revert.Scope.t;
}

let revert : revert Jsont.t =
  Jsont.Object.map ~kind:"revert request" (fun rv_session rv_scope ->
      { rv_session; rv_scope })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.rv_session)
  |> Jsont.Object.mem "scope" Mentat_mutation.Revert.Scope.jsont ~enc:(fun r ->
      r.rv_scope)
  |> Jsont.Object.finish

type save_api_key = { key_provider : Mentat_llm.Provider.t; key : string }

let save_api_key : save_api_key Jsont.t =
  Jsont.Object.map ~kind:"save_api_key request" (fun key_provider key ->
      { key_provider; key })
  |> Jsont.Object.mem "provider" Mentat_llm.Provider.jsont ~enc:(fun r ->
      r.key_provider)
  |> Jsont.Object.mem "key" Jsont.string ~enc:(fun r -> r.key)
  |> Jsont.Object.finish

type logout = { logout_provider : Mentat_llm.Provider.t; revoke : bool }

let logout : logout Jsont.t =
  Jsont.Object.map ~kind:"logout request" (fun logout_provider revoke ->
      { logout_provider; revoke })
  |> Jsont.Object.mem "provider" Mentat_llm.Provider.jsont ~enc:(fun r ->
      r.logout_provider)
  |> Jsont.Object.mem "revoke" Jsont.bool ~enc:(fun r -> r.revoke)
  |> Jsont.Object.finish

type login = {
  login_provider : Mentat_llm.Provider.t;
  method_ : Mentat_provider.Auth.Login.Id.t;
}

let login : login Jsont.t =
  Jsont.Object.map ~kind:"login request" (fun login_provider method_ ->
      { login_provider; method_ })
  |> Jsont.Object.mem "provider" Mentat_llm.Provider.jsont ~enc:(fun r ->
      r.login_provider)
  |> Jsont.Object.mem "method" login_method ~enc:(fun r -> r.method_)
  |> Jsont.Object.finish

type set_model = {
  sm_session : Mentat_session.Id.t;
  sm_effort : Mentat_llm.Request.Options.Reasoning_effort.t option;
  sm_selector : Mentat_provider.Selector.t;
}

let set_model : set_model Jsont.t =
  Jsont.Object.map ~kind:"set_model request"
    (fun sm_session sm_effort sm_selector ->
      { sm_session; sm_effort; sm_selector })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.sm_session)
  |> Jsont.Object.opt_mem "reasoning_effort" reasoning_effort ~enc:(fun r ->
      r.sm_effort)
  |> Jsont.Object.mem "selector" Mentat_provider.Selector.jsont ~enc:(fun r ->
      r.sm_selector)
  |> Jsont.Object.finish

(* The durable default-model write is sessionless: no session
   member, unlike [set_model]'s per-session override. *)
type set_default_model = {
  sdm_effort : Mentat_llm.Request.Options.Reasoning_effort.t option;
  sdm_selector : Mentat_provider.Selector.t;
}

let set_default_model : set_default_model Jsont.t =
  Jsont.Object.map ~kind:"set_default_model request"
    (fun sdm_effort sdm_selector -> { sdm_effort; sdm_selector })
  |> Jsont.Object.opt_mem "reasoning_effort" reasoning_effort ~enc:(fun r ->
      r.sdm_effort)
  |> Jsont.Object.mem "selector" Mentat_provider.Selector.jsont ~enc:(fun r ->
      r.sdm_selector)
  |> Jsont.Object.finish

(* The durable UI-theme write is sessionless: just the theme name. *)
type set_ui_theme = { sut_theme : string }

let set_ui_theme : set_ui_theme Jsont.t =
  Jsont.Object.map ~kind:"set_ui_theme request" (fun sut_theme -> { sut_theme })
  |> Jsont.Object.mem "theme" Jsont.string ~enc:(fun r -> r.sut_theme)
  |> Jsont.Object.finish

type dune_control = { dc_op : [ `Restart | `Stop ] }

let dune_control : dune_control Jsont.t =
  Jsont.Object.map ~kind:"dune_control request" (fun dc_op -> { dc_op })
  |> Jsont.Object.mem "op"
       (Jsont.enum ~kind:"dune op" [ ("restart", `Restart); ("stop", `Stop) ])
       ~enc:(fun r -> r.dc_op)
  |> Jsont.Object.finish

type set_permission_review = {
  spr_session : Mentat_session.Id.t;
  spr_review : Mentat_permission.Review_behavior.t;
}

let set_permission_review : set_permission_review Jsont.t =
  Jsont.Object.map ~kind:"set_permission_review request"
    (fun spr_session spr_review -> { spr_session; spr_review })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.spr_session)
  |> Jsont.Object.mem "review" Mentat_permission.Review_behavior.jsont
       ~enc:(fun r -> r.spr_review)
  |> Jsont.Object.finish

type create = { create_id : Mentat_session.Id.t; title : string option }

let create : create Jsont.t =
  Jsont.Object.map ~kind:"create request" (fun create_id title ->
      { create_id; title })
  |> Jsont.Object.mem "id" Mentat_session.Id.jsont ~enc:(fun r -> r.create_id)
  |> Jsont.Object.opt_mem "title" Jsont.string ~enc:(fun r -> r.title)
  |> Jsont.Object.finish

type rename = { rename_session : Mentat_session.Id.t; rename_title : string }

let rename : rename Jsont.t =
  Jsont.Object.map ~kind:"rename request" (fun rename_session rename_title ->
      { rename_session; rename_title })
  |> Jsont.Object.mem "session" Mentat_session.Id.jsont ~enc:(fun r ->
      r.rename_session)
  |> Jsont.Object.mem "title" Jsont.string ~enc:(fun r -> r.rename_title)
  |> Jsont.Object.finish

let listing : Mentat_session.Listing.t Jsont.t =
  let scope =
    Jsont.enum ~kind:"listing scope" [ ("cwd", `Cwd); ("all", `All) ]
  in
  Jsont.Object.map ~kind:"session listing" (fun scope lifecycles search limit ->
      { Mentat_session.Listing.scope; lifecycles; search; limit })
  |> Jsont.Object.mem "scope" scope ~enc:(fun l ->
      l.Mentat_session.Listing.scope)
  |> Jsont.Object.mem "lifecycles"
       (Jsont.list Mentat_session.Metadata.Status.jsont) ~enc:(fun l ->
         l.Mentat_session.Listing.lifecycles)
  |> Jsont.Object.opt_mem "search" Jsont.string ~enc:(fun l ->
      l.Mentat_session.Listing.search)
  |> Jsont.Object.opt_mem "limit" Jsont.int ~enc:(fun l ->
      l.Mentat_session.Listing.limit)
  |> Jsont.Object.finish

let review_diff_path : Lpath.Rel.t Jsont.t = rel_path

(* Response codecs that combine owner values. *)

let sessions_result :
    (Mentat_session.Summary.t list * Mentat_diagnostic.t list) Jsont.t =
  Jsont.Object.map ~kind:"sessions result" (fun summaries diagnostics ->
      (summaries, diagnostics))
  |> Jsont.Object.mem "summaries"
       (Jsont.list Mentat_session.Summary.jsont)
       ~enc:fst
  |> Jsont.Object.mem "diagnostics"
       (Jsont.list Mentat_diagnostic.jsont)
       ~enc:snd
  |> Jsont.Object.finish

let glance_result : Textdiff.stats option Jsont.t =
  Jsont.Object.map ~kind:"workspace glance" Fun.id
  |> Jsont.Object.mem "stats" (Jsont.option Textdiff.Stats.jsont) ~enc:Fun.id
  |> Jsont.Object.finish
