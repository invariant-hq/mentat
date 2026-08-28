(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for the github library. The HTTP effect is one injected
   closure, so every test scripts the replies and inspects the recorded
   requests — header and URL construction, the response body bound, status
   classification, Link-header pagination, the App JWT against a pinned
   vector, the manifest documents, the narrowed mints, the pull-request
   reads, and webhook signature verification all run with no network. *)

open Windtrap

type call = {
  meth : [ `GET | `PATCH | `POST ];
  url : string;
  headers : (string * string) list;
  body : string option;
}

(* A scripted requester: replies in order, recording each request; a request
   past the script's end is the test's failure. *)
let scripted script =
  let calls = ref [] in
  let remaining = ref script in
  let http ~meth ~url ~headers ~body =
    calls := { meth; url; headers; body } :: !calls;
    match !remaining with
    | [] -> fail ("unexpected request: " ^ url)
    | reply :: rest ->
        remaining := rest;
        reply
  in
  (calls, http)

let reply ?(headers = []) status body =
  Ok { Github.Api.status; headers; body }

let header name (call : call) =
  List.assoc_opt name call.headers

let json text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok json -> json
  | Error reason -> failf "test fixture is not JSON: %s" reason

let encode j =
  match Jsont_bytesrw.encode_string Jsont.json j with
  | Ok text -> text
  | Error reason -> failf "test fixture failed to encode: %s" reason

let kind_name error =
  match Github.Api.Error.kind error with
  | Github.Api.Error.Response { status; _ } ->
      Printf.sprintf "response %d" status
  | Github.Api.Error.Transport _ -> "transport"

(* The client. *)

let get_builds_the_request () =
  let calls, http = scripted [ reply 200 {|{"ok":true}|} ] in
  let t = Github.Api.of_http ~token:"tok-123" http in
  let body =
    require_ok ~pp_error:Github.Api.Error.pp
      (Github.Api.get t ~path:"/repos/acme/widgets/pulls/7")
  in
  equal string ~msg:"decoded body" {|{"ok":true}|} (encode body);
  match !calls with
  | [ call ] ->
      is_true ~msg:"method is GET" (call.meth = `GET);
      equal string ~msg:"url is base + path"
        "https://api.github.com/repos/acme/widgets/pulls/7" call.url;
      equal (option string) ~msg:"bearer authorization" (Some "Bearer tok-123")
        (header "authorization" call);
      equal (option string) ~msg:"github accept"
        (Some "application/vnd.github+json")
        (header "accept" call);
      equal (option string) ~msg:"pinned api version"
        (Some Github.Api.api_version)
        (header "x-github-api-version" call);
      equal (option string) ~msg:"the default user agent" (Some "github")
        (header "user-agent" call);
      is_none ~msg:"no content type on a read" (header "content-type" call);
      is_none ~msg:"no body on a read" call.body
  | calls -> failf "expected one request, got %d" (List.length calls)

let user_agent_is_the_callers () =
  let calls, http = scripted [ reply 200 "{}" ] in
  let t = Github.Api.of_http ~user_agent:"my-app" ~token:"t" http in
  let _ =
    require_ok ~pp_error:Github.Api.Error.pp (Github.Api.get t ~path:"/x")
  in
  match !calls with
  | [ call ] ->
      equal (option string) ~msg:"the supplied user agent rides every request"
        (Some "my-app") (header "user-agent" call)
  | _ -> fail "expected one request"

let base_url_strips_trailing_slashes () =
  let calls, http = scripted [ reply 200 "{}" ] in
  let t =
    Github.Api.of_http ~base_url:"http://127.0.0.1:8080/" ~token:"t" http
  in
  let _ =
    require_ok ~pp_error:Github.Api.Error.pp (Github.Api.get t ~path:"/x")
  in
  match !calls with
  | [ call ] -> equal string "http://127.0.0.1:8080/x" call.url
  | _ -> fail "expected one request"

let paths_must_be_absolute () =
  let _, http = scripted [] in
  let t = Github.Api.of_http ~token:"t" http in
  raises_match (Exn.invalid_arg ~substring:"start with '/'") (fun () ->
      Github.Api.get t ~path:"repos/acme/widgets");
  raises_match (Exn.invalid_arg ~substring:"max_pages") (fun () ->
      Github.Api.get_paginated t ~path:"/x" ~max_pages:0)

let write_sends_json_and_decodes () =
  let calls, http =
    scripted [ reply 201 {|{"id":42}|}; reply 204 "" ] in
  let t = Github.Api.of_http ~token:"t" http in
  let status, created =
    require_ok ~pp_error:Github.Api.Error.pp
      (Github.Api.post t ~path:"/repos/a/b/pulls/1/comments"
         ~body:(json {|{"body":"hi"}|}))
  in
  equal int ~msg:"created status" 201 status;
  equal string ~msg:"decoded reply body" {|{"id":42}|}
    (encode (require_some created));
  let status, no_body =
    require_ok ~pp_error:Github.Api.Error.pp
      (Github.Api.patch t ~path:"/repos/a/b/issues/comments/9"
         ~body:(json {|{"body":"hi"}|}))
  in
  equal int ~msg:"empty-body status" 204 status;
  is_none ~msg:"an empty body decodes to None" no_body;
  match List.rev !calls with
  | [ post; patch ] ->
      is_true ~msg:"method is POST" (post.meth = `POST);
      is_true ~msg:"method is PATCH" (patch.meth = `PATCH);
      equal (option string) ~msg:"writes carry a JSON content type"
        (Some "application/json")
        (header "content-type" post);
      equal (option string) ~msg:"the body is the encoded JSON"
        (Some {|{"body":"hi"}|}) post.body
  | calls -> failf "expected two requests, got %d" (List.length calls)

let non_2xx_is_a_response_error () =
  let _, http =
    scripted
      [ reply 422 "{\"message\":\"Validation\x01\nFailed\"}" ]
  in
  let t = Github.Api.of_http ~token:"t" http in
  let error =
    require_error (Github.Api.post t ~path:"/repos/a/b/pulls/1/comments"
                     ~body:(json "{}"))
  in
  match Github.Api.Error.kind error with
  | Github.Api.Error.Response { status; body } ->
      equal int ~msg:"status" 422 status;
      (* The excerpt is one printable-ASCII line: the control byte and the
         newline arrive as spaces. *)
      equal string ~msg:"sanitized excerpt"
        "{\"message\":\"Validation  Failed\"}" body;
      contains ~msg:"message names the status" ~sub:"422"
        (Github.Api.Error.message error)
  | _ -> failf "expected a response error, got %s" (kind_name error)

let response_excerpt_is_truncated () =
  let _, http = scripted [ reply 500 (String.make 5000 'x') ] in
  let t = Github.Api.of_http ~token:"t" http in
  let error = require_error (Github.Api.get t ~path:"/x") in
  match Github.Api.Error.kind error with
  | Github.Api.Error.Response { body; _ } ->
      equal int ~msg:"excerpt bound" 400 (String.length body)
  | _ -> failf "expected a response error, got %s" (kind_name error)

let non_json_success_is_a_transport_error () =
  let _, http = scripted [ reply 200 "not json" ] in
  let t = Github.Api.of_http ~token:"t" http in
  let error = require_error (Github.Api.get t ~path:"/x") in
  match Github.Api.Error.kind error with
  | Github.Api.Error.Transport reason ->
      contains ~msg:"reason names the decode" ~sub:"not JSON" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error)

