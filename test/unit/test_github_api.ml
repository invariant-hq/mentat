(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Github_api], the bounded GitHub REST client. The HTTP
   effect is one injected closure, so every test scripts the replies and
   inspects the recorded requests — header and URL construction, the response
   body bound, status classification, and Link-header pagination all run with
   no network. The production requester [make] wires (TLS, one connection per
   request) is exercised by the github crams, not here.

   The module lives in the private [mentat_github] library under
   [bin/github/], linked directly. *)

open Windtrap
open Mentat_github

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
  Ok { Github_api.status; headers; body }

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
  match Github_api.Error.kind error with
  | Github_api.Error.Response { status; _ } -> Printf.sprintf "response %d" status
  | Github_api.Error.Transport _ -> "transport"

let get_builds_the_request () =
  let calls, http = scripted [ reply 200 {|{"ok":true}|} ] in
  let t = Github_api.of_http ~token:"tok-123" http in
  let body = require_ok ~pp_error:Github_api.Error.pp (Github_api.get t ~path:"/repos/acme/widgets/pulls/7") in
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
        (Some Github_api.api_version)
        (header "x-github-api-version" call);
      equal (option string) ~msg:"user agent" (Some "mentat")
        (header "user-agent" call);
      is_none ~msg:"no content type on a read" (header "content-type" call);
      is_none ~msg:"no body on a read" call.body
  | calls -> failf "expected one request, got %d" (List.length calls)

let base_url_strips_trailing_slashes () =
  let calls, http = scripted [ reply 200 "{}" ] in
  let t = Github_api.of_http ~base_url:"http://127.0.0.1:8080/" ~token:"t" http in
  let _ = require_ok ~pp_error:Github_api.Error.pp (Github_api.get t ~path:"/x") in
  match !calls with
  | [ call ] -> equal string "http://127.0.0.1:8080/x" call.url
  | _ -> fail "expected one request"

let paths_must_be_absolute () =
  let _, http = scripted [] in
  let t = Github_api.of_http ~token:"t" http in
  raises_match (Exn.invalid_arg ~substring:"start with '/'") (fun () ->
      Github_api.get t ~path:"repos/acme/widgets");
  raises_match (Exn.invalid_arg ~substring:"max_pages") (fun () ->
      Github_api.get_paginated t ~path:"/x" ~max_pages:0)

let write_sends_json_and_decodes () =
  let calls, http =
    scripted [ reply 201 {|{"id":42}|}; reply 204 "" ] in
  let t = Github_api.of_http ~token:"t" http in
  let status, created =
    require_ok ~pp_error:Github_api.Error.pp
      (Github_api.post t ~path:"/repos/a/b/pulls/1/comments"
         ~body:(json {|{"body":"hi"}|}))
  in
  equal int ~msg:"created status" 201 status;
  equal string ~msg:"decoded reply body" {|{"id":42}|}
    (encode (require_some created));
  let status, no_body =
    require_ok ~pp_error:Github_api.Error.pp
      (Github_api.patch t ~path:"/repos/a/b/issues/comments/9"
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
  let t = Github_api.of_http ~token:"t" http in
  let error =
    require_error (Github_api.post t ~path:"/repos/a/b/pulls/1/comments"
                     ~body:(json "{}"))
  in
  match Github_api.Error.kind error with
  | Github_api.Error.Response { status; body } ->
      equal int ~msg:"status" 422 status;
      (* The excerpt is one printable-ASCII line: the control byte and the
         newline arrive as spaces. *)
      equal string ~msg:"sanitized excerpt"
        "{\"message\":\"Validation  Failed\"}" body;
      contains ~msg:"message names the status" ~sub:"422"
        (Github_api.Error.message error)
  | _ -> failf "expected a response error, got %s" (kind_name error)

let response_excerpt_is_truncated () =
  let _, http = scripted [ reply 500 (String.make 5000 'x') ] in
  let t = Github_api.of_http ~token:"t" http in
  let error = require_error (Github_api.get t ~path:"/x") in
  match Github_api.Error.kind error with
  | Github_api.Error.Response { body; _ } ->
      equal int ~msg:"excerpt bound" 400 (String.length body)
  | _ -> failf "expected a response error, got %s" (kind_name error)

let non_json_success_is_a_transport_error () =
  let _, http = scripted [ reply 200 "not json" ] in
  let t = Github_api.of_http ~token:"t" http in
  let error = require_error (Github_api.get t ~path:"/x") in
  match Github_api.Error.kind error with
  | Github_api.Error.Transport reason ->
      contains ~msg:"reason names the decode" ~sub:"not JSON" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error)

