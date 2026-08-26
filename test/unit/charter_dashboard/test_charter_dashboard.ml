(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Charter_dashboard]'s pure projection — the needs-me-first
   page, driven over hand-built observations with no store, roster, or
   daemon behind it. The module lives in [bin/mentatd] and is not
   library-linkable, so its source is copied into this test executable by
   the [copy_files] rules in [dune]; the effectful observation is exercised
   end to end by the web blackbox family. *)

open Windtrap
open Mentat_charter

let now = 1_700_000_000.

(* Receipt fixtures. *)

let receipt ~at ~identity ~digest kind = { Receipt.at; identity; digest; kind }

let spawned ?(at = now -. 60.) ~identity ~digest session =
  receipt ~at ~identity ~digest
    (Receipt.Kind.Disposition (Receipt.Disposition.Spawned { session }))

let reaped ?(at = now -. 30.) ?(exit = 0) ?(head = Receipt.Head.Settled)
    ?(cause = Receipt.Cause.Exited) ?usd ~identity ~digest session =
  receipt ~at ~identity ~digest
    (Receipt.Kind.Disposition
       (Receipt.Disposition.Reaped
          { session; exit; head; usage = Jsont.Json.object' []; usd; cause }))

let alert ?(at = now -. 20.) ~identity ~digest transition =
  receipt ~at ~identity ~digest
    (Receipt.Kind.Alert { transition; window = `Identity })

let egress ?(at = now -. 10.) ~identity ~digest summary threads =
  receipt ~at ~identity ~digest (Receipt.Kind.Egress { summary; threads })

(* Charter fixtures, built directly — no disk. *)

let webhook_arm =
  Charter.Trigger.Github_webhook
    {
      Charter.Trigger.Webhook.events = [ "pull_request.opened" ];
      gate = { Charter.Gate.base = None; drafts = false; associations = None };
    }

let test_charter ?(enabled = true) ?(webhook = false) ?usd_per_day
    ?runs_per_hour ?(wall_clock = 900.) name =
  {
    Charter.name;
    enabled;
    repo = "acme/widgets";
    triggers = (if webhook then [ webhook_arm ] else [ Charter.Trigger.Cli ]);
    permission_unattended = None;
    run =
      {
        Charter.Run.model = None;
        reasoning = None;
        max_steps = 1;
        prompt = "prompt.md";
        output_schema = "schema.json";
        project_instructions = None;
      };
    budget = { Charter.Budget.wall_clock; usd_per_day; runs_per_hour };
    notify = None;
    suppress_clean_run = false;
  }

let loaded ?(digest = "aaaaaaaaaaaaaaaa") ?ingress_id charter =
  {
    Charter_store.Loaded.name = charter.Charter.name;
    dir = "/nonexistent/" ^ charter.Charter.name;
    charter;
    digest;
    prompt = "";
    output_schema = "";
    ingress_id;
  }

let observed ?(receipts = Ok []) ?(runs = []) loaded =
  Charter_dashboard.Observed.Charter
    { Charter_dashboard.Observed.loaded; receipts; runs }

let open_run ~fence (pending : Charter_reconcile.Pending.t) =
  { Charter_dashboard.Observed.pending; fence }

let pending ?(spawned_at = now -. 60.) ~digest ~identity session =
  { Charter_reconcile.Pending.identity; digest; session; spawned_at }

let store_error message =
  { Charter_store.Error.operation = "read"; path = "/nonexistent"; reason = message }

let html ?(ingress = None) observed =
  Mentat_web.Html.to_string (Charter_dashboard.page ~now ~ingress observed)

(* The empty and failure statements: never a blank page. *)

let empty_roster () =
  let page = html (Ok []) in
  contains ~msg:page ~sub:"No charters are installed" page;
  contains ~sub:"mentat charter add" page

let roster_failure () =
  let page = html (Error (store_error "permission denied")) in
  contains ~msg:page ~sub:"notice failure" page;
  contains ~sub:"read: /nonexistent: permission denied" page

let nothing_needed () =
  let page =
    html (Ok [ observed (loaded (test_charter ~usd_per_day:15.0 "quiet")) ])
  in
  contains ~msg:page ~sub:"Nothing needs you." page;
  contains ~sub:"spend 24h: 0.00 usd of 15.00" page;
  contains ~sub:"runs 1h: 0 (no limit)" page;
  contains ~sub:"last: no receipts" page;
  contains ~sub:"egress: -" page

(* The attention buckets render in their fixed order, whatever the roster
   order interleaves; the record follows below the fold. *)

let bucket_order () =
  let d = "aaaaaaaaaaaaaaaa" in
  let fenced_charter =
    let charter = test_charter ~webhook:true ~runs_per_hour:1 "g-fenced" in
    observed
      ~receipts:(Ok [ spawned ~identity:"i-g" ~digest:d "s-g" ])
      (loaded ~digest:d charter)
  in
  let entries =
    [
      observed
        ~receipts:
          (Ok
             [
               reaped ~exit:0 ~head:Receipt.Head.Settled ~identity:"i-h"
                 ~digest:d "s-h";
               egress ~identity:"i-h" ~digest:d `Created 2;
             ])
        (loaded ~digest:d (test_charter "a-healthy"));
      observed
        ~receipts:
          (Ok
             [
               reaped ~exit:255 ~head:Receipt.Head.Missing ~identity:"i-f"
                 ~digest:d "s-f";
               alert ~identity:"i-f" ~digest:d Receipt.Transition.Failed;
             ])
        (loaded ~digest:d (test_charter "b-failed"));
      observed
        ~receipts:
          (Ok
             [
               reaped ~exit:130 ~head:Receipt.Head.Parked
                 ~cause:Receipt.Cause.Park_expired ~identity:"i-p" ~digest:d
                 "s-p";
               alert ~identity:"i-p" ~digest:d Receipt.Transition.Parked;
             ])
        (loaded ~digest:d (test_charter "c-parked"));
      Charter_dashboard.Observed.Broken
        { name = "d-broken"; error = store_error "bad json" };
      observed
        ~receipts:(Error (store_error "torn line"))
        (loaded ~digest:d (test_charter "e-unreadable"));
      observed
        ~receipts:(Ok [ spawned ~identity:"i-o" ~digest:d "s-o" ])
        ~runs:
          [
            open_run ~fence:`Held
              (pending ~spawned_at:(now -. 3600.) ~digest:d ~identity:"i-o"
                 "s-o");
          ]
        (loaded ~digest:d (test_charter ~wall_clock:900. "f-overdue"));
      fenced_charter;
      observed
        ~receipts:
          (Ok
             [
               spawned ~identity:"i-u" ~digest:d "s-u";
               reaped ~identity:"i-u" ~digest:d "s-u";
             ])
        (loaded ~digest:d (test_charter "h-unpublished"));
      observed
        ~receipts:(Ok [ spawned ~identity:"i-x" ~digest:d "s-x" ])
        ~runs:
          [ open_run ~fence:(`Io "probe boom") (pending ~digest:d ~identity:"i-x" "s-x") ]
        (loaded ~digest:d (test_charter "i-unprobeable"));
    ]
  in
  let page = html (Ok entries) in
  in_order ~msg:page
    ~subs:
      [
        "item parked";
        "item failed";
        "item broken";
        "item unreadable";
        "item overdue";
        "item unprobeable";
        "item fenced";
        "item unpublished";
        "The record";
      ]
    page

(* Item content: the alert's judgment, the attach path, the narrations. *)

let failed_item () =
  let d = "aaaaaaaaaaaaaaaa" in
  let page =
    html
      (Ok
         [
           observed
             ~receipts:
               (Ok
                  [
                    reaped ~exit:255 ~head:Receipt.Head.Missing ~identity:"i-f"
                      ~digest:d "s-f";
                    alert ~identity:"i-f" ~digest:d Receipt.Transition.Failed;
                  ])
             (loaded ~digest:d (test_charter "pr-review"));
         ])
  in
  contains ~msg:page ~sub:"settled without a publishable outcome" page;
  contains ~sub:"href=\"/session/s-f\"" page;
  contains ~sub:"i-f" page

let overdue_and_live () =
  let d = "aaaaaaaaaaaaaaaa" in
  let overdue_page =
    html
      (Ok
         [
           observed
             ~receipts:(Ok [ spawned ~identity:"i" ~digest:d "s" ])
             ~runs:
               [
                 open_run ~fence:`Held
                   (pending ~spawned_at:(now -. 3600.) ~digest:d ~identity:"i"
                      "s");
               ]
             (loaded ~digest:d (test_charter ~wall_clock:900. "late"));
         ])
  in
  contains ~msg:overdue_page
    ~sub:"outlives its wall clock; its fence holder is left to finish"
    overdue_page;
  let live_page =
    html
      (Ok
         [
           observed
             ~receipts:(Ok [ spawned ~identity:"i" ~digest:d "s" ])
             ~runs:
               [
                 open_run ~fence:`Held
                   (pending ~spawned_at:(now -. 60.) ~digest:d ~identity:"i"
                      "s");
               ]
             (loaded ~digest:d (test_charter ~wall_clock:900. "live"));
         ])
  in
  contains ~msg:live_page ~sub:"Nothing needs you." live_page;
  let settle_page =
    html
      (Ok
         [
           observed
             ~receipts:(Ok [ spawned ~identity:"i" ~digest:d "s" ])
             ~runs:[ open_run ~fence:`Free (pending ~digest:d ~identity:"i" "s") ]
             (loaded ~digest:d (test_charter "dead"));
         ])
  in
  contains ~msg:settle_page ~sub:"Nothing needs you." settle_page

let fenced_detail () =
  let d = "aaaaaaaaaaaaaaaa" in
  let page =
    html
      (Ok
         [
           observed
             ~receipts:
               (Ok
                  [
                    reaped ~exit:0 ~head:Receipt.Head.Settled ~usd:10.5
                      ~identity:"i" ~digest:d "s";
                    egress ~identity:"i" ~digest:d `Created 1;
                  ])
             (loaded ~digest:d (test_charter ~usd_per_day:10.0 "spent"));
         ])
  in
  contains ~msg:page ~sub:"usd_per_day exhausted: 10.50 usd of 10.00 in 24h"
    page;
  contains ~sub:"spend 24h: 10.50 usd of 10.00" page

(* Disposition-derived buckets fold under the digest in force; open runs
   are judged whatever their digest, as the reconcile fold adopts them. *)

let digest_scoping () =
  let page =
    html
      (Ok
         [
           observed
             ~receipts:
               (Ok
                  [
                    reaped ~exit:255 ~head:Receipt.Head.Missing ~identity:"i"
                      ~digest:"oldoldoldoldoldo" "s-old";
                    alert ~identity:"i" ~digest:"oldoldoldoldoldo"
                      Receipt.Transition.Failed;
                    spawned ~identity:"i2" ~digest:"oldoldoldoldoldo" "s-run";
                  ])
             ~runs:
               [
                 open_run ~fence:`Held
                   (pending ~spawned_at:(now -. 3600.)
                      ~digest:"oldoldoldoldoldo" ~identity:"i2" "s-run");
               ]
             (loaded ~digest:"aaaaaaaaaaaaaaaa"
                (test_charter ~wall_clock:900. "edited"));
         ])
  in
  not_contains ~msg:page ~sub:"item failed" page;
  contains ~sub:"item overdue" page

let unpublished_item () =
  let d = "aaaaaaaaaaaaaaaa" in
  let page =
    html
      (Ok
         [
           observed
             ~receipts:
               (Ok
                  [
                    reaped ~exit:0 ~head:Receipt.Head.Settled ~identity:"i"
                      ~digest:d "s";
                  ])
             (loaded ~digest:d (test_charter "owed"));
         ])
  in
  contains ~msg:page
    ~sub:"settled with no egress line; the next pass re-enters the publisher"
    page;
  contains ~sub:"href=\"/session/s\"" page

let broken_only_roster () =
  let page =
    html
      (Ok
         [
           Charter_dashboard.Observed.Broken
             { name = "torn"; error = store_error "bad <script> & json" };
         ])
  in
  contains ~msg:page ~sub:"item broken" page;
  contains ~sub:"Every installed charter failed to load" page;
  (* The store's message reaches the page escaped, never as markup. *)
  contains ~sub:"bad &lt;script&gt; &amp; json" page;
  not_contains ~sub:"<script>" page

let ingress_lines () =
  let charter =
    loaded ~ingress_id:"0123456789abcdef0123456789abcdef"
      (test_charter ~webhook:true "hooked")
  in
  let bound = html ~ingress:(Some "127.0.0.1:7777") (Ok [ observed charter ]) in
  contains ~msg:bound
    ~sub:
      "ingress: POST http://127.0.0.1:7777/ingress/github/0123456789abcdef0123456789abcdef"
    bound;
  let unbound = html (Ok [ observed charter ]) in
  contains ~msg:unbound
    ~sub:
      "ingress: POST /ingress/github/0123456789abcdef0123456789abcdef (unbound)"
    unbound;
  let cli = html (Ok [ observed (loaded (test_charter "plain")) ]) in
  not_contains ~sub:"ingress:" cli

let record_row () =
  let d = "aaaaaaaaaaaaaaaa" in
  let page =
    html
      (Ok
         [
           observed
             ~receipts:
               (Ok
                  [
                    spawned ~at:(now -. 90.) ~identity:"i" ~digest:d "s";
                    reaped ~at:1_699_999_970. ~exit:0
                      ~head:Receipt.Head.Settled ~identity:"i" ~digest:d "s";
                    egress ~at:1_699_999_990. ~identity:"i" ~digest:d `Updated
                      3;
                  ])
             (loaded ~digest:d
                (test_charter ~webhook:true ~usd_per_day:15.0 ~runs_per_hour:6
                   ~enabled:false "pr-review"));
         ])
  in
  in_order ~msg:page ~subs:[ "pr-review"; "aaaaaaaaaaaaaaaa"; "disabled" ] page;
  contains ~sub:"runs 1h: 1 of 6" page;
  contains ~sub:"last: reaped:0 " page;
  contains ~sub:"<time>2023-11-14T22:12:50Z</time>" page;
  contains ~sub:"egress: updated, 3 threads" page

