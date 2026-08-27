(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open! Cmdliner
module Client = Mentat_client
module Protocol = Mentat_protocol
module Command = Mentat_protocol.Command
module Fact = Mentat_protocol.Fact
module Id = Mentat_session.Id
module Session = Mentat_session
module Turn = Mentat_session.Turn
module Document = Mentat_store.Session.Document
module Catalog = Mentat_provider.Catalog

let docs = Cli_common.s_run
let ( let* ) = Result.bind

(* An explicit [--id] is validated before any store smart constructor; [None]
   mints a fresh id. *)
let validate_id_opt = function
  | None -> Ok None
  | Some s -> Result.map Option.some (Argv.session_id s)

(* The context-override flag trio, resolved to their instruction-field steps. *)
type context_flags = {
  no_instructions : bool;
  project_instructions : bool;
  no_project_instructions : bool;
  no_skills : bool;
}

(* An overlay step maps a config forward or reports a usage error; the config
   field renderer already produces a clean, hinted message, so a rejected set is
   a usage error carrying it. *)
let usage_of_config = function
  | Ok config -> Ok config
  | Error e -> Error (Exit_status.usage (Mentat_config.Error.message e))

let set_text_step field raw config =
  usage_of_config (Mentat_config.set_text field raw config)

let set_step field value config =
  usage_of_config (Mentat_config.set field value config)

(* The boot-config flags overlay the resolved configuration the composition
   seals the turn contract from — exactly the surface the [MENTAT_*] environment
   already drives — so [--reasoning], [--sandbox], [--permission-unattended],
   [--require-sandbox], [--max-steps], and the context toggles need no engine
   plumbing beyond one layered overlay. [--model] validates its format cleanly
   here (sidestepping the doubled "model model selector" the field renderer
   produces); catalog existence is checked post-composition with
   flag-provenance. [--mode] is deliberately absent: it has no config
   field and travels on the prompt command. *)
let build_overrides ~model ~reasoning ~permission_unattended ~sandbox
    ~require_sandbox ~max_steps ~context =
  let* () =
    if
      context.project_instructions
      && (context.no_project_instructions || context.no_instructions)
    then
      Error
        (Exit_status.usage
           "--project-instructions cannot be combined with an \
            instruction-disabling flag")
    else Ok ()
  in
  let* max_steps_step =
    match max_steps with
    | None -> Ok None
    | Some n when n > 0 ->
        Ok
          (Some
             (set_text_step Mentat_config.Field.run_max_steps (string_of_int n)))
    | Some n ->
        Error
          (Exit_status.usage
             (Printf.sprintf "--max-steps must be positive, got %d" n))
  in
  let* model_step =
    match model with
    | None -> Ok None
    | Some m ->
        let* raw = Argv.model_selector m in
        Ok (Some (set_text_step Mentat_config.Field.model raw))
  in
  let instructions_project_step =
    if context.no_instructions || context.no_project_instructions then
      Some (set_step Mentat_config.Field.instructions_project false)
    else if context.project_instructions then
      Some (set_step Mentat_config.Field.instructions_project true)
    else None
  in
  let steps =
    List.filter_map Fun.id
      [
        model_step;
        Option.map (set_text_step Mentat_config.Field.reasoning) reasoning;
        Option.map
          (set_text_step Mentat_config.Field.permission_unattended)
          permission_unattended;
        Option.map (set_text_step Mentat_config.Field.sandbox_mode) sandbox;
        (if require_sandbox then
           Some
             (set_step Mentat_config.Field.sandbox_require
                Mentat_sandbox.Requirement.Enforced_or_external)
         else None);
        max_steps_step;
        (if context.no_instructions then
           Some (set_step Mentat_config.Field.instructions_global false)
         else None);
        instructions_project_step;
        (if context.no_skills then
           Some (set_step Mentat_config.Field.skills_enabled false)
         else None);
      ]
  in
  match steps with
  | [] -> Ok []
  | steps ->
      let* overlay =
        List.fold_left
          (fun acc step ->
            let* config = acc in
            step config)
          (Ok Mentat_config.empty) steps
      in
      Ok [ overlay ]

(* An explicit [--model] whose provider/model is unknown is a usage error
   (exit 2); a derived default that fails to resolve is a runtime error (exit 1),
   surfaced downstream through [default_model]. *)
let check_explicit_model t = function
  | None -> Ok ()
  | Some m -> (
      match Catalog.resolve (Composition.catalog t) m with
      | Ok _ -> Ok ()
      | Error e -> Error (Exit_status.usage (Catalog.Error.message e)))

(* F7: the run-start posture summary on stderr — the configured sandbox posture
   block, then the untrusted-workspace warning when the workspace is not trusted.
   Human-path only; the [--json] stream carries its own terminal events.

   Trust decides which config warning is worth the line: an untrusted workspace
   drops every workspace file for one reason, stated once; a trusted one drops
   individual keys, and each needs naming. *)
let run_start_notices t ~json =
  if not json then (
    Cli_sandbox.print_run_posture t;
    if not (Composition.trusted t) then
      Output.stderr_printf
        "mentat: warning: workspace is not trusted; project config and rules \
         are disabled (run `mentat trust .`)\n"
    else Cli_config.print_warnings t)

(* Shell-quote the id in the saved hint so it stays copy-pasteable regardless of
   its bytes (ids are already restricted to a safe charset). *)
let shell_quote s =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let saved_hint session =
  Output.stderr_printf
    "mentat: session saved; resume with: mentat run resume %s\n"
    (shell_quote (Id.to_string session))

(* JSONL lifecycle stream. — the [--json] projection of the client feed. Each
   committed fact projects to at most one enveloped line carrying the session id;
   payloads reuse the owners' own codecs, so the stream cannot drift from the
   durable values it reports. *)

let emit_event ~session type_ fields =
  Output.stdout_printf "%s\n"
    (Output.Json.to_string
       (Output.Json.envelope ~type_
          (("session_id", Output.Json.string (Id.to_string session)) :: fields)))

let model_string model = Format.asprintf "%a" Mentat_llm.Model.pp model

let mode_string = function
  | Session.Contract.Mode.Build -> "build"
  | Session.Contract.Mode.Plan -> "plan"
  | Session.Contract.Mode.Review -> "review"

let turn_origin_string = function
  | Turn.Origin.User -> "user"
  | Turn.Origin.Goal_continuation -> "goal_continuation"
  | Turn.Origin.Queued _ -> "queued"
  | Turn.Origin.Plan_build -> "plan_build"
  | Turn.Origin.Compaction -> "compaction"
  | Turn.Origin.Step_limit_wind_down -> "step_limit_wind_down"

(* The goal and queue facts are single journal arms; the wire tag is the
   transition the update records (the "per-transition tags derive at the headless
   mapping" the fact vocabulary defers here). These dotted tag strings are the
   product contract, chosen once to match the existing per-arm fact tags. *)
let goal_event_type = function
  | Session.Goal.Update.Declare _ -> "goal.declared"
  | Session.Goal.Update.Pause _ -> "goal.paused"
  | Session.Goal.Update.Resume _ -> "goal.resumed"
  | Session.Goal.Update.Edit _ -> "goal.edited"
  | Session.Goal.Update.Clear _ -> "goal.cleared"
  | Session.Goal.Update.Complete _ -> "goal.completed"
  | Session.Goal.Update.Block _ -> "goal.blocked"
  | Session.Goal.Update.Budget_limited _ -> "goal.budget_limited"

let queue_event_type = function
  | Session.Queue.Update.Enqueued _ -> "queue.enqueued"
  | Session.Queue.Update.Replaced _ -> "queue.replaced"
  | Session.Queue.Update.Cleared -> "queue.cleared"

let owner_json codec value =
  match Jsont.Json.encode codec value with
  | Ok json -> json
  | Error message -> failwith ("event encode failed: " ^ message)

let requested_json = owner_json Session.Decision.Requested.jsont

(* run.started mirrors the human posture block as one stream event: the
   configured sandbox posture and whether the workspace is trusted, read from
   the same resolved config the human path renders. *)
let emit_run_started t ~session =
  let config = Composition.config t in
  emit_event ~session "run.started"
    [
      ( "sandbox",
        Output.Json.obj
          [
            ( "mode",
              Output.Json.string
                (Mentat_config.Mode.to_string
                   (Composition.configured_sandbox_mode t)) );
            ( "read",
              Output.Json.string
                (Mentat_config.Read.to_string
                   (Mentat_config.Resolved.get Mentat_config.Field.sandbox_read
                      config)) );
            ( "network",
              Output.Json.string
                (Mentat_sandbox.Policy.Network.to_string
                   (Mentat_config.Resolved.get
                      Mentat_config.Field.sandbox_network config)) );
          ] );
      ("trusted", Output.Json.bool (Composition.trusted t));
    ]

(* Feed rendering. — headless: assistant prose streams to stdout as it arrives
   and is reconciled against the authoritative fact at each step boundary. *)

type terminal =
  | Same_turn of Turn.Id.t
  | Plan_build_after of Turn.Id.t
  | Await_plan_build

let human_line fmt = Printf.ksprintf Output.model_text fmt

let render_human_waiting ~session request =
  let module Requested = Session.Decision.Requested in
  let decision = Requested.id request in
  let decision_text = Session.Decision.Id.to_string decision in
  let session_text = Id.to_string session in
  human_line "Decision %s (%s)" decision_text (Requested.tag request);
  human_line "Tool call %s: %s (%s)"
    (Requested.call_id request)
    (Requested.name request)
    (Mentat_tool.Stage.to_string (Requested.stage request));
  (match Requested.request request with
  | Session.Decision.Request.Permission review ->
      let permission_request = Mentat_permission.Policy.Review.request review in
      Option.iter (human_line "Source: %s")
        (Mentat_permission.Request.source permission_request);
      Option.iter (human_line "Request: %s")
        (Mentat_permission.Request.display permission_request);
      List.iter
        (fun (access, reason) ->
          let reason =
            match reason with
            | Mentat_permission.Policy.Review.Unmatched -> "unmatched"
            | Mentat_permission.Policy.Review.By_rule rule ->
                Format.asprintf "reviewed by rule %a"
                  Mentat_permission.Policy.Rule.pp rule
          in
          human_line "Access: %s (%s)"
            (Format.asprintf "%a" Mentat_permission.Access.pp access)
            reason)
        (Mentat_permission.Policy.Review.reasons review)
  | Session.Decision.Request.Question question ->
      human_line "Question: %s" (Session.Question.prompt question);
      Option.iter
        (List.iteri (fun index choice ->
             human_line "  %d. %s" (index + 1) choice))
        (Session.Question.choices question)
  | Session.Decision.Request.Plan plan ->
      Option.iter (human_line "Plan: %s") (Session.Plan.title plan);
      human_line "%s" (Session.Plan.body plan));
  let prefix =
    Printf.sprintf "mentat run reply %s --decision %s"
      (shell_quote session_text)
      (shell_quote decision_text)
  in
  Output.stdout_printf "Reply with:\n";
  match Requested.request request with
  | Session.Decision.Request.Permission _ ->
      Output.stdout_printf "  %s --allow\n" prefix;
      Output.stdout_printf "  %s --allow-conversation\n" prefix;
      Output.stdout_printf "  %s --deny\n" prefix;
      Output.stdout_printf "  %s --deny --message 'GUIDANCE'\n" prefix
  | Session.Decision.Request.Question _ ->
      Output.stdout_printf "  %s --answer 'YOUR ANSWER'\n" prefix
  | Session.Decision.Request.Plan _ ->
      Output.stdout_printf "  %s --approve-plan\n" prefix;
      Output.stdout_printf
        "  %s --approve-plan --message 'IMPLEMENTATION FEEDBACK'\n" prefix;
      Output.stdout_printf "  %s --reject-plan\n" prefix;
      Output.stdout_printf "  %s --reject-plan --message 'REVISION FEEDBACK'\n"
        prefix

let render_feed t ~client ~json ~session ~output_schema ~thinking ~terminal
    ~interrupted feed =
  let emit type_ fields = if json then emit_event ~session type_ fields in
  (* The structured answer is a projection: the last successfully-settled
     [structured_output] claim's validated input (its [Tool_started] fact carries
     it). [provider_failed] separates a provider fault — which precedes its
     terminal [Turn_settled] with a [Turn_provider_failed] fact — from an
     unmet-schema failure, which does not. *)
  let answer = ref None in
  let provider_failed = ref false in
  (* Per-step streaming state. [open_line] tracks whether the stdout text
     line has streamed bytes since the last newline; it is a ref so the
     force-quit [at_exit] can close it. [streamed] holds the sanitized bytes
     shown this step, reconciled against the authoritative fact at the step
     boundary; [superseded] marks that the step's assistant fact has landed, so
     a leftover same-step delta is dropped (the model-pulse omission law). *)
  let open_line = ref false in
  let streamed = Buffer.create 256 in
  let superseded = ref false in
  let close_line () =
    if !open_line then (
      Output.stdout_printf "\n";
      open_line := false)
  in
  (* A second Ctrl-C force-exits before [settled] runs; terminate a
     still-open captured line so the last bytes carry a trailing newline. *)
  at_exit (fun () -> if !open_line then Output.stdout_printf "\n");
  let reconcile full_text =
    (* The step boundary and reconcile point: the authoritative
       fact wins over the streamed preview. When the line is open, complete it —
       print the un-streamed suffix if the stream is a prefix of the fact, else
       close the partial line and print the fact fresh (a provider whose deltas
       do not sum to its terminal text). When nothing streamed this step, print
       the whole text at the boundary (a non-streaming provider); an empty
       tool-only step then prints nothing. Suppressed under [--json] (the
       authoritative aggregate is [turn.finished]) and under a schema (the
       answer supplants the prose). *)
    (if (not json) && not output_schema then
       let auth = Output.sanitize_c0 full_text in
       let streamed_text = Buffer.contents streamed in
       if !open_line then
         if String.starts_with ~prefix:streamed_text auth then
           Output.model_text
             (String.sub auth
                (String.length streamed_text)
                (String.length auth - String.length streamed_text))
         else (
           close_line ();
           Output.model_text auth)
       else if String.length auth > 0 then Output.model_text auth);
    superseded := true;
    open_line := false
  in
  let settled final_text outcome =
    (* The final step's assistant fact already reconciled and closed the stdout
       line; only a line left open by streamed deltas with no assistant fact — a
       provider fault — remains to close here. *)
    close_line ();
    match (outcome : Mentat_session.Turn.Outcome.t) with
    | Turn.Outcome.Completed when output_schema -> (
        match !answer with
        | Some value ->
            if json then
              emit "turn.finished"
                [
                  ("outcome", Output.Json.string "completed");
                  ("text", Output.Json.null);
                  ("output", value);
                ]
            else
              (* Verbatim validated JSON with a single trailing newline; not
                 routed through [Output.model_text]. *)
              Output.stdout_printf "%s\n" (Output.Json.to_string value);
            saved_hint session;
            Exit_status.Success
        | None ->
            saved_hint session;
            let message = "the run completed without a structured answer" in
            if json then (
              emit "run.output_schema_failed"
                [ ("message", Output.Json.string message) ];
              Exit_status.Failed)
            else Exit_status.runtime message)
    | Turn.Outcome.Completed ->
        emit "turn.finished"
          [
            ("outcome", Output.Json.string "completed");
            ("text", Output.Json.string_or_null final_text);
          ];
        saved_hint session;
        Exit_status.Success
    | Turn.Outcome.Step_limit ->
        emit "turn.finished" [ ("outcome", Output.Json.string "step_limit") ];
        saved_hint session;
        Exit_status.runtime "the turn hit its step limit"
    | Turn.Outcome.Interrupted { reason; _ } ->
        emit "turn.finished"
          [
            ("outcome", Output.Json.string "interrupted");
            ("reason", Output.Json.string_or_null reason);
          ];
        saved_hint session;
        (* A SIGINT-initiated interrupt exits 130 (you stopped it), distinct
           from a decision-Blocked exit 3 (the agent is waiting for you). *)
        if !interrupted then Exit_status.Interrupted
        else
          Exit_status.Blocked
            (Option.value ~default:"the turn was interrupted" reason)
    | Turn.Outcome.Failed { message }
      when output_schema && (not !provider_failed) && Option.is_none !answer ->
        (* Schema active, no provider fault, and no answer projected: the run
           settled without ever delivering a conforming structured answer (the
           retry budget was spent). A distinct [--json] type lets scripts tell it
           apart from a generic runtime failure. *)
        saved_hint session;
        if json then (
          emit "run.output_schema_failed"
            [ ("message", Output.Json.string message) ];
          Exit_status.Failed)
        else Exit_status.runtime message
    | Turn.Outcome.Failed { message } ->
        saved_hint session;
        if json then (
          emit "session.failed" [ ("message", Output.Json.string message) ];
          (* The failure is in the JSONL; exit 1 with no extra stderr. *)
          Exit_status.Failed)
        else Exit_status.runtime message
  in
  let rec loop final_text terminal =
    match Client.Feed.next feed with
    | Error e -> Exit_status.of_protocol_error e
    | Ok Client.Feed.Closed -> (
        match terminal with
        | Await_plan_build ->
            Exit_status.runtime
              "feed closed before the approved plan admitted its Build turn"
        | Same_turn _ | Plan_build_after _ ->
            Exit_status.runtime "feed closed before the turn settled")
    | Ok (Client.Feed.Item update) -> (
        match update with
        | Protocol.Update.Progress progress -> (
            (* Stream only the deltas of the turn whose settle we await,
               mirroring the TUI's applies-turn guard. *)
            let applies turn =
              match terminal with
              | Same_turn tid | Plan_build_after tid -> Turn.Id.equal turn tid
              | Await_plan_build -> false
            in
            match progress with
            | Protocol.Progress.Model { turn; update = model_update }
              when applies turn -> (
                match model_update with
                | Protocol.Progress.Model.Started ->
                    (* A new model step: discard the previous step's preview so
                       this step's deltas reconcile on their own. *)
                    Buffer.clear streamed;
                    superseded := false;
                    loop final_text terminal
                | Protocol.Progress.Model.Assistant_delta { text }
                  when (not output_schema) && not !superseded ->
                    if json then
                      emit "turn.text.delta"
                        [
                          ( "turn_id",
                            Output.Json.string (Turn.Id.to_string turn) );
                          ("text", Output.Json.string text);
                        ]
                    else (
                      Output.model_delta text;
                      Buffer.add_string streamed (Output.sanitize_c0 text);
                      open_line := true);
                    loop final_text terminal
                | Protocol.Progress.Model.Reasoning_delta { text }
                  when thinking && not output_schema ->
                    if json then
                      emit "turn.reasoning.delta"
                        [
                          ( "turn_id",
                            Output.Json.string (Turn.Id.to_string turn) );
                          ("text", Output.Json.string text);
                        ]
                    else (
                      close_line ();
                      Output.stderr_printf "%s" (Output.sanitize_c0 text));
                    loop final_text terminal
                | Protocol.Progress.Model.Assistant_delta _
                | Protocol.Progress.Model.Reasoning_delta _
                | Protocol.Progress.Model.Usage _
                | Protocol.Progress.Model.Retrying _ ->
                    loop final_text terminal)
            | Protocol.Progress.Model _ | Protocol.Progress.Model_download _
            | Protocol.Progress.Compaction _ ->
                loop final_text terminal)
        | Protocol.Update.Committed { fact; _ } -> (
            match fact with
            | Fact.Turn_assistant response ->
                let text = Mentat_llm.Response.text response in
                reconcile text;
                loop (Some text) terminal
            | Fact.Turn_assistant_interrupted { text } ->
                reconcile text;
                loop (Some text) terminal
            | Fact.Turn_started turn -> (
                let contract = Turn.contract turn in
                emit "turn.started"
                  [
                    ( "turn_id",
                      Output.Json.string (Turn.Id.to_string (Turn.id turn)) );
                    ( "mode",
                      Output.Json.string
                        (mode_string (Session.Contract.mode contract)) );
                    ( "origin",
                      Output.Json.string (turn_origin_string (Turn.origin turn))
                    );
                    ( "model",
                      Output.Json.string
                        (model_string (Session.Contract.model contract)) );
                  ];
                match terminal with
                | Await_plan_build
                  when Turn.Origin.equal (Turn.origin turn)
                         Turn.Origin.Plan_build ->
                    loop None (Same_turn (Turn.id turn))
                | Await_plan_build ->
                    Exit_status.runtime
                      (Format.asprintf
                         "approved plan admitted a %a turn instead of a \
                          plan-build turn"
                         Turn.Origin.pp (Turn.origin turn))
                | Same_turn _ | Plan_build_after _ -> loop final_text terminal)
            | Fact.Tool_started started ->
                let module Started = Session.Tool_claim.Started in
                let call = Started.call started in
                if
                  String.equal
                    (Mentat_llm.Tool.Call.name call)
                    Mentat_agent.Catalog.output_tool_name
                then answer := Some (Started.input started);
                if json then
                  emit "tool.started"
                    [
                      ( "claim_id",
                        Output.Json.string
                          (Session.Tool_claim.Id.to_string (Started.id started))
                      );
                      ( "call_id",
                        Output.Json.string (Mentat_llm.Tool.Call.id call) );
                      ( "tool",
                        Output.Json.string (Mentat_llm.Tool.Call.name call) );
                      ( "stage",
                        Output.Json.string
                          (Mentat_tool.Stage.to_string (Started.stage started))
                      );
                    ]
                else (
                  close_line ();
                  Output.stderr_printf "• tool %s\n"
                    (Mentat_llm.Tool.Call.name call));
                loop final_text terminal
            | Fact.Tool_returned { claim; _ } ->
                emit "tool.finished"
                  [
                    ( "claim_id",
                      Output.Json.string (Session.Tool_claim.Id.to_string claim)
                    );
                    ("outcome", Output.Json.string "returned");
                  ];
                loop final_text terminal
            | Fact.Tool_ambiguous { claim; _ } ->
                emit "tool.finished"
                  [
                    ( "claim_id",
                      Output.Json.string (Session.Tool_claim.Id.to_string claim)
                    );
                    ("outcome", Output.Json.string "ambiguous");
                  ];
                loop final_text terminal
            | Fact.Decision_resolved resolved ->
                emit "decision.resolved"
                  [
                    ( "decision_id",
                      Output.Json.string
                        (Session.Decision.Id.to_string
                           (Session.Decision.Resolved.id resolved)) );
                    ( "resolution",
                      owner_json Session.Decision.Resolved.jsont resolved );
                  ];
                loop final_text terminal
            | Fact.Compaction compaction ->
                emit "compaction.installed"
                  [
                    ( "reason",
                      Output.Json.string
                        (Session.Compaction.Reason.to_string
                           (Session.Compaction.reason compaction)) );
                    ( "compaction",
                      owner_json Session.Compaction.jsont compaction );
                  ];
                loop final_text terminal
            | Fact.Journal_goal update ->
                emit (goal_event_type update)
                  [ ("goal", owner_json Session.Goal.Update.jsont update) ];
                loop final_text terminal
            | Fact.Journal_queue update ->
                emit (queue_event_type update)
                  [ ("queue", owner_json Session.Queue.Update.jsont update) ];
                loop final_text terminal
            | Fact.Decision_requested req -> (
                let decision = Mentat_session.Decision.Requested.id req in
                let block () =
                  let id = Mentat_session.Decision.Id.to_string decision in
                  emit "session.waiting"
                    [
                      ("decision_id", Output.Json.string id);
                      ("decision", requested_json req);
                    ];
                  if not json then (
                    close_line ();
                    render_human_waiting ~session req);
                  Exit_status.Blocked
                    (Printf.sprintf
                       "session blocked on a %s decision (%s); resolve with \
                        `mentat run reply`"
                       (Mentat_session.Decision.Requested.tag req)
                       id)
                in
                match
                  ( Mentat_config.Resolved.get
                      Mentat_config.Field.permission_unattended
                      (Composition.config t),
                    Mentat_session.Decision.Requested.request req )
                with
                | ( Mentat_permission.Unattended.Deny,
                    Mentat_session.Decision.Request.Permission _ ) -> (
                    (* The unattended denial continues the turn: the request and
                       its resolution both cross the feed, so the stream pairs a
                       [decision.requested] with the [decision.resolved] the
                       denial commits, rather than a terminal [session.waiting]. *)
                    emit "decision.requested"
                      [
                        ( "decision_id",
                          Output.Json.string
                            (Session.Decision.Id.to_string decision) );
                        ("decision", requested_json req);
                      ];
                    match
                      Client.answer_unattended client ~session ~decision
                    with
                    | Ok () -> loop final_text terminal
                    | Error e -> Exit_status.of_protocol_error e)
                | _ -> block ())
            | Fact.Turn_settled { turn; outcome } -> (
                match terminal with
                | Same_turn expected when Turn.Id.equal turn expected ->
                    settled final_text outcome
                | Plan_build_after planning when Turn.Id.equal turn planning
                  -> (
                    match outcome with
                    | Turn.Outcome.Completed -> loop None Await_plan_build
                    | ( Turn.Outcome.Step_limit | Turn.Outcome.Interrupted _
                      | Turn.Outcome.Failed _ ) as outcome ->
                        settled final_text outcome)
                | Same_turn _ | Plan_build_after _ | Await_plan_build ->
                    loop final_text terminal)
            | Fact.Turn_provider_failed _ ->
                provider_failed := true;
                loop final_text terminal
            | _ -> loop final_text terminal))
  in
  loop None terminal

(* The SIGINT guard. — armed only while a turn is in flight.
   First Ctrl-C submits a graceful interrupt through the live client; a second
   forces an immediate exit 130. The store's durable interrupt event lets the
   next attach recover, so the hard escape hatch is always safe. *)
let with_sigint_guard t ~client ~session ~interrupted body =
  let clock = Eio.Stdenv.clock (Composition.stdenv t) in
  let count = Atomic.make 0 in
  let previous =
    Sys.signal Sys.sigint
      (Sys.Signal_handle (fun _ -> ignore (Atomic.fetch_and_add count 1)))
  in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigint previous)
    (fun () ->
      Eio.Switch.run (fun sw ->
          let finished = ref false in
          let announced = ref false in
          Eio.Fiber.fork ~sw (fun () ->
              let rec loop () =
                if !finished then ()
                else (
                  (match Atomic.get count with
                  | 0 -> ()
                  | 1 ->
                      if not !announced then (
                        announced := true;
                        interrupted := true;
                        (match
                           Command.interrupt ~session
                             ~reason:"interrupted by the user (SIGINT)" ()
                         with
                        | Ok cmd -> ignore (Client.submit client cmd)
                        | Error _ -> ());
                        Output.stderr_printf
                          "interrupting… press Ctrl-C again to force quit\n")
                  | _ -> exit 130);
                  Eio.Time.sleep clock 0.05;
                  loop ())
              in
              loop ());
          let status = body () in
          finished := true;
          status))

(* The shared drive: cred-gate, create-if-new, follow, submit, render. *)

(* [--skill NAME] pins one or more skills' guidance as durable user content
   ahead of the first prompt block (the ratified CLI design). The snapshot loads
   exactly as the composition builds the engine's, so pinned guidance matches
   what discovery surfaces; an unknown or malformed name is a usage error. *)
let skill_injections t ~names =
  match names with
  | [] -> Ok []
  | names -> (
      let user_config_file =
        Lpath.Abs.of_string_exn (User_dirs.config_file (Composition.dirs t))
      in
      let snapshot =
        Mentat_context.Skills.load ~stdenv:(Composition.stdenv t)
          ~builtins:Mentat_prompts.Skills.all ~config:(Composition.config t)
          ~trusted:(Composition.trusted t) ~root:(Composition.root t)
          ~cwd:(Composition.root t) ~user_config_file
      in
      match Mentat_context.Skills.injections snapshot ~names with
      | Ok texts -> Ok texts
      | Error message -> Error (Exit_status.usage message))

(* A headless [run "/name args"] intercepts only a KNOWN leading command
   token — the token is expanded through the client and the expansion submitted.
   An unmatched [/x] is not an error: it passes through as a literal prompt,
   preserving the behavior of a non-interactive surface where a [/]-leading
   string is plausibly literal, and matching the TUI's unrecognized-slash path.
   Adding a command file named [x] later thus changes a previously-literal [/x]
   prompt (the accepted, documented edge). *)
let split_slash_command prompt =
  if String.length prompt = 0 || prompt.[0] <> '/' then None
  else begin
    let body = String.sub prompt 1 (String.length prompt - 1) in
    let is_whitespace = function
      | ' ' | '\t' | '\n' | '\r' -> true
      | _ -> false
    in
    let n = String.length body in
    let stop = ref 0 in
    while !stop < n && not (is_whitespace body.[!stop]) do
      incr stop
    done;
    let token = String.sub body 0 !stop in
    let rest = String.sub body !stop (n - !stop) in
    (* Arguments trim surrounding horizontal whitespace only; internal bytes,
       newlines included, are preserved. *)
    let is_horizontal = function ' ' | '\t' -> true | _ -> false in
    let first = ref 0 and last = ref (String.length rest) in
    while !first < !last && is_horizontal rest.[!first] do
      incr first
    done;
    while !last > !first && is_horizontal rest.[!last - 1] do
      decr last
    done;
    Some (token, String.sub rest !first (!last - !first))
  end

let known_command client token =
  match Client.user_commands client with
  | Ok commands ->
      List.exists
        (fun (command : Protocol.User_command.t) ->
          String.equal
            (Protocol.User_command.Name.to_string
               command.Protocol.User_command.name)
            token)
        commands
  | Error _ -> false

(* The prompt content blocks: the command expansion for a known [/name] token,
   or a single literal text block otherwise. A blank expansion is the empty list,
   which [Command.prompt] rejects as an empty prompt. *)
let prompt_content ~client ~prompt =
  match split_slash_command prompt with
  | Some (token, arguments) when known_command client token ->
      Client.expand_command client ~name:token ~arguments
  | Some _ | None -> Ok [ Mentat_llm.Content.text prompt ]

(* Ephemeral runs stage the session store under a throwaway root removed when the
   run ends, so one-shot scripted calls leave nothing behind. A blocked ephemeral
   run is discarded with it: the exit code is the only durable fact. *)
let with_run_base ~cwd ~overrides ~ephemeral f =
  if not ephemeral then Composition.with_base ~cwd ~overrides f
  else
    let root = Filename.temp_dir "mentat-ephemeral" "" in
    Fun.protect
      ~finally:(fun () -> Fs.remove_tree root)
      (fun () -> Composition.with_base ~cwd ~overrides ~data_home:root f)

(* [--output-schema FILE] validation at the argv boundary: read the file
   (byte-capped; absent is distinguished from unreadable), require a JSON object,
   then subset-check it. Any failure is a clean usage error (exit 2) naming the
   offending keyword, never a raw exception repr. The raw JSON is kept — the
   engine seals it as the synthetic tool's input schema — while the parsed [t] is
   discarded (its only role here is the subset gate). *)
let resolve_output_schema = function
  | None -> Ok None
  | Some path -> (
      let usage message =
        Error (Exit_status.usage (Printf.sprintf "--output-schema: %s" message))
      in
      match Fs.read_capped ~max_bytes:Fs.default_max_bytes path with
      | Error message -> usage message
      | Ok None -> usage (Printf.sprintf "file not found: %s" path)
      | Ok (Some bytes) -> (
          match Jsont_bytesrw.decode_string Jsont.json bytes with
          | Error message ->
              usage (Printf.sprintf "%s is not valid JSON: %s" path message)
          | Ok (Jsont.Object _ as json) -> (
              match Mentat_llm.Schema.of_json json with
              | Ok _ -> Ok (Some json)
              | Error e -> usage (Mentat_llm.Schema.Error.message e))
          | Ok _ -> usage "the schema must be a JSON object"))

(* The capability gate on the {e effective} run model (flag or config), resolved
   here rather than via [check_explicit_model] so a config-default no-tools model
   cannot slip past. A tools-incapable model is a usage error (exit 2) because
   [--output-schema] is explicit, independent of how the model was chosen; a
   model that cannot resolve at all is a runtime failure (exit 1). *)
let schema_capability_gate t = function
  | None -> Ok ()
  | Some (_ : Jsont.json) -> (
      match Composition.default_catalog_model t with
      | Error message -> Error (Exit_status.runtime message)
      | Ok model ->
          if
            Mentat_provider.Model.has_capability
              Mentat_provider.Model.Capability.tools model
          then Ok ()
          else
            Error
              (Exit_status.usage
                 "--output-schema requires a model that supports tool calling, \
                  but the effective model does not"))

(* The client the run drives: the in-process one by default, or a driver the
   per-user daemon fills over the wire under [--attach], wrapped with this
   workspace's local command expansion. Everything downstream (submit, follow,
   sigint guard, JSONL projection, decision reply) is transport-neutral,
   so the only difference is where the engine runs. *)
let run_client t ~attach =
  if attach then
    Result.map (Composition.attach_client t) (Daemon.find_or_spawn t)
  else Composition.client t

(* [-i/--image FILE] (repeatable) attaches each image as model-visible media
   ahead of the prompt. The CLI reads the file bytes (it is the composition root)
   and hands them to the attach flow, which sniffs, downscales, validates, and
   stores them fence-free — attach runs after the session exists but before the
   turn's fence. Failure is loud and pre-turn: a missing file, a wrong format, or
   an over-cap image after downscale is a usage error naming the cap. *)
let attach_images t ~client ~session ~images =
  match images with
  | [] -> Ok []
  | _ -> (
      let config = Composition.config t in
      let caps =
        {
          Protocol.Attach.max_bytes =
            Mentat_config.Resolved.get Mentat_config.Field.image_max_bytes
              config;
          max_dimension =
            Mentat_config.Resolved.get Mentat_config.Field.image_max_dimension
              config;
          max_count =
            Mentat_config.Resolved.get Mentat_config.Field.image_max_count
              config;
        }
      in
      match Protocol.Attach.check_count caps ~count:(List.length images) with
      | Error rejection ->
          Error
            (Exit_status.usage
               (Format.asprintf "%a" Protocol.Attach.Rejection.pp rejection))
      | Ok () ->
          let rec loop acc = function
            | [] -> Ok (List.rev acc)
            | path :: rest -> (
                match Fs.read_capped ~max_bytes:(64 * 1024 * 1024) path with
                | Error message ->
                    Error
                      (Exit_status.usage
                         (Printf.sprintf "--image %s: %s" path message))
                | Ok None ->
                    Error
                      (Exit_status.usage
                         (Printf.sprintf "--image: file not found: %s" path))
                | Ok (Some bytes) -> (
                    match
                      Client.attach client ~session
                        (Protocol.Attach.Bytes { media_type = ""; bytes })
                    with
                    | Ok content -> loop (content :: acc) rest
                    | Error e ->
                        Error
                          (Exit_status.usage
                             (Format.asprintf "--image %s: %a" path
                                Protocol.Attach.Error.pp e))))
          in
          loop [] images)

let drive t ~attach ~json ~session ~create ~mode ~review ~title ~skill_texts
    ~images ~goal ~output_schema ~thinking ~prompt =
  (* Attribute this run's logs and any crash report to the session: a fresh
     session on [start] opened, an existing one on [resume] resumed. *)
  Log_setup.set_session
    ~event:(if create then Log_setup.Opened else Log_setup.Resumed)
    (Some (Id.to_string session));
  match schema_capability_gate t output_schema with
  | Error status -> status
  | Ok () -> (
      match run_client t ~attach with
      | Error status -> status
      | Ok client -> (
          (* Gate credential readiness before create, so a run that cannot
         authenticate never leaves an empty idle session behind. *)
          let cred_gate =
            if not create then Ok ()
            else
              match Composition.default_model t with
              | Error message -> Error (Exit_status.runtime message)
              | Ok model -> (
                  let provider = Mentat_llm.Model.provider model in
                  match Composition.provider_auth_satisfied t provider with
                  | Error error ->
                      Error
                        (Exit_status.runtime
                           (Mentat_provider_runtime.Error.message error))
                  | Ok true -> Ok ()
                  | Ok false ->
                      Error
                        (Exit_status.runtime
                           (Printf.sprintf
                              "no credential for provider %s; run `mentat auth \
                               login %s`"
                              (Mentat_llm.Provider.id provider)
                              (Mentat_llm.Provider.id provider))))
          in
          match cred_gate with
          | Error status -> status
          | Ok () -> (
              let created =
                if create then Client.create client ~id:session ?title ()
                else Ok ()
              in
              (* [--permission] is a session-scoped review posture the client sets
             before the turn seals its contract (there is no config field for
             it); it reaches the very next turn this run submits. *)
              let review_set =
                match created with
                | Error _ as e -> e
                | Ok () -> (
                    match review with
                    | None -> Ok ()
                    | Some behavior ->
                        Client.set_permission_review client ~session behavior)
              in
              match review_set with
              | Error e -> Exit_status.of_protocol_error e
              | Ok () -> (
                  (* Attach [-i] images after the session exists but before submit,
                 so their media blocks lead the prompt input. *)
                  match attach_images t ~client ~session ~images with
                  | Error status -> status
                  | Ok media_blocks -> (
                      (* A fresh, unnamed session earns a title from its first prompt.
                 It runs before submission: submitting attaches the turn's driver,
                 which holds the session's exclusive guard for the rest of the
                 process, and the rename needs that guard. *)
                      if create && Option.is_none title then
                        Auto_title.run t ~client ~session ~prompt;
                      if json then (
                        emit_run_started t ~session;
                        emit_event ~session "session.started" []);
                      let turn =
                        Turn.Id.of_string (Session_meta.fresh_id ~prefix:"t" ())
                      in
                      (* [--skill] guidance is durable user content ahead of the prompt
                 block, so pinned skills survive resume like a slash-expansion. A
                 known [/name] prompt is expanded here; anything else is a
                 literal prompt block. *)
                      match prompt_content ~client ~prompt with
                      | Error e -> Exit_status.of_protocol_error e
                      (* A blank command expansion is an empty prompt even when [--skill]
                 pins guidance ahead of it: reject it here, before the skill
                 content can carry a skills-only turn past the guard. *)
                      | Ok [] -> Exit_status.usage "prompt must not be empty"
                      | Ok prompt_blocks -> (
                          let input =
                            media_blocks
                            @ List.map Mentat_llm.Content.text skill_texts
                            @ prompt_blocks
                          in
                          match
                            Command.prompt ~session ~turn ~input ?mode ?goal
                              ?output_schema ()
                          with
                          | Error _ ->
                              Exit_status.usage "prompt must not be empty"
                          | Ok cmd -> (
                              (* Observation before admission: follow [`Now]
                     on the session's runtime-owned hub, then submit. The
                     pre-opened feed subscribes to the same per-session hub the
                     attaching driver adopts, so it tails every fact of the turn
                     [submit] admits — no fact slips between admission and the
                     follow. *)
                              match
                                Client.follow_session ~sw:(Composition.sw t)
                                  client session ~from:`Now
                              with
                              | Error e -> Exit_status.of_protocol_error e
                              | Ok feed -> (
                                  match Client.submit client cmd with
                                  | Error e ->
                                      Client.Feed.close feed;
                                      Exit_status.of_protocol_error e
                                  | Ok () ->
                                      let interrupted = ref false in
                                      let status =
                                        with_sigint_guard t ~client ~session
                                          ~interrupted (fun () ->
                                            render_feed t ~client ~json ~session
                                              ~output_schema:
                                                (Option.is_some output_schema)
                                              ~thinking
                                              ~terminal:(Same_turn turn)
                                              ~interrupted feed)
                                      in
                                      Client.Feed.close feed;
                                      status))))))))

let read_prompt raw =
  if String.equal raw "-" then
    String.trim (In_channel.input_all In_channel.stdin)
  else raw

(* Shared run options. — the boot-config and per-turn flags [start] and
   [resume] both accept. Every field but [mode] folds into the config overlay
   ({!build_overrides}); [mode] has no config field and is validated here into a
   {!Session.Contract.Mode.t} carried on the prompt command. *)

type run_options = {
  model : string option;
  reasoning : string option;
  mode : string option;
  permission : string option;
  permission_unattended : string option;
  sandbox : string option;
  require_sandbox : bool;
  max_steps : int option;
  output_schema : string option;
  thinking : bool;
  context : context_flags;
}

let model_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "model" ] ~docv:"MODEL" ~doc:"Override the model for this run.")

let reasoning_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "reasoning" ] ~docv:"EFFORT"
        ~doc:
          "Reasoning effort: none, minimal, low, medium, high, xhigh, or max.")

