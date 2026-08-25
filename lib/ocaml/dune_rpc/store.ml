(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  synced : bool;
  findings : (string * Mentat_ocaml.Finding.t) list;
  busy : bool;
  settle_witnessed : bool;
  last_event : Mtime.t option;
}

let initial =
  {
    synced = false;
    findings = [];
    busy = true;
    settle_witnessed = false;
    last_event = None;
  }

type event =
  | Connected
  | Diagnostics of
      [ `Add of string * Mentat_ocaml.Finding.t | `Remove of string ] list
  | Progress of [ `Settle | `Busy ]

let apply ~at event t =
  match event with
  (* The quiet clock restarts at the connection, so a reading is never
     admitted on the strength of silence that predates the stream. *)
  | Connected -> { initial with last_event = Some at }
  | Diagnostics events ->
      List.fold_left
        (fun t event ->
          match event with
          | `Add (id, finding) ->
              {
                t with
                findings = (id, finding) :: List.remove_assoc id t.findings;
              }
          | `Remove id ->
              {
                t with
                findings = List.remove_assoc id t.findings;
                settle_witnessed = false;
              })
        { t with synced = true; last_event = Some at }
        events
  | Progress `Settle -> { t with busy = false; settle_witnessed = true }
  | Progress `Busy -> { t with busy = true }

let building t = t.busy

let span_s a b = Mtime.Span.to_float_ns (Mtime.span a b) *. 1e-9

let reading t ~now ~quiet_s ~fallback_s =
  if (not t.synced) || t.busy then None
  else
    let quiet_for =
      match t.last_event with None -> 0. | Some at -> span_s at now
    in
    if quiet_for < quiet_s then None
    else
      let empty_confirmed =
        t.settle_witnessed || quiet_for >= fallback_s
      in
      Some
        (Mentat_ocaml.Build_change.Reading.make ~empty_confirmed
           (List.rev_map snd t.findings))
