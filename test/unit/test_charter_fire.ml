(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Charter_fire]'s pure pieces: the sweep's delivery
   synthesis, the findings extraction from a run log, and the publication
   outcome folds. The pipeline's effectful spine — claim, receipts, spawn,
   reap, publish — is exercised end to end by the charter cram family. *)

open Windtrap

let arm events =
  {
    Mentat_charter.Charter.Trigger.Webhook.events;
    gate =
      {
        Mentat_charter.Charter.Gate.base = None;
        drafts = false;
        associations = None;
      };
  }

let pr number =
  {
    Charter_fire.Github.number;
    head_sha = String.make 40 'a';
    base_ref = "main";
    draft = false;
    author_association = "OWNER";
  }

let sweep_synthesis () =
  (match
     Charter_fire.sweep_events
       (arm [ "pull_request.opened" ])
       ~repo:"acme/widgets" [ pr 7; pr 9 ]
   with
  | [ first; second ] ->
      equal string ~msg:"admitted action" "opened"
        first.Mentat_charter.Event.Pull_request.action;
      equal string ~msg:"repo is the charter's" "acme/widgets"
        first.Mentat_charter.Event.Pull_request.repo;
      equal int ~msg:"listing order" 7
        first.Mentat_charter.Event.Pull_request.number;
      equal int ~msg:"second head" 9
        second.Mentat_charter.Event.Pull_request.number
  | events -> failf "expected two events, got %d" (List.length events));
  (match
     Charter_fire.sweep_events
       (arm [ "pull_request.synchronize"; "pull_request.opened" ])
       ~repo:"acme/widgets" [ pr 7 ]
   with
  | [ event ] ->
      equal string ~msg:"the first admitted review-class action wins"
        "synchronize" event.Mentat_charter.Event.Pull_request.action
  | events -> failf "expected one event, got %d" (List.length events));
  equal int ~msg:"no review-class action synthesizes nothing" 0
    (List.length
       (Charter_fire.sweep_events
          (arm [ "pull_request.closed" ])
          ~repo:"acme/widgets" [ pr 7 ]))

let findings_extraction () =
  let log =
    String.concat "\n"
      [
        {|{"schema_version":1,"type":"run.started"}|};
        "not json at all";
        {|{"schema_version":1,"type":"turn.finished","outcome":"completed","output":{"summary":"s","findings":[]}}|};
      ]
  in
  equal (option string) ~msg:"the output member, minified"
    (Some {|{"summary":"s","findings":[]}|})
    (Charter_fire.findings_of_log log);
  equal (option string) ~msg:"no finished line, no findings" None
    (Charter_fire.findings_of_log {|{"type":"run.started"}|});
  equal (option string) ~msg:"a null output is not a document" None
    (Charter_fire.findings_of_log
       {|{"type":"turn.finished","outcome":"completed","output":null}|});
  equal (option string) ~msg:"the last finished line wins"
    (Some {|{"summary":"late","findings":[]}|})
    (Charter_fire.findings_of_log
       (String.concat "\n"
          [
            {|{"type":"turn.finished","output":{"summary":"early","findings":[]}}|};
            {|{"type":"turn.finished","output":{"summary":"late","findings":[]}}|};
          ]))

let envelope_summary_method () =
  let named bytes =
    match Charter_fire.summary_method_of_envelope bytes with
    | Some `Post -> Some "POST"
    | Some `Patch -> Some "PATCH"
    | None -> None
  in
  equal (option string) ~msg:"a POST summary" (Some "POST")
    (named {|{"summary":{"method":"POST","path":"/x","body":{}},"review":[]}|});
  equal (option string) ~msg:"a PATCH summary" (Some "PATCH")
    (named {|{"summary":{"method":"PATCH","path":"/x","body":{}}}|});
  equal (option string) ~msg:"not an envelope" None (named "[]")

let publish_outcome_folds () =
  let outcome =
    String.concat "\n"
      [
        {|{"schema_version":1,"type":"github.publish","label":"aa11","status":201}|};
        {|{"schema_version":1,"type":"github.publish","label":"bb22","status":422,"error":"refused"}|};
        {|{"schema_version":1,"type":"github.publish","label":null,"status":200}|};
      ]
  in
  equal int ~msg:"one thread answered 2xx" 1
    (Charter_fire.publish_threads_posted outcome);
  is_true ~msg:"the summary landed" (Charter_fire.publish_summary_ok outcome);
  is_false ~msg:"a refused summary is not ok"
    (Charter_fire.publish_summary_ok
       {|{"type":"github.publish","label":null,"status":502}|});
  equal int ~msg:"an empty log posted nothing" 0
    (Charter_fire.publish_threads_posted "")

let () =
  run "mentat.charter_fire"
    [
      test "the sweep synthesizes admitted review-class deliveries"
        sweep_synthesis;
      test "the findings document is the last finished line's output"
        findings_extraction;
      test "the envelope names its summary method" envelope_summary_method;
      test "the poster's outcome log folds to the egress facts"
        publish_outcome_folds;
    ]
