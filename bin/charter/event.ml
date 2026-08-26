(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Pull_request = struct
  type t = {
    action : string;
    number : int;
    head_sha : string;
    base_ref : string;
    draft : bool;
    author_association : string;
    repo : string;
  }

  module Error = Mentat_json.Error

  let ( let* ) = Result.bind
  let error ~context reason = Error (Mentat_json.Error.make ~context reason)

  (* Narrow member access: take the named member, ignore its siblings. *)
  let member ~context name mems =
    match Jsont.Json.find_mem name mems with
    | Some (_, json) -> Ok json
    | None ->
        error ~context (Printf.sprintf "missing member %S" name)

  let path ~context name =
    if String.equal context "" then name else context ^ "." ^ name

  let member_string ~context name mems =
    let* json = member ~context name mems in
    Mentat_json.as_string ~context:(path ~context name) json

  let member_bool ~context name mems =
    let* json = member ~context name mems in
    Mentat_json.as_bool ~context:(path ~context name) json

  let member_int ~context name mems =
    let* json = member ~context name mems in
    Mentat_json.positive_int ~context:(path ~context name) json

  let member_object ~context name mems =
    let* json = member ~context name mems in
    match json with
    | Jsont.Object (inner, _) -> Ok inner
    | _ -> error ~context:(path ~context name) "must be a JSON object"

  let action_token s =
    String.length s > 0
    && String.for_all (fun c -> (c >= 'a' && c <= 'z') || Char.equal c '_') s

  let association_token s =
    String.length s > 0
    && String.for_all (fun c -> (c >= 'A' && c <= 'Z') || Char.equal c '_') s

  let commit_sha s =
    (String.length s = 40 || String.length s = 64)
    && String.for_all
         (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
         s

  (* The base ref reaches a git fetch refspec, so it gets the ref-name
     discipline the head hash and repository name already get: no byte git's
     own ref grammar refuses, no leading '-', no '..', no leading or
     trailing '/'. *)
  let ref_name s =
    let n = String.length s in
    let byte c =
      Char.code c > 32
      && Char.code c <> 127
      && not
           (Char.equal c '~' || Char.equal c '^' || Char.equal c ':'
          || Char.equal c '?' || Char.equal c '*' || Char.equal c '['
          || Char.equal c '\\')
    in
    n > 0
    && (not (Char.equal s.[0] '-'))
    && (not (Char.equal s.[0] '/'))
    && (not (Char.equal s.[n - 1] '/'))
    && String.for_all byte s
    &&
    let rec no_dotdot i =
      i + 2 > n
      || ((not (Char.equal s.[i] '.' && Char.equal s.[i + 1] '.'))
         && no_dotdot (i + 1))
    in
    no_dotdot 0

  (* The decoder recurses per nesting level, so depth is bounded before it
     runs: a delivery needs a handful of levels, and a hostile megabyte of
     brackets must be a decode error, never a stack fault. The scan is
     string-aware — a bracket inside a string literal nests nothing. *)
  let max_depth = 64

  let nesting_depth bytes =
    let n = String.length bytes in
    let rec go i depth deepest in_string escaped =
      if i >= n || deepest > max_depth then deepest
      else
        let c = bytes.[i] in
        if in_string then
          if escaped then go (i + 1) depth deepest true false
          else if Char.equal c '\\' then go (i + 1) depth deepest true true
          else if Char.equal c '"' then go (i + 1) depth deepest false false
          else go (i + 1) depth deepest true false
        else
          match c with
          | '{' | '[' ->
              go (i + 1) (depth + 1) (Stdlib.max (depth + 1) deepest) false
                false
          | '}' | ']' -> go (i + 1) (depth - 1) deepest false false
          | '"' -> go (i + 1) depth deepest true false
          | _ -> go (i + 1) depth deepest false false
    in
    go 0 0 0 false false

  let decode bytes =
    if nesting_depth bytes > max_depth then
      error ~context:""
        (Printf.sprintf "nesting exceeds %d levels" max_depth)
    else
      match
        (* The depth bound above keeps the recursive decoder inside the
           stack; a residual fault must still be a decode error, never a
           crash. *)
        try Jsont_bytesrw.decode_string Jsont.json bytes
        with Stack_overflow -> Error "nesting overflows the decoder"
      with
      | Error reason -> error ~context:"" reason
      | Ok (Jsont.Object (mems, _)) ->
        let* action = member_string ~context:"" "action" mems in
        let* action =
          if action_token action then Ok action
          else
            error ~context:"action"
              "must be a lowercase action token like \"opened\""
        in
        let* repository = member_object ~context:"" "repository" mems in
        let* repo =
          let* name = member_string ~context:"repository" "full_name" repository in
          Mentat_json.repo_full_name ~context:"repository.full_name" name
        in
        let* pull_request = member_object ~context:"" "pull_request" mems in
        let in_pr = "pull_request" in
        let* number = member_int ~context:in_pr "number" pull_request in
        let* draft = member_bool ~context:in_pr "draft" pull_request in
        let* author_association =
          let* value =
            member_string ~context:in_pr "author_association" pull_request
          in
          if association_token value then Ok value
          else
            error ~context:"pull_request.author_association"
              "must be an uppercase association token"
        in
        let* head = member_object ~context:in_pr "head" pull_request in
        let* head_sha =
          let* sha = member_string ~context:"pull_request.head" "sha" head in
          if commit_sha sha then Ok sha
          else
            error ~context:"pull_request.head.sha"
              "must be a 40- or 64-character lowercase commit hash"
        in
        let* base = member_object ~context:in_pr "base" pull_request in
        let* base_ref =
          let* value =
            member_string ~context:"pull_request.base" "ref" base
          in
          if ref_name value then Ok value
          else
            error ~context:"pull_request.base.ref"
              "must be a git branch name"
        in
        Ok { action; number; head_sha; base_ref; draft; author_association; repo }
      | Ok _ -> error ~context:"" "payload must be a JSON object"
end

module Identity = struct
  type t = string

  (* The actions that all say "this head wants review" collapse to one
     class: the head commit already separates pushes, so a second delivery
     about the same head — reopened after opened, ready after draft — is the
     same event, not a fresh spend. *)
  let review_class = function
    | "opened" | "reopened" | "ready_for_review" | "synchronize" -> true
    | _ -> false

  let action_class action = if review_class action then "head" else action

  let of_pull_request (pr : Pull_request.t) =
    let { Pull_request.action; number; head_sha; repo; _ } = pr in
    Printf.sprintf "github:%s#%d@%s:%s" repo number head_sha
      (action_class action)

  let policy_digest_hex s =
    String.length s = 16
    && String.for_all
         (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
         s

  let cli ~digest ~key =
    if not (policy_digest_hex digest) then
      invalid_arg "Event.Identity.cli: digest must be 16 lowercase hex characters";
    if String.equal key "" then
      invalid_arg "Event.Identity.cli: key must be non-empty";
    Printf.sprintf "cli:%s:%s" digest key

  let to_string t = t
  let equal = String.equal
end
