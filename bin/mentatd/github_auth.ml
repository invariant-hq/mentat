(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Github_app_store = Mentat_boot.Github_app_store
module Routine_fire = Mentat_boot.Routine_fire
module Routine_store = Mentat_boot.Routine_store

let ( let* ) = Result.bind
let store_error e = Routine_store.Error.message e
let app_error e = Github_app_store.Error.message e

(* The narrowed permission sets the two mints request (A3): the read mint
   covers the git fetch and the three API reads, the write mint the poster
   child alone. *)
let read_permissions = [ ("contents", "read"); ("pull_requests", "read") ]
let write_permissions = [ ("pull_requests", "write") ]

(* The three reads, snapped onto the pipeline's injected record over one
   client; the posting identity comes from the caller's arm — [/user] for a
   PAT, the stored bot login for the App. A posted comment is ours iff the
   connector's marker grammar recognizes its body. *)
let reads api ~watched ~posted_login =
  {
    Routine_fire.Github.current_head =
      (fun ~number -> Github.Reads.current_head api ~repo:watched ~number);
    open_prs =
      (fun () ->
        Result.map
          (List.map (fun (pr : Github.Reads.Open_pr.t) ->
               {
                 Routine_fire.Github.number = pr.Github.Reads.Open_pr.number;
                 head_sha = pr.Github.Reads.Open_pr.head_sha;
                 base_ref = pr.Github.Reads.Open_pr.base_ref;
                 draft = pr.Github.Reads.Open_pr.draft;
                 author_association =
                   pr.Github.Reads.Open_pr.author_association;
               }))
          (Github.Reads.open_prs api ~repo:watched));
    posted =
      (fun ~number ->
        let* login = posted_login () in
        Github.Reads.posted api ~login
          ~marked:Mentat_connector.Publication.Marker.marks ~repo:watched
          ~number);
  }

let make_api ~net ~base_url ~token =
  match Mentat_boot.Github_transport.make ?base_url ~token net with
  | Ok api -> Ok api
  | Error e -> Error (Github.Api.Error.message e)

let pat_repo ~net ~base_url ~git_url ~watched (loaded : Routine_store.Loaded.t) =
  let* token =
    match Routine_store.read_secret loaded ~file:"read-token" with
    | Ok (Some token) -> Ok token
    | Ok None ->
        Error
          (Printf.sprintf
             "routine %s has no GitHub read credential at %s (a fine-grained \
              PAT with read access to %s)"
             loaded.Routine_store.Loaded.name
             (Filename.concat
                (Filename.concat loaded.Routine_store.Loaded.dir "secrets")
                "read-token")
             watched)
    | Error e -> Error (store_error e)
  in
  let* api = make_api ~net ~base_url ~token in
  let github =
    reads api ~watched ~posted_login:(fun () -> Github.Reads.viewer_login api)
  in
  Ok
    {
      Routine_fire.Repo.git_url;
      github;
      git_token =
        (fun () ->
          Result.map_error store_error
            (Routine_store.read_secret loaded ~file:"read-token"));
      write_token =
        (fun () ->
          Result.map_error store_error
            (Routine_store.read_secret loaded ~file:"write-token"));
    }

let strip_slashes url =
  let rec strip url =
    if String.length url > 0 && url.[String.length url - 1] = '/' then
      strip (String.sub url 0 (String.length url - 1))
    else url
  in
  strip url

let app_repo ~net ~base_url ~git_url ~watched (app : Github_app_store.t) =
  let effective =
    strip_slashes (Option.value base_url ~default:"https://api.github.com")
  in
  let* () =
    if String.equal effective (strip_slashes app.Github_app_store.api_base)
    then Ok ()
    else
      Error
        (Printf.sprintf
           "github app: the App at %s was created against %s, but this fire \
            is configured for %s; re-run `mentatd github setup` against this \
            host or write PAT files"
           app.Github_app_store.dir app.Github_app_store.api_base effective)
  in
  (* The key is re-read per mint: the file is the registration, so a
     replaced key is in force at the next event. *)
  let mint_jwt () =
    let* key_pem =
      Result.map_error app_error (Github_app_store.read_key_pem app)
    in
    Result.map_error
      (fun e -> Printf.sprintf "github app: %s" e)
      (Github.App.Jwt.make ~issuer:app.Github_app_store.client_id ~key_pem
         ~now:(Unix.gettimeofday ()))
  in
  let* jwt = mint_jwt () in
  let* jwt_api = make_api ~net ~base_url ~token:jwt in
  let* installation_id =
    match Github.App.Mint.installation_id jwt_api ~repo:watched with
    | Ok id -> Ok id
    | Error `No_installation ->
        Error
          (Printf.sprintf
             "github app: %s is not installed on %s; install it: %s"
             app.Github_app_store.slug watched
             (Github_app_store.install_url app))
    | Error (`Error message) ->
        Error (Printf.sprintf "github app: installation lookup: %s" message)
  in
  let* read_token =
    Result.map_error
      (fun e -> Printf.sprintf "github app: read token mint: %s" e)
      (Github.App.Mint.access_token jwt_api ~installation_id ~repo:watched
         ~permissions:read_permissions)
  in
  let* api = make_api ~net ~base_url ~token:read_token in
  let github =
    reads api ~watched ~posted_login:(fun () ->
        Ok (Github_app_store.posting_login app))
  in
  (* The write mint happens at publish time, freshly JWT'd, so the
     write-capable token exists only for the seconds a publication takes
     and never during the run window. *)
  let write_token () =
    let* jwt = mint_jwt () in
    let* jwt_api = make_api ~net ~base_url ~token:jwt in
    let* token =
      Result.map_error
        (fun e -> Printf.sprintf "github app: write token mint: %s" e)
        (Github.App.Mint.access_token jwt_api ~installation_id ~repo:watched
           ~permissions:write_permissions)
    in
    Ok (Some token)
  in
  Ok
    {
      Routine_fire.Repo.git_url;
      github;
      git_token = (fun () -> Ok (Some read_token));
      write_token;
    }

let repo ~dirs ~net ~base_url ~git_url (loaded : Routine_store.Loaded.t) =
  let watched = loaded.Routine_store.Loaded.routine.Mentat_routine.Routine.repo in
  match Routine_store.auth_mode dirs loaded with
  | Error e -> Error (store_error e)
  | Ok `Pat -> pat_repo ~net ~base_url ~git_url ~watched loaded
  | Ok (`App app) -> app_repo ~net ~base_url ~git_url ~watched app
  | Ok `Neither ->
      Error
        (Printf.sprintf
           "routine %s has no GitHub credential: install the App (`mentatd \
            github setup`) or write %s"
           loaded.Routine_store.Loaded.name
           (Filename.concat
              (Filename.concat loaded.Routine_store.Loaded.dir "secrets")
              "read-token"))