let unreadable_row () =
  let page =
    html
      (Ok
         [
           observed
             ~receipts:(Error (store_error "torn line 3"))
             (loaded (test_charter "torn"));
         ])
  in
  contains ~msg:page ~sub:"item unreadable" page;
  contains ~sub:"read: /nonexistent: torn line 3" page;
  contains ~sub:"spend 24h: unreadable" page;
  contains ~sub:"last: unreadable" page

let () =
  Windtrap.run "mentat.charter_dashboard"
    [
      test "an empty roster says so plainly" empty_roster;
      test "a roster read failure is the page's own notice" roster_failure;
      test "a quiet charter needs no one" nothing_needed;
      test "attention buckets hold their fixed order" bucket_order;
      test "a failed alert names identity, session, and outcome" failed_item;
      test "overdue narrates; live and dead-but-owed runs do not" overdue_and_live;
      test "a tripped fence renders admission's own numbers" fenced_detail;
      test "dispositions fold under the digest in force" digest_scoping;
      test "a publishable settle with no egress is owed" unpublished_item;
      test "a broken-only roster keeps both statements honest" broken_only_roster;
      test "the ingress line follows the bound address" ingress_lines;
      test "the record row mirrors the status fold" record_row;
      test "unreadable receipts show the error, never a blank" unreadable_row;
    ]