let bodies_over_the_bound_are_refused () =
  let over = "\"" ^ String.make Github.Api.max_body_bytes 'a' ^ "\"" in
  let at = "\"" ^ String.make (Github.Api.max_body_bytes - 2) 'a' ^ "\"" in
  let _, http = scripted [ reply 200 over ] in
  let t = Github.Api.of_http ~token:"t" http in
  let error = require_error (Github.Api.get t ~path:"/x") in
  (match Github.Api.Error.kind error with
  | Github.Api.Error.Transport reason ->
      contains ~msg:"reason names the bound" ~sub:"exceeds" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error));
  let _, http = scripted [ reply 200 at ] in
  let t = Github.Api.of_http ~token:"t" http in
  is_true ~msg:"a body at the bound passes"
    (Result.is_ok (Github.Api.get t ~path:"/x"))

let pagination_follows_rel_next () =
  let base = "https://api.github.com" in
  let calls, http =
    scripted
      [
        reply
          ~headers:
            [
              ( "Link",
                Printf.sprintf
                  "<%s/repos/a/b/pulls?page=2>; rel=\"next\", \
                   <%s/repos/a/b/pulls?page=3>; rel=\"last\""
                  base base );
            ]
          200 "[1]";
        reply
          ~headers:
            [ ("Link", Printf.sprintf "<%s/repos/a/b/pulls?page=1>; rel=\"prev\"" base) ]
          200 "[2]";
      ]
  in
  let t = Github.Api.of_http ~token:"t" http in
  let pages =
    require_ok ~pp_error:Github.Api.Error.pp
      (Github.Api.get_paginated t ~path:"/repos/a/b/pulls" ~max_pages:5)
  in
  equal (list string) ~msg:"pages in request order" [ "[1]"; "[2]" ]
    (List.map encode pages);
  equal (list string) ~msg:"the next target is requested as served"
    [
      base ^ "/repos/a/b/pulls";
      base ^ "/repos/a/b/pulls?page=2";
    ]
    (List.rev_map (fun (call : call) -> call.url) !calls)

