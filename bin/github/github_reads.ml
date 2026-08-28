(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Open_pr = struct
  type t = {
    number : int;
    head_sha : string;
    base_ref : string;
    draft : bool;
    author_association : string;
  }
end

let ( let* ) = Result.bind
let api_error e = Github_api.Error.message e

let head_sha_of item =
  Option.bind
    (Option.bind (Mentat_json.Lenient.mem "head" item)
       (Mentat_json.Lenient.mem "sha"))
    Mentat_json.Lenient.string

let current_head api ~repo ~number =
  match
    Github_api.get api ~path:(Printf.sprintf "/repos/%s/pulls/%d" repo number)
  with
  | Error e -> Error (api_error e)
  | Ok json -> (
      match head_sha_of json with
      | Some sha -> Ok sha
      | None -> Error "pull request answered without head.sha")

(* The listing's page items, mapped to typed rows. Members the pipeline does
   not gate on are ignored, the narrow-read posture every foreign payload
   gets. *)
let open_prs api ~repo =
  match
    Github_api.get_paginated api
      ~path:(Printf.sprintf "/repos/%s/pulls?state=open&per_page=100" repo)
      ~max_pages:10
  with
  | Error e -> Error (api_error e)
  | Ok pages ->
      Ok
        (List.concat_map
           (fun page ->
             match page with
             | Jsont.Array (items, _) ->
                 List.filter_map
                   (fun item ->
                     let ( let* ) = Option.bind in
                     let* number =
                       Option.bind
                         (Mentat_json.Lenient.mem "number" item)
                         Mentat_json.Lenient.int
                     in
                     let* head_sha = head_sha_of item in
                     let* base_ref =
                       Option.bind
                         (Option.bind
                            (Mentat_json.Lenient.mem "base" item)
                            (Mentat_json.Lenient.mem "ref"))
                         Mentat_json.Lenient.string
                     in
                     let* draft =
                       Option.bind
                         (Mentat_json.Lenient.mem "draft" item)
                         Mentat_json.Lenient.bool
                     in
                     let* author_association =
                       Option.bind
                         (Mentat_json.Lenient.mem "author_association" item)
                         Mentat_json.Lenient.string
                     in
                     Some
                       {
                         Open_pr.number;
                         head_sha;
                         base_ref;
                         draft;
                         author_association;
                       })
                   items
             | _ -> [])
           pages)

let viewer_login api =
  match Github_api.get api ~path:"/user" with
  | Error e -> Error (api_error e)
  | Ok json -> (
      match
        Option.bind (Mentat_json.Lenient.mem "login" json)
          Mentat_json.Lenient.string
      with
      | Some login -> Ok login
      | None -> Error "/user answered without a login member")

let posted api ~login ~repo ~number =
  let listing path =
    match Github_api.get_paginated api ~path ~max_pages:10 with
    | Error e -> Error (api_error e)
    | Ok pages ->
        Ok
          (List.concat_map
             (fun page ->
               match page with Jsont.Array (items, _) -> items | _ -> [])
             pages)
  in
  let* review_comments =
    listing (Printf.sprintf "/repos/%s/pulls/%d/comments?per_page=100" repo number)
  in
  let* issue_comments =
    listing (Printf.sprintf "/repos/%s/issues/%d/comments?per_page=100" repo number)
  in
  (* Both comment families the publisher writes into, filtered to the
     credential's own login and the connector's marker grammar — marker
     presence alone is forgeable, so the author predicate is what makes a
     comment ours. *)
  let ours item =
    let by_us =
      Option.bind
        (Option.bind (Mentat_json.Lenient.mem "user" item)
           (Mentat_json.Lenient.mem "login"))
        Mentat_json.Lenient.string
      = Some login
    in
    let marked =
      match
        Option.bind (Mentat_json.Lenient.mem "body" item)
          Mentat_json.Lenient.string
      with
      | Some body -> Mentat_connector.Publication.Marker.marks body
      | None -> false
    in
    by_us && marked
  in
  let rows =
    List.filter_map
      (fun item ->
        if not (ours item) then None
        else
          match
            ( Option.bind (Mentat_json.Lenient.mem "id" item)
                Mentat_json.Lenient.int,
              Option.bind (Mentat_json.Lenient.mem "body" item)
                Mentat_json.Lenient.string )
          with
          | Some id, Some body ->
              Some
                (Jsont.Json.object'
                   [
                     Jsont.Json.mem (Jsont.Json.name "id") (Jsont.Json.int id);
                     Jsont.Json.mem (Jsont.Json.name "body")
                       (Jsont.Json.string body);
                   ])
          | _ -> None)
      (review_comments @ issue_comments)
  in
  match Jsont_bytesrw.encode_string Jsont.json (Jsont.Json.list rows) with
  | Ok bytes -> Ok bytes
  | Error reason -> Error ("posted listing failed to encode: " ^ reason)
