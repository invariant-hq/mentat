(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Github_app] — the RS256 app JWT against a pinned vector,
   the manifest flow's documents, the conversion decode, the narrowed
   installation-token mints, and the hook-config projection. *)

open Windtrap
open Mentat_github

(* A fixed throwaway RSA key, generated once for this suite; the pinned JWT
   below was computed over it with an independent implementation (Python
   cryptography), so the OCaml encoder cannot drift without this failing. *)
let test_key_pem =
  {|-----BEGIN RSA PRIVATE KEY-----
MIIEpQIBAAKCAQEAvP8Hg58J/tD8yQLsdtJ7jbVlhtg8AFSOLayJEhcondf3cp5i
cokncJ25WWsBAequ9Q26URDQEg4ml8qNXLRzHGyFefGu65uAh+HzqInHaFzTAJmH
K3W5LTy/7qTMT5VSGadfOH7wi7Qs1WqpKjctIMeFTDuVBVKSA9QE71+CnQDZnQ5G
7rEhyesXL1NWODJuFCpbJNugutgskgaXHWQf8+36K4NTSTc/Z0dGwNOnCJrDaRco
j00ugo1fKJrQ6Mo8IHt9t1/KI23fA0O1RhxgbbdV9cqqh4ZdHUiyIutnJhajZP5r
x7w8JBn/EpNszNakr2raHk9H0YNsCCeoT+RiZQIDAQABAoIBAAsY3g//qYaALr4+
cR7R9uYSya+8UxuW22lO+UEUwd0GG7YBGu6MOJgKHs0OCsyvbbn0UNARO2e6qSVJ
A/oL8LqxcY3qimGJq3yZtbpGlWzpObd44aEEOXewmo7F4jw7BuDRknZUAnDwMaC6
BvhJre6VNdxhyZB628QknGySEFktDr0SpsehYY2Z4BZwQGY00bysEHVeHJKU7rNa
1wE+JzadpHBQxdORRlT1G01nkWhJ55tRG2D6benbl35dmz0fgr15KIDtsyCFItmP
asnozgEC6GLRYXyIYpotFQYYTWAf5RlKOGYPDW385I8VjqCB7jTXt7+SBIePEZ/e
DTw0fTECgYEA8cJrXvN5amwzEO+Okbb5tt8EG1Zf4B8u2oJvFDdDH4kOIof4b0yR
ZDIInouf4wKz6icyRhlpamM3UB3mixClqyN+vydVGRnl1RdfBQopblAdbYWsKzCo
wwDhEgfOiEwuMEMA9wpHswqwPUVVge7lWD9AuGXncftY0mZustDuhtUCgYEAyCD5
MJ7oI2JkPPrJIV4eqFm/KcCCFmRxqGSy6bobAY1+lROCaPqNFPF1TW/hu/jGdnNb
6lrZKvhYfcc5EGnog1REEWkG6Zeou/HaE42ndHQaT6lDrqPUL17WA1c8mDdEA6qM
SYdxw63HgENw3OAcqOLtlLWFj32c6Iwx6JyLVVECgYEA4eHmkkvoqK+5stwxGCKf
BOcwnh5A7FYWX+E4yemsVJ2o0Ei8rbkbq0M4XHJWjDNtSJ0g0vBRVy6mcrvNOSfv
sowyk4W7c/2HiWcRx9KrzT8bj8YyjBQlyjVbFY6nwR90lHE2SJuZTEbzTfwnHYTJ
Un+fB+tmqU/PuJ4uVfLyupUCgYEAok8byvMWEpyZ71r2BLnw41jmUVZwKvkLtSb2
c9kcTgYTw5QvEDUkdvfdyxASZAE/9JFa2pcTymXgXyJUhZtfmCOfkP89O/ZkQwnD
dFhOl4QSUslUuy7jyAeCSvNVkZ5A6zhGztuqyKkIRF5uCrU4iUCCrzkJOXcG6xPI
5n8QAgECgYEAxODOXI4GtDL1ijdHfoorh9cUMDw29PGGz2D3RiRAdKC7g2i1i9KL
/wal5UMZNNj0keWxs09CHwa/uX08SHlyeKBRr0tL90uqCrkJP/B3E0dqj0dUm55i
wKI8NYXfoA68SkCmKvHC6cpC/lE2eLobuGS4uz8aXdNCIianuExAX9o=
-----END RSA PRIVATE KEY-----
|}