let mode_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "mode" ] ~docv:"MODE" ~doc:"Workflow mode: build, plan, or review.")

let permission_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "permission" ] ~docv:"MODE"
        ~doc:
          "Review posture: default enforces reviews; bypass allows reviews but \
           never denies.")

let permission_unattended_opt =
  Arg.(
    value
    & opt (some string) None
    & info
        [ "permission-unattended" ]
        ~docv:"POLICY"
        ~doc:
          "Unattended review policy: block parks the session (exit 3); deny \
           records a model-visible denial and continues.")

let sandbox_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "sandbox" ] ~docv:"MODE"
        ~doc:
          "Sandbox mode: read-only, workspace-write, danger-full-access, or \
           external-sandbox.")

let require_sandbox_flag =
  Arg.(
    value & flag
    & info [ "require-sandbox" ]
        ~doc:"Refuse to run unless the sandbox is enforceable or external.")

let max_steps_opt =
  Arg.(
    value
    & opt (some int) None
    & info [ "max-steps" ] ~docv:"N"
        ~doc:"Maximum model and tool steps for the turn.")

let output_schema_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "output-schema" ] ~docv:"FILE"
        ~doc:
          "Require the final answer to be JSON matching the JSON Schema in \
           FILE (a documented subset). The model delivers it through a \
           synthetic structured_output tool; the answer is emitted as JSON \
           (raw on stdout, or in the --json envelope's output member).")

