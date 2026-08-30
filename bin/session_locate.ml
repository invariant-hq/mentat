(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Store = Mentat_store
module Session = Mentat_session
module Id = Mentat_session.Id
module Document = Store.Session.Document
module Composition = Mentat_boot.Composition
module Exit_status = Mentat_boot.Exit_status

type candidate = { id : Id.t; available : bool }

type error =
  | Invalid_input of string
  | Store of Store.Session.Error.t
  | Ambiguous of { prefix : string; candidates : candidate list }
  | Unavailable of string

let message = function
  | Invalid_input message | Unavailable message -> message
  | Store error -> Store.Session.Error.message error
  | Ambiguous { prefix; candidates } ->
      let candidate candidate =
        let id = Id.to_string candidate.id in
        if candidate.available then id else id ^ " (unavailable)"
      in
      Printf.sprintf "ambiguous session id prefix %S: matches %s" prefix
        (String.concat ", " (List.map candidate candidates))

let status = function
  | Invalid_input message -> Exit_status.usage message
  | Ambiguous _ as error -> Exit_status.usage (message error)
  | Store error ->
      Exit_status.of_diagnostic (Store.Session.Error.diagnostic error)
  | Unavailable message -> Exit_status.runtime message

let scan t =
  match Store.Session.scan (Composition.store t) with
  | Error error -> Error (Store error)
  | Ok result -> Ok result

let doc_id d = Id.to_string (Document.id d)

let locate t raw =
  if String.is_empty raw then
    Error (Invalid_input "session id must not be empty")
  else
    let id = Id.of_string raw in
    match Store.Session.load (Composition.store t) id with
    | Ok document -> Ok document
    | Error (Store.Session.Error.Not_found _ as exact_not_found) -> (
        match scan t with
        | Error _ as error -> error
        | Ok (documents, corrupt) -> (
            let healthy =
              List.filter
                (fun document ->
                  String.starts_with ~prefix:raw (doc_id document))
                documents
            in
            let damaged =
              List.filter_map
                (fun fact ->
                  match Store.Session.Corrupt.id fact with
                  | Some id
                    when String.starts_with ~prefix:raw (Id.to_string id) ->
                      Some (id, fact)
                  | None | Some _ -> None)
                corrupt
            in
            match (healthy, damaged) with
            | [ document ], [] -> Ok document
            | [], [ (_, fact) ] ->
                Error (Store (Store.Session.Error.Corrupt fact))
            | [], [] -> Error (Store exact_not_found)
            | _ ->
                let healthy =
                  List.map
                    (fun document ->
                      { id = Document.id document; available = true })
                    healthy
                in
                let damaged =
                  List.map (fun (id, _) -> { id; available = false }) damaged
                in
                let candidates =
                  List.sort (fun a b -> Id.compare a.id b.id) (healthy @ damaged)
                in
                Error (Ambiguous { prefix = raw; candidates })))
    | Error error -> Error (Store error)

(* [--last] resumes the workspace's most recent resumable conversation, so it
   must agree with the session listing on membership. It consumes the one pure
   selector rather than re-deriving the filter: [Mentat_session.Listing.select]
   excludes delegated children — which a raw archived/deleted metadata filter
   would wrongly offer for resume — and orders by descending recency, so the head
   of a [limit]-one cwd/active listing is the session [--last] means. *)
let newest_in_cwd t =
  match scan t with
  | Error _ as error -> error
  | Ok (docs, _corrupt) -> (
      let root = Composition.root t in
      let listing : Mentat_session.Listing.t =
        {
          Mentat_session.Listing.scope = `Cwd;
          lifecycles = [ Session.Metadata.Status.Active ];
          search = None;
          limit = Some 1;
        }
      in
      let summaries =
        List.map (fun d -> Session.Summary.of_session (Document.session d)) docs
      in
      match Mentat_session.Listing.select ~cwd:root listing summaries with
      | summary :: _ -> (
          let id = Session.Summary.id summary in
          match List.find_opt (fun d -> Id.equal (Document.id d) id) docs with
          | Some d -> Ok d
          | None -> Error (Unavailable "no resumable session in this workspace")
          )
      | [] -> Error (Unavailable "no resumable session in this workspace"))

let resolve t ~session ~last =
  match (session, last) with
  | Some _, true -> Error (Invalid_input "choose SESSION or --last, not both")
  | Some raw, false -> locate t raw
  | None, true -> newest_in_cwd t
  | None, false ->
      Error
        (Invalid_input "requires SESSION or --last; run `mentat session list`")
