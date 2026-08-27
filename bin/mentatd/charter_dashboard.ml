(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mentat_charter
open Mentat_web

module Observed = struct
  type run = { pending : Receipt.Pending.t; fence : Record.fence }

  type charter = {
    loaded : Charter_store.Loaded.t;
    receipts : (Receipt.t list, Charter_store.Error.t) result;
    runs : run list;
  }

  type t =
    | Broken of { name : string; error : Charter_store.Error.t }
    | Charter of charter
end

(* The observation. Every read is per request — the roster, each charter's
   receipts, one fence probe per open run — so an owner's edit is in force
   at the next request and the page can never disagree with the record. *)

let observe ~dirs ~store =
  Result.map
    (List.map (fun (name, entry) ->
         match entry with
         | Error error -> Observed.Broken { name; error }
         | Ok loaded ->
             let receipts = Charter_store.read_receipts dirs ~name in
             let runs =
               match receipts with
               | Error _ -> []
               | Ok receipts ->
                   List.map
                     (fun (pending : Receipt.Pending.t) ->
                       {
                         Observed.pending;
                         fence =
                           Charter_fire.probe_fence store
                             ~session:pending.Receipt.Pending.session;
                       })
                     (Receipt.pending_runs receipts)
             in
             Observed.Charter { Observed.loaded; receipts; runs }))
    (Charter_store.roster dirs)

(* Shared fragments. *)

let utc at =
  let tm = Unix.gmtime at in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let stamp at = Html.El.time [ Html.El.txt (utc at) ]

(* The leading '/' pins the link to a same-origin path, whatever bytes the
   receipt carried. *)
let session_link session =
  Html.El.a
    ~at:[ Html.At.href ("/session/" ^ session); Html.At.class_ "session" ]
    [ Html.El.txt ("session " ^ session) ]

let detail text =
  Html.El.span ~at:[ Html.At.class_ "detail" ] [ Html.El.txt text ]

let identity_span identity =
  Html.El.span ~at:[ Html.At.class_ "identity" ] [ Html.El.txt identity ]

(* ── The attention fold ──────────────────────────────────────────────────
   Buckets fix the page's order; within one bucket the roster's order and
   the log's order stand ([attention]'s sort is stable). *)

let rank_parked = 0
let rank_failed = 1
let rank_broken = 2
let rank_unreadable = 3
let rank_overdue = 4
let rank_unprobeable = 5
let rank_fenced = 6
let rank_unpublished = 7

let item ~kind ~name parts =
  Html.El.li
    ~at:[ Html.At.class_ ("item " ^ kind) ]
    (Html.El.span ~at:[ Html.At.class_ "charter" ] [ Html.El.txt name ]
    :: Html.El.span ~at:[ Html.At.class_ "kind" ] [ Html.El.txt kind ]
    :: parts)