let thinking_flag =
  Arg.(
    value & flag
    & info [ "thinking" ]
        ~doc:
          "Stream the model's reasoning summary to stderr as it arrives \
           (default off). Display only: it never reaches stdout or the \
           scriptable answer. Orthogonal to --reasoning, which sets effort.")

let no_instructions_flag =
  Arg.(
    value & flag
    & info [ "no-instructions" ]
        ~doc:"Disable global and project instruction files for this run.")

let project_instructions_flag =
  Arg.(
    value & flag
    & info [ "project-instructions" ]
        ~doc:"Force-enable project instruction files for this run.")

let no_project_instructions_flag =
  Arg.(
    value & flag
    & info
        [ "no-project-instructions" ]
        ~doc:"Disable project instruction files for this run.")

let no_skills_flag =
  Arg.(
    value & flag
    & info [ "no-skills" ]
        ~doc:"Disable skill discovery and the skill tool for this run.")

let context_term =
  Term.(
    const
      (fun
        no_instructions
        project_instructions
        no_project_instructions
        no_skills
      ->
        {
          no_instructions;
          project_instructions;
          no_project_instructions;
          no_skills;
        })
    $ no_instructions_flag $ project_instructions_flag
    $ no_project_instructions_flag $ no_skills_flag)

let run_options_term =
  Term.(
    const
      (fun
        model
        reasoning
        mode
        permission
        permission_unattended
        sandbox
        require_sandbox
        max_steps
        output_schema
        thinking
        context
      ->
        {
          model;
          reasoning;
          mode;
          permission;
          permission_unattended;
          sandbox;
          require_sandbox;
          max_steps;
          output_schema;
          thinking;
          context;
        })
    $ model_opt $ reasoning_opt $ mode_opt $ permission_opt
    $ permission_unattended_opt $ sandbox_opt $ require_sandbox_flag
    $ max_steps_opt $ output_schema_opt $ thinking_flag $ context_term)