let pagination_link_grammar () =
  (* The Link value splitting must survive commas inside the bracketed
     target and inside quoted parameter values, an unquoted rel, a
     multi-relation rel list, and a rel that only matches case-insensitively.
     A rev-only link never matches. *)
  let page target extra = ("Link", Printf.sprintf "<%s>%s" target extra) in
  let follows ~msg link =
    let calls, http =
      scripted [ reply ~headers:[ link ] 200 "[]"; reply 200 "[]" ]
    in
    let t = Github.Api.of_http ~token:"t" http in
    let _ =
      require_ok ~pp_error:Github.Api.Error.pp
        (Github.Api.get_paginated t ~path:"/x" ~max_pages:3)
    in
    equal int ~msg 2 (List.length !calls)
  in
  let stops ~msg link =
    let calls, http = scripted [ reply ~headers:[ link ] 200 "[]" ] in
    let t = Github.Api.of_http ~token:"t" http in
    let _ =
      require_ok ~pp_error:Github.Api.Error.pp
        (Github.Api.get_paginated t ~path:"/x" ~max_pages:3)
    in
    equal int ~msg 1 (List.length !calls)
  in
  follows ~msg:"a comma inside the target does not split the link"
    (page "https://api.github.com/x?ids=1,2&page=2" "; rel=\"next\"");
  follows ~msg:"an unquoted rel matches"
    (page "https://api.github.com/x?page=2" "; rel=next");
  follows ~msg:"a multi-relation rel list matches"
    (page "https://api.github.com/x?page=2" "; rel=\"alternate next\"");
  follows ~msg:"rel compares case-insensitively"
    (page "https://api.github.com/x?page=2" "; rel=\"Next\"");
  follows ~msg:"a quoted comma in another parameter does not split the link"
    (page "https://api.github.com/x?page=2"
       "; title=\"a, b\"; rel=\"next\"");
  stops ~msg:"a rev-only link is not a next target"
    (page "https://api.github.com/x?page=2" "; rev=\"next\"");
  stops ~msg:"an unbracketed target is ignored"
    ("Link", "https://api.github.com/x?page=2; rel=\"next\"");
  stops ~msg:"a rel of another relation is ignored"
    (page "https://api.github.com/x?page=2" "; rel=\"prev\"")

let pagination_stops_loudly_at_max_pages () =
  let next = [ ("Link", "<https://api.github.com/x?page=2>; rel=\"next\"") ] in
  let calls, http =
    scripted [ reply ~headers:next 200 "[]"; reply ~headers:next 200 "[]" ]
  in
  let t = Github.Api.of_http ~token:"t" http in
  let error =
    require_error (Github.Api.get_paginated t ~path:"/x" ~max_pages:2)
  in
  equal int ~msg:"exactly max_pages requests were sent" 2 (List.length !calls);
  match Github.Api.Error.kind error with
  | Github.Api.Error.Transport reason ->
      contains ~msg:"reason names the page bound" ~sub:"after 2 pages" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error)

let pagination_refuses_to_leave_the_origin () =
  let calls, http =
    scripted
      [
        reply
          ~headers:[ ("Link", "<https://evil.example/x>; rel=\"next\"") ]
          200 "[]";
      ]
  in
  let t = Github.Api.of_http ~token:"t" http in
  let error =
    require_error (Github.Api.get_paginated t ~path:"/x" ~max_pages:5)
  in
  equal int ~msg:"no request follows the foreign link" 1 (List.length !calls);
  match Github.Api.Error.kind error with
  | Github.Api.Error.Transport reason ->
      contains ~msg:"reason names the origin" ~sub:"origin" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error)

