(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Mentat_routine], the pure routine layer: the strict
   version-1 routine decode with its closed grant envelope, the policy
   digest, the four-kind receipt log codec, the narrow pull_request event
   decode and event identities, the admission gate, the budget fences, and
   the run session-id mint. Everything is pure, so the whole layer is
   exercised on strings and values directly.

   The modules live in the private [mentat_routine] library under
   [bin/routine/]. *)

open Windtrap
open Mentat_routine

let str_contains sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  n = 0 || go 0

let lowercase_hex s =
  String.length s > 0
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       s

(* Routine decode. *)

(* The reference routine: a webhook-and-cli review routine exercising every
   member the version-1 envelope admits. *)
let conforming =
  {|{
  "routine": 1,
  "name": "pr-review",
  "enabled": true,
  "workspace": { "repo": "invariant/spice" },
  "trigger": [
    { "kind": "github_webhook",
      "events": ["pull_request.opened", "pull_request.synchronize",
                 "pull_request.reopened", "pull_request.ready_for_review"],
      "gate": { "base": ["main"], "drafts": false,
                "associations": ["OWNER", "MEMBER", "COLLABORATOR"] } },
    { "kind": "cli" }
  ],
  "run": {
    "mode": "review",
    "model": "claude-sonnet-4-6", "reasoning": "high",
    "max_steps": 60,
    "prompt": "prompt.md",
    "output_schema": "findings.schema.json"
  },
  "budget": { "per_run": { "wall_clock": "15m" },
              "per_routine": { "usd_per_day": 15.0, "runs_per_hour": 6 } },
  "publish": { "github": "review-threads" },
  "notify": { "on": ["failed", "parked", "fenced"],
              "command": ["~/.config/mentat/notify.sh"] },
  "suppress": { "clean_run": "silent" }
}|}

let routine_decodes () =
  match Routine.decode conforming with
  | Error e -> failf "decode: %s" (Routine.Error.message e)
  | Ok c -> (
      equal string ~msg:"name" "pr-review" c.Routine.name;
      is_true ~msg:"enabled" c.Routine.enabled;
      equal string ~msg:"repo" "invariant/spice" c.Routine.repo;
      (match c.Routine.triggers with
      | [ Routine.Trigger.Github_webhook webhook; Routine.Trigger.Cli ] ->
          equal (list string) ~msg:"events"
            [
              "pull_request.opened";
              "pull_request.synchronize";
              "pull_request.reopened";
              "pull_request.ready_for_review";
            ]
            webhook.Routine.Trigger.Webhook.events;
          let gate = webhook.Routine.Trigger.Webhook.gate in
          equal
            (option (list string))
            ~msg:"gate base" (Some [ "main" ]) gate.Routine.Gate.base;
          is_false ~msg:"gate drafts" gate.Routine.Gate.drafts;
          equal
            (option (list string))
            ~msg:"gate associations"
            (Some [ "OWNER"; "MEMBER"; "COLLABORATOR" ])
            gate.Routine.Gate.associations
      | _ -> fail "expected a webhook arm then a cli arm");
      equal (option string) ~msg:"model" (Some "claude-sonnet-4-6")
        c.Routine.run.Routine.Run.model;
      equal (option string) ~msg:"reasoning" (Some "high")
        c.Routine.run.Routine.Run.reasoning;
      equal int ~msg:"max_steps" 60 c.Routine.run.Routine.Run.max_steps;
      equal string ~msg:"prompt" "prompt.md" c.Routine.run.Routine.Run.prompt;
      equal string ~msg:"output_schema" "findings.schema.json"
        c.Routine.run.Routine.Run.output_schema;
      equal (option bool) ~msg:"project_instructions" None
        c.Routine.run.Routine.Run.project_instructions;
      equal float_exact ~msg:"wall_clock is 15 minutes of seconds" 900.0
        c.Routine.budget.Routine.Budget.wall_clock;
      equal (option float_exact) ~msg:"usd_per_day" (Some 15.0)
        c.Routine.budget.Routine.Budget.usd_per_day;
      equal (option int) ~msg:"runs_per_hour" (Some 6)
        c.Routine.budget.Routine.Budget.runs_per_hour;
      (match c.Routine.notify with
      | Some notify ->
          equal (list string) ~msg:"notify.on"
            [ "failed"; "parked"; "fenced" ]
            (List.map Receipt.Transition.to_string notify.Routine.Notify.on);
          equal (list string) ~msg:"notify.command"
            [ "~/.config/mentat/notify.sh" ]
            notify.Routine.Notify.command
      | None -> fail "expected a notify contract");
      is_true ~msg:"suppress.clean_run" c.Routine.suppress_clean_run;
      (match Routine.webhook_arm c with
      | Some arm ->
          equal int ~msg:"webhook_arm is the webhook trigger" 4
            (List.length arm.Routine.Trigger.Webhook.events)
      | None -> fail "expected a webhook arm");
      match c.Routine.permission_unattended with
      | None -> ()
      | Some _ -> fail "expected no unattended override")

(* A minimal routine: only the required members, so every default shows. *)
let minimal =
  {|{
  "routine": 1,
  "name": "nightly",
  "workspace": { "repo": "invariant/spice" },
  "trigger": [ { "kind": "cli" } ],
  "run": { "mode": "review", "prompt": "prompt.md",
           "output_schema": "schema.json" },
  "budget": { "per_run": { "wall_clock": "1h" } },
  "publish": { "github": "review-threads" }
}|}

let routine_defaults () =
  match Routine.decode minimal with
  | Error e -> failf "decode: %s" (Routine.Error.message e)
  | Ok c ->
      is_true ~msg:"enabled defaults true" c.Routine.enabled;
      equal int ~msg:"max_steps defaults to 60" 60
        c.Routine.run.Routine.Run.max_steps;
      equal (option string) ~msg:"model defaults absent" None
        c.Routine.run.Routine.Run.model;
      equal float_exact ~msg:"1h of seconds" 3600.0
        c.Routine.budget.Routine.Budget.wall_clock;
      equal (option float_exact) ~msg:"no spend meter" None
        c.Routine.budget.Routine.Budget.usd_per_day;
      equal (option int) ~msg:"no rate meter" None
        c.Routine.budget.Routine.Budget.runs_per_hour;
      is_false ~msg:"clean runs announce by default" c.Routine.suppress_clean_run;
      is_true ~msg:"no notify contract" (Option.is_none c.Routine.notify);
      match c.Routine.triggers with
      | [ Routine.Trigger.Cli ] -> ()
      | _ -> fail "expected exactly the cli arm"

let gate_defaults_when_omitted () =
  let payload =
    {|{
  "routine": 1,
  "name": "n",
  "workspace": { "repo": "o/r" },
  "trigger": [ { "kind": "github_webhook",
                 "events": ["pull_request.opened"] } ],
  "run": { "mode": "review", "prompt": "p.md", "output_schema": "s.json" },
  "budget": { "per_run": { "wall_clock": "5m" } },
  "publish": { "github": "review-threads" }
}|}
  in
  match Routine.decode payload with
  | Error e -> failf "decode: %s" (Routine.Error.message e)
  | Ok c -> (
      match c.Routine.triggers with
      | [ Routine.Trigger.Github_webhook webhook ] ->
          let gate = webhook.Routine.Trigger.Webhook.gate in
          equal (option (list string)) ~msg:"any base" None
            gate.Routine.Gate.base;
          is_false ~msg:"drafts refused by default" gate.Routine.Gate.drafts;
          equal (option (list string)) ~msg:"any author" None
            gate.Routine.Gate.associations
      | _ -> fail "expected exactly the webhook arm")

(* Routine payload surgery: a fixture with one member line replaced, so
   each rejection test states only its delta. *)
let replace_line ~payload ~old_string ~new_string =
  let lines = String.split_on_char '\n' payload in
  let count = ref 0 in
  let rewritten =
    List.map
      (fun line ->
        if str_contains old_string line then (
          incr count;
          new_string)
        else line)
      lines
  in
  if !count <> 1 then
    failf "replace_line: %S matched %d lines" old_string !count
  else String.concat "\n" rewritten

let amended ~old_string ~new_string =
  replace_line ~payload:conforming ~old_string ~new_string

let rejects ~msg ?expect payload =
  match Routine.decode payload with
  | Ok _ -> failf "%s: decode accepted the payload" msg
  | Error e -> (
      let message = Routine.Error.message e in
      match expect with
      | None -> ()
      | Some needle ->
          if not (str_contains needle message) then
            failf "%s: message %S does not name %S" msg message needle)