let pinned_jwt =
  "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE2OTk5OTk5NDAsImV4cCI6MTcw\
   MDAwMDU0MCwiaXNzIjoiSXYxLmFiY2RlZjEyMzQ1Njc4OTAifQ.Tn3MYwcntUi6SRgoI3y2-a\
   u2X01a8mnmxQeBrfeAPiFiPDZIv3jWaW1SBgV1ZE4x_rPjBlCsTH0sTMbT0LFNT15OBXquiJW\
   gy7UTyAv94-W3DKubKAFX3H23K3phyAyF2edMcqaCD6DfByk4Tk03wlcRWgoxzTbAcdDWgPjT\
   qW_X2FRKeIda-NVogmVFThC5aCE_sWdWAaBOz4MlYLacu1vE4b5PHEatTL3mfC8NedZFG21km\
   46DycyyGJ97m6WHo5XtjuIT8jq5eGISjx6oCXyfcXZaeNVWqAwNO8hBcRyDhuVilImGl3rZuU\
   6twqVctXzpp4c5BhbX2b4qxEmQng"

let jwt_vector () =
  match
    Github_app.Jwt.make ~issuer:"Iv1.abcdef1234567890" ~key_pem:test_key_pem
      ~now:1700000000.0
  with
  | Ok jwt -> equal string ~msg:"the pinned RS256 vector" pinned_jwt jwt
  | Error message -> failf "jwt: %s" message

let jwt_refusals () =
  (match
     Github_app.Jwt.make ~issuer:"x" ~key_pem:"not a pem" ~now:1700000000.0
   with
  | Ok _ -> fail "a non-PEM key must not sign"
  | Error message ->
      is_true ~msg:"the PEM refusal is generic and carries no key bytes"
        (String.equal message "the private key PEM does not decode"));
  equal int ~msg:"the skew constant" 60 Github_app.Jwt.skew_s;
  equal int ~msg:"the lifetime stays under GitHub's 10-minute cap" 540
    Github_app.Jwt.lifetime_s

let manifest_documents () =
  equal string ~msg:"the public API base maps to the public web host"
    "https://github.com"
    (Github_app.Manifest.web_base ~api_base:"https://api.github.com");
  equal string ~msg:"a GHES base sheds its /api/v3 suffix"
    "https://ghe.example.com"
    (Github_app.Manifest.web_base ~api_base:"https://ghe.example.com/api/v3");
  equal string ~msg:"the user create page"
    "https://github.com/settings/apps/new?state=s1"
    (Github_app.Manifest.create_url ~web_base:"https://github.com" ~org:None
       ~state:"s1");
  equal string ~msg:"the organization create page"
    "https://github.com/organizations/acme/settings/apps/new?state=s1"
    (Github_app.Manifest.create_url ~web_base:"https://github.com"
       ~org:(Some "acme") ~state:"s1");
  equal string ~msg:"a routed hook target"
    "https://hooks.example.com/ingress/github/abcd"
    (Github_app.Manifest.hook_url ~public_url:(Some "https://hooks.example.com/")
       ~ingress_id:"abcd");
  equal string ~msg:"the unrouted placeholder is RFC 2606 .invalid"
    "https://unrouted.invalid/ingress/github/abcd"
    (Github_app.Manifest.hook_url ~public_url:None ~ingress_id:"abcd");
  equal string ~msg:"the manifest document"
    {|{"name":"mentat-review-a3f9","url":"https://example.com/mentat","public":false,"redirect_url":"http://127.0.0.1:8917/callback","hook_attributes":{"url":"https://unrouted.invalid/ingress/github/abcd","active":true},"default_events":["pull_request"],"default_permissions":{"contents":"read","pull_requests":"write","metadata":"read"}}|}
    (Github_app.Manifest.json ~name:"mentat-review-a3f9"
       ~homepage:"https://example.com/mentat"
       ~redirect_url:"http://127.0.0.1:8917/callback"
       ~hook_url:"https://unrouted.invalid/ingress/github/abcd");
  let page =
    Github_app.Manifest.entry_page
      ~create_url:"https://github.com/settings/apps/new?state=s1"
      ~manifest:{|{"name":"a","url":"b&c"}|}
  in
  let contains needle =
    let n = String.length needle and h = String.length page in
    let rec go i =
      i + n <= h && (String.equal (String.sub page i n) needle || go (i + 1))
    in
    go 0
  in
  is_true ~msg:"the form posts to the create page"
    (contains {|action="https://github.com/settings/apps/new?state=s1"|});
  is_true ~msg:"the manifest rides one hidden field, attribute-escaped"
    (contains
       {|name="manifest" value="{&quot;name&quot;:&quot;a&quot;,&quot;url&quot;:&quot;b&amp;c&quot;}"|});
  is_true ~msg:"a no-script browser gets a visible submit"
    (contains "<noscript><button")