let transport_errors_pass_through () =
  let _, http =
    scripted [ Error (Github.Api.Error.transport "connection refused") ]
  in
  let t = Github.Api.of_http ~token:"t" http in
  let error = require_error (Github.Api.get t ~path:"/x") in
  (match Github.Api.Error.kind error with
  | Github.Api.Error.Transport reason ->
      equal string "connection refused" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error));
  equal string ~msg:"transport messages pass through verbatim"
    "connection refused"
    (Github.Api.Error.message error)

(* The App JWT. *)

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
    Github.App.Jwt.make ~issuer:"Iv1.abcdef1234567890" ~key_pem:test_key_pem
      ~now:1700000000.0
  with
  | Ok jwt -> equal string ~msg:"the pinned RS256 vector" pinned_jwt jwt
  | Error message -> failf "jwt: %s" message

let jwt_refusals () =
  (match
     Github.App.Jwt.make ~issuer:"x" ~key_pem:"not a pem" ~now:1700000000.0
   with
  | Ok _ -> fail "a non-PEM key must not sign"
  | Error message ->
      is_true ~msg:"the PEM refusal is generic and carries no key bytes"
        (String.equal message "the private key PEM does not decode"));
  equal int ~msg:"the skew constant" 60 Github.App.Jwt.skew_s;
  equal int ~msg:"the lifetime stays under GitHub's 10-minute cap" 540
    Github.App.Jwt.lifetime_s

(* The manifest flow. *)

let manifest_documents () =
  equal string ~msg:"the public API base maps to the public web host"
    "https://github.com"
    (Github.App.Manifest.web_base ~api_base:"https://api.github.com");
  equal string ~msg:"an Enterprise base sheds its /api/v3 suffix"
    "https://ghe.example.com"
    (Github.App.Manifest.web_base ~api_base:"https://ghe.example.com/api/v3");
  equal string ~msg:"the user create page"
    "https://github.com/settings/apps/new?state=s1"
    (Github.App.Manifest.create_url ~web_base:"https://github.com" ~org:None
       ~state:"s1");
  equal string ~msg:"the organization create page"
    "https://github.com/organizations/acme/settings/apps/new?state=s1"
    (Github.App.Manifest.create_url ~web_base:"https://github.com"
       ~org:(Some "acme") ~state:"s1");
  equal string ~msg:"the manifest document"
    {|{"name":"review-bot-a3f9","url":"https://example.com/review-bot","public":false,"redirect_url":"http://127.0.0.1:8917/callback","hook_attributes":{"url":"https://unrouted.invalid/hooks/abcd","active":true},"default_events":["pull_request"],"default_permissions":{"contents":"read","pull_requests":"write","metadata":"read"}}|}
    (Github.App.Manifest.json ~name:"review-bot-a3f9"
       ~homepage:"https://example.com/review-bot"
       ~redirect_url:"http://127.0.0.1:8917/callback"
       ~hook_url:"https://unrouted.invalid/hooks/abcd"
       ~events:[ "pull_request" ]
       ~permissions:
         [
           ("contents", "read");
           ("pull_requests", "write");
           ("metadata", "read");
         ]);
  let page =
    Github.App.Manifest.entry_page
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
    | Ok json -> Github.App.Conversion.decode json
    | Error message -> failf "fixture: %s" message
  in
  (match
     decode
       {|{"id":12345,"slug":"review-bot-a3f9","name":"review-bot-a3f9",
          "client_id":"Iv1.abcdef1234567890","html_url":"https://github.com/apps/review-bot-a3f9",
          "webhook_secret":"whs","pem":"PEMPEM","client_secret":"discarded",
          "node_id":"x","owner":{"login":"o"}}|}
   with
  | Error message -> failf "decode: %s" message
  | Ok conversion ->
      equal int ~msg:"id" 12345 conversion.Github.App.Conversion.app_id;
      equal string ~msg:"slug" "review-bot-a3f9"
        conversion.Github.App.Conversion.slug;
      equal string ~msg:"client id" "Iv1.abcdef1234567890"
        conversion.Github.App.Conversion.client_id;
      equal (option string) ~msg:"webhook secret" (Some "whs")
        conversion.Github.App.Conversion.webhook_secret;
      equal string ~msg:"pem" "PEMPEM" conversion.Github.App.Conversion.pem);
  (match
     decode
       {|{"id":1,"slug":"s","name":"n","client_id":"c","html_url":"h","pem":"p"}|}
   with
  | Error message -> failf "decode without webhook_secret: %s" message
  | Ok conversion ->
      equal (option string)
        ~msg:"an omitted webhook_secret decodes to None, observed live" None
        conversion.Github.App.Conversion.webhook_secret);
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
    Ok { Github.Api.status; headers = []; body }
  in
  (sent, http)