let resolve_mode = function
  | None -> Ok None
  | Some raw -> Result.map Option.some (Argv.workflow_mode raw)

let resolve_review = function
  | None -> Ok None
  | Some raw -> Result.map Option.some (Argv.review_behavior raw)

(* A goal declared at start rides the prompt command as an optional payload; the
   engine mints its id at admission. [--goal-budget] is meaningless without an
   objective. *)
let resolve_goal ~goal_objective ~goal_budget =
  match (goal_objective, goal_budget) with
  | None, Some _ -> Error (Exit_status.usage "--goal-budget requires --goal")
  | None, None -> Ok None
  | Some raw, budget -> (
      let objective = String.trim raw in
      if String.is_empty objective then
        Error (Exit_status.usage "--goal must not be empty")
      else
        match budget with
        | Some n when n < 0 ->
            Error
              (Exit_status.usage
                 (Printf.sprintf "--goal-budget must not be negative, got %d" n))
        | _ -> Ok (Some { Command.objective; token_budget = budget }))

let overrides_of_options options =
  build_overrides ~model:options.model ~reasoning:options.reasoning
    ~permission_unattended:options.permission_unattended
    ~sandbox:options.sandbox ~require_sandbox:options.require_sandbox
    ~max_steps:options.max_steps ~context:options.context

