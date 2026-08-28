(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

let b64url bytes =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet bytes

(* Minimal JSON string escaping for the hand-assembled JWT segments; the
   segments are built byte-exact so the pinned vector stays honest. *)
let json_escape s =
  let buffer = Buffer.create (String.length s + 2) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c when Char.code c < 32 ->
          Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.contents buffer

module Jwt = struct
  let skew_s = 60
  let lifetime_s = 540

  let make ~issuer ~key_pem ~now =
    let* key =
      match X509.Private_key.decode_pem key_pem with
      | Ok (`RSA key) -> Ok key
      | Ok _ -> Error "the private key is not an RSA key"
      (* The PEM decoder's message can quote input; a key file's bytes never
         belong in a diagnostic. *)
      | Error (`Msg _) -> Error "the private key PEM does not decode"
    in
    let iat = int_of_float now - skew_s in
    let exp = int_of_float now + lifetime_s in
    let header = {|{"alg":"RS256","typ":"JWT"}|} in
    let claims =
      Printf.sprintf {|{"iat":%d,"exp":%d,"iss":"%s"}|} iat exp
        (json_escape issuer)
    in
    let signing_input = b64url header ^ "." ^ b64url claims in
    (* PKCS 1.5 is deterministic and masking only blinds the transform's
       timing, so [`No] keeps the signing path free of any RNG dependency —
       the signer runs in the token owner's own process, not against an
       adversarial timing observer. *)
    match
      Mirage_crypto_pk.Rsa.PKCS1.sign ~mask:`No ~hash:`SHA256 ~key
        (`Message signing_input)
    with
    | signature -> Ok (signing_input ^ "." ^ b64url signature)
    | exception Mirage_crypto_pk.Rsa.Insufficient_key ->
        Error "the private key is too small to sign with"
end

(* HTML attribute/body escaping for the entry page. *)
let html_escape s =
  let buffer = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '&' -> Buffer.add_string buffer "&amp;"
      | '<' -> Buffer.add_string buffer "&lt;"
      | '>' -> Buffer.add_string buffer "&gt;"
      | '"' -> Buffer.add_string buffer "&quot;"
      | '\'' -> Buffer.add_string buffer "&#39;"
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.contents buffer

module Manifest = struct
  let strip_slashes url =
    let rec strip url =
      if String.length url > 0 && url.[String.length url - 1] = '/' then
        strip (String.sub url 0 (String.length url - 1))
      else url
    in
    strip url

  let web_base ~api_base =
    let base = strip_slashes api_base in
    if String.equal base "https://api.github.com" then "https://github.com"
    else if String.ends_with ~suffix:"/api/v3" base then
      String.sub base 0 (String.length base - String.length "/api/v3")
    else base

  let create_url ~web_base ~org ~state =
    match org with
    | Some org ->
        Printf.sprintf "%s/organizations/%s/settings/apps/new?state=%s"
          web_base org state
    | None -> Printf.sprintf "%s/settings/apps/new?state=%s" web_base state

  let json ~name ~homepage ~redirect_url ~hook_url ~events ~permissions =
    let mem name value = Jsont.Json.mem (Jsont.Json.name name) value in
    let manifest =
      Jsont.Json.object'
        [
          mem "name" (Jsont.Json.string name);
          mem "url" (Jsont.Json.string homepage);
          mem "public" (Jsont.Json.bool false);
          mem "redirect_url" (Jsont.Json.string redirect_url);
          mem "hook_attributes"
            (Jsont.Json.object'
               [
                 mem "url" (Jsont.Json.string hook_url);
                 mem "active" (Jsont.Json.bool true);
               ]);
          mem "default_events"
            (Jsont.Json.list
               (List.map (fun event -> Jsont.Json.string event) events));
          mem "default_permissions"
            (Jsont.Json.object'
               (List.map
                  (fun (permission, access) ->
                    mem permission (Jsont.Json.string access))
                  permissions));
        ]
    in
    match Jsont_bytesrw.encode_string Jsont.json manifest with
    | Ok bytes -> bytes
    | Error message -> failwith message

  let entry_page ~create_url ~manifest =
    Printf.sprintf
      {|<!doctype html>
<html>
<head><meta charset="utf-8"><title>create your GitHub App</title></head>
<body>
<p>Continuing to GitHub to create your App&hellip;</p>
<form id="manifest-form" method="post" action="%s">
<input type="hidden" name="manifest" value="%s">
<noscript><button type="submit">Create GitHub App</button></noscript>
</form>
<script>document.getElementById("manifest-form").submit();</script>
</body>
</html>
|}
      (html_escape create_url) (html_escape manifest)
end

let api_error e = Api.Error.message e

(* Narrow reads over GitHub's response documents: take the named member when
   it has the expected shape, ignore everything else — the foreign document
   grows members freely, and what absence means stays with each caller. *)
let member name = function
  | Jsont.Object (mems, _) -> Option.map snd (Jsont.Json.find_mem name mems)
  | _ -> None

let string_member json name =
  match member name json with Some (Jsont.String (s, _)) -> Some s | _ -> None

let int_member json name =
  match member name json with
  | Some (Jsont.Number (v, _)) when Float.is_integer v -> Some (int_of_float v)
  | _ -> None

module Conversion = struct
  type t = {
    app_id : int;
    slug : string;
    name : string;
    client_id : string;
    html_url : string;
    webhook_secret : string option;
    pem : string;
  }

  let decode json =
    let required name value =
      match value with
      | Some value -> Ok value
      | None ->
          Error
            (Printf.sprintf "conversion answered without a usable %s member"
               name)
    in
    let* app_id = required "id" (int_member json "id") in
    let* slug = required "slug" (string_member json "slug") in
    let* name = required "name" (string_member json "name") in
    let* client_id = required "client_id" (string_member json "client_id") in
    let* html_url = required "html_url" (string_member json "html_url") in
    let* pem = required "pem" (string_member json "pem") in
    let webhook_secret = string_member json "webhook_secret" in
    Ok { app_id; slug; name; client_id; html_url; webhook_secret; pem }

  let code_char c =
    (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || Char.equal c '.' || Char.equal c '_' || Char.equal c '-'

  let exchange api ~code =
    if String.equal code "" || not (String.for_all code_char code) then
      Error "malformed conversion code"
    else
      match
        Api.post api
          ~path:(Printf.sprintf "/app-manifests/%s/conversions" code)
          ~body:(Jsont.Json.object' [])
      with
      | Error e -> Error (api_error e)
      | Ok (_, None) -> Error "conversion answered with an empty body"
      | Ok (_, Some json) -> decode json
end

module Mint = struct
  let installation_id api ~repo =
    match
      Api.get api ~path:(Printf.sprintf "/repos/%s/installation" repo)
    with
    | Error e -> (
        match Api.Error.kind e with
        | Api.Error.Response { status = 404; _ } -> Error `No_installation
        | Api.Error.Response _ | Api.Error.Transport _ ->
            Error (`Error (api_error e)))
    | Ok json -> (
        match int_member json "id" with
        | Some id -> Ok id
        | None -> Error (`Error "installation answered without an id member"))

  (* The repository's name half: the mint's [repositories] member takes bare
     names, the installation already scoping the owner. *)
  let repo_name repo =
    match String.index_opt repo '/' with
    | Some slash when slash + 1 < String.length repo ->
        String.sub repo (slash + 1) (String.length repo - slash - 1)
    | Some _ | None -> repo

  let access_token api ~installation_id ~repo ~permissions =
    let mem name value = Jsont.Json.mem (Jsont.Json.name name) value in
    let body =
      Jsont.Json.object'
        [
          mem "repositories"
            (Jsont.Json.list [ Jsont.Json.string (repo_name repo) ]);
          mem "permissions"
            (Jsont.Json.object'
               (List.map
                  (fun (permission, access) ->
                    mem permission (Jsont.Json.string access))
                  permissions));
        ]
    in
    match
      Api.post api
        ~path:
          (Printf.sprintf "/app/installations/%d/access_tokens" installation_id)
        ~body
    with
    | Error e -> Error (api_error e)
    | Ok (_, Some json) -> (
        match string_member json "token" with
        | Some token -> Ok token
        | None -> Error "token mint answered without a token member")
    | Ok (_, None) -> Error "token mint answered with an empty body"
end

module Hook = struct
  let upsert api ~url ~secret =
    let mem name value = Jsont.Json.mem (Jsont.Json.name name) value in
    let body =
      Jsont.Json.object'
        [
          mem "url" (Jsont.Json.string url);
          mem "content_type" (Jsont.Json.string "json");
          mem "secret" (Jsont.Json.string secret);
        ]
    in
    match Api.patch api ~path:"/app/hook/config" ~body with
    | Error e -> Error (api_error e)
    | Ok _ -> Ok ()

  let current_url api =
    match Api.get api ~path:"/app/hook/config" with
    | Error e -> Error (api_error e)
    | Ok json -> (
        match string_member json "url" with
        | Some url -> Ok url
        | None -> Error "hook config answered without a url member")
end

let identity api =
  match Api.get api ~path:"/app" with
  | Error e -> Error (api_error e)
  | Ok json -> (
      match (string_member json "slug", string_member json "name") with
      | Some slug, Some name -> Ok (slug, name)
      | _ -> Error "/app answered without slug and name members")

let installations api =
  match
    Api.get_paginated api ~path:"/app/installations?per_page=100" ~max_pages:10
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
                     match
                       ( int_member item "id",
                         Option.bind (member "account" item) (fun account ->
                             string_member account "login") )
                     with
                     | Some id, Some login -> Some (id, login)
                     | _ -> None)
                   items
             | _ -> [])
           pages)
