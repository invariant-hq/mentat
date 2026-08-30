(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Http = Mentat_llm_http

let float_value = Testable.make ~pp:Format.pp_print_float ~equal:Float.equal

let retry_guidance () =
  let after headers = Http.Retry_after.delay ~now:784_111_777. headers in
  equal (option float_value) ~msg:"retry-after-ms wins" (Some 1.5)
    (after [ ("Retry-After-Ms", "1500"); ("retry-after", "9") ]);
  equal (option float_value) ~msg:"numeric seconds" (Some 9.)
    (after [ ("Retry-After", "9") ]);
  equal (option float_value) ~msg:"IMF-fixdate relative to now" (Some 23.)
    (after [ ("retry-after", "Sun, 06 Nov 1994 08:50:00 GMT") ]);
  equal (option float_value) ~msg:"past dates clamp to zero" (Some 0.)
    (after [ ("retry-after", "Sun, 06 Nov 1994 08:00:00 GMT") ]);
  equal (option float_value) ~msg:"garbage is ignored" None
    (after [ ("retry-after", "soon") ]);
  equal (option float_value) ~msg:"absent header" None (after [])

let transport_messages () =
  let render = Http.transport_message in
  let net err = Eio.Net.err err in
  let refused =
    net
      (Eio.Net.Connection_failure
         (Eio.Net.Refused
            (Eio_unix.Unix_error (Unix.ECONNREFUSED, "connect", ""))))
  in
  (* The exact clean phrase — proving the raw [Eio.Io (Net (Connection_failure
     …))] dump (RUN-02) never reaches the message. *)
  equal string ~msg:"connection refused" "connection refused" (render refused);
  equal string ~msg:"host resolution" "could not resolve host"
    (render
       (net (Eio.Net.Address_lookup_failed Eio.Net.Getaddrinfo_error.NONAME)));
  equal string ~msg:"connect timeout" "connection timed out"
    (render (net (Eio.Net.Connection_failure Eio.Net.Timeout)));
  equal string ~msg:"connection reset" "connection reset"
    (render
       (net
          (Eio.Net.Connection_reset
             (Eio_unix.Unix_error (Unix.ECONNRESET, "read", "")))));
  (* An unknown exception degrades to a trimmed representation rather than
     raising or emitting a network blob. *)
  equal string ~msg:"unknown exn" "Failure(\"boom\")" (render (Failure "boom"))

let sse_framing () =
  let source =
    Eio.Flow.string_source
      "event: delta\ndata: first\ndata: second\n\n: keep-alive\n\ndata: last"
  in
  let reader = Http.Sse.make (source :> Eio.Flow.source_ty Eio.Std.r) in
  let event msg =
    match Http.Sse.next reader with
    | None -> fail (msg ^ ": expected an event")
    | Some (Error message) -> fail (msg ^ ": " ^ message)
    | Some (Ok event) -> event
  in
  let first = event "first event" in
  equal string ~msg:"event name" "delta" first.Http.Sse.name;
  equal string ~msg:"multiline data" "first\nsecond" first.Http.Sse.data;
  let last = event "event at EOF" in
  equal string ~msg:"missing event name" "" last.Http.Sse.name;
  equal string ~msg:"EOF flushes data" "last" last.Http.Sse.data;
  equal (option pass) ~msg:"EOF is stable" None (Http.Sse.next reader)

(* The reader owns the shared exception policy: a read failure surfaces as the
   concise transport rendering rather than raising, and close drains the pull.
   Cancellation stays an exception; that path needs a live fiber and is not
   exercised here. *)
let sse_read_failures_are_trapped () =
  Eio_mock.Backend.run @@ fun () ->
  let flow = Eio_mock.Flow.make "sse" in
  Eio_mock.Flow.on_read flow
    [ `Return "data: one\n\n"; `Raise (Failure "boom") ];
  let reader = Http.Sse.make (flow :> Eio.Flow.source_ty Eio.Std.r) in
  (match Http.Sse.next reader with
  | Some (Ok event) ->
      equal string ~msg:"event before the fault" "one" event.Http.Sse.data
  | Some (Error _) | None -> fail "expected the first event");
  (match Http.Sse.next reader with
  | Some (Error message) ->
      equal string ~msg:"trapped transport rendering" "Failure(\"boom\")"
        message
  | Some (Ok _) | None -> fail "expected a trapped read failure");
  Http.Sse.close reader;
  Http.Sse.close reader;
  equal (option pass) ~msg:"closed reader is drained" None
    (Http.Sse.next reader)

(* The direct Retry tests drive the shared loop against test-supplied thunks
   under a mock backend, so the backoff sleeps advance the auto-advancing clock
   instead of the wall clock. This pins the retry budget, backoff, and
   suppression policy once, without a per-provider loopback server. *)

let http_failure ?(headers = []) status : (unit, Http.error) result =
  Error (Http.Response { Http.status; headers; body = "{}" })

(* Capacity statuses ([429], [503], [529]) deepen the budget to ten and a plain
   server fault ([500], …) to eight even when the caller asked for a single
   retry, so the loop outlasts an overload window. The announced reason is the
   status's human phrase. Both floors and the reason mapping live in Retry, so
   one test pins them without a provider. *)
let retry_budget_floors () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let exhausts status ~expected_calls ~expected_limit ~expected_reason =
    let calls = ref 0 and announced = ref [] in
    let result =
      Http.Retry.pre_stream ~clock ~max_retries:1
        ~on_retry:(fun ~attempt ~limit ~delay:_ ~reason ->
          announced := (attempt, limit, reason) :: !announced)
        (fun ~attempt:_ ->
          incr calls;
          http_failure status)
    in
    (match result with
    | Error (Http.Response response) ->
        equal int ~msg:"exhausted status surfaces" status response.Http.status
    | _ -> fail "expected the exhausted response to surface");
    equal int ~msg:"attempt_post invocations" expected_calls !calls;
    let announced = List.rev !announced in
    equal int ~msg:"retry announcements" expected_limit (List.length announced);
    equal (list int) ~msg:"attempts count up from one"
      (List.init expected_limit (fun n -> n + 1))
      (List.map (fun (attempt, _, _) -> attempt) announced);
    List.iter
      (fun (_, limit, reason) ->
        equal int ~msg:"announced limit is the budget" expected_limit limit;
        equal string ~msg:"announced reason" expected_reason reason)
      announced
  in
  exhausts 429 ~expected_calls:11 ~expected_limit:10
    ~expected_reason:"rate limited";
  exhausts 503 ~expected_calls:11 ~expected_limit:10
    ~expected_reason:"provider overloaded";
  exhausts 500 ~expected_calls:9 ~expected_limit:8
    ~expected_reason:"provider error"

(* [408] and [409] are retryable but neither capacity nor server-fault, so their
   budget is the caller's [max_retries] verbatim — no deepening — and each keeps
   its own announced reason. *)
let retry_passes_through_max_retries () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let check_status status ~expected_reason =
    let calls = ref 0 and announced = ref [] in
    let _ =
      Http.Retry.pre_stream ~clock ~max_retries:3
        ~on_retry:(fun ~attempt:_ ~limit ~delay:_ ~reason ->
          announced := (limit, reason) :: !announced)
        (fun ~attempt:_ ->
          incr calls;
          http_failure status)
    in
    equal int ~msg:"attempts are max_retries + 1" 4 !calls;
    equal int ~msg:"retry announcements" 3 (List.length !announced);
    List.iter
      (fun (limit, reason) ->
        equal int ~msg:"announced limit is max_retries" 3 limit;
        equal string ~msg:"announced reason" expected_reason reason)
      !announced
  in
  check_status 408 ~expected_reason:"provider timed out";
  check_status 409 ~expected_reason:"provider error"

(* Backoff starts at half a second and grows by a factor of 1.5 each attempt,
   spread by a tenth either way. With no server delay the announced sleep is that
   jittered backoff, so each delay lands in [0.9, 1.1] x 0.5 x 1.5^n. *)
let retry_backoff_grows_by_one_and_a_half () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let delays = ref [] in
  let _ =
    Http.Retry.pre_stream ~clock ~max_retries:8
      ~on_retry:(fun ~attempt:_ ~limit:_ ~delay ~reason:_ ->
        delays := delay :: !delays)
      (fun ~attempt:_ -> http_failure 500)
  in
  let delays = List.rev !delays in
  equal int ~msg:"eight backoff announcements" 8 (List.length delays);
  List.iteri
    (fun n delay ->
      let base = 0.5 *. (1.5 ** float_of_int n) in
      is_true
        ~msg:(Printf.sprintf "delay %d within lower jitter band" n)
        (delay >= (base *. 0.9) -. 1e-9);
      is_true
        ~msg:(Printf.sprintf "delay %d within upper jitter band" n)
        (delay <= (base *. 1.1) +. 1e-9))
    delays

(* A transport-layer failure carries no status to classify, so it retries on the
   plain [max_retries] with no deepening and surfaces once the budget is spent. *)
let retry_transport_errors () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let calls = ref 0 and retries = ref 0 in
  let result =
    Http.Retry.pre_stream ~clock ~max_retries:2
      ~on_retry:(fun ~attempt:_ ~limit ~delay:_ ~reason ->
        incr retries;
        equal int ~msg:"transport limit is max_retries" 2 limit;
        equal string ~msg:"transport reason" "connection failed" reason)
      (fun ~attempt:_ ->
        incr calls;
        (Error (Http.Transport "connection reset") : (unit, Http.error) result))
  in
  (match result with
  | Error (Http.Transport message) ->
      equal string ~msg:"surfaced transport message" "connection reset" message
  | _ -> fail "expected the transport error to surface");
  equal int ~msg:"transport attempts are max_retries + 1" 3 !calls;
  equal int ~msg:"transport retry announcements" 2 !retries

(* Which resolver failures are permanent. A name the resolver rejects — no such
   name, or a name carrying no address — answers identically however often it is
   asked; a resolver that is merely unwell may not, so it keeps its retry. *)
let resolution_failures_are_classified () =
  let net err = Eio.Net.err err in
  let lookup code =
    Http.error_of_exn (net (Eio.Net.Address_lookup_failed code))
  in
  let permanent code =
    match lookup code with
    | Http.Unresolved_host message ->
        equal string ~msg:"permanent lookup keeps the clean phrase"
          "could not resolve host" message
    | Http.Transport _ | Http.Response _ ->
        fail "expected a permanent resolution failure"
  in
  let transient code =
    match lookup code with
    | Http.Transport _ -> ()
    | Http.Unresolved_host _ | Http.Response _ ->
        fail "expected a retryable resolution failure"
  in
  permanent Eio.Net.Getaddrinfo_error.NONAME;
  permanent Eio.Net.Getaddrinfo_error.NODATA;
  transient Eio.Net.Getaddrinfo_error.AGAIN;
  transient Eio.Net.Getaddrinfo_error.FAIL;
  (* A failure that is not a lookup at all stays retryable. *)
  match Http.error_of_exn (Failure "boom") with
  | Http.Transport message ->
      equal string ~msg:"unknown exn keeps its trimmed repr" "Failure(\"boom\")"
        message
  | Http.Unresolved_host _ | Http.Response _ ->
      fail "expected an unclassified failure to stay retryable"

(* A host with no address surfaces on its first attempt: the budget a transport
   fault earns would only be spent as backoff before the same answer. *)
let unresolved_host_fails_fast () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let calls = ref 0 and retries = ref 0 in
  let result =
    Http.Retry.pre_stream ~clock ~max_retries:2
      ~on_retry:(fun ~attempt:_ ~limit:_ ~delay:_ ~reason:_ -> incr retries)
      (fun ~attempt:_ ->
        incr calls;
        (Error (Http.Unresolved_host "could not resolve host")
          : (unit, Http.error) result))
  in
  (match result with
  | Error (Http.Unresolved_host message) ->
      equal string ~msg:"surfaced resolution message" "could not resolve host"
        message
  | _ -> fail "expected the unresolved host to surface");
  equal int ~msg:"an unresolved host is attempted once" 1 !calls;
  equal int ~msg:"an unresolved host announces no retry" 0 !retries

(* Server guidance outranks the status table. An explicit [x-should-retry]
   header rules in both directions — [false] fails fast on a retryable status,
   [true] retries a status the table would surface — and a [Retry-After] beyond
   the sixty-second bound fails at once rather than re-issuing early into a
   promised refusal, while one within the bound floors the announced delay
   exactly. *)
let retry_follows_server_guidance () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let exhaust ?headers status ~max_retries =
    let calls = ref 0 and retries = ref 0 in
    let result =
      Http.Retry.pre_stream ~clock ~max_retries
        ~on_retry:(fun ~attempt:_ ~limit:_ ~delay:_ ~reason:_ -> incr retries)
        (fun ~attempt:_ ->
          incr calls;
          http_failure ?headers status)
    in
    (result, !calls, !retries)
  in
  let _, calls, retries =
    exhaust 500 ~max_retries:2
      ~headers:[ ("X-Should-Retry", "FALSE") ]
  in
  equal int ~msg:"explicit false is attempted once" 1 calls;
  equal int ~msg:"explicit false announces no retry" 0 retries;
  let _, calls, retries =
    exhaust 400 ~max_retries:1 ~headers:[ ("x-should-retry", "true") ]
  in
  equal int ~msg:"explicit true retries a terminal status" 2 calls;
  equal int ~msg:"explicit true announces the retry" 1 retries;
  let result, calls, retries =
    exhaust 429 ~max_retries:1 ~headers:[ ("retry-after", "300") ]
  in
  (match result with
  | Error (Http.Response response) ->
      equal int ~msg:"the over-bound response surfaces" 429 response.Http.status
  | _ -> fail "expected the over-bound response to surface");
  equal int ~msg:"an over-bound delay is attempted once" 1 calls;
  equal int ~msg:"an over-bound delay announces no retry" 0 retries;
  let delays = ref [] in
  let result =
    Http.Retry.pre_stream ~clock ~max_retries:1
      ~on_retry:(fun ~attempt:_ ~limit:_ ~delay ~reason:_ ->
        delays := delay :: !delays)
      (fun ~attempt ->
        if attempt = 0 then http_failure 429 ~headers:[ ("retry-after", "30") ]
        else Ok ())
  in
  (match result with
  | Ok () -> ()
  | Error _ -> fail "expected the in-bound retry to succeed");
  equal (list float_value) ~msg:"an in-bound delay floors the backoff exactly"
    [ 30. ] !delays

(* A stream re-run is safe only before any assistant output reaches the caller:
   replaying over already-streamed text would double it. A retryable stream fault
   before output re-runs up to the budget; the same fault after a delta surfaces
   at once. *)
let stream_reruns_only_before_output () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let transient =
    Mentat_llm.Error.make ~kind:Mentat_llm.Error.Provider "boom"
  in
  let run_stream ~consume =
    let opens = ref 0 in
    let result =
      Http.Retry.stream ~clock
        ~cancelled:(fun () -> false)
        ~max_retries:2
        ~on_event:(fun _ -> ())
        ~open_stream:(fun ~on_retry:_ ->
          incr opens;
          Ok ())
        ~consume
    in
    (!opens, result)
  in
  let opens, result =
    run_stream ~consume:(fun ~on_event:_ () -> Error transient)
  in
  (match result with
  | Error error ->
      is_true ~msg:"budget exhausted surfaces the fault"
        (Mentat_llm.Error.equal error transient)
  | Ok () -> fail "expected the exhausted stream fault to surface");
  equal int ~msg:"opened three times before the budget is spent" 3 opens;
  let opens, result =
    run_stream ~consume:(fun ~on_event () ->
        on_event (Mentat_llm.Event.text_delta "partial");
        Error transient)
  in
  (match result with
  | Error error ->
      is_true ~msg:"the fault surfaces without a re-run"
        (Mentat_llm.Error.equal error transient)
  | Ok () -> fail "expected the surfaced stream fault");
  equal int ~msg:"no re-run once a delta has reached the caller" 1 opens

let () =
  run "mentat.llm.http"
    [
      test "parse server retry guidance" retry_guidance;
      test "render clean transport messages" transport_messages;
      test "frame SSE events" sse_framing;
      test "trap SSE read failures" sse_read_failures_are_trapped;
      test "retry budget floors" retry_budget_floors;
      test "retry passes through max retries" retry_passes_through_max_retries;
      test "retry backoff grows by one and a half"
        retry_backoff_grows_by_one_and_a_half;
      test "retry transport errors" retry_transport_errors;
      test "classify resolution failures" resolution_failures_are_classified;
      test "unresolved host fails fast" unresolved_host_fails_fast;
      test "retry follows server guidance" retry_follows_server_guidance;
      test "stream re-runs only before output" stream_reruns_only_before_output;
    ]