(* start. *)

let start json id_opt title_opt options ephemeral attach skills images
    goal_objective goal_budget prompt_raw cwd =
  (let* id_opt = validate_id_opt id_opt in
   let* () =
     (* An ephemeral run is discarded with its store, so naming it for a later
        resume is contradictory. *)
     if ephemeral && Option.is_some id_opt then
       Error
         (Exit_status.usage
            "--ephemeral discards the session; it cannot be combined with --id")
     else Ok ()
   in
   let* () =
     (* An ephemeral throwaway store and the per-user daemon are contradictory:
        the daemon serves the shared store, not a caller's temp dir. *)
     if ephemeral && attach then
       Error
         (Exit_status.usage
            "--ephemeral cannot be combined with --attach (the daemon serves \
             the per-user store, not a throwaway one)")
     else Ok ()
   in
   let* title = Argv.title_opt title_opt in
   let* mode = resolve_mode options.mode in
   let* review = resolve_review options.permission in
   let* goal = resolve_goal ~goal_objective ~goal_budget in
   let* output_schema = resolve_output_schema options.output_schema in
   let* overrides = overrides_of_options options in
   Ok
     (with_run_base ~cwd ~overrides ~ephemeral (fun t ->
          match check_explicit_model t options.model with
          | Error status -> status
          | Ok () -> (
              match skill_injections t ~names:skills with
              | Error status -> status
              | Ok skill_texts ->
                  let prompt = read_prompt prompt_raw in
                  if String.length prompt = 0 then
                    Exit_status.usage "prompt must not be empty"
                  else
                    let session =
                      match id_opt with
                      | Some id -> id
                      | None ->
                          Id.of_string (Session_meta.fresh_id ~prefix:"s" ())
                    in
                    run_start_notices t ~json;
                    drive t ~attach ~json ~session ~create:true ~mode ~review
                      ~title ~skill_texts ~images ~goal ~output_schema
                      ~thinking:options.thinking ~prompt))))
  |> Exit_status.of_result

let prompt_req =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"PROMPT" ~doc:"The prompt; - reads stdin.")