let routine_envelope_is_closed () =
  rejects ~msg:"malformed JSON" "{";
  rejects ~msg:"non-object document" ~expect:"JSON object" "[]";
  rejects ~msg:"future version" ~expect:"unsupported version 2"
    (amended ~old_string:{|"routine": 1|} ~new_string:{|  "routine": 2,|});
  rejects ~msg:"goal does not exist" ~expect:{|unknown member "goal"|}
    (amended ~old_string:{|"routine": 1|}
       ~new_string:{|  "routine": 1, "goal": "ship it",|});
  rejects ~msg:"write sandbox refused" ~expect:{|only "read-only"|}
    (amended ~old_string:{|"routine": 1|}
       ~new_string:{|  "routine": 1, "sandbox": "workspace-write",|});
  rejects ~msg:"unattended review refused" ~expect:{|"deny" or "block"|}
    (amended ~old_string:{|"routine": 1|}
       ~new_string:{|  "routine": 1, "permission_unattended": "review",|});
  rejects ~msg:"unknown workspace member" ~expect:{|unknown member "mirror"|}
    (amended ~old_string:{|"workspace": { "repo": "invariant/spice" },|}
       ~new_string:
         {|  "workspace": { "repo": "invariant/spice", "mirror": "x" },|});
  rejects ~msg:"unknown run member" ~expect:{|unknown member "tools"|}
    (amended ~old_string:{|"mode": "review",|}
       ~new_string:{|    "mode": "review", "tools": ["bash"],|});
  rejects ~msg:"unknown gate member" ~expect:{|unknown member "labels"|}
    (amended
       ~old_string:{|"gate": { "base": ["main"], "drafts": false,|}
       ~new_string:
         {|      "gate": { "labels": [], "base": ["main"], "drafts": false,|});
  rejects ~msg:"unknown budget member" ~expect:{|unknown member "per_month"|}
    (amended
       ~old_string:{|"budget": { "per_run": { "wall_clock": "15m" },|}
       ~new_string:
         {|  "budget": { "per_month": {}, "per_run": { "wall_clock": "15m" },|});
  rejects ~msg:"unknown notify member" ~expect:{|unknown member "channel"|}
    (amended ~old_string:{|"notify": { "on": ["failed", "parked", "fenced"],|}
       ~new_string:
         {|  "notify": { "channel": "bell", "on": ["failed", "parked", "fenced"],|});
  rejects ~msg:"unknown suppress member" ~expect:{|unknown member "noise"|}
    (amended ~old_string:{|"suppress": { "clean_run": "silent" }|}
       ~new_string:{|  "suppress": { "clean_run": "silent", "noise": true }|});
  rejects ~msg:"unknown trigger member"
    ~expect:{|trigger[1]: unknown member "secret"|}
    (amended ~old_string:{|{ "kind": "cli" }|}
       ~new_string:{|    { "kind": "cli", "secret": "s" }|});
  rejects ~msg:"non-review mode" ~expect:{|run.mode: v1 admits only "review"|}
    (amended ~old_string:{|"mode": "review",|}
       ~new_string:{|    "mode": "build",|});
  rejects ~msg:"skills cannot be pinned"
    ~expect:{|run.skills: v1 admits only an empty list|}
    (amended ~old_string:{|"mode": "review",|}
       ~new_string:{|    "mode": "review", "skills": ["review"],|});
  rejects ~msg:"clean_run vocabulary is closed"
    ~expect:{|suppress.clean_run: v1 admits only "silent"|}
    (amended ~old_string:{|"suppress": { "clean_run": "silent" }|}
       ~new_string:{|  "suppress": { "clean_run": "loud" }|});
  rejects ~msg:"publish vocabulary is closed"
    ~expect:{|publish.github: v1 admits only "review-threads"|}
    (amended ~old_string:{|"publish": { "github": "review-threads" },|}
       ~new_string:{|  "publish": { "github": "issues" },|});
  rejects ~msg:"missing name" ~expect:{|missing member "name"|}
    (amended ~old_string:{|"name": "pr-review",|} ~new_string:"");
  rejects ~msg:"missing workspace" ~expect:{|missing member "workspace"|}
    (amended ~old_string:{|"workspace": { "repo": "invariant/spice" },|}
       ~new_string:"");
  rejects ~msg:"missing publish" ~expect:{|missing member "publish"|}
    (amended ~old_string:{|"publish": { "github": "review-threads" },|}
       ~new_string:"");
  rejects ~msg:"missing prompt" ~expect:{|run: missing member "prompt"|}
    (amended ~old_string:{|"prompt": "prompt.md",|} ~new_string:"");
  rejects ~msg:"missing wall_clock"
    ~expect:{|budget.per_run: missing member "wall_clock"|}
    (amended ~old_string:{|"budget": { "per_run": { "wall_clock": "15m" },|}
       ~new_string:{|  "budget": { "per_run": {},|});
  rejects ~msg:"name grammar"
    ~expect:"name: must contain only letters, digits"
    (amended ~old_string:{|"name": "pr-review",|}
       ~new_string:{|  "name": "pr review",|});
  rejects ~msg:"repo shape" ~expect:"workspace.repo"
    (amended ~old_string:{|"workspace": { "repo": "invariant/spice" },|}
       ~new_string:{|  "workspace": { "repo": "not-a-repo" },|});
  rejects ~msg:"bad duration" ~expect:"budget.per_run.wall_clock"
    (amended ~old_string:{|"budget": { "per_run": { "wall_clock": "15m" },|}
       ~new_string:{|  "budget": { "per_run": { "wall_clock": "soon" },|});
  rejects ~msg:"zero duration" ~expect:"budget.per_run.wall_clock"
    (amended ~old_string:{|"budget": { "per_run": { "wall_clock": "15m" },|}
       ~new_string:{|  "budget": { "per_run": { "wall_clock": "0m" },|});
  rejects ~msg:"bad reasoning" ~expect:"run.reasoning"
    (amended ~old_string:{|"model": "claude-sonnet-4-6", "reasoning": "high",|}
       ~new_string:{|    "model": "claude-sonnet-4-6", "reasoning": "hard",|});
  rejects ~msg:"absolute prompt path"
    ~expect:"run.prompt: must be a relative path"
    (amended ~old_string:{|"prompt": "prompt.md",|}
       ~new_string:{|    "prompt": "/etc/passwd",|});
  rejects ~msg:"traversing prompt path" ~expect:"run.prompt"
    (amended ~old_string:{|"prompt": "prompt.md",|}
       ~new_string:{|    "prompt": "../other/prompt.md",|});
  rejects ~msg:"prompt under secrets/" ~expect:"run.prompt"
    (amended ~old_string:{|"prompt": "prompt.md",|}
       ~new_string:{|    "prompt": "secrets/prompt.md",|});
  rejects ~msg:"prompt naming a reserved file" ~expect:"run.prompt"
    (amended ~old_string:{|"prompt": "prompt.md",|}
       ~new_string:{|    "prompt": "routine.json",|});
  rejects ~msg:"unknown association"
    ~expect:{|unknown author association "FRIEND"|}
    (amended
       ~old_string:{|"associations": ["OWNER", "MEMBER", "COLLABORATOR"] } },|}
       ~new_string:{|                "associations": ["FRIEND"] } },|});
  rejects ~msg:"duplicate association" ~expect:"duplicate entry"
    (amended
       ~old_string:{|"associations": ["OWNER", "MEMBER", "COLLABORATOR"] } },|}
       ~new_string:{|                "associations": ["OWNER", "OWNER"] } },|});
  rejects ~msg:"empty base allowlist" ~expect:"must be a non-empty array"
    (amended ~old_string:{|"gate": { "base": ["main"], "drafts": false,|}
       ~new_string:{|      "gate": { "base": [], "drafts": false,|});
  rejects ~msg:"bad event name" ~expect:"trigger[0].events[0]"
    (amended
       ~old_string:{|"events": ["pull_request.opened", "pull_request.synchronize",|}
       ~new_string:{|      "events": ["push", "pull_request.synchronize",|});
  rejects ~msg:"typo'd pull_request action"
    ~expect:{|unknown pull_request action "sychronize"|}
    (amended
       ~old_string:{|"events": ["pull_request.opened", "pull_request.synchronize",|}
       ~new_string:{|      "events": ["pull_request.sychronize",|});
  (* The closed vocabulary tracks GitHub's documented enum: every documented
     action must load, [stacked] being the newest admission. *)
  (match
     Routine.decode
       (amended
          ~old_string:
            {|"events": ["pull_request.opened", "pull_request.synchronize",|}
          ~new_string:
            {|      "events": ["pull_request.stacked", "pull_request.synchronize",|})
   with
  | Ok _ -> ()
  | Error e ->
      failf "a documented pull_request action must load: %s"
        (Routine.Error.message e));
  rejects ~msg:"unknown notify transition" ~expect:"notify.on[0]"
    (amended ~old_string:{|"notify": { "on": ["failed", "parked", "fenced"],|}
       ~new_string:{|  "notify": { "on": ["clean_run", "parked", "fenced"],|});
  rejects ~msg:"negative usd fence" ~expect:"budget.per_routine.usd_per_day"
    (amended
       ~old_string:{|"per_routine": { "usd_per_day": 15.0, "runs_per_hour": 6 } },|}
       ~new_string:
         {|              "per_routine": { "usd_per_day": -1.0, "runs_per_hour": 6 } },|});
  rejects ~msg:"zero rate fence" ~expect:"budget.per_routine.runs_per_hour"
    (amended
       ~old_string:{|"per_routine": { "usd_per_day": 15.0, "runs_per_hour": 6 } },|}
       ~new_string:
         {|              "per_routine": { "usd_per_day": 15.0, "runs_per_hour": 0 } },|})

let routine_trigger_kinds () =
  let with_arm arm =
    amended ~old_string:{|{ "kind": "cli" }|} ~new_string:("    " ^ arm)
  in
  rejects ~msg:"unknown kind" ~expect:{|unknown trigger kind "webhookz"|}
    (with_arm {|{ "kind": "webhookz" }|});
  List.iter
    (fun kind ->
      rejects
        ~msg:(kind ^ " parses and is refused")
        ~expect:
          (Printf.sprintf "%S parses but is refused as unimplemented" kind)
        (with_arm (Printf.sprintf {|{ "kind": %S }|} kind)))
    [ "schedule"; "agent_message"; "self_schedule" ];
  rejects ~msg:"retention knob parses and is refused until a reaper exists"
    ~expect:
      "retention.keep_failed_worktrees: parses but is refused as unimplemented"
    (amended ~old_string:{|"suppress": { "clean_run": "silent" }|}
       ~new_string:
         {|  "suppress": { "clean_run": "silent" },
  "retention": { "keep_failed_worktrees": 3 }|});
  rejects ~msg:"duplicate kind" ~expect:{|duplicate trigger kind "cli"|}
    (amended ~old_string:{|{ "kind": "cli" }|}
       ~new_string:{|    { "kind": "cli" }, { "kind": "cli" }|});
  rejects ~msg:"empty trigger list"
    ~expect:"trigger: must be a non-empty array"
    (replace_line ~payload:minimal
       ~old_string:{|"trigger": [ { "kind": "cli" } ],|}
       ~new_string:{|  "trigger": [],|})

(* Policy digest. *)

let policy_digest_identity () =
  let digest =
    Routine.policy_digest ~routine_json:conforming ~prompt:"Review the diff."
      ~output_schema:"{}"
  in
  equal int ~msg:"16 characters" 16 (String.length digest);
  is_true ~msg:"lowercase hexadecimal" (lowercase_hex digest);
  (* The derivation is a wire format: digests persist in receipts and in
     trigger-origin mail, so a silent change would re-run every head. *)
  equal string ~msg:"pinned derivation" "47f6195b5839d948" digest;
  equal string ~msg:"deterministic" digest
    (Routine.policy_digest ~routine_json:conforming
       ~prompt:"Review the diff." ~output_schema:"{}");
  let differs ~msg other = is_true ~msg (not (String.equal digest other)) in
  differs ~msg:"routine.json moves the digest"
    (Routine.policy_digest ~routine_json:(conforming ^ " ")
       ~prompt:"Review the diff." ~output_schema:"{}");
  differs ~msg:"prompt moves the digest"
    (Routine.policy_digest ~routine_json:conforming
       ~prompt:"Review the diff!" ~output_schema:"{}");
  differs ~msg:"schema moves the digest"
    (Routine.policy_digest ~routine_json:conforming
       ~prompt:"Review the diff." ~output_schema:"{ }");
  is_true ~msg:"framing forbids cross-file byte shifts"
    (not
       (String.equal
          (Routine.policy_digest ~routine_json:"a" ~prompt:"bc"
             ~output_schema:"d")
          (Routine.policy_digest ~routine_json:"ab" ~prompt:"c"
             ~output_schema:"d")))

(* Receipts. *)

let sample_identity =
  "github:invariant/spice#312@9c41f2e8a5b06c7d9e0f1a2b3c4d5e6f70819202:head"

let sample_digest = "0123456789abcdef"

let receipt ?(at = 90061.0) kind =
  { Receipt.at; identity = sample_identity; digest = sample_digest; kind }

let usage_json =
  Jsont.Json.object'
    [
      Jsont.Json.mem (Jsont.Json.name "input") (Jsont.Json.int 1200);
      Jsont.Json.mem (Jsont.Json.name "output") (Jsont.Json.int 340);
    ]

let sample_session = "c-fdfec12877f34773"

let all_kinds =
  [
    Receipt.Kind.Delivery None;
    Receipt.Kind.Delivery
      (Some
         {
           Receipt.Delivery.action = "opened";
           base_ref = "main";
           draft = false;
           author_association = "OWNER";
         });
    Receipt.Kind.Disposition
      (Receipt.Disposition.Spawned { session = sample_session });
    Receipt.Kind.Disposition (Receipt.Disposition.Skipped "draft pull requests are not admitted");
    Receipt.Kind.Disposition Receipt.Disposition.Dup;
    Receipt.Kind.Disposition (Receipt.Disposition.Fenced Receipt.Meter.Usd_per_day);
    Receipt.Kind.Disposition Receipt.Disposition.Already_exists;
    Receipt.Kind.Disposition Receipt.Disposition.Superseded;
    Receipt.Kind.Disposition (Receipt.Disposition.Refused "credential:read.token");
    Receipt.Kind.Disposition
      (Receipt.Disposition.Reaped
         {
           session = sample_session;
           exit = 0;
           head = Receipt.Head.Settled;
           usage = usage_json;
           usd = Some 1.25;
           cause = Receipt.Cause.Exited;
         });
    Receipt.Kind.Disposition
      (Receipt.Disposition.Reaped
         {
           session = sample_session;
           exit = 130;
           head = Receipt.Head.Interrupted;
           usage = usage_json;
           usd = None;
           cause = Receipt.Cause.Wall_clock;
         });
    Receipt.Kind.Disposition
      (Receipt.Disposition.Reaped
         {
           session = sample_session;
           exit = 137;
           head = Receipt.Head.Unsettled;
           usage = usage_json;
           usd = Some 0.5;
           cause = Receipt.Cause.Interrupted;
         });
    Receipt.Kind.Egress { summary = `Created; threads = 3 };
    Receipt.Kind.Egress { summary = `None_needed; threads = 0 };
    Receipt.Kind.Egress { summary = `Skipped_no_token; threads = 0 };
    Receipt.Kind.Alert
      {
        transition = Receipt.Transition.Fenced;
        window = `Meter Receipt.Meter.Usd_per_day;
      };
    Receipt.Kind.Alert
      { transition = Receipt.Transition.Parked; window = `Identity };
  ]

let receipt_round_trips () =
  List.iter
    (fun kind ->
      let original = receipt kind in
      let line = Receipt.encode original in
      is_false ~msg:"one line"
        (String.exists (fun c -> Char.equal c '\n') line);
      match Receipt.decode line with
      | Error e ->
          failf "decode of %s: %s" line (Receipt.Error.message e)
      | Ok read ->
          equal float_exact ~msg:"at survives" original.Receipt.at
            read.Receipt.at;
          equal string ~msg:"identity survives" original.Receipt.identity
            read.Receipt.identity;
          equal string ~msg:"digest survives" original.Receipt.digest
            read.Receipt.digest;
          (* Value equality through the codec: re-encoding what decode read
             reproduces the original line byte for byte. *)
          equal string ~msg:"re-encode reproduces the line" line
            (Receipt.encode read))
    all_kinds;
  let reaped =
    receipt
      (Receipt.Kind.Disposition
         (Receipt.Disposition.Reaped
            {
              session = sample_session;
              exit = 1;
              head = Receipt.Head.Unsettled;
              usage = usage_json;
              usd = None;
              cause = Receipt.Cause.Recovered;
            }))
  in
  match Receipt.decode (Receipt.encode reaped) with
  | Error e -> failf "decode: %s" (Receipt.Error.message e)
  | Ok read -> (
      match read.Receipt.kind with
      | Receipt.Kind.Disposition
          (Receipt.Disposition.Reaped
             { session; exit; head; usd; cause; usage = _ }) ->
          equal string ~msg:"session survives" sample_session session;
          equal int ~msg:"exit" 1 exit;
          is_true ~msg:"head" (Receipt.Head.equal Receipt.Head.Unsettled head);
          equal (option float_exact) ~msg:"unpriced usd survives" None usd;
          is_true ~msg:"cause"
            (Receipt.Cause.equal Receipt.Cause.Recovered cause)
      | _ -> fail "expected a reaped disposition")

let receipt_rejects ~msg ?expect line =
  match Receipt.decode line with
  | Ok _ -> failf "%s: decode accepted the line" msg
  | Error e -> (
      let message = Receipt.Error.message e in
      match expect with
      | None -> ()
      | Some needle ->
          if not (str_contains needle message) then
            failf "%s: message %S does not name %S" msg message needle)

let receipt_decode_is_strict () =
  let base = {|"at":90061,"identity":"cli:0123456789abcdef:k","digest":"ab"|} in
  receipt_rejects ~msg:"malformed JSON" "{";
  receipt_rejects ~msg:"non-object line" ~expect:"JSON object" "[]";
  receipt_rejects ~msg:"unknown kind" ~expect:{|unknown receipt kind "audit"|}
    (Printf.sprintf {|{"kind":"audit",%s}|} base);
  receipt_rejects ~msg:"missing kind" ~expect:{|missing member "kind"|}
    (Printf.sprintf {|{%s}|} base);
  receipt_rejects ~msg:"unknown member"
    ~expect:{|unknown member "note"|}
    (Printf.sprintf {|{"kind":"delivery",%s,"note":"n"}|} base);
  receipt_rejects ~msg:"reason does not belong on spawned"
    ~expect:{|unknown member "reason"|}
    (Printf.sprintf
       {|{"kind":"disposition",%s,"disposition":"spawned","session":"c-1","reason":"r"}|}
       base);
  receipt_rejects ~msg:"spawned requires the session"
    ~expect:{|missing member "session"|}
    (Printf.sprintf {|{"kind":"disposition",%s,"disposition":"spawned"}|} base);
  receipt_rejects ~msg:"empty session" ~expect:"session"
    (Printf.sprintf
       {|{"kind":"disposition",%s,"disposition":"spawned","session":""}|}
       base);
  receipt_rejects ~msg:"reaped requires the session"
    ~expect:{|missing member "session"|}
    (Printf.sprintf
       {|{"kind":"disposition",%s,"disposition":"reaped","exit":0,"head":"settled","usage":{},"cause":"exited"}|}
       base);
  receipt_rejects ~msg:"missing at" ~expect:{|missing member "at"|}
    {|{"kind":"delivery","identity":"i","digest":"ab"}|};
  receipt_rejects ~msg:"negative at" ~expect:"at"
    {|{"kind":"delivery","at":-1,"identity":"i","digest":"ab"}|};
  receipt_rejects ~msg:"empty identity" ~expect:"identity"
    {|{"kind":"delivery","at":1,"identity":"","digest":"ab"}|};
  receipt_rejects ~msg:"digest must be hex" ~expect:"digest"
    {|{"kind":"delivery","at":1,"identity":"i","digest":"XY"}|};
  receipt_rejects ~msg:"unknown disposition"
    ~expect:{|unknown disposition "vanished"|}
    (Printf.sprintf {|{"kind":"disposition",%s,"disposition":"vanished"}|} base);
  receipt_rejects ~msg:"unknown meter" ~expect:{|unknown meter "tokens"|}
    (Printf.sprintf {|{"kind":"disposition",%s,"disposition":"fenced","meter":"tokens"}|}
       base);
  receipt_rejects ~msg:"exit above 255" ~expect:"exit"
    (Printf.sprintf
       {|{"kind":"disposition",%s,"disposition":"reaped","session":"c-1","exit":256,"head":"settled","usage":{},"cause":"exited"}|}
       base);
  receipt_rejects ~msg:"unknown head" ~expect:{|unknown head outcome "gone"|}
    (Printf.sprintf
       {|{"kind":"disposition",%s,"disposition":"reaped","session":"c-1","exit":0,"head":"gone","usage":{},"cause":"exited"}|}
       base);
  receipt_rejects ~msg:"unknown cause" ~expect:{|unknown cause "boredom"|}
    (Printf.sprintf
       {|{"kind":"disposition",%s,"disposition":"reaped","session":"c-1","exit":0,"head":"settled","usage":{},"cause":"boredom"}|}
       base);
  receipt_rejects ~msg:"usage must be an object" ~expect:"usage"
    (Printf.sprintf
       {|{"kind":"disposition",%s,"disposition":"reaped","session":"c-1","exit":0,"head":"settled","usage":3,"cause":"exited"}|}
       base);
  receipt_rejects ~msg:"negative usd" ~expect:"usd"
    (Printf.sprintf
       {|{"kind":"disposition",%s,"disposition":"reaped","session":"c-1","exit":0,"head":"settled","usage":{},"usd":-0.5,"cause":"exited"}|}
       base);
  receipt_rejects ~msg:"unknown egress summary" ~expect:"summary"
    (Printf.sprintf {|{"kind":"egress",%s,"summary":"upserted","threads":1}|}
       base);
  receipt_rejects ~msg:"negative threads" ~expect:"threads"
    (Printf.sprintf {|{"kind":"egress",%s,"summary":"created","threads":-1}|}
       base);
  receipt_rejects ~msg:"unknown transition"
    ~expect:{|must be "failed", "parked", or "fenced"|}
    (Printf.sprintf {|{"kind":"alert",%s,"transition":"clean_run","window":"w"}|}
       base);
  receipt_rejects ~msg:"empty alert window" ~expect:"window"
    (Printf.sprintf {|{"kind":"alert",%s,"transition":"failed","window":""}|}
       base);
  receipt_rejects ~msg:"alert window vocabulary is closed" ~expect:"window"
    (Printf.sprintf
       {|{"kind":"alert",%s,"transition":"failed","window":"cli:0123456789abcdef:k"}|}
       base)

let receipt_diagnostics () =
  (* 90061 seconds is 1970-01-02T01:01:01Z: the rendering is pure UTC
     arithmetic, no local zone. *)
  equal string ~msg:"delivery line"
    (Printf.sprintf "1970-01-02T01:01:01Z delivery %s" sample_identity)
    (Receipt.diagnostic (receipt (Receipt.Kind.Delivery None)));
  equal string ~msg:"bare dispositions render their wire token"
    (Printf.sprintf "1970-01-02T01:01:01Z already_exists %s" sample_identity)
    (Receipt.diagnostic
       (receipt (Receipt.Kind.Disposition Receipt.Disposition.Already_exists)));
  equal string ~msg:"fenced line"
    (Printf.sprintf "1970-01-02T01:01:01Z fenced %s: usd_per_day"
       sample_identity)
    (Receipt.diagnostic
       (receipt
          (Receipt.Kind.Disposition
             (Receipt.Disposition.Fenced Receipt.Meter.Usd_per_day))));
  equal string ~msg:"spawned line"
    (Printf.sprintf "1970-01-02T01:01:01Z spawned %s: session %s"
       sample_identity sample_session)
    (Receipt.diagnostic
       (receipt
          (Receipt.Kind.Disposition
             (Receipt.Disposition.Spawned { session = sample_session }))));
  equal string ~msg:"reaped line"
    (Printf.sprintf
       "1970-01-02T01:01:01Z reaped %s: session %s, exit 0, head settled, \
        cause exited, $1.2500"
       sample_identity sample_session)
    (Receipt.diagnostic
       (receipt
          (Receipt.Kind.Disposition
             (Receipt.Disposition.Reaped
                {
                  session = sample_session;
                  exit = 0;
                  head = Receipt.Head.Settled;
                  usage = usage_json;
                  usd = Some 1.25;
                  cause = Receipt.Cause.Exited;
                }))));
  equal string ~msg:"egress none_needed line"
    (Printf.sprintf
       "1970-01-02T01:01:01Z egress %s: summary none_needed, 0 threads"
       sample_identity)
    (Receipt.diagnostic
       (receipt (Receipt.Kind.Egress { summary = `None_needed; threads = 0 })));
  equal string ~msg:"a modern timestamp renders"
    (Printf.sprintf "2026-08-25T00:00:00Z dup %s" sample_identity)
    (Receipt.diagnostic
       (receipt ~at:1787616000.0
          (Receipt.Kind.Disposition Receipt.Disposition.Dup)))

let receipt_log_queries () =
  let other_digest = "feedfacefeedface" in
  let reaped ?(exit = 0) ?(head = Receipt.Head.Settled) session =
    receipt
      (Receipt.Kind.Disposition
         (Receipt.Disposition.Reaped
            {
              session;
              exit;
              head;
              usage = Jsont.Json.object' [];
              usd = None;
              cause = Receipt.Cause.Exited;
            }))
  in
  let log =
    [
      receipt (Receipt.Kind.Delivery None);
      receipt (Receipt.Kind.Disposition (Receipt.Disposition.Spawned { session = "c-1" }));
      receipt
        (Receipt.Kind.Alert
           { transition = Receipt.Transition.Failed; window = `Identity });
      receipt
        (Receipt.Kind.Alert
           {
             transition = Receipt.Transition.Fenced;
             window = `Meter Receipt.Meter.Runs_per_hour;
           });
    ]
  in
  is_true ~msg:"the spawn is recorded"
    (Receipt.spawn_recorded ~digest:sample_digest ~identity:sample_identity log);
  is_false ~msg:"another digest's marker has no spawned line"
    (Receipt.spawn_recorded ~digest:other_digest ~identity:sample_identity log);
  is_false ~msg:"another identity has no spawned line"
    (Receipt.spawn_recorded ~digest:sample_digest
       ~identity:"cli:0123456789abcdef:k" log);
  is_false ~msg:"a delivery is not a spawn"
    (Receipt.spawn_recorded ~digest:sample_digest ~identity:sample_identity
       [ receipt (Receipt.Kind.Delivery None) ]);
  equal (option string) ~msg:"the last clean settled reap names its session"
    (Some "c-2")
    (Receipt.settled_session ~digest:sample_digest ~identity:sample_identity
       [ reaped "c-1"; reaped "c-2" ]);
  equal (option string) ~msg:"a failed exit is not a settled session" None
    (Receipt.settled_session ~digest:sample_digest ~identity:sample_identity
       [ reaped ~exit:1 "c-1" ]);
  equal (option string) ~msg:"an unsettled head is not a settled session" None
    (Receipt.settled_session ~digest:sample_digest ~identity:sample_identity
       [ reaped ~head:Receipt.Head.Interrupted "c-1" ]);
  equal (option string) ~msg:"another digest's reap does not answer" None
    (Receipt.settled_session ~digest:other_digest ~identity:sample_identity
       [ reaped "c-1" ]);
  is_true ~msg:"an egress decides the identity"
    (Receipt.egress_recorded ~digest:sample_digest ~identity:sample_identity
       [ receipt (Receipt.Kind.Egress { summary = `Skipped_no_token; threads = 0 }) ]);
  is_false ~msg:"no egress line, nothing decided"
    (Receipt.egress_recorded ~digest:sample_digest ~identity:sample_identity log);
  is_true ~msg:"the identity-window failed alert is recorded"
    (Receipt.alerted ~digest:sample_digest ~identity:sample_identity
       ~transition:Receipt.Transition.Failed log);
  is_false ~msg:"parked never fired"
    (Receipt.alerted ~digest:sample_digest ~identity:sample_identity
       ~transition:Receipt.Transition.Parked log);
  is_false ~msg:"a meter-window alert is not an identity alert"
    (Receipt.alerted ~digest:sample_digest ~identity:sample_identity
       ~transition:Receipt.Transition.Fenced log);
  is_false ~msg:"a policy edit resets identity alerts"
    (Receipt.alerted ~digest:other_digest ~identity:sample_identity
       ~transition:Receipt.Transition.Failed log)

(* Events. *)

let sample_sha = "9c41f2e8a5b06c7d9e0f1a2b3c4d5e6f70819202"

(* A pull_request delivery in GitHub's documented shape, carrying members
   the narrow decode must ignore at every level. *)
let pull_request_payload ?(action = "opened") ?(draft = "false")
    ?(association = "OWNER") ?(sha = sample_sha) ?(base = "main") () =
  Printf.sprintf
    {|{
  "action": %S,
  "number": 312,
  "pull_request": {
    "id": 190210,
    "number": 312,
    "state": "open",
    "locked": false,
    "title": "Hold a one-row floor under squeezed panels",
    "user": { "login": "tmattio", "id": 42 },
    "body": "Fixes the collapse.",
    "draft": %s,
    "author_association": %S,
    "head": { "label": "invariant:fix", "ref": "fix", "sha": %S,
              "repo": { "full_name": "invariant/spice" } },
    "base": { "label": "invariant:main", "ref": %S,
              "sha": "1111111111111111111111111111111111111111" },
    "labels": [],
    "requested_reviewers": []
  },
  "repository": { "id": 7, "full_name": "invariant/spice",
                  "private": true, "default_branch": "main" },
  "sender": { "login": "tmattio" }
}|}
    action draft association sha base

let event_decodes () =
  match Event.Pull_request.decode (pull_request_payload ()) with
  | Error e -> failf "decode: %s" (Event.Pull_request.Error.message e)
  | Ok pr ->
      equal string ~msg:"action" "opened" pr.Event.Pull_request.action;
      equal int ~msg:"number" 312 pr.Event.Pull_request.number;
      equal string ~msg:"head sha" sample_sha pr.Event.Pull_request.head_sha;
      equal string ~msg:"base ref" "main" pr.Event.Pull_request.base_ref;
      is_false ~msg:"draft" pr.Event.Pull_request.draft;
      equal string ~msg:"association" "OWNER"
        pr.Event.Pull_request.author_association;
      equal string ~msg:"repo" "invariant/spice" pr.Event.Pull_request.repo

let event_rejects ~msg ?expect payload =
  match Event.Pull_request.decode payload with
  | Ok _ -> failf "%s: decode accepted the payload" msg
  | Error e -> (
      let message = Event.Pull_request.Error.message e in
      match expect with
      | None -> ()
      | Some needle ->
          if not (str_contains needle message) then
            failf "%s: message %S does not name %S" msg message needle)

let event_decode_is_narrow () =
  event_rejects ~msg:"malformed JSON" "{";
  event_rejects ~msg:"non-object payload" ~expect:"JSON object" "[]";
  event_rejects ~msg:"missing action" ~expect:{|missing member "action"|}
    {|{"number":1}|};
  event_rejects ~msg:"bad sha" ~expect:"pull_request.head.sha"
    (pull_request_payload ~sha:"9c41f2e" ());
  event_rejects ~msg:"uppercase action" ~expect:"action"
    (pull_request_payload ~action:"Opened" ());
  event_rejects ~msg:"draft must be a boolean" ~expect:"pull_request.draft"
    (pull_request_payload ~draft:{|"no"|} ());
  event_rejects ~msg:"lowercase association"
    ~expect:"pull_request.author_association"
    (pull_request_payload ~association:"owner" ());
  event_rejects ~msg:"empty base ref" ~expect:"pull_request.base.ref"
    (pull_request_payload ~base:"" ());
  (* The base ref reaches a git fetch refspec; the ref-name grammar refuses
     what git's own would. *)
  List.iter
    (fun base ->
      event_rejects
        ~msg:(Printf.sprintf "base ref %S is not a ref name" base)
        ~expect:"pull_request.base.ref"
        (pull_request_payload ~base ()))
    [ "-flag"; "a..b"; "with space"; "tab\there"; "a~b"; "a^b"; "a:b";
      "a?b"; "a*b"; "a[b"; "back\\slash"; "/leading"; "trailing/" ];
  (match
     Event.Pull_request.decode
       (pull_request_payload ~base:"release/2026-08.x_1" ())
   with
  | Ok pr ->
      equal string ~msg:"an ordinary hierarchical branch passes"
        "release/2026-08.x_1" pr.Event.Pull_request.base_ref
  | Error e -> failf "decode: %s" (Event.Pull_request.Error.message e));
  (* The decoder recurses per nesting level; a hostile bracket tower is a
     decode error before parsing, never a stack fault. *)
  event_rejects ~msg:"a bracket tower is refused by depth" ~expect:"nesting"
    (String.make 3000 '[' ^ String.make 3000 ']');
  match
    Event.Pull_request.decode
      ({|{"ignored":{"a":{"b":[[[1]]]}},|}
      ^ String.sub (pull_request_payload ()) 1
          (String.length (pull_request_payload ()) - 1))
  with
  | Ok _ -> ()
  | Error e ->
      failf "shallow nesting must decode: %s"
        (Event.Pull_request.Error.message e)

let event_identity () =
  let decode payload =
    match Event.Pull_request.decode payload with
    | Ok pr -> pr
    | Error e -> failf "decode: %s" (Event.Pull_request.Error.message e)
  in
  let opened = Event.Identity.of_pull_request (decode (pull_request_payload ())) in
  equal string ~msg:"stable string form"
    (Printf.sprintf "github:invariant/spice#312@%s:head" sample_sha)
    (Event.Identity.to_string opened);
  is_true ~msg:"a redelivered reopen is the same event"
    (Event.Identity.equal opened
       (Event.Identity.of_pull_request
          (decode (pull_request_payload ~action:"reopened" ()))));
  is_true ~msg:"ready_for_review shares the head class"
    (Event.Identity.equal opened
       (Event.Identity.of_pull_request
          (decode (pull_request_payload ~action:"ready_for_review" ()))));
  is_false ~msg:"a new push is a new event"
    (Event.Identity.equal opened
       (Event.Identity.of_pull_request
          (decode
             (pull_request_payload
                ~sha:"2222222222222222222222222222222222222222" ()))));
  is_false ~msg:"an unclassed action is its own event"
    (Event.Identity.equal opened
       (Event.Identity.of_pull_request
          (decode (pull_request_payload ~action:"labeled" ()))));
  (* The predicate and the class fold are one definition: the set here is
     exactly the set whose identities collapse above. *)
  List.iter
    (fun action ->
      is_true ~msg:(action ^ " is review-class")
        (Event.Identity.review_class action))
    [ "opened"; "reopened"; "ready_for_review"; "synchronize" ];
  is_false ~msg:"closed is not review-class"
    (Event.Identity.review_class "closed");
  let cli = Event.Identity.cli ~digest:sample_digest ~key:"nightly@1" in
  equal string ~msg:"cli identity string"
    (Printf.sprintf "cli:%s:nightly@1" sample_digest)
    (Event.Identity.to_string cli);
  (match Event.Identity.cli ~digest:"short" ~key:"k" with
  | exception Invalid_argument _ -> ()
  | _ -> fail "a malformed digest must raise");
  match Event.Identity.cli ~digest:sample_digest ~key:"" with
  | exception Invalid_argument _ -> ()
  | _ -> fail "an empty key must raise"

(* Gate. *)

let webhook_arm =
  {
    Routine.Trigger.Webhook.events =
      [ "pull_request.opened"; "pull_request.synchronize" ];
    gate =
      {
        Routine.Gate.base = Some [ "main" ];
        drafts = false;
        associations = Some [ "OWNER"; "MEMBER" ];
      };
  }

let sample_event =
  {
    Event.Pull_request.action = "opened";
    number = 312;
    head_sha = sample_sha;
    base_ref = "main";
    draft = false;
    author_association = "OWNER";
    repo = "invariant/spice";
  }

let gate_arms () =
  let check ~msg expected verdict =
    match (expected, verdict) with
    | None, Gate.Pass -> ()
    | Some needle, Gate.Skip reason ->
        if not (str_contains needle reason) then
          failf "%s: reason %S does not name %S" msg reason needle
    | None, Gate.Skip reason -> failf "%s: unexpectedly skipped: %s" msg reason
    | Some _, Gate.Pass -> failf "%s: unexpectedly passed" msg
  in
  let repo = "invariant/spice" in
  check ~msg:"a conforming event passes" None
    (Gate.evaluate ~repo webhook_arm sample_event);
  check ~msg:"a foreign repository skips first"
    (Some {|repository "acme/widgets" is not the routine's|})
    (Gate.evaluate ~repo webhook_arm
       { sample_event with Event.Pull_request.repo = "acme/widgets" });
  check ~msg:"an unadmitted event skips" (Some {|"pull_request.closed"|})
    (Gate.evaluate ~repo webhook_arm
       { sample_event with Event.Pull_request.action = "closed" });
  check ~msg:"an unadmitted base skips" (Some {|base branch "dev"|})
    (Gate.evaluate ~repo webhook_arm
       { sample_event with Event.Pull_request.base_ref = "dev" });
  check ~msg:"a draft skips" (Some "draft")
    (Gate.evaluate ~repo webhook_arm
       { sample_event with Event.Pull_request.draft = true });
  check ~msg:"an admitted draft passes" None
    (Gate.evaluate ~repo
       {
         webhook_arm with
         Routine.Trigger.Webhook.gate =
           { webhook_arm.Routine.Trigger.Webhook.gate with Routine.Gate.drafts = true };
       }
       { sample_event with Event.Pull_request.draft = true });
  check ~msg:"an unadmitted association skips" (Some "association NONE")
    (Gate.evaluate ~repo webhook_arm
       { sample_event with Event.Pull_request.author_association = "NONE" });
  check ~msg:"a permissive gate passes anything but drafts" None
    (Gate.evaluate ~repo
       {
         Routine.Trigger.Webhook.events = [ "pull_request.opened" ];
         gate = { Routine.Gate.base = None; drafts = false; associations = None };
       }
       {
         sample_event with
         Event.Pull_request.base_ref = "dev";
         author_association = "NONE";
       })

(* Fences. *)

let spawned_at ?(digest = sample_digest) at =
  {
    Receipt.at;
    identity = sample_identity;
    digest;
    kind =
      Receipt.Kind.Disposition
        (Receipt.Disposition.Spawned { session = sample_session });
  }

let reaped_at ?(digest = sample_digest) ?usd at =
  {
    Receipt.at;
    identity = sample_identity;
    digest;
    kind =
      Receipt.Kind.Disposition
        (Receipt.Disposition.Reaped
           {
             session = sample_session;
             exit = 0;
             head = Receipt.Head.Settled;
             usage = usage_json;
             usd;
             cause = Receipt.Cause.Exited;
           });
  }

let fence_alert_at ?(digest = sample_digest)
    ?(window = `Meter Receipt.Meter.Usd_per_day) at =
  {
    Receipt.at;
    identity = sample_identity;
    digest;
    kind =
      Receipt.Kind.Alert
        { transition = Receipt.Transition.Fenced; window };
  }

let fence_windows () =
  let now = 1000000.0 in
  let day = 86400.0 and hour = 3600.0 in
  equal float_exact ~msg:"spend sums priced reaps in the day window" 15.0
    (Fence.spend_in_window ~digest:sample_digest ~now
       [
         reaped_at ~usd:10.5 (now -. 100.0);
         reaped_at ~usd:4.5 (now -. day +. 1.0);
         reaped_at ~usd:99.0 (now -. day);
         reaped_at (now -. 50.0);
         reaped_at ~usd:7.0 ~digest:"feedfacefeedface" (now -. 50.0);
         spawned_at (now -. 10.0);
       ]);
  equal int ~msg:"spawns count only the trailing hour" 2
    (Fence.spawns_in_window ~digest:sample_digest ~now
       [
         spawned_at (now -. 10.0);
         spawned_at (now -. hour +. 1.0);
         spawned_at (now -. hour);
         spawned_at ~digest:"feedfacefeedface" (now -. 10.0);
         reaped_at ~usd:1.0 (now -. 10.0);
       ]);
  let budget ?usd_per_day ?runs_per_hour () =
    { Routine.Budget.wall_clock = 900.0; usd_per_day; runs_per_hour }
  in
  let admit ?usd_per_day ?runs_per_hour ?(trigger = `Cli) receipts =
    Fence.admit ~digest:sample_digest
      ~budget:(budget ?usd_per_day ?runs_per_hour ())
      ~trigger ~now receipts
  in
  (match admit ~usd_per_day:15.0 [ reaped_at ~usd:15.0 (now -. 100.0) ] with
  | Fence.Fenced Receipt.Meter.Usd_per_day -> ()
  | _ -> fail "spend at the limit must fence");
  (match admit ~usd_per_day:15.0 [ reaped_at ~usd:14.99 (now -. 100.0) ] with
  | Fence.Pass -> ()
  | _ -> fail "spend under the limit must pass");
  (match admit ~usd_per_day:15.0 [ reaped_at ~usd:15.0 (now -. day) ] with
  | Fence.Pass -> ()
  | _ -> fail "a receipt exactly a day old has left the window");
  (match
     admit ~runs_per_hour:2 ~trigger:`Webhook
       [ spawned_at (now -. 10.0); spawned_at (now -. 20.0) ]
   with
  | Fence.Fenced Receipt.Meter.Runs_per_hour -> ()
  | _ -> fail "an explicit rate limit fences at its own count");
  (match
     admit ~runs_per_hour:2 [ spawned_at (now -. 10.0); spawned_at (now -. hour) ]
   with
  | Fence.Pass -> ()
  | _ -> fail "an hour-old spawn has left the window");
  (match
     admit ~usd_per_day:1.0 ~runs_per_hour:1
       [ reaped_at ~usd:2.0 (now -. 10.0); spawned_at (now -. 10.0) ]
   with
  | Fence.Fenced Receipt.Meter.Usd_per_day -> ()
  | _ -> fail "spend is checked before rate");
  (match
     admit ~usd_per_day:1.0
       [ reaped_at ~usd:2.0 ~digest:"feedfacefeedface" (now -. 10.0) ]
   with
  | Fence.Pass -> ()
  | _ -> fail "a policy edit resets the window");
  let six_spawns =
    List.init 6 (fun i -> spawned_at (now -. 10.0 -. float_of_int i))
  in
  (match admit ~trigger:`Webhook six_spawns with
  | Fence.Fenced Receipt.Meter.Runs_per_hour -> ()
  | _ -> fail "an unfenced webhook routine defaults to 6 runs per hour");
  (match admit ~trigger:`Webhook (List.tl six_spawns) with
  | Fence.Pass -> ()
  | _ -> fail "five spawns pass the webhook default");
  (match admit six_spawns with
  | Fence.Pass -> ()
  | _ -> fail "the cli arm imposes no default rate fence");
  match admit [] with
  | Fence.Pass -> ()
  | _ -> fail "no limits means no fence"

let fence_alert_dedup () =
  let now = 1000000.0 in
  let meter = Receipt.Meter.Usd_per_day in
  is_true ~msg:"first trip alerts"
    (Fence.should_alert ~digest:sample_digest ~now ~meter []);
  is_false ~msg:"a trip inside the window stays silent"
    (Fence.should_alert ~digest:sample_digest ~now ~meter
       [ fence_alert_at (now -. 100.0) ]);
  is_true ~msg:"the window rolling re-alerts"
    (Fence.should_alert ~digest:sample_digest ~now ~meter
       [ fence_alert_at (now -. 86400.0) ]);
  is_true ~msg:"another meter's alert does not suppress"
    (Fence.should_alert ~digest:sample_digest ~now ~meter
       [
         fence_alert_at ~window:(`Meter Receipt.Meter.Runs_per_hour)
           (now -. 100.0);
       ]);
  is_true ~msg:"a policy edit re-alerts"
    (Fence.should_alert ~digest:sample_digest ~now ~meter
       [ fence_alert_at ~digest:"feedfacefeedface" (now -. 100.0) ])

(* Run ids. *)

let run_id_mint () =
  let identity = Event.Identity.cli ~digest:sample_digest ~key:"nightly@1" in
  let id = Run_id.mint ~policy_digest:sample_digest identity in
  (* The derivation is a wire format: run ids name sessions on disk and in
     receipts, so a silent change would orphan every recorded run. *)
  equal string ~msg:"pinned derivation" "c-3631e2c48c255307" id;
  equal int ~msg:"18 characters" 18 (String.length id);
  is_true ~msg:"c- then lowercase hex"
    (String.equal (String.sub id 0 2) "c-"
    && lowercase_hex (String.sub id 2 16));
  (* The id grammar must stay admissible as a session id: letters, digits,
     '.', '_', '-', at most 128 characters. *)
  is_true ~msg:"admissible as a session id"
    (String.length id <= 128
    && String.for_all
         (fun c ->
           (c >= 'A' && c <= 'Z')
           || (c >= 'a' && c <= 'z')
           || (c >= '0' && c <= '9')
           || Char.equal c '.' || Char.equal c '_' || Char.equal c '-')
         id);
  equal string ~msg:"deterministic" id
    (Run_id.mint ~policy_digest:sample_digest identity);
  is_true ~msg:"the policy moves the id"
    (not
       (String.equal id
          (Run_id.mint ~policy_digest:"feedfacefeedface" identity)));
  is_true ~msg:"the event moves the id"
    (not
       (String.equal id
          (Run_id.mint ~policy_digest:sample_digest
             (Event.Identity.cli ~digest:sample_digest ~key:"nightly@2"))));
  match Run_id.mint ~policy_digest:"nothex" identity with
  | exception Invalid_argument _ -> ()
  | _ -> fail "a malformed policy digest must raise"

(* The delivery event members: the group codec, the rebuild, and the ping
   recognizer behind the body-derived route. *)

let delivery_fields =
  {
    Receipt.Delivery.action = "opened";
    base_ref = "main";
    draft = false;
    author_association = "OWNER";
  }

let delivery_members () =
  let line =
    Receipt.encode (receipt (Receipt.Kind.Delivery (Some delivery_fields)))
  in
  (match Receipt.decode line with
  | Ok { Receipt.kind = Receipt.Kind.Delivery (Some d); _ } ->
      equal string ~msg:"action survives" "opened" d.Receipt.Delivery.action;
      equal string ~msg:"base_ref survives" "main" d.Receipt.Delivery.base_ref;
      is_false ~msg:"draft survives" d.Receipt.Delivery.draft;
      equal string ~msg:"association survives" "OWNER"
        d.Receipt.Delivery.author_association
  | Ok _ -> fail "expected a delivery with members"
  | Error e -> failf "decode: %s" (Receipt.Error.message e));
  let base = {|"at":90061,"identity":"i","digest":"ab"|} in
  (match
     Receipt.decode (Printf.sprintf {|{"kind":"delivery",%s}|} base)
   with
  | Ok { Receipt.kind = Receipt.Kind.Delivery None; _ } -> ()
  | Ok _ -> fail "a memberless delivery line must decode to None"
  | Error e -> failf "legacy decode: %s" (Receipt.Error.message e));
  receipt_rejects ~msg:"a partial member set is a torn line"
    ~expect:{|missing member "base_ref"|}
    (Printf.sprintf {|{"kind":"delivery",%s,"action":"opened"}|} base);
  receipt_rejects ~msg:"draft must be a boolean" ~expect:"draft"
    (Printf.sprintf
       {|{"kind":"delivery",%s,"action":"opened","base_ref":"main","draft":"no","author_association":"OWNER"}|}
       base)

let event_of_delivery () =
  let pr =
    {
      Event.Pull_request.action = "opened";
      number = 312;
      head_sha = sample_sha;
      base_ref = "main";
      draft = false;
      author_association = "OWNER";
      repo = "invariant/spice";
    }
  in
  let identity = Event.Identity.to_string (Event.Identity.of_pull_request pr) in
  let rebuild ?(identity = identity) ?(action = "opened") ?(base_ref = "main")
      ?(draft = false) ?(author_association = "OWNER") () =
    Event.Pull_request.of_delivery ~identity ~action ~base_ref ~draft
      ~author_association
  in
  (match rebuild () with
  | Some rebuilt ->
      equal string ~msg:"the rebuilt event re-derives its own identity"
        identity
        (Event.Identity.to_string (Event.Identity.of_pull_request rebuilt));
      equal int ~msg:"the number reads back" 312
        rebuilt.Event.Pull_request.number;
      equal string ~msg:"the head reads back" sample_sha
        rebuilt.Event.Pull_request.head_sha
  | None -> fail "a well-formed record must rebuild");
  is_true ~msg:"a review-class sibling action shares the identity's class"
    (Option.is_some (rebuild ~action:"synchronize" ()));
  is_true ~msg:"an action outside the identity's class is refused"
    (Option.is_none (rebuild ~action:"labeled" ()));
  is_true ~msg:"a cli identity rebuilds nothing"
    (Option.is_none
       (rebuild ~identity:"cli:0123456789abcdef:k" ()));
  is_true ~msg:"a malformed identity rebuilds nothing"
    (Option.is_none (rebuild ~identity:"github:oops" ()));
  is_true ~msg:"a base ref that fails the ref grammar is refused"
    (Option.is_none (rebuild ~base_ref:"-evil" ()));
  is_true ~msg:"an association outside the token grammar is refused"
    (Option.is_none (rebuild ~author_association:"owner" ()))

let ping_recognizer () =
  is_true ~msg:"a zen body is a ping" (Event.ping {|{"zen":"keep it simple"}|});
  is_true ~msg:"a hook_id body is a ping"
    (Event.ping {|{"hook_id":42,"hook":{}}|});
  is_false ~msg:"a pull_request body is not a ping"
    (Event.ping {|{"action":"opened"}|});
  is_false ~msg:"garbage is not a ping" (Event.ping "not json");
  is_false ~msg:"a bare array is not a ping" (Event.ping "[]")

(* The reconcile fold's decision table, driven arm by arm over thunk
   probes — including which probes each arm may spend. *)

let sweep_decision =
  Testable.make
    ~pp:(fun ppf -> function
      | `Drive -> Format.pp_print_string ppf "Drive"
      | `Republish session -> Format.fprintf ppf "Republish %s" session
      | `Done -> Format.pp_print_string ppf "Done")
    ~equal:(fun (a : Record.sweep) (b : Record.sweep) ->
      match (a, b) with
      | `Drive, `Drive | `Done, `Done -> true
      | `Republish a, `Republish b -> String.equal a b
      | _ -> false)

let never_spawned () : bool = fail "spawned must not be read on this arm"
let never_egress () : bool = fail "egress must not be read on this arm"

let never_settled () : string option =
  fail "settled must not be read on this arm"

let sweep_action ?(spawned = never_spawned) ?(egress = never_egress)
    ?(settled = never_settled) claimed =
  Record.sweep_action ~claimed ~spawned ~egress ~settled

let sweep_table () =
  equal sweep_decision ~msg:"an unclaimed identity is driven whole" `Drive
    (sweep_action false);
  equal sweep_decision
    ~msg:"a claim with no spawned line is adopted and driven" `Drive
    (sweep_action ~spawned:(fun () -> false) true);
  equal sweep_decision ~msg:"an egress line completes the record" `Done
    (sweep_action ~spawned:(fun () -> true) ~egress:(fun () -> true) true);
  equal sweep_decision
    ~msg:"a publishable settle with no egress re-enters the publisher"
    (`Republish "s1")
    (sweep_action
       ~spawned:(fun () -> true)
       ~egress:(fun () -> false)
       ~settled:(fun () -> Some "s1")
       true);
  equal sweep_decision
    ~msg:"a committed record with nothing publishable is left alone" `Done
    (sweep_action
       ~spawned:(fun () -> true)
       ~egress:(fun () -> false)
       ~settled:(fun () -> None)
       true)

(* The open-record folds: pending runs and undecided deliveries. *)

let pending_receipt ?(at = 1000.) ~identity ~digest kind =
  { Receipt.at; identity; digest; kind }

let fold_spawned ?at ~identity ~digest session =
  pending_receipt ?at ~identity ~digest
    (Receipt.Kind.Disposition (Receipt.Disposition.Spawned { session }))

let fold_reaped ?at ~identity ~digest session =
  pending_receipt ?at ~identity ~digest
    (Receipt.Kind.Disposition
       (Receipt.Disposition.Reaped
          {
            session;
            exit = 0;
            head = Receipt.Head.Settled;
            usage = Jsont.Json.object' [];
            usd = None;
            cause = Receipt.Cause.Exited;
          }))

let pending =
  Testable.make
    ~pp:(fun ppf (p : Receipt.Pending.t) ->
      Format.fprintf ppf "%s@%s:%s at %g" p.Receipt.Pending.identity
        p.Receipt.Pending.digest p.Receipt.Pending.session
        p.Receipt.Pending.spawned_at)
    ~equal:(fun (a : Receipt.Pending.t) b ->
      String.equal a.Receipt.Pending.identity b.Receipt.Pending.identity
      && String.equal a.Receipt.Pending.digest b.Receipt.Pending.digest
      && String.equal a.Receipt.Pending.session b.Receipt.Pending.session
      && Float.equal a.Receipt.Pending.spawned_at b.Receipt.Pending.spawned_at)

let open_run ~identity ~digest ~session ~spawned_at =
  { Receipt.Pending.identity; digest; session; spawned_at }

let pending_fold () =
  let runs = Testable.list pending in
  equal runs ~msg:"an empty log holds nothing open" [] (Receipt.pending_runs []);
  equal runs ~msg:"a delivery alone opens nothing" []
    (Receipt.pending_runs
       [ pending_receipt ~identity:"i" ~digest:"d" (Receipt.Kind.Delivery None) ]);
  equal runs ~msg:"other dispositions neither open nor close" []
    (Receipt.pending_runs
       [
         pending_receipt ~identity:"i" ~digest:"d"
           (Receipt.Kind.Disposition (Receipt.Disposition.Skipped "draft"));
         pending_receipt ~identity:"i" ~digest:"d"
           (Receipt.Kind.Disposition Receipt.Disposition.Dup);
       ]);
  equal runs ~msg:"a spawned line with no reap is open"
    [ open_run ~identity:"i" ~digest:"d" ~session:"s" ~spawned_at:7. ]
    (Receipt.pending_runs [ fold_spawned ~at:7. ~identity:"i" ~digest:"d" "s" ]);
  equal runs ~msg:"a reaped line closes its spawn" []
    (Receipt.pending_runs
       [
         fold_spawned ~identity:"i" ~digest:"d" "s";
         fold_reaped ~identity:"i" ~digest:"d" "s";
       ]);
  equal runs ~msg:"pairing is by digest and identity, never by session" []
    (Receipt.pending_runs
       [
         fold_spawned ~identity:"i" ~digest:"d" "s";
         fold_reaped ~identity:"i" ~digest:"d" "other";
       ]);
  equal runs ~msg:"a reap under another digest closes nothing"
    [ open_run ~identity:"i" ~digest:"d1" ~session:"s" ~spawned_at:7. ]
    (Receipt.pending_runs
       [
         fold_spawned ~at:7. ~identity:"i" ~digest:"d1" "s";
         fold_reaped ~identity:"i" ~digest:"d2" "s";
       ]);
  equal runs ~msg:"a reap under another identity closes nothing"
    [ open_run ~identity:"a" ~digest:"d" ~session:"s" ~spawned_at:7. ]
    (Receipt.pending_runs
       [
         fold_spawned ~at:7. ~identity:"a" ~digest:"d" "s";
         fold_reaped ~identity:"b" ~digest:"d" "s";
       ]);
  equal runs ~msg:"open runs keep log order"
    [
      open_run ~identity:"a" ~digest:"d" ~session:"s1" ~spawned_at:1.;
      open_run ~identity:"b" ~digest:"d" ~session:"s2" ~spawned_at:2.;
    ]
    (Receipt.pending_runs
       [
         fold_spawned ~at:1. ~identity:"a" ~digest:"d" "s1";
         pending_receipt ~identity:"c" ~digest:"d" (Receipt.Kind.Delivery None);
         fold_spawned ~at:2. ~identity:"b" ~digest:"d" "s2";
       ])

let open_deliveries_fold () =
  let ats receipts =
    List.map (fun (r : Receipt.t) -> r.Receipt.at) receipts
  in
  let deliver ~at ~identity ~digest =
    pending_receipt ~at ~identity ~digest (Receipt.Kind.Delivery None)
  in
  equal (Testable.list float_exact) ~msg:"an empty log owes nothing" []
    (ats (Receipt.open_deliveries []));
  equal (Testable.list float_exact)
    ~msg:"an undecided delivery is open" [ 1. ]
    (ats (Receipt.open_deliveries [ deliver ~at:1. ~identity:"i" ~digest:"d" ]));
  equal (Testable.list float_exact)
    ~msg:"any disposition closes the pair" []
    (ats
       (Receipt.open_deliveries
          [
            deliver ~at:1. ~identity:"i" ~digest:"d";
            pending_receipt ~identity:"i" ~digest:"d"
              (Receipt.Kind.Disposition (Receipt.Disposition.Skipped "draft"));
          ]));
  equal (Testable.list float_exact)
    ~msg:"a redelivery collapses to its last line" [ 2. ]
    (ats
       (Receipt.open_deliveries
          [
            deliver ~at:1. ~identity:"i" ~digest:"d";
            deliver ~at:2. ~identity:"i" ~digest:"d";
          ]));
  equal (Testable.list float_exact)
    ~msg:"another digest's disposition closes nothing" [ 1. ]
    (ats
       (Receipt.open_deliveries
          [
            deliver ~at:1. ~identity:"i" ~digest:"d1";
            pending_receipt ~identity:"i" ~digest:"d2"
              (Receipt.Kind.Disposition Receipt.Disposition.Dup);
          ]))

let status_projections () =
  equal string ~msg:"a bare disposition labels its wire token" "dup"
    (Receipt.Disposition.label Receipt.Disposition.Dup);
  equal string ~msg:"a fenced disposition names its meter"
    "fenced:runs_per_hour"
    (Receipt.Disposition.label
       (Receipt.Disposition.Fenced Receipt.Meter.Runs_per_hour));
  equal string ~msg:"a reaped disposition names its exit" "reaped:130"
    (Receipt.Disposition.label
       (Receipt.Disposition.Reaped
          {
            session = sample_session;
            exit = 130;
            head = Receipt.Head.Interrupted;
            usage = Jsont.Json.object' [];
            usd = None;
            cause = Receipt.Cause.Wall_clock;
          }));
  let budget ?usd_per_day ?runs_per_hour () =
    { Routine.Budget.wall_clock = 900.; usd_per_day; runs_per_hour }
  in
  let reaped_now =
    pending_receipt ~at:90000. ~identity:sample_identity ~digest:sample_digest
      (Receipt.Kind.Disposition
         (Receipt.Disposition.Reaped
            {
              session = sample_session;
              exit = 0;
              head = Receipt.Head.Settled;
              usage = Jsont.Json.object' [];
              usd = Some 1.25;
              cause = Receipt.Cause.Exited;
            }))
  in
  equal string ~msg:"the metered spend line"
    "spend 24h: 1.25 usd of 15.00"
    (Fence.spend_line ~digest:sample_digest ~now:90061.
       ~budget:(budget ~usd_per_day:15.0 ())
       [ reaped_now ]);
  equal string ~msg:"the unmetered spend line" "spend 24h: 1.25 usd (no limit)"
    (Fence.spend_line ~digest:sample_digest ~now:90061. ~budget:(budget ())
       [ reaped_now ]);
  equal string ~msg:"the webhook rate line carries the in-admission default"
    "runs 1h: 0 of 6"
    (Fence.runs_line ~digest:sample_digest ~now:90061. ~budget:(budget ())
       ~trigger:`Webhook []);
  equal string ~msg:"the cli rate line is unmetered" "runs 1h: 0 (no limit)"
    (Fence.runs_line ~digest:sample_digest ~now:90061. ~budget:(budget ())
       ~trigger:`Cli []);
  match Routine.decode conforming with
  | Error e -> failf "decode: %s" (Routine.Error.message e)
  | Ok routine ->
      is_true ~msg:"a webhook arm is a webhook-shaped delivery"
        (match Routine.delivery_trigger routine with
        | `Webhook -> true
        | `Cli -> false)

let reap_recorded_fold () =
  let log =
    [
      fold_spawned ~identity:sample_identity ~digest:sample_digest "c-1";
      fold_reaped ~identity:sample_identity ~digest:sample_digest "c-1";
    ]
  in
  is_true ~msg:"the reap is recorded"
    (Receipt.reap_recorded ~digest:sample_digest ~identity:sample_identity log);
  is_false ~msg:"another digest's reap does not answer"
    (Receipt.reap_recorded ~digest:"feedfacefeedface"
       ~identity:sample_identity log);
  is_false ~msg:"a spawn alone records no reap"
    (Receipt.reap_recorded ~digest:sample_digest ~identity:sample_identity
       [ fold_spawned ~identity:sample_identity ~digest:sample_digest "c-1" ])

(* Suite. *)

let () =
  run "mentat.routine"
    [
      test "the reference routine decodes fully" routine_decodes;
      test "omitted members take their documented defaults" routine_defaults;
      test "an omitted gate is permissive except for drafts"
        gate_defaults_when_omitted;
      test "the version-1 envelope is closed at decode"
        routine_envelope_is_closed;
      test "trigger kinds split into unknown, refused, and duplicate"
        routine_trigger_kinds;
      test "the policy digest is a stable 16-hex identity"
        policy_digest_identity;
      test "every receipt kind round-trips through the line codec"
        receipt_round_trips;
      test "receipt decode rejects every departure from the contract"
        receipt_decode_is_strict;
      test "receipt diagnostics render pinned one-liners" receipt_diagnostics;
      test "log queries answer the torn-claim and alert-dedup questions"
        receipt_log_queries;
      test "a pull_request payload decodes narrowly" event_decodes;
      test "event decode names the member a payload lacks or mangles"
        event_decode_is_narrow;
      test "event identities dedupe redeliveries and separate pushes"
        event_identity;
      test "the gate refuses with the reason receipts will carry" gate_arms;
      test "fence windows trail the clock in plain seconds" fence_windows;
      test "the first fence trip in a window alerts, later trips stay silent"
        fence_alert_dedup;
      test "run ids are stable, admissible session ids" run_id_mint;
      test "delivery event members ride the line codec as a group"
        delivery_members;
      test "a delivery receipt rebuilds its admitted event" event_of_delivery;
      test "the ping recognizer reads the body, never a header"
        ping_recognizer;
      test "the sweep table" sweep_table;
      test "the pending fold" pending_fold;
      test "the open-deliveries fold" open_deliveries_fold;
      test "status projections speak the log's own vocabulary"
        status_projections;
      test "the reap-recorded fold discriminates settles" reap_recorded_fold;
    ]