let last sent =
  match !sent with
  | entry :: _ -> entry
  | [] -> fail "no request was sent"

let mints () =
  let sent, http = recording ~body:{|{"id":987}|} () in
  let api = Github.Api.of_http ~token:"jwt-token" http in
  (match Github.App.Mint.installation_id api ~repo:"acme/widgets" with
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
  let api404 = Github.Api.of_http ~token:"jwt" http404 in
  (match Github.App.Mint.installation_id api404 ~repo:"acme/widgets" with
  | Error `No_installation -> ignore (last sent404)
  | Ok _ | Error (`Error _) -> fail "a 404 is `No_installation");
  let sent_read, http_read = recording ~status:201 ~body:{|{"token":"ghs_read"}|} () in
  let api_read = Github.Api.of_http ~token:"jwt" http_read in
  (match
     Github.App.Mint.access_token api_read ~installation_id:987
       ~repo:"acme/widgets"
       ~permissions:[ ("contents", "read"); ("pull_requests", "read") ]
   with
  | Ok token -> equal string ~msg:"the read mint's token" "ghs_read" token
  | Error message -> failf "read mint: %s" message);
  let _, url, _, body = last sent_read in
  equal string ~msg:"the mint path names the installation"
    "https://api.github.com/app/installations/987/access_tokens" url;
  equal (option string)
    ~msg:"the mint narrows to the one repository and the given permissions"
    (Some
       {|{"repositories":["widgets"],"permissions":{"contents":"read","pull_requests":"read"}}|})
    body;
  let sent_write, http_write =
    recording ~status:201 ~body:{|{"token":"ghs_write"}|} ()
  in
  let api_write = Github.Api.of_http ~token:"jwt" http_write in
  (match
     Github.App.Mint.access_token api_write ~installation_id:987
       ~repo:"acme/widgets" ~permissions:[ ("pull_requests", "write") ]
   with
  | Ok token -> equal string ~msg:"the write mint's token" "ghs_write" token
  | Error message -> failf "write mint: %s" message);
  let _, _, _, body = last sent_write in
  equal (option string)
    ~msg:"a single-permission mint reaches exactly that permission"
    (Some
       {|{"repositories":["widgets"],"permissions":{"pull_requests":"write"}}|})
    body

let hook_projection () =
  let sent, http = recording ~body:{|{}|} () in
  let api = Github.Api.of_http ~token:"jwt" http in
  (match
     Github.App.Hook.upsert api ~url:"https://h.example.com/hooks/i"
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
       {|{"url":"https://h.example.com/hooks/i","content_type":"json","secret":"whs"}|})
    body;
  let _, http_read =
    recording ~body:{|{"url":"https://h.example.com/hooks/i","content_type":"json"}|} ()
  in
  let api_read = Github.Api.of_http ~token:"jwt" http_read in
  match Github.App.Hook.current_url api_read with
  | Ok url ->
      equal string ~msg:"the config read's url"
        "https://h.example.com/hooks/i" url
  | Error message -> failf "current_url: %s" message

let unauthenticated_conversion () =
  let sent, http = recording ~status:201 ~body:{|{"id":1,"slug":"s","name":"n","client_id":"c","html_url":"h","webhook_secret":"w","pem":"p"}|} () in
  let api = Github.Api.of_http http in
  (match Github.App.Conversion.exchange api ~code:"one-shot-code" with
  | Ok conversion ->
      equal int ~msg:"the conversion decodes" 1
        conversion.Github.App.Conversion.app_id
  | Error message -> failf "exchange: %s" message);
  let _, url, headers, _ = last sent in
  equal string ~msg:"the conversion path carries the code"
    "https://api.github.com/app-manifests/one-shot-code/conversions" url;
  is_true ~msg:"the conversion sends no authorization header at all"
    (not (List.exists (fun (k, _) -> String.equal k "authorization") headers));
  match Github.App.Conversion.exchange api ~code:"../evil" with
  | Ok _ -> fail "a path-mangling code must refuse"
  | Error message ->
      is_true ~msg:"the refusal names the code"
        (String.equal message "malformed conversion code")

