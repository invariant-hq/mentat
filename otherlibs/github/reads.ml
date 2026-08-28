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
let api_error e = Api.Error.message e

(* Narrow reads over GitHub's response documents: take the named member when
   it has the expected shape, ignore everything else — the foreign document
   grows members freely, and what absence means stays with each caller. *)
let member name = function
  | Jsont.Object (mems, _) -> Option.map snd (Jsont.Json.find_mem name mems)
  | _ -> None

let string_value = function Jsont.String (s, _) -> Some s | _ -> None
let bool_value = function Jsont.Bool (b, _) -> Some b | _ -> None

let int_value = function
  | Jsont.Number (v, _) when Float.is_integer v -> Some (int_of_float v)
  | _ -> None

let head_sha_of item =
  Option.bind (Option.bind (member "head" item) (member "sha")) string_value

let current_head api ~repo ~number =
  match
    Api.get api ~path:(Printf.sprintf "/repos/%s/pulls/%d" repo number)
  with
  | Error e -> Error (api_error e)
  | Ok json -> (
      match head_sha_of json with
      | Some sha -> Ok sha
      | None -> Error "pull request answered without head.sha")

(* The listing's page items, mapped to typed rows. Members the caller does
   not gate on are ignored, the narrow-read posture every foreign payload
   gets. *)
let open_prs api ~repo =
  match
    Api.get_paginated api
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
                       Option.bind (member "number" item) int_value
                     in
                     let* head_sha = head_sha_of item in
                     let* base_ref =
                       Option.bind
                         (Option.bind (member "base" item) (member "ref"))
                         string_value
                     in
                     let* draft =
                       Option.bind (member "draft" item) bool_value
                     in
                     let* author_association =
                       Option.bind (member "author_association" item)
                         string_value
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
  match Api.get api ~path:"/user" with
  | Error e -> Error (api_error e)
  | Ok json -> (
      match Option.bind (member "login" json) string_value with
      | Some login -> Ok login
      | None -> Error "/user answered without a login member")

let posted api ~login ~marked ~repo ~number =
  let listing path =
    match Api.get_paginated api ~path ~max_pages:10 with
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
  (* Both comment families, filtered to the posting identity's own login and
     the caller's body predicate — a recognizable body alone is forgeable,
     so the author predicate is what makes a comment the caller's. *)
  let ours item =
    let by_us =
      Option.bind
        (Option.bind (member "user" item) (member "login"))
        string_value
      = Some login
    in
    let is_marked =
      match Option.bind (member "body" item) string_value with
      | Some body -> marked body
      | None -> false
    in
    by_us && is_marked
  in
  let rows =
    List.filter_map
      (fun item ->
        if not (ours item) then None
        else
          match
            ( Option.bind (member "id" item) int_value,
              Option.bind (member "body" item) string_value )
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