let id_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "id" ] ~docv:"ID" ~doc:"Use this session id.")

let title_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "title" ] ~docv:"TITLE" ~doc:"Set the new session's title.")

let skill_opt =
  Arg.(
    value & opt_all string []
    & info [ "skill" ] ~docv:"NAME"
        ~doc:"Pin a skill's guidance ahead of the prompt. Repeatable.")

let image_opt =
  Arg.(
    value & opt_all string []
    & info [ "i"; "image" ] ~docv:"FILE"
        ~doc:
          "Attach an image file as model-visible content ahead of the prompt. \
           Repeatable.")

let ephemeral_flag =
  Arg.(
    value & flag
    & info [ "ephemeral" ]
        ~doc:
          "Persist nothing: stage the session under a throwaway store removed \
           when the run ends. A blocked ephemeral run cannot be resumed.")

let goal_objective_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "goal" ] ~docv:"OBJECTIVE"
        ~doc:"Declare a goal for this session, pursued across turns.")

let goal_budget_start_opt =
  Arg.(
    value
    & opt (some int) None
    & info [ "goal-budget" ] ~docv:"TOKENS"
        ~doc:"Token budget for the declared goal.")

let start_term =
  Term.(
    const start $ Cli_common.json $ id_opt $ title_opt $ run_options_term
    $ ephemeral_flag $ Cli_common.attach $ skill_opt $ image_opt
    $ goal_objective_opt $ goal_budget_start_opt $ prompt_req $ Cli_common.cwd)

let start_cmd =
  let doc = "Run a headless turn on a new session." in
  Cmd.v
    (Cmd.info "start" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term start_term)

(* resume. — a new turn on an existing session.

   A single-positional [SESSION_OR_PROMPT] matrix so
   [run resume --last "continue"] and [run resume <id> <prompt>] both parse,
   expressing both [--last PROMPT] and a no-prompt resume. *)

let resolve_resume_args ~last pos0 pos1 =
  match (last, pos0, pos1) with
  | true, Some prompt, None -> Ok (None, true, prompt)
  | true, Some _, Some _ -> Error "with --last, pass only a PROMPT"
  | true, None, _ -> Error "--last needs a PROMPT"
  | false, Some session, Some prompt -> Ok (Some session, false, prompt)
  | false, Some _, None -> Error "resume requires a PROMPT to start a new turn"
  | false, None, _ -> Error "resume requires SESSION or --last"

let resume json options attach images last pos0 pos1 cwd =
  (let* mode = resolve_mode options.mode in
   let* review = resolve_review options.permission in
   let* output_schema = resolve_output_schema options.output_schema in
   let* overrides = overrides_of_options options in
   Ok
     (Composition.with_base ~cwd ~overrides (fun t ->
          match check_explicit_model t options.model with
          | Error status -> status
          | Ok () -> (
              match resolve_resume_args ~last pos0 pos1 with
              | Error message -> Exit_status.usage message
              | Ok (session_opt, use_last, prompt_raw) -> (
                  match
                    Session_locate.resolve t ~session:session_opt ~last:use_last
                  with
                  | Error error -> Session_locate.status error
                  | Ok doc ->
                      let session = Document.id doc in
                      (* [--cwd] is an assertion — the session's
                          recorded cwd must equal the resolved workspace root, so
                          a stale or wrong [--cwd] refuses rather than running
                          against an arbitrary directory. *)
                      let recorded =
                        Session.Metadata.cwd
                          (Session.metadata (Document.session doc))
                      in
                      if not (Lpath.Abs.equal recorded (Composition.root t))
                      then
                        Exit_status.usage
                          (Printf.sprintf
                             "session %s was recorded in %s, not %s; resume \
                              from its workspace"
                             (Id.to_string session)
                             (Lpath.Abs.to_string recorded)
                             (Lpath.Abs.to_string (Composition.root t)))
                      else
                        let prompt = read_prompt prompt_raw in
                        if String.length prompt = 0 then
                          Exit_status.usage
                            "resume requires a PROMPT to start a new turn"
                        else (
                          run_start_notices t ~json;
                          drive t ~attach ~json ~session ~create:false ~mode
                            ~review ~title:None ~skill_texts:[] ~images
                            ~goal:None ~output_schema ~thinking:options.thinking
                            ~prompt))))))
  |> Exit_status.of_result

