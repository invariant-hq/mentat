(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Transition = struct
  type t = Failed | Parked | Fenced

  let of_string = function
    | "failed" -> Some Failed
    | "parked" -> Some Parked
    | "fenced" -> Some Fenced
    | _ -> None

  let to_string = function
    | Failed -> "failed"
    | Parked -> "parked"
    | Fenced -> "fenced"

  let equal a b =
    match (a, b) with
    | Failed, Failed | Parked, Parked | Fenced, Fenced -> true
    | (Failed | Parked | Fenced), _ -> false
end

module Meter = struct
  type t = Usd_per_day | Runs_per_hour

  let of_string = function
    | "usd_per_day" -> Some Usd_per_day
    | "runs_per_hour" -> Some Runs_per_hour
    | _ -> None

  let to_string = function
    | Usd_per_day -> "usd_per_day"
    | Runs_per_hour -> "runs_per_hour"

  let window = function Usd_per_day -> 86400.0 | Runs_per_hour -> 3600.0

  let equal a b =
    match (a, b) with
    | Usd_per_day, Usd_per_day | Runs_per_hour, Runs_per_hour -> true
    | (Usd_per_day | Runs_per_hour), _ -> false
end

module Head = struct
  type t = Settled | Interrupted | Parked | Unsettled | Missing

  let of_string = function
    | "settled" -> Some Settled
    | "interrupted" -> Some Interrupted
    | "parked" -> Some Parked
    | "unsettled" -> Some Unsettled
    | "missing" -> Some Missing
    | _ -> None

  let to_string = function
    | Settled -> "settled"
    | Interrupted -> "interrupted"
    | Parked -> "parked"
    | Unsettled -> "unsettled"
    | Missing -> "missing"

  let equal a b =
    match (a, b) with
    | Settled, Settled
    | Interrupted, Interrupted
    | Parked, Parked
    | Unsettled, Unsettled
    | Missing, Missing ->
        true
    | (Settled | Interrupted | Parked | Unsettled | Missing), _ -> false
end

module Cause = struct
  type t = Exited | Wall_clock | Interrupted | Park_expired | Recovered

  let of_string = function
    | "exited" -> Some Exited
    | "wall_clock" -> Some Wall_clock
    | "interrupted" -> Some Interrupted
    | "park_expired" -> Some Park_expired
    | "recovered" -> Some Recovered
    | _ -> None

  let to_string = function
    | Exited -> "exited"
    | Wall_clock -> "wall_clock"
    | Interrupted -> "interrupted"
    | Park_expired -> "park_expired"
    | Recovered -> "recovered"

  let equal a b =
    match (a, b) with
    | Exited, Exited
    | Wall_clock, Wall_clock
    | Interrupted, Interrupted
    | Park_expired, Park_expired
    | Recovered, Recovered ->
        true
    | (Exited | Wall_clock | Interrupted | Park_expired | Recovered), _ ->
        false
end

module Disposition = struct
  type t =
    | Spawned of { session : string }
    | Skipped of string
    | Dup
    | Fenced of Meter.t
    | Already_exists
    | Superseded
    | Refused of string
    | Reaped of {
        session : string;
        exit : int;
        head : Head.t;
        usage : Jsont.json;
        usd : float option;
        cause : Cause.t;
      }

  let name = function
    | Spawned _ -> "spawned"
    | Skipped _ -> "skipped"
    | Dup -> "dup"
    | Fenced _ -> "fenced"
    | Already_exists -> "already_exists"
    | Superseded -> "superseded"
    | Refused _ -> "refused"
    | Reaped _ -> "reaped"

  let label t =
    match t with
    | Fenced meter -> Printf.sprintf "%s:%s" (name t) (Meter.to_string meter)
    | Reaped { exit; _ } -> Printf.sprintf "%s:%d" (name t) exit
    | Spawned _ | Skipped _ | Dup | Already_exists | Superseded | Refused _ ->
        name t
end

module Delivery = struct
  type t = {
    action : string;
    base_ref : string;
    draft : bool;
    author_association : string;
  }
end

module Kind = struct
  type t =
    | Delivery of Delivery.t option
    | Disposition of Disposition.t
    | Egress of {
        summary : [ `Created | `Updated | `None_needed | `Skipped_no_token ];
        threads : int;
      }
    | Alert of {
        transition : Transition.t;
        window : [ `Meter of Meter.t | `Identity ];
      }
end

type t = { at : float; identity : string; digest : string; kind : Kind.t }

module Error = Mentat_json.Error

let ( let* ) = Result.bind
let error ~context reason = Error (Mentat_json.Error.make ~context reason)

(* Encoding. *)

let mem name value = Jsont.Json.mem (Jsont.Json.name name) value
let str s = Jsont.Json.string s

let disposition_mems disposition =
  mem "disposition" (str (Disposition.name disposition))
  ::
  (match disposition with
  | Disposition.Spawned { session } -> [ mem "session" (str session) ]
  | Disposition.Skipped reason | Disposition.Refused reason ->
      [ mem "reason" (str reason) ]
  | Disposition.Dup | Disposition.Already_exists | Disposition.Superseded ->
      []
  | Disposition.Fenced meter -> [ mem "meter" (str (Meter.to_string meter)) ]
  | Disposition.Reaped { session; exit; head; usage; usd; cause } ->
      [
        mem "session" (str session);
        mem "exit" (Jsont.Json.int exit);
        mem "head" (str (Head.to_string head));
        mem "usage" usage;
      ]
      @ (match usd with
        | None -> []
        | Some usd -> [ mem "usd" (Jsont.Json.number usd) ])
      @ [ mem "cause" (str (Cause.to_string cause)) ])

let kind_mems = function
  | Kind.Delivery None -> (str "delivery", [])
  | Kind.Delivery (Some { Delivery.action; base_ref; draft; author_association })
    ->
      ( str "delivery",
        [
          mem "action" (str action);
          mem "base_ref" (str base_ref);
          mem "draft" (Jsont.Json.bool draft);
          mem "author_association" (str author_association);
        ] )
  | Kind.Disposition d -> (str "disposition", disposition_mems d)
  | Kind.Egress { summary; threads } ->
      ( str "egress",
        [
          mem "summary"
            (str
               (match summary with
               | `Created -> "created"
               | `Updated -> "updated"
               | `None_needed -> "none_needed"
               | `Skipped_no_token -> "skipped_no_token"));
          mem "threads" (Jsont.Json.int threads);
        ] )
  | Kind.Alert { transition; window } ->
      ( str "alert",
        [
          mem "transition" (str (Transition.to_string transition));
          mem "window"
            (str
               (match window with
               | `Meter meter -> Meter.to_string meter
               | `Identity -> "identity"));
        ] )

let encode t =
  let kind, payload = kind_mems t.kind in
  let json =
    Jsont.Json.object'
      ([
         mem "kind" kind;
         mem "at" (Jsont.Json.number t.at);
         mem "identity" (str t.identity);
         mem "digest" (str t.digest);
       ]
      @ payload)
  in
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok line -> line
  | Error message -> failwith message

(* Decoding. *)

let lowercase_hex s =
  String.length s > 0
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
       s

let as_time ~context = function
  | Jsont.Number (v, _) when Float.is_finite v && Float.compare v 0.0 >= 0 ->
      Ok v
  | _ -> error ~context "must be a non-negative number of seconds"

let as_cost ~context = function
  | Jsont.Number (v, _) when Float.is_finite v && Float.compare v 0.0 >= 0 ->
      Ok v
  | _ -> error ~context "must be a non-negative number"

let as_usage ~context = function
  | Jsont.Object _ as json -> Ok json
  | _ -> error ~context "must be a JSON object"

(* Peek one string member before routing, so the member set to route against
   can depend on it — the receipt kind and the disposition word both widen
   the legal members. *)
let peek_string name mems =
  match Jsont.Json.find_mem name mems with
  | Some (_, Jsont.String (s, _)) -> Ok s
  | Some _ -> error ~context:name "must be a string"
  | None -> error ~context:"" (Printf.sprintf "missing member %S" name)

let decode line =
  match Jsont_bytesrw.decode_string Jsont.json line with
  | Error reason -> error ~context:"" reason
  | Ok (Jsont.Object (mems, _)) ->
      let route extra =
        let slots =
          List.map
            (fun name -> (name, ref None))
            ([ "kind"; "at"; "identity"; "digest" ] @ extra)
        in
        let* () = Mentat_json.route_members ~context:"" ~slots mems in
        Ok slots
      in
      let value slots name =
        Mentat_json.require ~context:"" name (List.assoc name slots)
      in
      let string_value slots name =
        let* json = value slots name in
        Mentat_json.as_string ~context:name json
      in
      let finish slots kind =
        let* at =
          let* json = value slots "at" in
          as_time ~context:"at" json
        in
        let* identity =
          let* json = value slots "identity" in
          Mentat_json.as_non_empty_string ~context:"identity" json
        in
        let* digest =
          let* digest = string_value slots "digest" in
          if lowercase_hex digest then Ok digest
          else error ~context:"digest" "must be lowercase hexadecimal"
        in
        Ok { at; identity; digest; kind }
      in
      let reason_disposition slots wrap =
        let* reason =
          let* json = value slots "reason" in
          Mentat_json.as_non_empty_string ~context:"reason" json
        in
        finish slots (Kind.Disposition (wrap reason))
      in
      let session_value slots =
        let* json = value slots "session" in
        Mentat_json.as_non_empty_string ~context:"session" json
      in
      let* kind_word = peek_string "kind" mems in
      (match kind_word with
      | "delivery" ->
          let event_members =
            [ "action"; "base_ref"; "draft"; "author_association" ]
          in
          let* slots = route event_members in
          (* The event members arrive as a group: a line written before they
             existed carries none of them; a partial set is a torn line. *)
          if
            List.for_all
              (fun name -> Option.is_none !(List.assoc name slots))
              event_members
          then finish slots (Kind.Delivery None)
          else
            let* action =
              let* json = value slots "action" in
              Mentat_json.as_non_empty_string ~context:"action" json
            in
            let* base_ref =
              let* json = value slots "base_ref" in
              Mentat_json.as_non_empty_string ~context:"base_ref" json
            in
            let* draft =
              let* json = value slots "draft" in
              Mentat_json.as_bool ~context:"draft" json
            in
            let* author_association =
              let* json = value slots "author_association" in
              Mentat_json.as_non_empty_string ~context:"author_association"
                json
            in
            finish slots
              (Kind.Delivery
                 (Some
                    { Delivery.action; base_ref; draft; author_association }))
      | "disposition" -> (
          let* word = peek_string "disposition" mems in
          match word with
          | "spawned" ->
              let* slots = route [ "disposition"; "session" ] in
              let* session = session_value slots in
              finish slots (Kind.Disposition (Disposition.Spawned { session }))
          | "dup" ->
              let* slots = route [ "disposition" ] in
              finish slots (Kind.Disposition Disposition.Dup)
          | "already_exists" ->
              let* slots = route [ "disposition" ] in
              finish slots (Kind.Disposition Disposition.Already_exists)
          | "superseded" ->
              let* slots = route [ "disposition" ] in
              finish slots (Kind.Disposition Disposition.Superseded)
          | "skipped" ->
              let* slots = route [ "disposition"; "reason" ] in
              reason_disposition slots (fun r -> Disposition.Skipped r)
          | "refused" ->
              let* slots = route [ "disposition"; "reason" ] in
              reason_disposition slots (fun r -> Disposition.Refused r)
          | "fenced" ->
              let* slots = route [ "disposition"; "meter" ] in
              let* meter =
                let* name = string_value slots "meter" in
                match Meter.of_string name with
                | Some meter -> Ok meter
                | None -> error ~context:"meter" (Printf.sprintf "unknown meter %S" name)
              in
              finish slots (Kind.Disposition (Disposition.Fenced meter))
          | "reaped" ->
              let* slots =
                route
                  [
                    "disposition"; "session"; "exit"; "head"; "usage"; "usd";
                    "cause";
                  ]
              in
              let* session = session_value slots in
              let* exit =
                let* json = value slots "exit" in
                let* exit = Mentat_json.non_negative_int ~context:"exit" json in
                if exit <= 255 then Ok exit
                else error ~context:"exit" "must be at most 255"
              in
              let* head =
                let* name = string_value slots "head" in
                match Head.of_string name with
                | Some head -> Ok head
                | None ->
                    error ~context:"head"
                      (Printf.sprintf "unknown head outcome %S" name)
              in
              let* usage =
                let* json = value slots "usage" in
                as_usage ~context:"usage" json
              in
              let* usd =
                match !(List.assoc "usd" slots) with
                | None -> Ok None
                | Some json ->
                    Result.map Option.some (as_cost ~context:"usd" json)
              in
              let* cause =
                let* name = string_value slots "cause" in
                match Cause.of_string name with
                | Some cause -> Ok cause
                | None ->
                    error ~context:"cause"
                      (Printf.sprintf "unknown cause %S" name)
              in
              finish slots
                (Kind.Disposition
                   (Disposition.Reaped { session; exit; head; usage; usd; cause }))
          | other ->
              error ~context:"disposition"
                (Printf.sprintf "unknown disposition %S" other))
      | "egress" ->
          let* slots = route [ "summary"; "threads" ] in
          let* summary =
            let* name = string_value slots "summary" in
            match name with
            | "created" -> Ok `Created
            | "updated" -> Ok `Updated
            | "none_needed" -> Ok `None_needed
            | "skipped_no_token" -> Ok `Skipped_no_token
            | _ ->
                error ~context:"summary"
                  "must be \"created\", \"updated\", \"none_needed\", or \
                   \"skipped_no_token\""
          in
          let* threads =
            let* json = value slots "threads" in
            Mentat_json.non_negative_int ~context:"threads" json
          in
          finish slots (Kind.Egress { summary; threads })
      | "alert" ->
          let* slots = route [ "transition"; "window" ] in
          let* transition =
            let* name = string_value slots "transition" in
            match Transition.of_string name with
            | Some transition -> Ok transition
            | None ->
                error ~context:"transition"
                  "must be \"failed\", \"parked\", or \"fenced\""
          in
          let* window =
            let* name = string_value slots "window" in
            match Meter.of_string name with
            | Some meter -> Ok (`Meter meter)
            | None ->
                if String.equal name "identity" then Ok `Identity
                else
                  error ~context:"window"
                    "must name a meter or be \"identity\""
          in
          finish slots (Kind.Alert { transition; window })
      | other ->
          error ~context:"kind" (Printf.sprintf "unknown receipt kind %S" other))
  | Ok _ -> error ~context:"" "receipt must be a JSON object"

(* Diagnostic projection. *)

(* Civil date from a day count since 1970-01-01, proleptic Gregorian — the
   era decomposition keeps the arithmetic exact over the whole float-second
   range receipts can carry. Hand-rolled rather than [Unix.gmtime] because
   this library's dependency envelope deliberately excludes unix: the
   charter layer is pure and linkable anywhere. *)
let civil days =
  let z = days + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = mp + if mp < 10 then 3 else -9 in
  ((if m <= 2 then y + 1 else y), m, d)

let rfc3339 at =
  let seconds = int_of_float (Float.floor at) in
  let days =
    if seconds >= 0 then seconds / 86400 else (seconds - 86399) / 86400
  in
  let rem = seconds - (days * 86400) in
  let y, m, d = civil days in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" y m d (rem / 3600)
    (rem mod 3600 / 60) (rem mod 60)

let diagnostic t =
  let stamp = rfc3339 t.at in
  match t.kind with
  | Kind.Delivery _ -> Printf.sprintf "%s delivery %s" stamp t.identity
  | Kind.Disposition d -> (
      match d with
      | Disposition.Spawned { session } ->
          Printf.sprintf "%s spawned %s: session %s" stamp t.identity session
      | Disposition.Skipped reason ->
          Printf.sprintf "%s skipped %s: %s" stamp t.identity reason
      | (Disposition.Dup | Disposition.Already_exists | Disposition.Superseded)
        as bare ->
          Printf.sprintf "%s %s %s" stamp (Disposition.name bare) t.identity
      | Disposition.Fenced meter ->
          Printf.sprintf "%s fenced %s: %s" stamp t.identity
            (Meter.to_string meter)
      | Disposition.Refused reason ->
          Printf.sprintf "%s refused %s: %s" stamp t.identity reason
      | Disposition.Reaped { session; exit; head; usd; cause; usage = _ } ->
          Printf.sprintf "%s reaped %s: session %s, exit %d, head %s, cause %s, %s"
            stamp t.identity session exit (Head.to_string head)
            (Cause.to_string cause)
            (match usd with
            | Some usd -> Printf.sprintf "$%.4f" usd
            | None -> "unpriced"))
  | Kind.Egress { summary; threads } ->
      Printf.sprintf "%s egress %s: summary %s, %d threads" stamp t.identity
        (match summary with
        | `Created -> "created"
        | `Updated -> "updated"
        | `None_needed -> "none_needed"
        | `Skipped_no_token -> "skipped_no_token")
        threads
  | Kind.Alert { transition; window } ->
      Printf.sprintf "%s alert %s: %s (window %s)" stamp t.identity
        (Transition.to_string transition)
        (match window with
        | `Meter meter -> Meter.to_string meter
        | `Identity -> "identity")

(* Log queries. *)

let spawn_recorded ~digest ~identity receipts =
  List.exists
    (fun t ->
      match t.kind with
      | Kind.Disposition (Disposition.Spawned _) ->
          String.equal t.digest digest && String.equal t.identity identity
      | Kind.Disposition _ | Kind.Delivery _ | Kind.Egress _ | Kind.Alert _ ->
          false)
    receipts

let settled_session ~digest ~identity receipts =
  List.fold_left
    (fun acc t ->
      match t.kind with
      | Kind.Disposition
          (Disposition.Reaped { session; exit = 0; head = Head.Settled; _ })
        when String.equal t.digest digest && String.equal t.identity identity
        ->
          Some session
      | Kind.Disposition _ | Kind.Delivery _ | Kind.Egress _ | Kind.Alert _ ->
          acc)
    None receipts

let egress_recorded ~digest ~identity receipts =
  List.exists
    (fun t ->
      match t.kind with
      | Kind.Egress _ ->
          String.equal t.digest digest && String.equal t.identity identity
      | Kind.Delivery _ | Kind.Disposition _ | Kind.Alert _ -> false)
    receipts

let reap_recorded ~digest ~identity receipts =
  List.exists
    (fun t ->
      match t.kind with
      | Kind.Disposition (Disposition.Reaped _) ->
          String.equal t.digest digest && String.equal t.identity identity
      | Kind.Disposition _ | Kind.Delivery _ | Kind.Egress _ | Kind.Alert _ ->
          false)
    receipts

let alerted ~digest ~identity ~transition receipts =
  List.exists
    (fun t ->
      match t.kind with
      | Kind.Alert { transition = fired; window = `Identity } ->
          String.equal t.digest digest
          && String.equal t.identity identity
          && (match (fired, transition) with
             | Transition.Failed, Transition.Failed
             | Transition.Parked, Transition.Parked
             | Transition.Fenced, Transition.Fenced ->
                 true
             | (Transition.Failed | Transition.Parked | Transition.Fenced), _
               ->
                 false)
      | Kind.Alert { window = `Meter _; _ }
      | Kind.Delivery _ | Kind.Disposition _ | Kind.Egress _ ->
          false)
    receipts

module Pending = struct
  type t = {
    identity : string;
    digest : string;
    session : string;
    spawned_at : float;
  }
end

let pending_runs receipts =
  let reaped = Hashtbl.create 8 in
  List.iter
    (fun t ->
      match t.kind with
      | Kind.Disposition (Disposition.Reaped _) ->
          Hashtbl.replace reaped (t.digest, t.identity) ()
      | _ -> ())
    receipts;
  List.filter_map
    (fun t ->
      match t.kind with
      | Kind.Disposition (Disposition.Spawned { session })
        when not (Hashtbl.mem reaped (t.digest, t.identity)) ->
          Some
            {
              Pending.identity = t.identity;
              digest = t.digest;
              session;
              spawned_at = t.at;
            }
      | _ -> None)
    receipts

let open_deliveries receipts =
  let disposed = Hashtbl.create 8 in
  List.iter
    (fun t ->
      match t.kind with
      | Kind.Disposition _ -> Hashtbl.replace disposed (t.digest, t.identity) ()
      | _ -> ())
    receipts;
  (* The last delivery line per open pair: a redelivery re-records arrival,
     and the freshest members are the ones worth re-driving. *)
  let last = Hashtbl.create 8 in
  List.iter
    (fun t ->
      match t.kind with
      | Kind.Delivery _ when not (Hashtbl.mem disposed (t.digest, t.identity))
        ->
          Hashtbl.replace last (t.digest, t.identity) t
      | _ -> ())
    receipts;
  List.filter_map
    (fun t ->
      match Hashtbl.find_opt last (t.digest, t.identity) with
      | Some kept when kept == t -> Some t
      | Some _ | None -> None)
    receipts