let app_identity_reads () =
  let sent, http = recording ~body:{|{"slug":"bot","name":"Bot"}|} () in
  let api = Github.Api.of_http ~token:"jwt" http in
  (match Github.App.identity api with
  | Ok (slug, name) ->
      equal string ~msg:"slug" "bot" slug;
      equal string ~msg:"name" "Bot" name
  | Error message -> failf "identity: %s" message);
  let _, url, _, _ = last sent in
  equal string ~msg:"identity reads /app" "https://api.github.com/app" url;
  let _, http =
    recording
      ~body:
        {|[{"id":7,"account":{"login":"acme"}},{"id":8,"account":{"login":"o"}},{"no_id":true}]|}
      ()
  in
  let api = Github.Api.of_http ~token:"jwt" http in
  match Github.App.installations api with
  | Ok rows ->
      equal
        (list (pair int string))
        ~msg:"installation rows, rows missing members passed over"
        [ (7, "acme"); (8, "o") ]
        rows
  | Error message -> failf "installations: %s" message

(* The pull-request reads. *)

let reads_current_head () =
  let _, http =
    scripted [ reply 200 {|{"head":{"sha":"abc123"},"number":7}|} ]
  in
  let api = Github.Api.of_http ~token:"t" http in
  (match Github.Reads.current_head api ~repo:"acme/widgets" ~number:7 with
  | Ok sha -> equal string ~msg:"the head sha" "abc123" sha
  | Error message -> failf "current_head: %s" message);
  let _, http = scripted [ reply 200 {|{"number":7}|} ] in
  let api = Github.Api.of_http ~token:"t" http in
  match Github.Reads.current_head api ~repo:"acme/widgets" ~number:7 with
  | Ok _ -> fail "an answer without head.sha must refuse"
  | Error message -> contains ~msg:"the refusal names the member"
      ~sub:"head.sha" message

let reads_open_prs () =
  let listing =
    {|[{"number":1,"head":{"sha":"a"},"base":{"ref":"main"},"draft":false,"author_association":"OWNER"},
       {"number":2,"head":{"sha":"b"},"base":{"ref":"main"},"draft":true,"author_association":"MEMBER"},
       {"number":3,"head":{"sha":"c"},"base":{"ref":"main"},"draft":false}]|}
  in
  let calls, http = scripted [ reply 200 listing ] in
  let api = Github.Api.of_http ~token:"t" http in
  (match Github.Reads.open_prs api ~repo:"acme/widgets" with
  | Ok rows ->
      equal (list int) ~msg:"rows missing a gated member are passed over"
        [ 1; 2 ]
        (List.map
           (fun (pr : Github.Reads.Open_pr.t) -> pr.Github.Reads.Open_pr.number)
           rows);
      equal (list bool) ~msg:"draft flags survive" [ false; true ]
        (List.map
           (fun (pr : Github.Reads.Open_pr.t) -> pr.Github.Reads.Open_pr.draft)
           rows)
  | Error message -> failf "open_prs: %s" message);
  match !calls with
  | [ call ] ->
      equal string ~msg:"the listing path"
        "https://api.github.com/repos/acme/widgets/pulls?state=open&per_page=100"
        call.url
  | _ -> fail "expected one request"

let reads_posted () =
  let review_comments =
    {|[{"id":1,"body":"marked one","user":{"login":"bot"}},
       {"id":2,"body":"unmarked","user":{"login":"bot"}},
       {"id":3,"body":"marked forged","user":{"login":"someone-else"}}]|}
  in
  let issue_comments =
    {|[{"id":4,"body":"marked two","user":{"login":"bot"}}]|}
  in
  let _, http =
    scripted [ reply 200 review_comments; reply 200 issue_comments ]
  in
  let api = Github.Api.of_http ~token:"t" http in
  let marked body = String.length body >= 6 && String.sub body 0 6 = "marked" in
  match
    Github.Reads.posted api ~login:"bot" ~marked ~repo:"acme/widgets"
      ~number:7
  with
  | Ok bytes ->
      (* Ours = author is the login AND the body predicate holds: the
         unmarked own comment and the marked foreign comment both drop. *)
      equal string ~msg:"the encoded upsert input"
        {|[{"id":1,"body":"marked one"},{"id":4,"body":"marked two"}]|}
        bytes
  | Error message -> failf "posted: %s" message