let conversion_decode () =
  let decode body =
    match Jsont_bytesrw.decode_string Jsont.json body with
    | Ok json -> Github_app.Conversion.decode json
    | Error message -> failf "fixture: %s" message
  in
  (match
     decode
       {|{"id":12345,"slug":"mentat-review-a3f9","name":"mentat-review-a3f9",
          "client_id":"Iv1.abcdef1234567890","html_url":"https://github.com/apps/mentat-review-a3f9",
          "webhook_secret":"whs","pem":"PEMPEM","client_secret":"discarded",
          "node_id":"x","owner":{"login":"o"}}|}
   with
  | Error message -> failf "decode: %s" message
  | Ok conversion ->
      equal int ~msg:"id" 12345 conversion.Github_app.Conversion.app_id;
      equal string ~msg:"slug" "mentat-review-a3f9"
        conversion.Github_app.Conversion.slug;
      equal string ~msg:"client id" "Iv1.abcdef1234567890"
        conversion.Github_app.Conversion.client_id;
      equal (option string) ~msg:"webhook secret" (Some "whs")
        conversion.Github_app.Conversion.webhook_secret;
      equal string ~msg:"pem" "PEMPEM" conversion.Github_app.Conversion.pem);
  (match
     decode
       {|{"id":1,"slug":"s","name":"n","client_id":"c","html_url":"h","pem":"p"}|}
   with
  | Error message -> failf "decode without webhook_secret: %s" message
  | Ok conversion ->
      equal (option string)
        ~msg:"an omitted webhook_secret decodes to None, checked live" None
        conversion.Github_app.Conversion.webhook_secret);
  match decode {|{"id":1,"slug":"s","name":"n","client_id":"c","html_url":"h"}|} with
  | Ok _ -> fail "a conversion without its pem must refuse"
  | Error message ->
      is_true ~msg:"the refusal names the member"
        (String.equal message "conversion answered without a usable pem member")

(* One recording requester: every assertion about paths, bodies, and headers
   reads what the client actually sent. *)
let recording ?(status = 200) ?(body = "{}") () =
  let sent = ref [] in
  let http ~meth ~url ~headers ~body:request_body =
    sent := (meth, url, headers, request_body) :: !sent;
    Ok { Github_api.status; headers = []; body }
  in
  (sent, http)

let last sent =
  match !sent with
  | entry :: _ -> entry
  | [] -> fail "no request was sent"