let bodies_over_the_bound_are_refused () =
  let over = "\"" ^ String.make Github_api.max_body_bytes 'a' ^ "\"" in
  let at = "\"" ^ String.make (Github_api.max_body_bytes - 2) 'a' ^ "\"" in
  let _, http = scripted [ reply 200 over ] in
  let t = Github_api.of_http ~token:"t" http in
  let error = require_error (Github_api.get t ~path:"/x") in
  (match Github_api.Error.kind error with
  | Github_api.Error.Transport reason ->
      contains ~msg:"reason names the bound" ~sub:"exceeds" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error));
  let _, http = scripted [ reply 200 at ] in
  let t = Github_api.of_http ~token:"t" http in
  is_true ~msg:"a body at the bound passes"
    (Result.is_ok (Github_api.get t ~path:"/x"))

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
  let t = Github_api.of_http ~token:"t" http in
  let pages =
    require_ok ~pp_error:Github_api.Error.pp
      (Github_api.get_paginated t ~path:"/repos/a/b/pulls" ~max_pages:5)
  in
  equal (list string) ~msg:"pages in request order" [ "[1]"; "[2]" ]
    (List.map encode pages);
  equal (list string) ~msg:"the next target is requested as served"
    [
      base ^ "/repos/a/b/pulls";
      base ^ "/repos/a/b/pulls?page=2";
    ]
    (List.rev_map (fun (call : call) -> call.url) !calls)

let pagination_stops_loudly_at_max_pages () =
  let next = [ ("Link", "<https://api.github.com/x?page=2>; rel=\"next\"") ] in
  let calls, http =
    scripted [ reply ~headers:next 200 "[]"; reply ~headers:next 200 "[]" ]
  in
  let t = Github_api.of_http ~token:"t" http in
  let error =
    require_error (Github_api.get_paginated t ~path:"/x" ~max_pages:2)
  in
  equal int ~msg:"exactly max_pages requests were sent" 2 (List.length !calls);
  match Github_api.Error.kind error with
  | Github_api.Error.Transport reason ->
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
  let t = Github_api.of_http ~token:"t" http in
  let error =
    require_error (Github_api.get_paginated t ~path:"/x" ~max_pages:5)
  in
  equal int ~msg:"no request follows the foreign link" 1 (List.length !calls);
  match Github_api.Error.kind error with
  | Github_api.Error.Transport reason ->
      contains ~msg:"reason names the origin" ~sub:"origin" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error)

let transport_errors_pass_through () =
  let _, http =
    scripted [ Error (Github_api.Error.transport "connection refused") ]
  in
  let t = Github_api.of_http ~token:"t" http in
  let error = require_error (Github_api.get t ~path:"/x") in
  (match Github_api.Error.kind error with
  | Github_api.Error.Transport reason ->
      equal string "connection refused" reason
  | _ -> failf "expected a transport error, got %s" (kind_name error));
  equal string ~msg:"transport messages pass through verbatim"
    "connection refused"
    (Github_api.Error.message error)

(* Suite. *)

let () =
  run "mentat.github_api"
    [
      test "get builds the authorized request" get_builds_the_request;
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
      test "pagination errors past max_pages"
        pagination_stops_loudly_at_max_pages;
      test "pagination never leaves the API origin"
        pagination_refuses_to_leave_the_origin;
      test "transport errors pass through the closure"
        transport_errors_pass_through;
    ]