let reads_viewer_login () =
  let _, http = scripted [ reply 200 {|{"login":"octocat"}|} ] in
  let api = Github.Api.of_http ~token:"t" http in
  match Github.Reads.viewer_login api with
  | Ok login -> equal string ~msg:"the credential's login" "octocat" login
  | Error message -> failf "viewer_login: %s" message

(* Webhook verification. *)

let webhook_verification () =
  (* RFC 4231 test case 2: HMAC-SHA256("Jefe", "what do ya want for
     nothing?"). *)
  let secret = "Jefe" in
  let body = "what do ya want for nothing?" in
  let digest =
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
  in
  is_true ~msg:"the RFC 4231 vector verifies"
    (Github.Webhook.verify ~secret ~signature:("sha256=" ^ digest) ~body);
  is_true ~msg:"uppercase hex verifies"
    (Github.Webhook.verify ~secret
       ~signature:("sha256=" ^ String.uppercase_ascii digest)
       ~body);
  is_false ~msg:"a mismatched digest refuses"
    (Github.Webhook.verify ~secret
       ~signature:
         "sha256=0000000000000000000000000000000000000000000000000000000000000000"
       ~body);
  is_false ~msg:"a wrong secret refuses"
    (Github.Webhook.verify ~secret:"jefe" ~signature:("sha256=" ^ digest)
       ~body);
  is_false ~msg:"a changed body refuses"
    (Github.Webhook.verify ~secret ~signature:("sha256=" ^ digest)
       ~body:(body ^ " "));
  is_false ~msg:"a missing prefix refuses"
    (Github.Webhook.verify ~secret ~signature:digest ~body);
  is_false ~msg:"the SHA-1 prefix refuses"
    (Github.Webhook.verify ~secret ~signature:("sha1=" ^ digest) ~body);
  is_false ~msg:"whitespace in the hex refuses"
    (Github.Webhook.verify ~secret
       ~signature:("sha256= " ^ String.sub digest 0 63)
       ~body);
  is_false ~msg:"odd-length hex refuses"
    (Github.Webhook.verify ~secret
       ~signature:("sha256=" ^ String.sub digest 0 63)
       ~body);
  is_false ~msg:"a truncated digest refuses"
    (Github.Webhook.verify ~secret
       ~signature:("sha256=" ^ String.sub digest 0 62)
       ~body);
  is_false ~msg:"an empty signature refuses"
    (Github.Webhook.verify ~secret ~signature:"" ~body)

(* Suite. *)

let () =
  run "github"
    [
      test "get builds the authorized request" get_builds_the_request;
      test "the user agent is the caller's" user_agent_is_the_callers;
      test "base URLs drop trailing slashes" base_url_strips_trailing_slashes;
      test "relative paths and non-positive page bounds raise"
        paths_must_be_absolute;
      test "post and patch send JSON and decode the reply"
        write_sends_json_and_decodes;
      test "a non-2xx answer is a response error with a safe excerpt"
        non_2xx_is_a_response_error;
      test "response excerpts are truncated" response_excerpt_is_truncated;
      test "a 2xx body that is not JSON is a transport error"
        non_json_success_is_a_transport_error;
      test "response bodies over the bound are refused"
        bodies_over_the_bound_are_refused;
      test "pagination follows rel=next in order" pagination_follows_rel_next;
      test "the Link grammar survives commas, quoting, and case"
        pagination_link_grammar;
      test "pagination errors past max_pages"
        pagination_stops_loudly_at_max_pages;
      test "pagination never leaves the API origin"
        pagination_refuses_to_leave_the_origin;
      test "transport errors pass through the closure"
        transport_errors_pass_through;
      test "the pinned RS256 vector" jwt_vector;
      test "jwt refusals and constants" jwt_refusals;
      test "manifest documents" manifest_documents;
      test "conversion decode" conversion_decode;
      test "narrowed mints" mints;
      test "hook-config projection" hook_projection;
      test "unauthenticated conversion" unauthenticated_conversion;
      test "app identity and installations" app_identity_reads;
      test "the pull request's current head" reads_current_head;
      test "the open-PR listing's typed rows" reads_open_prs;
      test "posted comments are the author's and marked" reads_posted;
      test "the credential's own login" reads_viewer_login;
      test "webhook signature verification" webhook_verification;
    ]