let resume_pos0 =
  Arg.(
    value
    & pos 0 (some string) None
    & info [] ~docv:"SESSION_OR_PROMPT"
        ~doc:"With --last, the PROMPT; otherwise the SESSION id or prefix.")

let resume_pos1 =
  Arg.(
    value
    & pos 1 (some string) None
    & info [] ~docv:"PROMPT" ~doc:"A new prompt; - reads stdin.")

let resume_cmd =
  let doc = "Run a new headless turn on an existing session." in
  Cmd.v
    (Cmd.info "resume" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const resume $ Cli_common.json $ run_options_term $ Cli_common.attach
         $ image_opt $ Cli_common.last $ resume_pos0 $ resume_pos1
         $ Cli_common.cwd))

(* reply. — submit one typed answer to the exact pending decision. *)

type reply_action =
  | Allow_once
  | Allow_conversation
  | Deny
  | Approve_plan
  | Reject_plan
  | Answer of string

let reply_action_name = function
  | Allow_once -> "--allow"
  | Allow_conversation -> "--allow-conversation"
  | Deny -> "--deny"
  | Approve_plan -> "--approve-plan"
  | Reject_plan -> "--reject-plan"
  | Answer _ -> "--answer"

let non_empty_text option raw =
  let text = String.trim raw in
  if String.is_empty text then
    Error (Exit_status.usage (option ^ " must not be empty"))
  else Ok text

let reply_choice ~decision ~allow ~allow_conversation ~deny ~approve_plan
    ~reject_plan ~answer ~message =
  let* decision =
    match decision with
    | None -> Error (Exit_status.usage "reply requires --decision DECISION_ID")
    | Some raw ->
        Result.map Session.Decision.Id.of_string
          (non_empty_text "--decision" raw)
  in
  let* answer =
    match answer with
    | None -> Ok None
    | Some raw -> Result.map Option.some (non_empty_text "--answer" raw)
  in
  let* message =
    match message with
    | None -> Ok None
    | Some raw -> Result.map Option.some (non_empty_text "--message" raw)
  in
  let actions =
    List.filter_map Fun.id
      [
        (if allow then Some Allow_once else None);
        (if allow_conversation then Some Allow_conversation else None);
        (if deny then Some Deny else None);
        (if approve_plan then Some Approve_plan else None);
        (if reject_plan then Some Reject_plan else None);
        Option.map (fun text -> Answer text) answer;
      ]
  in
  match actions with
  | [] when Option.is_some message ->
      Error
        (Exit_status.usage
           "--message requires --deny, --approve-plan, or --reject-plan")
  | [] ->
      Error
        (Exit_status.usage
           "choose one of --allow, --allow-conversation, --deny, \
            --approve-plan, --reject-plan, or --answer")
  | [ ((Approve_plan | Reject_plan) as action) ] ->
      Ok (decision, action, message)
  | [ (Allow_once | Allow_conversation | Answer _) ] when Option.is_some message
    ->
      Error
        (Exit_status.usage
           "--message is only valid with --deny, --approve-plan, or \
            --reject-plan")
  | [ Deny ] -> Ok (decision, Deny, message)
  | [ action ] -> Ok (decision, action, None)
  | _ ->
      Error
        (Exit_status.usage
           "choose exactly one of --allow, --allow-conversation, --deny, \
            --approve-plan, --reject-plan, or --answer")

let answer_request request action message =
  let module Requested = Session.Decision.Requested in
  let same_turn = Same_turn (Requested.turn request) in
  let mismatch () =
    Error
      (Exit_status.usage
         (Printf.sprintf "cannot use %s to answer a %s decision"
            (reply_action_name action) (Requested.tag request)))
  in
  match (Requested.request request, action) with
  | Session.Decision.Request.Permission _, Allow_once ->
      Ok
        ( Session.Decision.Answer.Permission
            { answer = Mentat_permission.Answer.once; message = None },
          same_turn )
  | Session.Decision.Request.Permission _, Allow_conversation ->
      Ok
        ( Session.Decision.Answer.Permission
            {
              answer = Mentat_permission.Answer.exact_for_conversation;
              message = None;
            },
          same_turn )
  | Session.Decision.Request.Permission _, Deny ->
      Ok
        ( Session.Decision.Answer.Permission
            { answer = Mentat_permission.Answer.deny; message },
          same_turn )
  | Session.Decision.Request.Question _, Answer text ->
      Ok
        ( Session.Decision.Answer.Question (Session.Question.Answer.free text),
          same_turn )
  | Session.Decision.Request.Plan plan, Approve_plan ->
      let answer =
        Session.Plan.Answer.approve ~body:plan ~context:`Current
          ?feedback:message ()
      in
      Ok
        ( Session.Decision.Answer.Plan answer,
          Plan_build_after (Requested.turn request) )
  | Session.Decision.Request.Plan _, Reject_plan ->
      let answer =
        match message with
        | None -> Session.Plan.Answer.keep_planning
        | Some feedback -> Session.Plan.Answer.revise feedback
      in
      Ok (Session.Decision.Answer.Plan answer, same_turn)
  | ( Session.Decision.Request.Permission _,
      (Approve_plan | Reject_plan | Answer _) )
  | ( Session.Decision.Request.Question _,
      (Allow_once | Allow_conversation | Deny | Approve_plan | Reject_plan) )
  | ( Session.Decision.Request.Plan _,
      (Allow_once | Allow_conversation | Deny | Answer _) ) ->
      mismatch ()

(* Goal actions and rename. — [reply] carries more than decision answers: the
   goal lifecycle verbs and the [--title] rename act on the session directly (no
   pending decision, no driven turn) and report the resulting state. Goals are
   declared by the model mid-turn; these verbs act on the current goal, whose id
   is read from the session view so a delayed command names the goal the user
   saw. *)

type goal_action = Pause | Resume of int option | Edit of string | Clear

let goal_action_tag = function
  | Pause -> "goal.paused"
  | Resume _ -> "goal.resumed"
  | Edit _ -> "goal.edited"
  | Clear -> "goal.cleared"

type goal_flags = {
  pause_goal : bool;
  resume_goal : bool;
  edit_goal : string option;
  clear_goal : bool;
  goal_budget : int option;
}

let resolve_goal_action gf =
  let* budget =
    match gf.goal_budget with
    | None -> Ok None
    | Some n when n >= 0 -> Ok (Some n)
    | Some n ->
        Error
          (Exit_status.usage
             (Printf.sprintf "--goal-budget must not be negative, got %d" n))
  in
  let* edit =
    match gf.edit_goal with
    | None -> Ok None
    | Some raw -> Result.map Option.some (non_empty_text "--edit-goal" raw)
  in
  let actions =
    List.filter_map Fun.id
      [
        (if gf.pause_goal then Some Pause else None);
        (if gf.resume_goal then Some (Resume budget) else None);
        Option.map (fun objective -> Edit objective) edit;
        (if gf.clear_goal then Some Clear else None);
      ]
  in
  match actions with
  | [] when Option.is_some budget ->
      Error (Exit_status.usage "--goal-budget requires --resume-goal")
  | [] -> Error (Exit_status.usage "choose a goal action")
  | [ (Resume _ as action) ] -> Ok action
  | [ _ ] when Option.is_some budget ->
      Error (Exit_status.usage "--goal-budget is only valid with --resume-goal")
  | [ action ] -> Ok action
  | _ ->
      Error
        (Exit_status.usage
           "choose exactly one of --pause-goal, --resume-goal, --edit-goal, or \
            --clear-goal")

let goal_command ~session ~goal action =
  let usage_of_invalid = function
    | Ok cmd -> Ok cmd
    | Error e -> Error (Exit_status.usage (Command.Invalid.message e))
  in
  match action with
  | Pause -> Ok (Command.goal_pause ~session ~goal)
  | Clear -> Ok (Command.goal_clear ~session ~goal)
  | Resume budget ->
      usage_of_invalid (Command.goal_resume ~session ~goal ?budget ())
  | Edit objective ->
      usage_of_invalid (Command.goal_edit ~session ~goal ~objective)

let report_goal ~json ~session ~tag goal =
  if json then
    emit_event ~session tag [ ("goal", owner_json Session.Goal.jsont goal) ]
  else
    Output.stderr_printf "mentat: goal %s: %s — %s\n"
      (Session.Goal.Id.to_string (Session.Goal.id goal))
      (Format.asprintf "%a" Session.Goal.Status.pp (Session.Goal.status goal))
      (Session.Goal.objective goal)

let run_goal_action ~json ~client ~session action =
  match Client.session client session with
  | Error e -> Exit_status.of_protocol_error e
  | Ok view -> (
      match Session.Session_view.goal view with
      | None ->
          Exit_status.usage
            (Printf.sprintf "no goal declared on %s" (Id.to_string session))
      | Some goal -> (
          match goal_command ~session ~goal:(Session.Goal.id goal) action with
          | Error status -> status
          | Ok cmd -> (
              match Client.submit client cmd with
              | Error e -> Exit_status.of_protocol_error e
              | Ok () ->
                  (* Report the goal's post-command state from a fresh read so
                     the reported status reflects the transition. *)
                  (match Client.session client session with
                  | Ok view ->
                      Option.iter
                        (report_goal ~json ~session
                           ~tag:(goal_action_tag action))
                        (Session.Session_view.goal view)
                  | Error _ -> ());
                  Exit_status.Success)))

let run_rename ~json ~client ~session ~title =
  match Client.rename client ~session ~title with
  | Error e -> Exit_status.of_protocol_error e
  | Ok () ->
      if json then
        emit_event ~session "session.renamed"
          [ ("title", Output.Json.string title) ]
      else
        Output.stderr_printf "mentat: session %s renamed\n"
          (Id.to_string session);
      Exit_status.Success

(* The decision-answer path: match the typed action against the exact pending
   decision, submit, and drive the continuation feed. *)
let run_decision t ~json ~client ~session ~decision ~action ~message =
  match Client.pending_decision client session with
  | Error e -> Exit_status.of_protocol_error e
  | Ok None ->
      Exit_status.usage
        (Printf.sprintf "no pending decision on %s" (Id.to_string session))
  | Ok (Some req) -> (
      let pending = Session.Decision.Requested.id req in
      if not (Session.Decision.Id.equal pending decision) then
        Exit_status.usage
          (Printf.sprintf "pending decision is %s, not %s"
             (Session.Decision.Id.to_string pending)
             (Session.Decision.Id.to_string decision))
      else
        match answer_request req action message with
        | Error status -> status
        | Ok (answer, terminal) -> (
            let cmd = Command.answer_decision ~session ~decision ~answer in
            match
              Client.follow_session ~sw:(Composition.sw t) client session
                ~from:`Now
            with
            | Error e -> Exit_status.of_protocol_error e
            | Ok feed -> (
                match Client.submit client cmd with
                | Error e ->
                    Client.Feed.close feed;
                    Exit_status.of_protocol_error e
                | Ok () ->
                    let interrupted = ref false in
                    let status =
                      with_sigint_guard t ~client ~session ~interrupted
                        (fun () ->
                          render_feed t ~client ~json ~session
                            ~output_schema:false ~thinking:false ~terminal
                            ~interrupted feed)
                    in
                    Client.Feed.close feed;
                    status)))

