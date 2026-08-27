(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

(* The two pulse vocabularies group presentationally; each is a submodule so
   the model and compaction [Started] arms never collide. The
   model vocabulary is a deliberate display projection of [Mentat_llm.Event.t]
   (the omission law is documented in the .mli); the compaction vocabulary is
   exactly the arms a producer emits. *)

module Model = struct
  type t =
    | Started
    | Assistant_delta of { text : string }
    | Reasoning_delta of { text : string }
    | Usage of Mentat_llm.Usage.t
    | Retrying of Mentat_llm.Event.Retry.t

  let equal a b =
    match (a, b) with
    | Started, Started -> true
    | Assistant_delta { text = a }, Assistant_delta { text = b } ->
        String.equal a b
    | Reasoning_delta { text = a }, Reasoning_delta { text = b } ->
        String.equal a b
    | Usage a, Usage b -> Mentat_llm.Usage.equal a b
    | Retrying a, Retrying b -> Mentat_llm.Event.Retry.equal a b
    | ( (Started | Assistant_delta _ | Reasoning_delta _ | Usage _ | Retrying _),
        _ ) ->
        false
end

module Model_download = struct
  type phase = Checking | Downloading | Verifying | Ready

  type t = {
    model : string;
    received : int64;
    total : int64 option;
    phase : phase;
  }

  let phase_equal a b =
    match (a, b) with
    | Checking, Checking
    | Downloading, Downloading
    | Verifying, Verifying
    | Ready, Ready ->
        true
    | (Checking | Downloading | Verifying | Ready), _ -> false

  let equal a b =
    String.equal a.model b.model
    && Int64.equal a.received b.received
    && Option.equal Int64.equal a.total b.total
    && phase_equal a.phase b.phase
end

module Compaction = struct
  type t =
    | Started of { reason : Mentat_session.Compaction.Reason.t }
    | Summarizing
    | Failed of {
        reason : Mentat_session.Compaction.Reason.t;
        message : string;
      }

  let equal a b =
    match (a, b) with
    | Started a, Started b ->
        Mentat_session.Compaction.Reason.equal a.reason b.reason
    | Summarizing, Summarizing -> true
    | Failed a, Failed b ->
        Mentat_session.Compaction.Reason.equal a.reason b.reason
        && String.equal a.message b.message
    | (Started _ | Summarizing | Failed _), _ -> false
end

type t =
  | Model of { turn : Mentat_session.Turn.Id.t; update : Model.t }
  | Model_download of {
      turn : Mentat_session.Turn.Id.t;
      update : Model_download.t;
    }
  | Compaction of { turn : Mentat_session.Turn.Id.t; update : Compaction.t }

let turn = function
  | Model { turn; _ } | Model_download { turn; _ } | Compaction { turn; _ } ->
      turn

let equal a b =
  match (a, b) with
  | Model { turn = ta; update = ua }, Model { turn = tb; update = ub } ->
      Mentat_session.Turn.Id.equal ta tb && Model.equal ua ub
  | ( Model_download { turn = ta; update = ua },
      Model_download { turn = tb; update = ub } ) ->
      Mentat_session.Turn.Id.equal ta tb && Model_download.equal ua ub
  | Compaction { turn = ta; update = ua }, Compaction { turn = tb; update = ub }
    ->
      Mentat_session.Turn.Id.equal ta tb && Compaction.equal ua ub
  | (Model _ | Model_download _ | Compaction _), _ -> false

let pp ppf t =
  let name =
    match t with
    | Model { update = Model.Started; _ } -> "model.started"
    | Model { update = Model.Assistant_delta _; _ } -> "model.assistant_delta"
    | Model { update = Model.Reasoning_delta _; _ } -> "model.reasoning_delta"
    | Model { update = Model.Usage _; _ } -> "model.usage"
    | Model { update = Model.Retrying _; _ } -> "model.retrying"
    | Model_download { update = { Model_download.phase; _ }; _ } -> (
        match phase with
        | Model_download.Checking -> "model.download.checking"
        | Model_download.Downloading -> "model.download.downloading"
        | Model_download.Verifying -> "model.download.verifying"
        | Model_download.Ready -> "model.download.ready")
    | Compaction { update = Compaction.Started _; _ } -> "compaction.started"
    | Compaction { update = Compaction.Summarizing; _ } ->
        "compaction.summarizing"
    | Compaction { update = Compaction.Failed _; _ } -> "compaction.failed"
  in
  Format.fprintf ppf "%s(%a)" name Mentat_session.Turn.Id.pp (turn t)

let jsont =
  let turn_mem map =
    Jsont.Object.mem "turn" Mentat_session.Turn.Id.jsont ~enc:turn map
  in
  let turn_only kind tag inj =
    Jsont.Object.map ~kind (fun turn -> inj turn)
    |> turn_mem |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let model_started_case =
    turn_only "model-started progress" "model.started" (fun turn ->
        Model { turn; update = Model.Started })
  in
  let delta_case kind tag inj proj =
    Jsont.Object.map ~kind (fun turn text -> inj turn text)
    |> turn_mem
    |> Jsont.Object.mem "text" Jsont.string ~enc:proj
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map tag ~dec:Fun.id
  in
  let assistant_delta_case =
    delta_case "assistant-delta progress" "model.assistant_delta"
      (fun turn text -> Model { turn; update = Model.Assistant_delta { text } })
      (function
        | Model { update = Model.Assistant_delta { text }; _ } -> text
        | _ -> assert false)
  in
  let reasoning_delta_case =
    delta_case "reasoning-delta progress" "model.reasoning_delta"
      (fun turn text -> Model { turn; update = Model.Reasoning_delta { text } })
      (function
        | Model { update = Model.Reasoning_delta { text }; _ } -> text
        | _ -> assert false)
  in
  let model_download_case =
    let phase_jsont =
      Jsont.enum ~kind:"model-download phase"
        [
          ("checking", Model_download.Checking);
          ("downloading", Model_download.Downloading);
          ("verifying", Model_download.Verifying);
          ("ready", Model_download.Ready);
        ]
    in
    let update = function
      | Model_download { update; _ } -> update
      | _ -> assert false
    in
    Jsont.Object.map ~kind:"model-download progress"
      (fun turn model received total phase ->
        Model_download
          { turn; update = { Model_download.model; received; total; phase } })
    |> turn_mem
    |> Jsont.Object.mem "model" Jsont.string ~enc:(fun p ->
        (update p).Model_download.model)
    |> Jsont.Object.mem "received" Jsont.int64 ~enc:(fun p ->
        (update p).Model_download.received)
    |> Jsont.Object.opt_mem "total" Jsont.int64 ~enc:(fun p ->
        (update p).Model_download.total)
    |> Jsont.Object.mem "phase" phase_jsont ~enc:(fun p ->
        (update p).Model_download.phase)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "model.download" ~dec:Fun.id
  in
  let usage_case =
    Jsont.Object.map ~kind:"model-usage progress" (fun turn usage ->
        Model { turn; update = Model.Usage usage })
    |> turn_mem
    |> Jsont.Object.mem "usage" Mentat_llm.Usage.jsont ~enc:(function
      | Model { update = Model.Usage usage; _ } -> usage
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "model.usage" ~dec:Fun.id
  in
  let retrying_case =
    let retry = function
      | Model { update = Model.Retrying retry; _ } -> retry
      | _ -> assert false
    in
    Jsont.Object.map ~kind:"model-retrying progress"
      (fun turn attempt limit delay reason ->
        match Mentat_llm.Event.Retry.make ~attempt ~limit ~delay ~reason () with
        | retry -> Model { turn; update = Model.Retrying retry }
        | exception Invalid_argument message -> decode_error message)
    |> turn_mem
    |> Jsont.Object.mem "attempt" Jsont.int ~enc:(fun p ->
        Mentat_llm.Event.Retry.attempt (retry p))
    |> Jsont.Object.mem "limit" Jsont.int ~enc:(fun p ->
        Mentat_llm.Event.Retry.limit (retry p))
    |> Jsont.Object.mem "delay" Jsont.number ~enc:(fun p ->
        Mentat_llm.Event.Retry.delay (retry p))
    |> Jsont.Object.mem "reason" Jsont.string ~enc:(fun p ->
        Mentat_llm.Event.Retry.reason (retry p))
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "model.retrying" ~dec:Fun.id
  in
  let compaction_started_case =
    Jsont.Object.map ~kind:"compaction-started progress" (fun turn reason ->
        Compaction { turn; update = Compaction.Started { reason } })
    |> turn_mem
    |> Jsont.Object.mem "reason" Mentat_session.Compaction.Reason.jsont
         ~enc:(function
         | Compaction { update = Compaction.Started { reason }; _ } -> reason
         | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "compaction.started" ~dec:Fun.id
  in
  let summarizing_case =
    turn_only "compaction-summarizing progress" "compaction.summarizing"
      (fun turn -> Compaction { turn; update = Compaction.Summarizing })
  in
  let failed_case =
    Jsont.Object.map ~kind:"compaction-failed progress"
      (fun turn reason message ->
        if String.is_empty message then decode_error "message must not be empty";
        Compaction { turn; update = Compaction.Failed { reason; message } })
    |> turn_mem
    |> Jsont.Object.mem "reason" Mentat_session.Compaction.Reason.jsont
         ~enc:(function
         | Compaction { update = Compaction.Failed { reason; _ }; _ } -> reason
         | _ -> assert false)
    |> Jsont.Object.mem "message" Jsont.string ~enc:(function
      | Compaction { update = Compaction.Failed { message; _ }; _ } -> message
      | _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "compaction.failed" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [
        model_started_case;
        assistant_delta_case;
        reasoning_delta_case;
        usage_case;
        retrying_case;
        model_download_case;
        compaction_started_case;
        summarizing_case;
        failed_case;
      ]
  in
  let enc_case = function
    | Model { update = Model.Started; _ } as p ->
        Jsont.Object.Case.value model_started_case p
    | Model { update = Model.Assistant_delta _; _ } as p ->
        Jsont.Object.Case.value assistant_delta_case p
    | Model { update = Model.Reasoning_delta _; _ } as p ->
        Jsont.Object.Case.value reasoning_delta_case p
    | Model { update = Model.Usage _; _ } as p ->
        Jsont.Object.Case.value usage_case p
    | Model { update = Model.Retrying _; _ } as p ->
        Jsont.Object.Case.value retrying_case p
    | Model_download _ as p -> Jsont.Object.Case.value model_download_case p
    | Compaction { update = Compaction.Started _; _ } as p ->
        Jsont.Object.Case.value compaction_started_case p
    | Compaction { update = Compaction.Summarizing; _ } as p ->
        Jsont.Object.Case.value summarizing_case p
    | Compaction { update = Compaction.Failed _; _ } as p ->
        Jsont.Object.Case.value failed_case p
  in
  Jsont.Object.map ~kind:"progress" (fun v p ->
      Wire.check v;
      p)
  |> Wire.mem
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.finish