let mints () =
  let sent, http = recording ~body:{|{"id":987}|} () in
  let api = Github_api.of_http ~token:"jwt-token" http in
  (match Github_app.Mint.installation_id api ~repo:"acme/widgets" with
  | Ok id -> equal int ~msg:"the installation id" 987 id
  | Error _ -> fail "installation lookup failed");
  let _, url, headers, _ = last sent in
  equal string ~msg:"the installation lookup path"
    "https://api.github.com/repos/acme/widgets/installation" url;
  is_true ~msg:"the JWT rides Bearer"
    (List.exists
       (fun (k, v) ->
         String.equal k "authorization" && String.equal v "Bearer jwt-token")
       headers);
  let sent404, http404 = recording ~status:404 ~body:{|{"message":"nf"}|} () in
  let api404 = Github_api.of_http ~token:"jwt" http404 in
  (match Github_app.Mint.installation_id api404 ~repo:"acme/widgets" with
  | Error `No_installation -> ignore (last sent404)
  | Ok _ | Error (`Error _) -> fail "a 404 is `No_installation");
  let sent_read, http_read = recording ~status:201 ~body:{|{"token":"ghs_read"}|} () in
  let api_read = Github_api.of_http ~token:"jwt" http_read in
  (match
     Github_app.Mint.access_token api_read ~installation_id:987
       ~repo:"acme/widgets" ~scope:Github_app.Mint.Read
   with
  | Ok token -> equal string ~msg:"the read mint's token" "ghs_read" token
  | Error message -> failf "read mint: %s" message);
  let _, url, _, body = last sent_read in
  equal string ~msg:"the mint path names the installation"
    "https://api.github.com/app/installations/987/access_tokens" url;
  equal (option string)
    ~msg:"the read mint narrows to the one repository and read permissions"
    (Some
       {|{"repositories":["widgets"],"permissions":{"contents":"read","pull_requests":"read"}}|})
    body;
  let sent_write, http_write =
    recording ~status:201 ~body:{|{"token":"ghs_write"}|} ()
  in
  let api_write = Github_api.of_http ~token:"jwt" http_write in
  (match
     Github_app.Mint.access_token api_write ~installation_id:987
       ~repo:"acme/widgets" ~scope:Github_app.Mint.Write
   with
  | Ok token -> equal string ~msg:"the write mint's token" "ghs_write" token
  | Error message -> failf "write mint: %s" message);
  let _, _, _, body = last sent_write in
  equal (option string)
    ~msg:"the write mint reaches one repository's pull requests and nothing \
          else"
    (Some
       {|{"repositories":["widgets"],"permissions":{"pull_requests":"write"}}|})
    body

let hook_projection () =
  let sent, http = recording ~body:{|{}|} () in
  let api = Github_api.of_http ~token:"jwt" http in
  (match
     Github_app.Hook.upsert api ~url:"https://h.example.com/ingress/github/i"
       ~secret:"whs"
   with
  | Ok () -> ()
  | Error message -> failf "upsert: %s" message);
  let meth, url, _, body = last sent in
  is_true ~msg:"the upsert is a PATCH" (match meth with `PATCH -> true | _ -> false);
  equal string ~msg:"the hook config path" "https://api.github.com/app/hook/config"
    url;
  equal (option string) ~msg:"the complete config is upserted whole"
    (Some
       {|{"url":"https://h.example.com/ingress/github/i","content_type":"json","secret":"whs"}|})
    body;
  let _, http_read =
    recording ~body:{|{"url":"https://h.example.com/ingress/github/i","content_type":"json"}|} ()
  in
  let api_read = Github_api.of_http ~token:"jwt" http_read in
  match Github_app.Hook.current_url api_read with
  | Ok url ->
      equal string ~msg:"the config read's url"
        "https://h.example.com/ingress/github/i" url
  | Error message -> failf "current_url: %s" message

let unauthenticated_conversion () =
  let sent, http = recording ~status:201 ~body:{|{"id":1,"slug":"s","name":"n","client_id":"c","html_url":"h","webhook_secret":"w","pem":"p"}|} () in
  let api = Github_api.of_http http in
  (match Github_app.Conversion.exchange api ~code:"one-shot-code" with
  | Ok conversion ->
      equal int ~msg:"the conversion decodes" 1
        conversion.Github_app.Conversion.app_id
  | Error message -> failf "exchange: %s" message);
  let _, url, headers, _ = last sent in
  equal string ~msg:"the conversion path carries the code"
    "https://api.github.com/app-manifests/one-shot-code/conversions" url;
  is_true ~msg:"the conversion sends no authorization header at all"
    (not (List.exists (fun (k, _) -> String.equal k "authorization") headers));
  match Github_app.Conversion.exchange api ~code:"../evil" with
  | Ok _ -> fail "a path-mangling code must refuse"
  | Error message ->
      is_true ~msg:"the refusal names the code"
        (String.equal message "malformed conversion code")

let () =
  run "mentat.github_app"
    [
      test "the pinned RS256 vector" jwt_vector;
      test "jwt refusals and constants" jwt_refusals;
      test "manifest documents" manifest_documents;
      test "conversion decode" conversion_decode;
      test "narrowed mints" mints;
      test "hook-config projection" hook_projection;
      test "unauthenticated conversion" unauthenticated_conversion;
    ]