type reply_mode =
  | Decision_mode of (Session.Decision.Id.t * reply_action * string option)
  | Goal_mode of goal_action
  | Rename_mode of string

(* Exactly one reply mode: answer a decision, act on the goal, or rename. A
   no-mode invocation falls through to the decision path so its "choose one of
   …" message names the decision actions the user most likely wanted. *)
let resolve_reply_mode ~decision_present ~goal_present ~title_present
    ~decision_opt ~allow ~allow_conversation ~deny ~approve_plan ~reject_plan
    ~answer ~message ~title_opt gf =
  let decision () =
    let* decision, action, message =
      reply_choice ~decision:decision_opt ~allow ~allow_conversation ~deny
        ~approve_plan ~reject_plan ~answer ~message
    in
    Ok (Decision_mode (decision, action, message))
  in
  match (decision_present, goal_present, title_present) with
  | true, false, false | false, false, false -> decision ()
  | false, true, false ->
      let* action = resolve_goal_action gf in
      Ok (Goal_mode action)
  | false, false, true ->
      let* title =
        match title_opt with Some raw -> Argv.title raw | None -> Ok ""
      in
      Ok (Rename_mode title)
  | _ ->
      Error
        (Exit_status.usage
           "choose one of a decision answer, a goal action, or --title")

let reply json session_opt last decision_opt allow allow_conversation deny
    approve_plan reject_plan answer message title_opt gf cwd =
  (* The raw flag matrix and all free text are validated before composition. *)
  let decision_present =
    allow || allow_conversation || deny || approve_plan || reject_plan
    || Option.is_some answer
    || Option.is_some decision_opt
    || Option.is_some message
  in
  let goal_present =
    gf.pause_goal || gf.resume_goal
    || Option.is_some gf.edit_goal
    || gf.clear_goal
    || Option.is_some gf.goal_budget
  in
  let title_present = Option.is_some title_opt in
  (let* mode =
     resolve_reply_mode ~decision_present ~goal_present ~title_present
       ~decision_opt ~allow ~allow_conversation ~deny ~approve_plan ~reject_plan
       ~answer ~message ~title_opt gf
   in
   Ok
     (Composition.with_base ~cwd ~overrides:[] (fun t ->
          match Composition.client t with
          | Error status -> status
          | Ok client -> (
              match Session_locate.resolve t ~session:session_opt ~last with
              | Error error -> Session_locate.status error
              | Ok doc -> (
                  let session = Document.id doc in
                  Log_setup.set_session ~event:Log_setup.Resumed
                    (Some (Id.to_string session));
                  match mode with
                  | Goal_mode action ->
                      run_goal_action ~json ~client ~session action
                  | Rename_mode title ->
                      run_rename ~json ~client ~session ~title
                  | Decision_mode (decision, action, message) ->
                      run_decision t ~json ~client ~session ~decision ~action
                        ~message)))))
  |> Exit_status.of_result

let allow_flag =
  Arg.(value & flag & info [ "allow" ] ~doc:"Allow this operation once.")

let allow_conversation_flag =
  Arg.(
    value & flag
    & info [ "allow-conversation" ]
        ~doc:"Remember this exact access for the conversation.")

let deny_flag =
  Arg.(value & flag & info [ "deny" ] ~doc:"Deny the blocked operation.")

let decision_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "decision" ] ~docv:"DECISION_ID"
        ~doc:"Target this exact pending decision.")

let message_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "message" ] ~docv:"MESSAGE"
        ~doc:
          "Reviewer guidance for a denial, or plan implementation or revision \
           feedback.")

let approve_plan_flag =
  Arg.(
    value & flag
    & info [ "approve-plan" ]
        ~doc:"Approve the exact proposed plan in the current context.")

let reject_plan_flag =
  Arg.(
    value & flag
    & info [ "reject-plan" ] ~doc:"Keep planning or request a revision.")

let answer_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "answer" ] ~docv:"ANSWER"
        ~doc:"Answer the pending question with free text.")

let reply_title_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "title" ] ~docv:"TITLE" ~doc:"Rename the session.")

let pause_goal_flag =
  Arg.(value & flag & info [ "pause-goal" ] ~doc:"Pause the current goal.")

let resume_goal_flag =
  Arg.(
    value & flag
    & info [ "resume-goal" ]
        ~doc:"Resume a paused, blocked, or budget-limited goal.")

let edit_goal_opt =
  Arg.(
    value
    & opt (some string) None
    & info [ "edit-goal" ] ~docv:"OBJECTIVE"
        ~doc:"Replace the current goal's objective.")

let clear_goal_flag =
  Arg.(value & flag & info [ "clear-goal" ] ~doc:"Clear the current goal.")

let goal_budget_opt =
  Arg.(
    value
    & opt (some int) None
    & info [ "goal-budget" ] ~docv:"TOKENS"
        ~doc:"Reset the goal's token budget when resuming.")

let goal_flags_term =
  Term.(
    const (fun pause_goal resume_goal edit_goal clear_goal goal_budget ->
        { pause_goal; resume_goal; edit_goal; clear_goal; goal_budget })
    $ pause_goal_flag $ resume_goal_flag $ edit_goal_opt $ clear_goal_flag
    $ goal_budget_opt)

let reply_cmd =
  let doc = "Answer a decision, act on the goal, or rename a session." in
  Cmd.v
    (Cmd.info "reply" ~doc ~docs ~exits:Cli_common.exits)
    (Exit_status.term
       Term.(
         const reply $ Cli_common.json $ Cli_common.session_arg
         $ Cli_common.last $ decision_opt $ allow_flag $ allow_conversation_flag
         $ deny_flag $ approve_plan_flag $ reject_plan_flag $ answer_opt
         $ message_opt $ reply_title_opt $ goal_flags_term $ Cli_common.cwd))

let cmd =
  let doc = "Run headless agent turns." in
  Cmd.group
    ~default:(Exit_status.term start_term)
    (Cmd.info "run" ~doc ~docs ~exits:Cli_common.exits)
    [ start_cmd; resume_cmd; reply_cmd ]