(* The last session an identity's dispositions name — the attach path an
   alert's owner follows. *)
let session_of ~digest ~identity receipts =
  List.fold_left
    (fun acc (r : Receipt.t) ->
      if
        String.equal r.Receipt.digest digest
        && String.equal r.Receipt.identity identity
      then
        match r.Receipt.kind with
        | Receipt.Kind.Disposition (Receipt.Disposition.Spawned { session })
        | Receipt.Kind.Disposition (Receipt.Disposition.Reaped { session; _ })
          ->
            Some session
        | Receipt.Kind.Disposition _ | Receipt.Kind.Delivery _
        | Receipt.Kind.Egress _ | Receipt.Kind.Alert _ ->
            acc
      else acc)
    None receipts

(* Parked and failed runs are read off the identity-scoped alert receipts
   the fire pipeline wrote — its own once-per-event judgment, never
   re-derived here, so the page and the alert surface cannot disagree.
   Fence trips alert under a meter window and render from the live fold
   below instead: a rolled window is no longer an attention item. *)
let alert_items ~name ~digest receipts =
  List.filter_map
    (fun (r : Receipt.t) ->
      match r.Receipt.kind with
      | Receipt.Kind.Alert { transition; window = `Identity }
        when String.equal r.Receipt.digest digest -> (
          let parts text =
            detail text
            :: identity_span r.Receipt.identity
            :: (match session_of ~digest ~identity:r.Receipt.identity receipts
                with
               | Some session -> [ session_link session ]
               | None -> [])
            @ [ stamp r.Receipt.at ]
          in
          match transition with
          | Receipt.Transition.Parked ->
              Some
                ( rank_parked,
                  item ~kind:"parked" ~name
                    (parts "parked on a question; answer it from its session")
                )
          | Receipt.Transition.Failed ->
              Some
                ( rank_failed,
                  item ~kind:"failed" ~name
                    (parts "settled without a publishable outcome") )
          | Receipt.Transition.Fenced -> None)
      | Receipt.Kind.Alert _ | Receipt.Kind.Delivery _
      | Receipt.Kind.Disposition _ | Receipt.Kind.Egress _ ->
          None)
    receipts

(* Open runs, judged by the reconcile fold's own pending-run table — the
   page narrates exactly what a pass would: an overdue holder is left to
   finish, an unprobeable fence is never settled over. A run within budget
   or one owed only the node's honest settle needs no owner. *)
let run_items ~name ~now ~budget runs =
  List.concat_map
    (fun { Observed.pending; fence } ->
      let { Receipt.Pending.session; spawned_at; _ } = pending in
      match
        Record.run_action
          ~fence:(fun () -> fence)
          ~overdue:(fun () ->
            now -. spawned_at > budget.Charter.Budget.wall_clock)
      with
      | `Settle | `Leave -> []
      | `Overdue ->
          [
            ( rank_overdue,
              item ~kind:"overdue" ~name
                [
                  detail
                    "outlives its wall clock; its fence holder is left to \
                     finish";
                  session_link session;
                  stamp spawned_at;
                ] );
          ]
      | `Skip message ->
          [
            ( rank_unprobeable,
              item ~kind:"unprobeable" ~name
                [
                  detail ("run fence unprobeable: " ^ message);
                  session_link session;
                ] );
          ])
    runs

(* The tripped-fence item, derived from the same fold admission runs at the
   same instant — what is displayed is what the next delivery meets. The
   no-limit arms are unreachable (a meter without a limit cannot trip) but
   render the count honestly rather than raising. *)
let fence_items ~name ~digest ~now ~budget ~trigger receipts =
  match Fence.admit ~digest ~budget ~trigger ~now receipts with
  | Fence.Pass -> []
  | Fence.Fenced meter ->
      let text =
        match meter with
        | Receipt.Meter.Usd_per_day -> (
            let spend = Fence.spend_in_window ~digest ~now receipts in
            match budget.Charter.Budget.usd_per_day with
            | Some limit ->
                Printf.sprintf "usd_per_day exhausted: %.2f usd of %.2f in 24h"
                  spend limit
            | None -> Printf.sprintf "usd_per_day exhausted: %.2f usd" spend)
        | Receipt.Meter.Runs_per_hour -> (
            let spawns = Fence.spawns_in_window ~digest ~now receipts in
            match Fence.effective_runs_per_hour ~budget ~trigger with
            | Some limit ->
                Printf.sprintf "runs_per_hour exhausted: %d of %d in 1h" spawns
                  limit
            | None -> Printf.sprintf "runs_per_hour exhausted: %d" spawns)
      in
      [ (rank_fenced, item ~kind:"fenced" ~name [ detail text ]) ]

let distinct_identities ~digest receipts =
  List.rev
    (List.fold_left
       (fun acc (r : Receipt.t) ->
         if
           String.equal r.Receipt.digest digest
           && not (List.mem r.Receipt.identity acc)
         then r.Receipt.identity :: acc
         else acc)
       [] receipts)

(* A publishable settle with no egress line — the one state the sweep
   re-publishes. It converges on the next pass; it renders because until
   then a review the owner paid for is not on its pull request. *)
let owed_items ~name ~digest receipts =
  List.filter_map
    (fun identity ->
      match Receipt.settled_session ~digest ~identity receipts with
      | Some session when not (Receipt.egress_recorded ~digest ~identity receipts)
        ->
          Some
            ( rank_unpublished,
              item ~kind:"unpublished" ~name
                [
                  detail
                    "settled with no egress line; the next pass re-enters the \
                     publisher";
                  identity_span identity;
                  session_link session;
                ] )
      | Some _ | None -> None)
    (distinct_identities ~digest receipts)

(* One charter's attention items. Disposition-derived buckets fold under
   the digest in force — the record the sweep operates on, which a policy
   edit deliberately re-opens — while open runs are judged whatever their
   digest, exactly as the reconcile fold adopts them. *)
let attention_of ~now = function
  | Observed.Broken { name; error } ->
      [
        ( rank_broken,
          item ~kind:"broken" ~name
            [ detail (Charter_store.Error.message error) ] );
      ]
  | Observed.Charter { Observed.loaded; receipts; runs } -> (
      let name = loaded.Charter_store.Loaded.name in
      let digest = loaded.Charter_store.Loaded.digest in
      let charter = loaded.Charter_store.Loaded.charter in
      let budget = charter.Charter.budget in
      match receipts with
      | Error error ->
          [
            ( rank_unreadable,
              item ~kind:"unreadable" ~name
                [ detail (Charter_store.Error.message error) ] );
          ]
      | Ok receipts ->
          alert_items ~name ~digest receipts
          @ run_items ~name ~now ~budget runs
          @ fence_items ~name ~digest ~now ~budget
              ~trigger:(Charter.delivery_trigger charter)
              receipts
          @ owed_items ~name ~digest receipts)

let attention ~now entries =
  List.map snd
    (List.stable_sort
       (fun (a, _) (b, _) -> Int.compare a b)
       (List.concat_map (attention_of ~now) entries))

(* ── The record ─────────────────────────────────────────────────────────── *)

let line nodes = Html.El.li nodes
let text_line text = line [ Html.El.txt text ]

let last_disposition receipts =
  List.fold_left
    (fun acc (r : Receipt.t) ->
      match r.Receipt.kind with
      | Receipt.Kind.Disposition disposition -> Some (r, disposition)
      | Receipt.Kind.Delivery _ | Receipt.Kind.Egress _ | Receipt.Kind.Alert _ ->
          acc)
    None receipts

let last_egress receipts =
  List.fold_left
    (fun acc (r : Receipt.t) ->
      match r.Receipt.kind with
      | Receipt.Kind.Egress { summary; threads } -> Some (r, summary, threads)
      | Receipt.Kind.Delivery _ | Receipt.Kind.Disposition _
      | Receipt.Kind.Alert _ ->
          acc)
    None receipts

let egress_token = function
  | `Created -> "created"
  | `Updated -> "updated"
  | `None_needed -> "none_needed"
  | `Skipped_no_token -> "skipped_no_token"

let last_line receipts =
  match last_disposition receipts with
  | None -> text_line "last: no receipts"
  | Some ((r : Receipt.t), disposition) ->
      let session =
        match disposition with
        | Receipt.Disposition.Spawned { session }
        | Receipt.Disposition.Reaped { session; _ } ->
            [ session_link session ]
        | Receipt.Disposition.Skipped _ | Receipt.Disposition.Dup
        | Receipt.Disposition.Fenced _ | Receipt.Disposition.Already_exists
        | Receipt.Disposition.Superseded | Receipt.Disposition.Refused _ ->
            []
      in
      line
        ([
           Html.El.txt
             (Printf.sprintf "last: %s " (Receipt.Disposition.label disposition));
           stamp r.Receipt.at;
         ]
        @ session)

let egress_line receipts =
  match last_egress receipts with
  | None -> text_line "egress: -"
  | Some ((r : Receipt.t), summary, threads) ->
      line
        [
          Html.El.txt
            (Printf.sprintf "egress: %s, %d threads " (egress_token summary)
               threads);
          stamp r.Receipt.at;
        ]

let ingress_line ~ingress ingress_id =
  match ingress_id with
  | None -> []
  | Some id -> (
      let path = "/ingress/github/" ^ id in
      match ingress with
      | Some address ->
          [ text_line (Printf.sprintf "ingress: POST http://%s%s" address path) ]
      | None -> [ text_line (Printf.sprintf "ingress: POST %s (unbound)" path) ]
      )

(* One roster row. A broken charter has no digest, state, or fences to
   show — its refusal is an attention item, so it takes no row here. *)
let record_row ~now ~ingress = function
  | Observed.Broken _ -> None
  | Observed.Charter { Observed.loaded; receipts; runs = _ } ->
      let name = loaded.Charter_store.Loaded.name in
      let digest = loaded.Charter_store.Loaded.digest in
      let charter = loaded.Charter_store.Loaded.charter in
      let budget = charter.Charter.budget in
      let state = if charter.Charter.enabled then "enabled" else "disabled" in
      let meters =
        match receipts with
        | Error _ ->
            [
              text_line "spend 24h: unreadable";
              text_line "runs 1h: unreadable";
              text_line "last: unreadable";
              text_line "egress: unreadable";
            ]
        | Ok receipts ->
            [
              text_line (Fence.spend_line ~digest ~now ~budget receipts);
              text_line
                (Fence.runs_line ~digest ~now ~budget
                   ~trigger:(Charter.delivery_trigger charter)
                   receipts);
              last_line receipts;
              egress_line receipts;
            ]
      in
      Some
        (Html.El.li
           ~at:[ Html.At.class_ "charter" ]
           [
             Html.El.div
               ~at:[ Html.At.class_ "head" ]
               [
                 Html.El.span ~at:[ Html.At.class_ "name" ] [ Html.El.txt name ];
                 Html.El.span
                   ~at:[ Html.At.class_ "digest" ]
                   [ Html.El.txt digest ];
                 Html.El.span
                   ~at:[ Html.At.class_ ("state " ^ state) ]
                   [ Html.El.txt state ];
               ];
             Html.El.ul
               ~at:[ Html.At.class_ "meters" ]
               (meters
               @ ingress_line ~ingress
                   loaded.Charter_store.Loaded.ingress_id);
           ])

(* ── The document ───────────────────────────────────────────────────────── *)

let shell body =
  Page.document ~head_title:"Mentat — Charters"
    ~body:
      [
        Html.El.v
          ~at:[ Html.At.class_ "top" ]
          "header"
          [
            Html.El.a ~at:[ Html.At.href "/" ] [ Html.El.txt "← Sessions" ];
            Html.El.h 1 [ Html.El.txt "Charters" ];
          ];
        Html.El.v ~at:[ Html.At.class_ "charters" ] "main" body;
      ]

let empty_notice text =
  Html.El.p ~at:[ Html.At.class_ "empty" ] [ Html.El.txt text ]

let page ~now ~ingress observed =
  match observed with
  | Error error ->
      shell
        [
          Html.El.p
            ~at:[ Html.At.class_ "notice failure" ]
            [ Html.El.txt (Charter_store.Error.message error) ];
        ]
  | Ok [] ->
      shell
        [
          empty_notice
            "No charters are installed. Install one with mentat charter add.";
        ]
  | Ok entries ->
      let items = attention ~now entries in
      let needs =
        Html.El.section
          ~at:[ Html.At.id "needs-me" ]
          (Html.El.h 2 [ Html.El.txt "Needs you" ]
          ::
          (match items with
          | [] -> [ empty_notice "Nothing needs you." ]
          | items -> [ Html.El.ul ~at:[ Html.At.class_ "items" ] items ]))
      in
      let rows = List.filter_map (record_row ~now ~ingress) entries in
      let record =
        Html.El.section
          ~at:[ Html.At.id "record" ]
          (Html.El.h 2 [ Html.El.txt "The record" ]
          ::
          (match rows with
          | [] ->
              [
                empty_notice
                  "Every installed charter failed to load; each refusal is \
                   named above.";
              ]
          | rows -> [ Html.El.ul ~at:[ Html.At.class_ "roster" ] rows ]))
      in
      shell [ needs; record ]
